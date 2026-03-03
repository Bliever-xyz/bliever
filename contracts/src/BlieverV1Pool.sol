// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN — UPGRADEABLE
//////////////////////////////////////////////////////////////*/
import {Initializable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}          from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable}         from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable}       from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable}   from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20FlashMintUpgradeable}from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20FlashMintUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}      from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN — STANDARD
//////////////////////////////////////////////////////////////*/
import {IERC20}    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math}      from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  BlieverV1Pool — Global LS-LMSR Liquidity Vault
/// @author Believer Protocol
/// @notice Single USDC vault that acts as the Automated Market Maker for every
///         Believer prediction market simultaneously.
///
///         Architecture overview
///         ─────────────────────
///         • Every real USDC lives here. Market contracts are pure math wrappers.
///         • LPs deposit USDC → receive bLP shares (ERC-4626, 18 dec).
///         • When a market is registered, `maxRiskPerMarket` USDC is reserved
///           from LP capital as the worst-case loss guarantee (= C(q⁰) = R).
///         • Market contracts (MARKET_ROLE) call `collectTradeCost` to pull
///           trader USDC into the vault and `settleMarket` + `claimWinnings`
///           to distribute payouts on resolution.
///         • LP withdrawal is capped to `totalAssets − totalLiability` so
///           reserved capital can never be drained below the guarantee.
///
///         LS-LMSR loss bound (Proposition 4.9 + Lemma 4.5)
///         ─────────────────────────────────────────────────
///         Loss per market ≤ C(q⁰) = R = maxRiskPerMarket, always.
///         totalLiability = Σ R_i across all active markets.
///
///         Token: bLP (Believer Liquidity Provider)
///         Underlying: USDC (6-decimal, Base-chain canonical)
///         Upgradeability: UUPS proxy (ERC-1822)
///
/// @dev    Inheritance stack resolves via C3 linearisation.
///         Storage layout must NEVER change in upgrades (append-only, __gap).
///         All USDC transfers use SafeERC20.
contract BlieverV1Pool is
    Initializable,
    ERC4626Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20FlashMintUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math      for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Allowed to register / deregister markets
    bytes32 public constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");

    /// @notice Granted to each registered market contract.
    ///         Required to call collectTradeCost, settleMarket, claimWinnings.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    /// @notice Allowed to pause / unpause the vault
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Allowed to authorise UUPS implementation upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Denominator for basis-point calculations (100 % = 10 000)
    uint256 public constant BPS_BASE = 10_000;

    /// @notice Hard upper bound on flash-loan fee (10 %)
    uint16  public constant MAX_FLASH_FEE_BPS = 1_000;

    /// @notice Hard upper bound on allocation cap parameter
    uint16  public constant MAX_ALLOCATION_BPS = 10_000;

    /// @notice Maximum simultaneously active prediction markets
    uint256 public constant MAX_ACTIVE_MARKETS = 10_000;

    /// @notice Minimum valid alpha (prevents division-by-zero in LS-LMSR)
    uint256 public constant MIN_ALPHA = 1e12;

    /// @notice Maximum valid alpha (20 % spread ceiling)
    uint256 public constant MAX_ALPHA = 2e17;

    /// @notice bLP token decimals = USDC decimals (6) + DECIMALS_OFFSET (12) = 18
    /// @dev    ERC-4626 virtual-share offset also acts as inflation-attack protection.
    uint8   internal constant DECIMALS_OFFSET = 12;

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Complete accounting record for one prediction market
    /// @dev    Slot-0 packs: bool(1) + bool(1) + bool(1) + uint32(4) + uint64(8) = 14 bytes
    ///         Remaining slots hold uint256 values.
    struct MarketInfo {
        // ── slot 0 (14/32 bytes used) ──────────────────────────────
        bool     registered;      // true from registerMarket, false after delete
        bool     settled;         // true after settleMarket is called
        bool     hasTrades;       // true after first collectTradeCost call
        uint32   outcomeCount;    // number of mutually-exclusive outcomes (≥2)
        uint64   registeredAt;    // block.timestamp at registration
        // ── slot 1 ─────────────────────────────────────────────────
        uint256  riskBudget;      // = maxRiskPerMarket at registration; C(q⁰) = R
        // ── slot 2 ─────────────────────────────────────────────────
        uint256  currentLiability;// live worst-case loss = LSMath.calculateWorstCaseLoss(...)
                                  // starts = riskBudget; updated each trade; 0 after settle
        // ── slot 3 ─────────────────────────────────────────────────
        uint256  settledPayout;   // total USDC authorised for winners (set on settlement)
        // ── slot 4 ─────────────────────────────────────────────────
        uint256  claimedPayout;   // USDC already transferred to winners (cumulative)
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAlpha(uint256 value);
    error InvalidMaxRisk(uint256 value);
    error InvalidBps(uint16 bps);
    error InvalidOutcomeCount(uint32 count);
    error MarketAlreadyRegistered(address market);
    error MarketNotRegistered(address market);
    error MarketAlreadySettled(address market);
    error MarketNotSettled(address market);
    error MarketHasTrades(address market);
    error AllocationCapExceeded(uint256 projected, uint256 allowed);
    error InsufficientVaultLiquidity(uint256 available, uint256 required);
    error PayoutExceedsRiskBudget(uint256 payout, uint256 budget);
    error PayoutExceedsSettlement(uint256 requested, uint256 remaining);
    error NoFeesToCollect();
    error ExceedsMaxMarkets(uint256 active);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new market is registered and risk is reserved
    event MarketRegistered(
        address indexed market,
        uint32          outcomeCount,
        uint256         riskBudget
    );

    /// @notice Emitted when an unsettled, trade-free market is removed
    event MarketDeregistered(address indexed market);

    /// @notice Emitted when a market resolves and payout is finalised
    /// @param profit Vault gain = riskBudget − totalPayout (≥0 always)
    event MarketSettled(
        address indexed market,
        uint256         totalPayout,
        uint256         profit
    );

    /// @notice Emitted each time a trader's USDC is collected for a trade
    event TradeCostCollected(
        address indexed market,
        address indexed trader,
        uint256         cost,
        uint256         newCurrentLiability
    );

    /// @notice Emitted each time a winner claims USDC winnings
    event WinningsClaimed(
        address indexed market,
        address indexed winner,
        uint256         amount
    );

    /// @notice Emitted when protocol fees are swept to a recipient
    event ProtocolFeesCollected(address indexed to, uint256 amount);

    /// @notice Emitted when the global alpha parameter changes
    event AlphaUpdated(uint256 oldAlpha, uint256 newAlpha);

    /// @notice Emitted when the per-market risk budget changes
    event MaxRiskUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when the allocation cap changes
    event AllocationCapUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the flash-loan fee changes
    event FlashFeeBpsUpdated(uint16 oldBps, uint16 newBps);

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
                  (append-only; never reorder for upgrades)
    //////////////////////////////////////////////////////////////*/

    /// @notice LS-LMSR commission / spread parameter α (18-dec fixed-point)
    ///         e.g. 3e16 = 3 %. Affects all markets registered after any change.
    uint256 public alpha;

    /// @notice Maximum USDC loss the vault absorbs per market (6-dec USDC units)
    ///         Equals C(q⁰) for each market — the LS-LMSR worst-case bound.
    uint256 public maxRiskPerMarket;

    /// @notice Maximum fraction of vault TVL lockable as active-market liability (BPS)
    ///         e.g. 5000 = 50 %. registerMarket reverts if this would be breached.
    uint16  public maxAllocationBps;

    /// @notice Flash-loan fee on bLP FlashMint (BPS). 0 = free (default).
    ///         Fee tokens are burned (deflationary for remaining LPs).
    uint16  public flashFeeBps;

    /// @notice Sum of riskBudget across all currently active (non-settled) markets.
    ///         Represents the total USDC that must remain in the vault at all times.
    uint256 public totalLiability;

    /// @notice Accumulated USDC admin fees, excluded from LP totalAssets.
    ///         V1: always 0 (fee infrastructure present, rate default 0).
    uint256 public protocolFeesAccrued;

    /// @notice Active (non-settled) market count
    uint256 public activeMarketCount;

    /// @notice Per-market accounting keyed by market contract address
    mapping(address => MarketInfo) public markets;

    /// @notice Chronological list of all ever-registered market addresses
    address[] private _marketList;

    /// @dev Reserve 43 slots for future state variables without storage collisions.
    ///      43 = 50 recommended gap − 7 slots used above.
    uint256[43] private __gap;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Disables initializers on the logic contract so it cannot be
    ///      initialised independently (only the proxy should be initialised).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time proxy initialisation — replaces constructor for upgradeable contracts
    /// @dev    Caller becomes DEFAULT_ADMIN + MARKET_MANAGER + PAUSER + UPGRADER.
    ///         All OpenZeppelin init chains must be called explicitly.
    /// @param usdc               USDC ERC-20 address on Base (underlying asset)
    /// @param admin              Initial admin address (receives all privileged roles)
    /// @param _alpha             LS-LMSR α (18-dec, e.g. 3e16 for 3 %)
    /// @param _maxRiskPerMarket  Worst-case loss per market in raw USDC (6-dec, e.g. 1e6 = $1)
    /// @param _maxAllocationBps  Allocation cap in BPS (e.g. 5000 = 50 % of TVL)
    function initialize(
        address usdc,
        address admin,
        uint256 _alpha,
        uint256 _maxRiskPerMarket,
        uint16  _maxAllocationBps
    ) external initializer {
        // ── Input validation ────────────────────────────────────────────────
        if (usdc  == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (_alpha < MIN_ALPHA || _alpha > MAX_ALPHA)  revert InvalidAlpha(_alpha);
        if (_maxRiskPerMarket  == 0)                   revert InvalidMaxRisk(_maxRiskPerMarket);
        if (_maxAllocationBps == 0 || _maxAllocationBps > MAX_ALLOCATION_BPS)
            revert InvalidBps(_maxAllocationBps);

        // ── ERC-20 / ERC-4626 chain ─────────────────────────────────────────
        __ERC20_init("Believer LP", "bLP");
        __ERC4626_init(IERC20(usdc));
        __ERC20Burnable_init();
        __ERC20Permit_init("Believer LP");
        __ERC20FlashMint_init();

        // ── Security chain ──────────────────────────────────────────────────
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // ── Role grants ─────────────────────────────────────────────────────
        _grantRole(DEFAULT_ADMIN_ROLE,   admin);
        _grantRole(MARKET_MANAGER_ROLE,  admin);
        _grantRole(PAUSER_ROLE,          admin);
        _grantRole(UPGRADER_ROLE,        admin);

        // ── Protocol parameters ─────────────────────────────────────────────
        alpha              = _alpha;
        maxRiskPerMarket   = _maxRiskPerMarket;
        maxAllocationBps   = _maxAllocationBps;
        flashFeeBps        = 0; // off by default; enable via setFlashFeeBps
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a prediction market and reserve its LS-LMSR risk budget.
    ///
    ///         What happens internally
    ///         ───────────────────────
    ///         1. Validates address, outcome count, allocation cap.
    ///         2. Creates MarketInfo with riskBudget = maxRiskPerMarket.
    ///         3. Adds riskBudget to totalLiability (locks LP capital).
    ///         4. Grants MARKET_ROLE to the market contract address.
    ///         5. Appends market to the chronological _marketList.
    ///
    ///         Why currentLiability starts at riskBudget
    ///         ──────────────────────────────────────────
    ///         From the LS-LMSR initialisation: ε = R / (1 + α·n·ln n),
    ///         which ensures C(q⁰) = R exactly. So from block 0 the market
    ///         maker's worst-case loss is already R. We initialise
    ///         currentLiability = riskBudget = R to reflect this conservatively.
    ///
    /// @param market     Address of the market contract (must NOT be already registered)
    /// @param nOutcomes  Number of mutually exclusive outcomes (2–100 inclusive)
    function registerMarket(
        address market,
        uint32  nOutcomes
    ) external onlyRole(MARKET_MANAGER_ROLE) whenNotPaused {
        // ── Checks ──────────────────────────────────────────────────────────
        if (market   == address(0))          revert ZeroAddress();
        if (nOutcomes < 2 || nOutcomes > 100) revert InvalidOutcomeCount(nOutcomes);
        if (markets[market].registered)       revert MarketAlreadyRegistered(market);
        if (activeMarketCount >= MAX_ACTIVE_MARKETS) revert ExceedsMaxMarkets(activeMarketCount);

        uint256 risk            = maxRiskPerMarket;
        uint256 newTotalLiab    = totalLiability + risk;
        uint256 assets          = totalAssets();

        // Enforce allocation cap: projected total liability ≤ TVL × maxAllocationBps
        uint256 maxAllowed = (assets * maxAllocationBps) / BPS_BASE;
        if (newTotalLiab > maxAllowed) {
            revert AllocationCapExceeded(newTotalLiab, maxAllowed);
        }

        // ── Effects ─────────────────────────────────────────────────────────
        markets[market] = MarketInfo({
            registered:       true,
            settled:          false,
            hasTrades:        false,
            outcomeCount:     nOutcomes,
            registeredAt:     uint64(block.timestamp),
            riskBudget:       risk,
            currentLiability: risk,   // conservative: = C(q⁰) = R
            settledPayout:    0,
            claimedPayout:    0
        });

        totalLiability = newTotalLiab;

        unchecked {
            ++activeMarketCount;
        }

        _marketList.push(market);
        _grantRole(MARKET_ROLE, market);

        emit MarketRegistered(market, nOutcomes, risk);
    }

    /// @notice Remove an unsettled market that has never received a trade.
    ///
    ///         Constraints
    ///         ───────────
    ///         • Market must be registered and not yet settled.
    ///         • Market must have NO trades (hasTrades == false).
    ///           This guarantees no trader USDC is stranded in the vault.
    ///         • Releases riskBudget from totalLiability (unlocks LP capital).
    ///         • Revokes MARKET_ROLE; market contract can no longer call vault.
    ///
    ///         For markets with active trading, use the pause/emergency path instead.
    ///
    /// @param market Address of the market to deregister
    function deregisterMarket(address market) external onlyRole(MARKET_MANAGER_ROLE) {
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered)  revert MarketNotRegistered(market);
        if ( info.settled)     revert MarketAlreadySettled(market);
        if ( info.hasTrades)   revert MarketHasTrades(market);

        uint256 risk = info.riskBudget;

        // ── Effects ─────────────────────────────────────────────────────────
        totalLiability -= risk;

        unchecked {
            if (activeMarketCount > 0) --activeMarketCount;
        }

        delete markets[market];
        _revokeRole(MARKET_ROLE, market);

        emit MarketDeregistered(market);
    }

    /*//////////////////////////////////////////////////////////////
                            TRADE FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull trade cost USDC from a trader into the vault.
    ///
    ///         Called by the market contract (msg.sender, MARKET_ROLE) immediately
    ///         after it has computed the trade delta and updated its q-vector.
    ///
    ///         Flow
    ///         ────
    ///         1. Market computes cost = C(q_new) − C(q_old) in USDC (6-dec).
    ///         2. Market computes newLiability = LSMath.calculateWorstCaseLoss(...).
    ///         3. Market calls vault.collectTradeCost(trader, cost, newLiability).
    ///         4. Vault pulls `cost` USDC from trader (trader must have approved vault).
    ///         5. Vault updates market's currentLiability (informational; capped at riskBudget).
    ///         6. Vault emits TradeCostCollected.
    ///
    ///         Note: totalLiability is NOT updated here — it was fully reserved at
    ///         registration. currentLiability is a live tracking value for analytics.
    ///
    /// @param trader        Trader address — must have approved this vault for ≥ cost USDC
    /// @param cost          USDC to transfer from trader to vault (may be 0 for no-cost ops)
    /// @param newLiability  Updated worst-case loss after this trade (6-dec USDC, ≤ riskBudget)
    function collectTradeCost(
        address trader,
        uint256 cost,
        uint256 newLiability
    ) external onlyRole(MARKET_ROLE) nonReentrant whenNotPaused {
        address market = msg.sender;
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered) revert MarketNotRegistered(market);
        if ( info.settled)    revert MarketAlreadySettled(market);
        if (trader == address(0)) revert ZeroAddress();

        // Belt-and-suspenders cap: LS-LMSR guarantees newLiability ≤ R (Prop 4.9)
        uint256 capped = newLiability > info.riskBudget ? info.riskBudget : newLiability;

        // ── Effects ─────────────────────────────────────────────────────────
        info.currentLiability = capped;
        info.hasTrades        = true;

        // ── Interaction ─────────────────────────────────────────────────────
        if (cost > 0) {
            IERC20(asset()).safeTransferFrom(trader, address(this), cost);
        }

        emit TradeCostCollected(market, trader, cost, capped);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalise a market resolution: record the total winner payout.
    ///
    ///         Called by the market contract (msg.sender, MARKET_ROLE) once an
    ///         oracle has resolved the winning outcome.
    ///
    ///         Accounting
    ///         ──────────
    ///         • totalPayout = q[winningOutcome] in 6-dec USDC.
    ///         • By Proposition 4.9: totalPayout ≤ riskBudget = R always.
    ///         • riskBudget is released from totalLiability (LP capital unlocked).
    ///         • Vault profit from this market = riskBudget − totalPayout ≥ 0.
    ///         • Winners call market.claim() → vault.claimWinnings() to receive USDC.
    ///
    ///         Does NOT pause-gate: markets must be settleable even during emergencies
    ///         so traders are never permanently locked out of resolution.
    ///
    /// @param totalPayout  Total USDC to pay across all winners (6-dec, ≤ riskBudget)
    function settleMarket(
        uint256 totalPayout
    ) external onlyRole(MARKET_ROLE) nonReentrant {
        address market = msg.sender;
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered) revert MarketNotRegistered(market);
        if ( info.settled)    revert MarketAlreadySettled(market);
        if (totalPayout > info.riskBudget) {
            revert PayoutExceedsRiskBudget(totalPayout, info.riskBudget);
        }

        uint256 risk   = info.riskBudget;
        uint256 profit = risk - totalPayout; // ≥ 0 guaranteed by check above

        // ── Effects ─────────────────────────────────────────────────────────
        info.settled          = true;
        info.settledPayout    = totalPayout;
        info.currentLiability = 0;

        totalLiability -= risk;

        unchecked {
            if (activeMarketCount > 0) --activeMarketCount;
        }

        emit MarketSettled(market, totalPayout, profit);
    }

    /// @notice Transfer USDC winnings to a single verified winner.
    ///
    ///         Called by the settled market contract (msg.sender, MARKET_ROLE).
    ///         The market is responsible for verifying the winner's share balance
    ///         and computing the correct USDC amount. The vault only enforces
    ///         the aggregate settlement budget (settledPayout − claimedPayout).
    ///
    ///         Pull-payment pattern: vault never proactively pushes funds.
    ///         Winner → market.claim() → vault.claimWinnings().
    ///
    /// @param winner  Recipient of USDC winnings
    /// @param amount  USDC to transfer (6-dec; must not exceed remaining settlement budget)
    function claimWinnings(
        address winner,
        uint256 amount
    ) external onlyRole(MARKET_ROLE) nonReentrant whenNotPaused {
        address market = msg.sender;
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered) revert MarketNotRegistered(market);
        if (!info.settled)    revert MarketNotSettled(market);
        if (winner == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();

        uint256 remaining = info.settledPayout - info.claimedPayout;
        if (amount > remaining) revert PayoutExceedsSettlement(amount, remaining);

        // ── Effects ─────────────────────────────────────────────────────────
        info.claimedPayout += amount;

        // ── Interaction ─────────────────────────────────────────────────────
        IERC20(asset()).safeTransfer(winner, amount);

        emit WinningsClaimed(market, winner, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         PROTOCOL FEE COLLECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sweep accumulated protocol fees (USDC) to a recipient.
    /// @dev    protocolFeesAccrued is excluded from totalAssets so LP NAV is
    ///         not diluted when fees are collected. V1 default rate = 0.
    /// @param to  Recipient address (e.g. multisig treasury)
    function collectProtocolFees(
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = protocolFeesAccrued;
        if (amount == 0) revert NoFeesToCollect();

        // ── Effects ─────────────────────────────────────────────────────────
        protocolFeesAccrued = 0;

        // ── Interaction ─────────────────────────────────────────────────────
        IERC20(asset()).safeTransfer(to, amount);

        emit ProtocolFeesCollected(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         PARAMETER ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the global LS-LMSR alpha (commission/spread) parameter.
    /// @dev    Only affects markets registered AFTER this call. Existing markets
    ///         have alpha embedded in their initialisation vector q⁰.
    /// @param newAlpha  New α in 18-dec fixed-point (range [1e12, 2e17])
    function setAlpha(uint256 newAlpha) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAlpha < MIN_ALPHA || newAlpha > MAX_ALPHA) revert InvalidAlpha(newAlpha);
        emit AlphaUpdated(alpha, newAlpha);
        alpha = newAlpha;
    }

    /// @notice Update the per-market risk budget (worst-case loss guarantee).
    /// @dev    Only affects markets registered AFTER this call.
    /// @param newMax  New maxRiskPerMarket in raw USDC (6-dec)
    function setMaxRiskPerMarket(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax == 0) revert InvalidMaxRisk(newMax);
        emit MaxRiskUpdated(maxRiskPerMarket, newMax);
        maxRiskPerMarket = newMax;
    }

    /// @notice Update the allocation cap: maximum fraction of TVL lockable as market liability.
    /// @param newBps  New cap in BPS (1–10 000)
    function setMaxAllocationBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps == 0 || newBps > MAX_ALLOCATION_BPS) revert InvalidBps(newBps);
        emit AllocationCapUpdated(maxAllocationBps, newBps);
        maxAllocationBps = newBps;
    }

    /// @notice Update the bLP flash-mint fee.
    ///         Fee bLP tokens are burned (deflationary). 0 = free flash loans.
    /// @param newBps  Fee in BPS (0–1 000 hard ceiling)
    function setFlashFeeBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_FLASH_FEE_BPS) revert InvalidBps(newBps);
        emit FlashFeeBpsUpdated(flashFeeBps, newBps);
        flashFeeBps = newBps;
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause deposits, withdrawals, trades, and token transfers.
    ///         Settlement (settleMarket) is NOT paused — markets resolve regardless.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume normal vault operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW / PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC immediately withdrawable by LPs.
    ///         = totalAssets − totalLiability (market risk reserves)
    /// @return free  Free USDC (6-dec)
    function availableLiquidity() external view returns (uint256 free) {
        return _freeLiquidity();
    }

    /// @notice Vault utilisation: locked liability as BPS of total LP assets.
    ///         > 10 000 means the vault is undercollateralised (should not occur).
    /// @return bps  Utilisation in basis points
    function utilizationBps() external view returns (uint256 bps) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        return (totalLiability * BPS_BASE) / assets;
    }

    /// @notice Return the full MarketInfo record for `market`.
    function getMarketInfo(address market) external view returns (MarketInfo memory) {
        return markets[market];
    }

    /// @notice Total count of ever-registered markets (including settled ones).
    function totalMarkets() external view returns (uint256) {
        return _marketList.length;
    }

    /// @notice Paginated view into the historical market list.
    /// @param offset  Start index (0-based)
    /// @param limit   Maximum entries to return
    /// @return list   Slice of market addresses
    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory list) {
        uint256 total = _marketList.length;
        if (offset >= total || limit == 0) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        list = new address[](len);
        for (uint256 i = 0; i < len; ) {
            list[i] = _marketList[offset + i];
            unchecked { ++i; }
        }
    }

    /// @notice True if `market` is registered and not yet settled.
    function isActiveMarket(address market) external view returns (bool) {
        MarketInfo storage info = markets[market];
        return info.registered && !info.settled;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Total USDC managed for LP shareholders.
    /// @dev    Excludes protocolFeesAccrued (admin-owned, not LP-owned).
    ///         Includes USDC locked for market liabilities — LPs own it, but
    ///         cannot withdraw it until markets settle (see maxWithdraw).
    function totalAssets()
        public
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 fees    = protocolFeesAccrued;
        return balance > fees ? balance - fees : 0;
    }

    /// @notice Maximum USDC an owner can withdraw right now.
    /// @dev    Constrained by _freeLiquidity (totalAssets − totalLiability).
    ///         Returns 0 when paused.
    function maxWithdraw(
        address owner
    ) public view override(ERC4626Upgradeable) returns (uint256) {
        if (paused()) return 0;
        uint256 ownerAssets = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 free        = _freeLiquidity();
        return ownerAssets < free ? ownerAssets : free;
    }

    /// @notice Maximum bLP shares an owner can redeem right now.
    /// @dev    Constrained by free liquidity converted to shares.
    ///         Returns 0 when paused.
    function maxRedeem(
        address owner
    ) public view override(ERC4626Upgradeable) returns (uint256) {
        if (paused()) return 0;
        uint256 free       = _freeLiquidity();
        uint256 freeShares = _convertToShares(free, Math.Rounding.Floor);
        uint256 owned      = balanceOf(owner);
        return owned < freeShares ? owned : freeShares;
    }

    /// @notice Maximum USDC that can be deposited (returns 0 while paused).
    function maxDeposit(
        address
    ) public view override(ERC4626Upgradeable) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @notice Maximum bLP shares that can be minted (returns 0 while paused).
    function maxMint(
        address
    ) public view override(ERC4626Upgradeable) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-20 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice bLP token decimals: 18 (USDC 6 + offset 12).
    /// @dev    Explicit override resolves the ERC20 / ERC4626 ambiguity.
    function decimals()
        public
        pure
        override(ERC20Upgradeable, ERC4626Upgradeable)
        returns (uint8)
    {
        return 18;
    }

    /// @notice Hook called on every token transfer, mint, and burn.
    ///         Reverts when the vault is paused, blocking all ERC-20 movements.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable) whenNotPaused {
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                      ERC-3156 FLASH MINT OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Flash-mint fee on bLP.
    ///         Fee = amount × flashFeeBps / BPS_BASE.
    ///         Fee bLP tokens are burned by the ERC-3156 implementation.
    function _flashFee(
        address, /* token — always address(this) for ERC20FlashMint */
        uint256  value
    ) internal view override(ERC20FlashMintUpgradeable) returns (uint256) {
        return (value * flashFeeBps) / BPS_BASE;
    }

    /// @notice Flash-mint fee receiver.
    ///         address(0) → fee bLP tokens are burned (deflationary for LPs).
    function _flashFeeReceiver()
        internal
        pure
        override(ERC20FlashMintUpgradeable)
        returns (address)
    {
        return address(0);
    }

    /*//////////////////////////////////////////////////////////////
                         UUPS UPGRADE OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorise a UUPS implementation upgrade.
    ///         Only UPGRADER_ROLE may upgrade the implementation contract.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override(UUPSUpgradeable) onlyRole(UPGRADER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                       INTERFACE SUPPORT
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-165 interface detection — merges AccessControl and ERC-4626.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-4626 decimal offset.
    ///         bLP decimals = USDC decimals (6) + DECIMALS_OFFSET (12) = 18.
    ///         The non-zero offset also provides virtual-share inflation-attack
    ///         protection without needing a dead-share seed deposit.
    function _decimalsOffset()
        internal
        pure
        override(ERC4626Upgradeable)
        returns (uint8)
    {
        return DECIMALS_OFFSET;
    }

    /// @notice USDC liquidity not locked by active market liabilities.
    ///         = totalAssets (net of protocol fees) − totalLiability
    /// @return free  Available USDC (6-dec); 0 if fully utilised
    function _freeLiquidity() internal view returns (uint256 free) {
        uint256 assets = totalAssets();
        uint256 locked = totalLiability;
        unchecked {
            free = assets > locked ? assets - locked : 0;
        }
    }
}
