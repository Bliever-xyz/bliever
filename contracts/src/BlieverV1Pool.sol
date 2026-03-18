// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN — UPGRADEABLE
//////////////////////////////////////////////////////////////*/
import {Initializable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}          from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable}         from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable}       from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable}   from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {PausableUpgradeable}      from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN — STANDARD (REENTRANCY)
//////////////////////////////////////////////////////////////*/
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
///         • Market contracts (MARKET_ROLE) call `collectTradeCost` to pull trader
///           USDC into the vault on a buy trade, and `distributeRefund` to push USDC
///           back to the trader on a sell trade; both update live liability atomically.
///           `settleMarket` + `claimWinnings` distribute payouts on resolution.
///         • LP withdrawal is capped to `_freeLiquidity` which enforces both the
///           live liability lock AND a 20 % uncommitted-NAV reserve floor.
///
///         LS-LMSR loss bound (Proposition 4.9 + Lemma 4.5)
///         ─────────────────────────────────────────────────
///         Loss per market ≤ C(q⁰) = R = maxRiskPerMarket, always.
///         totalLiability = Σ currentLiability_i (live, decreases as volume grows).
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
    ERC20PermitUpgradeable,
    PausableUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuard,
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

    /// @notice Allowed to pause the vault (a low-latency ops multisig in production)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Allowed to authorise UUPS implementation upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Allowed to force-settle broken or oracle-stuck markets.
    ///         Should be held by a faster-response multisig than DEFAULT_ADMIN_ROLE
    ///         (fewer required signers) so emergency actions can execute without
    ///         waiting for full governance quorum.
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Denominator for basis-point calculations (100 % = 10 000)
    uint256 public constant BPS_BASE = 10_000;

    /// @notice Absolute lower bound on the admin-configurable reserve buffer (5 %).
    ///         Ensures a meaningful withdrawal floor is always present.
    uint16  public constant MIN_RESERVE_BPS = 500;

    /// @notice Absolute upper bound on the admin-configurable reserve buffer (50 %).
    ///         Caps the most conservative mode; prevents the vault becoming deposit-only.
    uint16  public constant MAX_RESERVE_BPS = 5_000;

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
    /// @dev    Slot-0 packs: bool(1) + bool(1) + bool(1) = 3 bytes (29 bytes free for future use).
    ///         Remaining slots hold uint256 values.
    struct MarketInfo {
        // ── slot 0 (3/32 bytes used) ───────────────────────────────
        bool     registered;      // true from registerMarket, false after delete
        bool     settled;         // true after settleMarket is called
        bool     hasTrades;       // true after first collectTradeCost call
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
    error CapacityExceeded(uint256 projected, uint256 activeCap);
    error NotAContract(address account);
    error PayoutExceedsRiskBudget(uint256 payout, uint256 budget);
    error PayoutExceedsSettlement(uint256 requested, uint256 remaining);
    error ExceedsMaxMarkets(uint256 active);
    /// @notice Thrown when raw USDC balance falls below totalLiability (accounting invariant violated)
    error VaultInsolvent(uint256 balance, uint256 liability);
    /// @notice Thrown when claimedPayout somehow exceeds settledPayout (should never occur)
    error AccountingInvariantViolated();

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

    /// @notice Emitted each time a trader's USDC is refunded for a sell trade
    event RefundDistributed(
        address indexed market,
        address indexed trader,
        uint256         refundAmount,
        uint256         newCurrentLiability
    );

    /// @notice Emitted each time a winner claims USDC winnings
    event WinningsClaimed(
        address indexed market,
        address indexed winner,
        uint256         amount
    );

    /// @notice Emitted when all settledPayout has been claimed and MARKET_ROLE is revoked
    event MarketFullyClaimed(address indexed market, uint256 totalPaid);

    /// @notice Emitted when a market with zero trades is settled (riskBudget freed as profit)
    event MarketExpiredUntraded(address indexed market, uint256 riskBudget);

    /// @notice Emitted when the global alpha parameter changes
    event AlphaUpdated(uint256 oldAlpha, uint256 newAlpha);

    /// @notice Emitted when the per-market risk budget changes
    event MaxRiskUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when the reserve buffer parameter changes
    event ReserveBpsUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when a market's live liability is updated after a trade
    /// @param oldLiability Previous currentLiability for this market
    /// @param newLiability New currentLiability after the trade
    event MarketLiabilityUpdated(
        address indexed market,
        uint256         oldLiability,
        uint256         newLiability
    );

    /// @notice Emitted when an admin force-settles a broken/stuck market
    /// @param lossAbsorbed The currentLiability released from totalLiability (vault absorbs as loss)
    event MarketForceSettled(address indexed market, uint256 lossAbsorbed);

    /// @notice Emitted when a market contract reports newLiability > riskBudget.
    ///         This violates the LS-LMSR Proposition 4.9 invariant and indicates a
    ///         misbehaving market contract. The vault silently caps the value; this event
    ///         surfaces the anomaly for monitors and auditors.
    event LiabilityCapApplied(address indexed market, uint256 reported, uint256 cap);

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

    /// @notice Fraction of total vault assets permanently reserved as an LP withdrawal
    ///         buffer and excluded from market capacity (BPS, default 2000 = 20 %).
    ///         Active capital ceiling = assets × (BPS_BASE − reserveBps).
    ///         Admin may adjust within [MIN_RESERVE_BPS, MAX_RESERVE_BPS].
    uint16  public reserveBps;

    /// @notice Live sum of each active market's currentLiability.
    ///         Updated on every trade (collectTradeCost) and on settlement.
    ///         Decreases in real-time as volume grows (LS-LMSR property: C(q) rises → loss bound falls).
    ///         LP NAV = totalAssets − totalLiability reflects vault's true economic position.
    uint256 public totalLiability;

    /// @notice Active (non-settled) market count
    uint256 public activeMarketCount;

    /// @notice Per-market accounting keyed by market contract address
    mapping(address => MarketInfo) public markets;

    /// @dev Reserve 45 slots for future state variables without storage collisions.
    ///      Custom slots used: alpha(1) + maxRiskPerMarket(1) + reserveBps packed(1)
    ///      + totalLiability(1) + activeMarketCount(1) + markets(1)
    ///      = 6 slots. Gap = 50 − 6 = 44, plus 1 for conservative headroom = 45.
    ///      Future upgrades append before __gap and reduce by count.
    uint256[45] private __gap;

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
    /// @dev    Caller becomes DEFAULT_ADMIN + MARKET_MANAGER + PAUSER + UPGRADER + EMERGENCY.
    ///         All OpenZeppelin init chains must be called explicitly.
    ///
    ///         ⚠️  PRODUCTION DEPLOYMENT — separate roles across independent multisigs:
    ///             PAUSER_ROLE    → low-latency 2-of-3 ops multisig (fast circuit breaker).
    ///             EMERGENCY_ROLE → faster-response multisig (fewer signers; emergency only).
    ///             UPGRADER_ROLE  → high-security timelock contract.
    ///             DEFAULT_ADMIN_ROLE → governance multisig (slowest, highest quorum).
    ///         Granting all roles to a single address is acceptable only for testnet.
    ///
    ///         AccessControlDefaultAdminRules enforces two-step DEFAULT_ADMIN_ROLE transfer
    ///         with a configurable minimum delay, protecting against single-key compromise.
    ///
    /// @param usdc               USDC ERC-20 address on Base (underlying asset)
    /// @param admin              Initial admin address (receives all privileged roles)
    /// @param _alpha             LS-LMSR α (18-dec, e.g. 3e16 for 3 %)
    /// @param _maxRiskPerMarket  Worst-case loss per market in raw USDC (6-dec, e.g. 1e6 = $1)
    /// @param _reserveBps        Reserve buffer in BPS (range [MIN_RESERVE_BPS, MAX_RESERVE_BPS])
    function initialize(
        address usdc,
        address admin,
        uint256 _alpha,
        uint256 _maxRiskPerMarket,
        uint16  _reserveBps
    ) external initializer {
        // ── Input validation ────────────────────────────────────────────────
        if (usdc  == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (_alpha < MIN_ALPHA || _alpha > MAX_ALPHA)  revert InvalidAlpha(_alpha);
        if (_maxRiskPerMarket  == 0)                   revert InvalidMaxRisk(_maxRiskPerMarket);
        if (_reserveBps < MIN_RESERVE_BPS || _reserveBps > MAX_RESERVE_BPS)
            revert InvalidBps(_reserveBps);

        // ── ERC-20 / ERC-4626 chain ─────────────────────────────────────────
        __ERC20_init("Believer LP", "bLP");
        __ERC4626_init(IERC20(usdc));
        __ERC20Permit_init("Believer LP");

        // ── Security chain ──────────────────────────────────────────────────
        __Pausable_init();
        // minDelay = 0 at launch; governance should increase via beginDefaultAdminTransfer
        // once roles are distributed. Two-step accept is enforced regardless of delay.
        __AccessControlDefaultAdminRules_init(0, admin);

        // ── Role grants ─────────────────────────────────────────────────────
        _grantRole(MARKET_MANAGER_ROLE,  admin);
        _grantRole(PAUSER_ROLE,          admin);
        _grantRole(UPGRADER_ROLE,        admin);
        _grantRole(EMERGENCY_ROLE,       admin);

        // ── Role admin hierarchy ─────────────────────────────────────────────
        // MARKET_MANAGER_ROLE administers MARKET_ROLE: market managers can
        // grant/revoke MARKET_ROLE via the public grantRole/revokeRole paths,
        // consistent with their control over registerMarket/deregisterMarket.
        _setRoleAdmin(MARKET_ROLE, MARKET_MANAGER_ROLE);

        // ── Protocol parameters ─────────────────────────────────────────────
        alpha            = _alpha;
        maxRiskPerMarket = _maxRiskPerMarket;
        reserveBps       = _reserveBps;
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a prediction market and reserve its LS-LMSR risk budget.
    ///
    ///         What happens internally
    ///         ───────────────────────
    ///         1. Validates address (must be a contract), outcome count, and capacity check.
    ///         2. Creates MarketInfo with riskBudget = maxRiskPerMarket.
    ///         3. Adds riskBudget to totalLiability (liability reserved immediately).
    ///         4. Grants MARKET_ROLE to the market contract address.
    ///
    ///         Why currentLiability starts at riskBudget
    ///         ──────────────────────────────────────────
    ///         From the LS-LMSR initialisation: ε = R / (1 + α·n·ln n),
    ///         which ensures C(q⁰) = R exactly. So from block 0 the market
    ///         maker's worst-case loss is already R. We initialise
    ///         currentLiability = riskBudget = R conservatively; it will decrease
    ///         as trading volume grows and the vault earns spread.
    ///
    ///         Capacity check
    ///         ──────────────
    ///         Total vault assets split into two zones:
    ///           • Active capital  = assets × (100 % − reserveBps): markets draw from here.
    ///           • Reserve buffer  = assets × reserveBps: always free for LP withdrawals.
    ///         Registration is accepted only when newTotalLiability ≤ active capital.
    ///         One mulDiv, one comparison — semantically complete.
    ///
    /// @param market     Address of the market contract (must NOT be already registered)
    /// @param nOutcomes  Number of mutually exclusive outcomes (2–100 inclusive)
    function registerMarket(
        address market,
        uint32  nOutcomes
    ) external onlyRole(MARKET_MANAGER_ROLE) whenNotPaused {
        // ── Checks ──────────────────────────────────────────────────────────
        if (market   == address(0))           revert ZeroAddress();
        if (market.code.length == 0)          revert NotAContract(market);
        if (nOutcomes < 2 || nOutcomes > 100) revert InvalidOutcomeCount(nOutcomes);
        if (markets[market].registered)        revert MarketAlreadyRegistered(market);
        if (activeMarketCount >= MAX_ACTIVE_MARKETS) revert ExceedsMaxMarkets(activeMarketCount);

        uint256 risk         = maxRiskPerMarket;
        uint256 newTotalLiab = totalLiability + risk;
        uint256 assets       = totalAssets();

        // Active capital = assets × (100 % − reserveBps); liabilities must stay within it.
        uint256 activeCap = assets.mulDiv(BPS_BASE - reserveBps, BPS_BASE, Math.Rounding.Floor);
        if (newTotalLiab > activeCap) {
            revert CapacityExceeded(newTotalLiab, activeCap);
        }

        // ── Effects ─────────────────────────────────────────────────────────
        markets[market] = MarketInfo({
            registered:       true,
            settled:          false,
            hasTrades:        false,
            riskBudget:       risk,
            currentLiability: risk,   // conservative: = C(q⁰) = R
            settledPayout:    0,
            claimedPayout:    0
        });

        totalLiability = newTotalLiab;

        unchecked {
            ++activeMarketCount;
        }

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
    function deregisterMarket(address market) external onlyRole(MARKET_MANAGER_ROLE) whenNotPaused {
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered)  revert MarketNotRegistered(market);
        if ( info.settled)     revert MarketAlreadySettled(market);
        if ( info.hasTrades)   revert MarketHasTrades(market);

        uint256 risk = info.riskBudget;

        // ── Effects ─────────────────────────────────────────────────────────
        totalLiability -= risk;

        --activeMarketCount; // reverts on underflow, surfacing any accounting bug

        delete markets[market];
        _revokeRole(MARKET_ROLE, market);

        emit MarketDeregistered(market);
    }

    /*//////////////////////////////////////////////////////////////
                            TRADE FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull trade cost USDC from a trader into the vault AND update live liability.
    ///
    ///         Called by the market contract (msg.sender, MARKET_ROLE) immediately
    ///         after it has computed the trade delta and updated its q-vector.
    ///
    ///         Flow
    ///         ────
    ///         1. Market computes cost = C(q_new) − C(q_old) in USDC (6-dec).
    ///         2. Market computes newLiability = LSMath.calculateWorstCaseLoss(...).
    ///         3. Market calls vault.collectTradeCost(trader, cost, newLiability).
    ///         4. Vault adjusts totalLiability by the delta (live LS-LMSR tracking).
    ///         5. Vault pulls `cost` USDC from trader (trader must have approved vault).
    ///         6. Vault emits TradeCostCollected + MarketLiabilityUpdated.
    ///
    ///         Live liability property
    ///         ────────────────────────
    ///         As trading volume grows C(q) rises → calculateWorstCaseLoss decreases
    ///         → newLiability < old → totalLiability shrinks → LP NAV rises.
    ///         This reflects the LS-LMSR theorem: volume creates its own solvency.
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
        // If the cap fires, a market contract has violated Prop 4.9 — surface it immediately.
        if (newLiability > info.riskBudget) {
            emit LiabilityCapApplied(market, newLiability, info.riskBudget);
        }
        uint256 old    = info.currentLiability;

        // ── Effects ─────────────────────────────────────────────────────────
        // Delta-update totalLiability so it tracks the live sum of all currentLiability values
        if (capped > old) {
            totalLiability += (capped - old);
        } else if (capped < old) {
            totalLiability -= (old - capped);
        }

        info.currentLiability = capped;
        info.hasTrades        = true;

        // ── Interaction ─────────────────────────────────────────────────────
        if (cost > 0) {
            IERC20(asset()).safeTransferFrom(trader, address(this), cost);
        }

        emit TradeCostCollected(market, trader, cost, capped);
        if (capped != old) emit MarketLiabilityUpdated(market, old, capped);
    }

    /// @notice Push sell-refund USDC from vault to trader AND update live liability.
    ///
    ///         Called by the market contract (msg.sender, MARKET_ROLE) immediately
    ///         after it has computed the sell delta and updated its q-vector.
    ///
    ///         Flow
    ///         ────
    ///         1. Market computes refundAmount = C(q_old) − C(q_new) in USDC (6-dec).
    ///         2. Market computes newLiability  = LSMath.calculateWorstCaseLoss(...).
    ///         3. Market calls vault.distributeRefund(trader, refundAmount, newLiability).
    ///         4. Vault adjusts totalLiability by the delta (live LS-LMSR tracking).
    ///         5. Vault pushes `refundAmount` USDC to trader.
    ///         6. Vault emits RefundDistributed + MarketLiabilityUpdated (if delta ≠ 0).
    ///         7. Vault asserts solvency — balance must still cover all liabilities.
    ///
    ///         Sell-side liability behaviour
    ///         ──────────────────────────────
    ///         Selling shares reduces C(q) and shifts the obligation vector q back toward
    ///         the initialisation point q⁰. The new worst-case loss may rise or fall
    ///         depending on market skew. Belt-and-suspenders cap always applies.
    ///
    /// @param trader        Recipient of the refund USDC
    /// @param refundAmount  USDC to transfer from vault to trader (may be 0 for zero-cost ops)
    /// @param newLiability  Updated worst-case loss after this sell trade (6-dec USDC, ≤ riskBudget)
    function distributeRefund(
        address trader,
        uint256 refundAmount,
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
        if (newLiability > info.riskBudget) {
            emit LiabilityCapApplied(market, newLiability, info.riskBudget);
        }

        uint256 old = info.currentLiability;

        // ── Effects ─────────────────────────────────────────────────────────
        if (capped > old) {
            totalLiability += (capped - old);
        } else if (capped < old) {
            totalLiability -= (old - capped);
        }
        info.currentLiability = capped;

        // ── Interaction ─────────────────────────────────────────────────────
        if (refundAmount > 0) {
            IERC20(asset()).safeTransfer(trader, refundAmount);
        }

        emit RefundDistributed(market, trader, refundAmount, capped);
        if (capped != old) emit MarketLiabilityUpdated(market, old, capped);

        // Vault must still cover all liabilities after sending USDC out
        _assertSolvent();
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
    ///         • currentLiability (live worst-case loss) is released from totalLiability.
    ///         • Vault profit = riskBudget − totalPayout ≥ 0; absorbed into LP NAV.
    ///         • Winners call market.claim() → vault.claimWinnings() to receive USDC.
    ///
    ///         Zero-payout path
    ///         ─────────────────
    ///         When totalPayout == 0 (all positions on losing outcomes), no claim call
    ///         can ever arrive — claimWinnings would revert on ZeroAmount or
    ///         PayoutExceedsSettlement before reaching the role-revocation code.
    ///         MARKET_ROLE is therefore revoked immediately in settleMarket for this case.
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

        uint256 liveLiab  = info.currentLiability; // live worst-case loss (≤ riskBudget)
        uint256 riskBudget = info.riskBudget;       // cache before zeroing

        // ── Effects ─────────────────────────────────────────────────────────
        info.settled          = true;
        info.settledPayout    = totalPayout;
        info.currentLiability = 0;

        // liveLiab ≤ totalLiability by the totalLiability = Σ currentLiability invariant.
        // riskBudget ≥ totalPayout validated by the check above.
        // Both subtractions are provably safe; unchecked saves ~40 gas each on Base.
        unchecked {
            totalLiability -= liveLiab;
        }

        --activeMarketCount; // intentionally checked — underflow surfaces accounting bugs

        unchecked {
            emit MarketSettled(market, totalPayout, riskBudget - totalPayout);
        }

        if (!info.hasTrades) {
            emit MarketExpiredUntraded(market, riskBudget);
        }

        // Zero-payout: no valid claimWinnings call can ever arrive (remaining = 0).
        // Revoke MARKET_ROLE now so it is never held indefinitely after settlement.
        if (totalPayout == 0) {
            _revokeRole(MARKET_ROLE, market);
            emit MarketFullyClaimed(market, 0);
        }

        // Accounting sanity — should never revert if invariants hold
        _assertSolvent();
    }

    /// @notice Emergency path: force-settle a broken or oracle-stuck market.
    ///
    ///         Intended for markets whose oracle has permanently failed or whose
    ///         market contract is broken and cannot call settleMarket itself.
    ///         The vault absorbs `currentLiability` as a worst-case loss (LP NAV
    ///         decreases by that amount). No USDC is transferred — winners receive
    ///         nothing, mirroring a full-loss outcome.
    ///
    ///         After forceSettleMarket, the market is marked settled and MARKET_ROLE
    ///         is revoked. No further trades or claims are possible.
    ///
    ///         NOT pause-gated — emergencies must be handleable at any time.
    ///
    /// @param market  Address of the stuck market contract
    function forceSettleMarket(
        address market
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered) revert MarketNotRegistered(market);
        if ( info.settled)    revert MarketAlreadySettled(market);

        uint256 lossAbsorbed = info.currentLiability;

        // ── Effects ─────────────────────────────────────────────────────────
        // lossAbsorbed ≤ totalLiability by the totalLiability = Σ currentLiability invariant.
        unchecked {
            totalLiability -= lossAbsorbed;
        }

        --activeMarketCount; // intentionally checked — underflow surfaces accounting bugs

        info.settled          = true;
        info.settledPayout    = 0;
        info.currentLiability = 0;
        info.riskBudget       = 0;

        _revokeRole(MARKET_ROLE, market);

        emit MarketForceSettled(market, lossAbsorbed);

        // Accounting sanity — should never revert if invariants hold
        _assertSolvent();
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
    ///         NOT pause-gated — winners with a finalised, verified payout must
    ///         never be blocked by vault-level operational pauses. settleMarket
    ///         is already unpausable; blocking claimWinnings while settlement
    ///         proceeds would strand verified payouts indefinitely.
    ///
    ///         When the last winner claims (claimedPayout == settledPayout > 0),
    ///         MARKET_ROLE is automatically revoked from the market contract
    ///         and MarketFullyClaimed is emitted. For zero-payout markets
    ///         (settledPayout == 0), revocation is handled inside settleMarket
    ///         because no valid claimWinnings call can ever reach this function.
    ///
    /// @param winner  Recipient of USDC winnings
    /// @param amount  USDC to transfer (6-dec; must not exceed remaining settlement budget)
    function claimWinnings(
        address winner,
        uint256 amount
    ) external onlyRole(MARKET_ROLE) nonReentrant {
        address market = msg.sender;
        MarketInfo storage info = markets[market];

        // ── Checks ──────────────────────────────────────────────────────────
        if (!info.registered) revert MarketNotRegistered(market);
        if (!info.settled)    revert MarketNotSettled(market);
        if (winner == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();

        if (info.claimedPayout > info.settledPayout) revert AccountingInvariantViolated();
        uint256 remaining = info.settledPayout - info.claimedPayout;
        if (amount > remaining) revert PayoutExceedsSettlement(amount, remaining);

        // ── Effects ─────────────────────────────────────────────────────────
        info.claimedPayout += amount;

        // ── Interaction ─────────────────────────────────────────────────────
        IERC20(asset()).safeTransfer(winner, amount);

        emit WinningsClaimed(market, winner, amount);

        // Revoke MARKET_ROLE once all authorised winnings have been paid out.
        // This removes the lingering role attack surface after full settlement.
        if (info.claimedPayout == info.settledPayout) {
            _revokeRole(MARKET_ROLE, market);
            emit MarketFullyClaimed(market, info.settledPayout);
        }
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

    /// @notice Update the reserve buffer: fraction of total assets permanently held
    ///         back from market capacity and always available for LP withdrawals.
    ///         Lowering it admits more markets (more yield potential, more LP risk).
    ///         Raising it protects LP liquidity during uncertain or high-volume periods.
    /// @param newBps  New reserve in BPS ([MIN_RESERVE_BPS, MAX_RESERVE_BPS])
    function setReserveBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps < MIN_RESERVE_BPS || newBps > MAX_RESERVE_BPS) revert InvalidBps(newBps);
        emit ReserveBpsUpdated(reserveBps, newBps);
        reserveBps = newBps;
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause deposits, withdrawals, trades, and token transfers.
    ///         Settlement (settleMarket, forceSettleMarket) and winner payouts
    ///         (claimWinnings) are NOT paused — markets resolve and pay out
    ///         regardless of vault operational state.
    ///         PAUSER_ROLE may pause. Only DEFAULT_ADMIN_ROLE may unpause.
    ///         This asymmetry ensures a compromised pauser key cannot defeat an
    ///         emergency pause by immediately unpausing.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume normal vault operations.
    ///         Requires DEFAULT_ADMIN_ROLE — unpause requires higher authority than pause.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW / PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC immediately withdrawable by LPs.
    ///         = totalAssets − totalLiability − (totalAssets × reserveBps).
    ///         Both the liability lock and the reserve buffer are anchored to total assets.
    ///         Because totalLiability is live (decreases as markets earn spread), this
    ///         value rises organically as trading volume grows on active markets.
    /// @return free  Withdrawable USDC (6-dec); 0 if vault is fully utilised or at reserve floor
    function availableLiquidity() external view returns (uint256 free) {
        return _freeLiquidity();
    }

    /// @notice Vault utilisation: live liability as BPS of active capital (total assets minus reserve buffer).
    ///         Measuring against active capital — the portion actually available for markets — gives
    ///         operators an accurate headroom signal. A value of 7000 means 30 % of deployable
    ///         capital remains, regardless of how large the reserve buffer is.
    ///         > 10 000 means active capital is fully encumbered (should never occur through normal paths).
    /// @return bps  Utilisation in basis points relative to active capital
    function utilizationBps() external view returns (uint256 bps) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        uint256 activeCap = assets.mulDiv(BPS_BASE - reserveBps, BPS_BASE, Math.Rounding.Floor);
        if (activeCap == 0) return type(uint256).max; // reserve consumes all assets
        return totalLiability.mulDiv(BPS_BASE, activeCap, Math.Rounding.Floor);
    }

    /// @notice Net Asset Value: LP-owned USDC net of all live market liabilities.
    ///         NAV = totalAssets − totalLiability.
    ///         Rising NAV signals the vault is earning spread from market activity.
    /// @return nav_  NAV in 6-dec USDC (0 if liabilities exceed assets)
    function nav() external view returns (uint256 nav_) {
        uint256 assets = totalAssets();
        uint256 liab   = totalLiability;
        nav_ = assets > liab ? assets - liab : 0;
    }

    /// @notice On-chain solvency check: true if raw USDC balance ≥ totalLiability.
    ///         An off-chain monitor can poll this; it should always be true.
    function isSolvent() external view returns (bool) {
        return IERC20(asset()).balanceOf(address(this)) >= totalLiability;
    }

    /// @notice Return the full MarketInfo record for `market`.
    function getMarketInfo(address market) external view returns (MarketInfo memory) {
        return markets[market];
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
    ///         Includes USDC locked for market liabilities — LPs own it, but
    ///         cannot withdraw it until markets settle (see maxWithdraw).
    function totalAssets()
        public
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return IERC20(asset()).balanceOf(address(this));
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
    ) public view override(AccessControlDefaultAdminRulesUpgradeable) returns (bool) {
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

    /// @notice USDC liquidity available for LP withdrawals.
    ///         The vault's total assets are divided into two zones:
    ///           • Active capital (1 − reserveBps): encumbered by market liabilities.
    ///           • Reserve buffer (reserveBps):     always free for LP withdrawals.
    ///
    ///         Formula: free = max(0, assets − totalLiability − reserve)
    ///                  where reserve = assets × reserveBps / BPS_BASE
    ///
    ///         Both the liability lock and the reserve buffer are anchored to total assets,
    ///         not to NAV. This provides a real, non-self-referential withdrawal floor.
    ///
    ///         Because totalLiability is live, free liquidity rises naturally after every
    ///         trade that reduces a market's worst-case loss bound.
    ///
    /// @return free  Withdrawable USDC (6-dec); 0 when fully utilised or at reserve floor
    function _freeLiquidity() internal view returns (uint256 free) {
        uint256 assets  = totalAssets();
        uint256 reserve = assets.mulDiv(reserveBps, BPS_BASE, Math.Rounding.Ceil);
        uint256 minHeld = totalLiability + reserve;
        return assets > minHeld ? assets - minHeld : 0;
    }

    /// @notice Assert that raw USDC balance covers all live market liabilities.
    ///         Called at the end of settleMarket. Surfaces accounting bugs during
    ///         testing and provides an on-chain verifiable invariant.
    /// @dev    Should never revert if all accounting paths are correct.
    function _assertSolvent() internal view {
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        if (rawBalance < totalLiability) {
            revert VaultInsolvent(rawBalance, totalLiability);
        }
    }
}
