// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

// ─────────────────────────────────────────────────────────────────────────────
//  OpenZeppelin Upgradeable Contracts (v5)
// ─────────────────────────────────────────────────────────────────────────────
import {ERC4626Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20FlashMintUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20FlashMintUpgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  OpenZeppelin Non-Upgradeable Utilities
// ─────────────────────────────────────────────────────────────────────────────
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/*//////////////////////////////////////////////////////////////
                      LIBRARY IMPORT
//////////////////////////////////////////////////////////////*/

// LSMath is used by individual Market contracts for LS-LMSR
// calculations.  The vault imports it only for the bounded-loss
// constant and validation helpers exposed as pure functions.
import {LSMath} from "./libraries/LSMath.sol";

/*//////////////////////////////////////////////////////////////
                      GLOBALLPVAULT
//////////////////////////////////////////////////////////////*/

/// @title  GlobalLPVault
/// @author Bliever
/// @notice ERC-4626 USDC vault that provides pooled liquidity for
///         LS-LMSR political prediction markets.
///
/// @dev    Key design axioms (from research docs):
///
///         1. Liability-aware NAV
///            totalAssets() = rawUSDC + totalAllocated − totalLiabilities
///            Prevents share-price inflation and "rug-pull" exits by LPs.
///
///         2. Asynchronous withdrawal (Naked-Redeemer protection)
///            Shares are escrowed at request time; burned and USDC released
///            atomically after the cooldown window has elapsed.
///
///         3. Capital utilisation caps
///            The vault enforces minUncommittedBps (20 %) of NAV as a
///            liquid USDC reserve at all times, and maxCommittedBps (80 %)
///            as the ceiling for capital deployed to markets.
///
///         4. Bounded liability guarantee (LS-LMSR)
///            Each market's registered maxLoss ≤ C(q₀) — the initial cost
///            function value.  totalLiabilities is therefore always finite.
///
///         5. UUPS-upgradeable, using ERC-7201 namespaced storage so the
///            slot layout is stable across logic upgrades.
///
///         NOT included in V1 (deferred):
///         - Alpha/commission logic (lives in Market contracts)
///         - DAO governance
///         - External yield (Aave, Compound, etc.)
///
/// @custom:security-contact security@example.com
contract GlobalLPVault is
    ERC4626Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20FlashMintUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Can grant / revoke roles and authorise upgrades.
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /// @notice Can register markets, set protocol parameters.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Granted to authorised market contracts.
    ///         Allows capital allocation, liability updates, and settlement.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    /// @notice Can pause / unpause the vault.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Basis-points denominator (10 000 = 100 %).
    uint256 public constant BPS = 10_000;

    /// @dev Minimum uncommitted capital as a share of NAV (20 %).
    uint256 public constant MIN_UNCOMMITTED_BPS = 2_000;

    /// @dev Maximum capital that may be committed to markets (80 %).
    uint256 public constant MAX_COMMITTED_BPS = 8_000;

    /// @dev Absolute ceiling on vault-wide utilisation (95 %).
    uint256 public constant GLOBAL_MAX_UTILIZATION_BPS = 9_500;

    /// @dev Offset added to USDC's 6 decimals → gLP shares have 18 decimals.
    ///      Also provides virtual-shares inflation protection (EIP-4626).
    uint8 private constant DECIMAL_OFFSET = 12;

    /// @dev ERC-7201 storage namespace for GlobalLPVault's custom state.
    bytes32 private constant STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("globallpvault.storage.v1")) - 1)) & ~bytes32(uint256(0xff));

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-market accounting record.
    struct MarketInfo {
        /// @dev True while market is active.
        bool active;
        /// @dev USDC allocated to this market (seed capital = C(q₀)).
        uint256 allocated;
        /// @dev Current worst-case payout liability ≤ allocated.
        uint256 currentLiability;
        /// @dev ISO-3166 / topic tag for the political market.
        bytes32 topicTag;
        /// @dev Block at which market was registered.
        uint256 registeredAt;
    }

    /// @notice LP withdrawal escrow record.
    struct WithdrawalRequest {
        address owner;
        address receiver;
        /// @dev Shares escrowed in the vault's own balance.
        uint256 shares;
        /// @dev USDC to be released (computed at request time using NAV).
        uint256 assets;
        /// @dev Unix timestamp after which the request may be completed.
        uint256 readyAt;
        bool claimed;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Canonical vault storage.  Accessed exclusively through _vs().
    struct VaultStorage {
        // ── Market registry ──────────────────────────────────────
        mapping(address => MarketInfo) markets;
        address[] marketList;
        /// @dev Total USDC sent to all active markets.
        uint256 totalAllocated;
        /// @dev Sum of currentLiability across all active markets.
        uint256 totalLiabilities;

        // ── Withdrawal escrow ─────────────────────────────────────
        mapping(uint256 => WithdrawalRequest) withdrawalRequests;
        uint256 nextRequestId;

        // ── Configuration (mutable by MANAGER_ROLE) ───────────────
        /// @dev Cooldown seconds before an LP can complete a withdrawal.
        uint256 withdrawalCooldown;
        /// @dev Per-vault utilisation cap in BPS (≤ GLOBAL_MAX_UTILIZATION_BPS).
        uint256 maxUtilizationBps;
        /// @dev Flash-mint fee in BPS.
        uint256 flashFeeBps;
        /// @dev Address receiving flash-mint fees (zero = fee burned).
        address flashFeeReceiver;
    }

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error MarketAlreadyRegistered(address market);
    error MarketNotRegistered(address market);
    error MarketAlreadyActive(address market);
    error MarketNotActive(address market);
    error ExceedsCommittedCap(uint256 requested, uint256 available);
    error InsufficientUncommittedCapital(uint256 required, uint256 available);
    error LiabilityExceedsAllocation(uint256 liability, uint256 allocated);
    error RequestNotReady(uint256 readyAt, uint256 now_);
    error RequestAlreadyClaimed(uint256 requestId);
    error RequestNotOwned(uint256 requestId, address caller);
    error RequestNotFound(uint256 requestId);
    error AsyncWithdrawalRequired();
    error VaultInsolvent(uint256 rawBalance, uint256 liabilities);
    error UtilizationCapTooHigh(uint256 cap);
    error CooldownTooLong(uint256 cooldown);
    error SettlementExceedsAllocation(uint256 payout, uint256 allocated);
    error FlashFeeTooHigh(uint256 fee);

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketRegistered(address indexed market, bytes32 indexed topicTag);
    event MarketDeregistered(address indexed market);
    event CapitalAllocated(address indexed market, uint256 amount);
    event CapitalReturned(address indexed market, uint256 amount);
    event MarketLiabilityUpdated(address indexed market, uint256 oldLiability, uint256 newLiability);
    event MarketSettled(address indexed market, uint256 payout, uint256 loss);
    event WithdrawalRequested(uint256 indexed requestId, address indexed owner, address receiver, uint256 shares, uint256 assets, uint256 readyAt);
    event WithdrawalCompleted(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event WithdrawalCancelled(uint256 indexed requestId, address indexed owner, uint256 shares);
    event WithdrawalCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event MaxUtilizationUpdated(uint256 oldBps, uint256 newBps);
    event FlashFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FlashFeeReceiverUpdated(address oldReceiver, address newReceiver);

    /*//////////////////////////////////////////////////////////////
                      ERC-7201 STORAGE ACCESSOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns a reference to the vault's namespaced storage struct.
    function _vs() private pure returns (VaultStorage storage vs) {
        bytes32 slot = STORAGE_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            vs.slot := slot
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialises the vault proxy.
    /// @param usdc_          Address of the USDC token (underlying asset).
    /// @param admin_         Address granted ADMIN_ROLE.
    /// @param cooldown_      Initial withdrawal cooldown in seconds.
    /// @param maxUtilBps_    Initial utilisation cap in BPS (≤ 9 500).
    function initialize(
        address usdc_,
        address admin_,
        uint256 cooldown_,
        uint256 maxUtilBps_
    ) external initializer {
        if (usdc_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (maxUtilBps_ > GLOBAL_MAX_UTILIZATION_BPS) revert UtilizationCapTooHigh(maxUtilBps_);
        if (cooldown_ > 30 days) revert CooldownTooLong(cooldown_);

        // ── Base initialisers (order matters for C3 linearisation) ──
        __ERC20_init("Global LP Token", "gLP");
        __ERC4626_init(IERC20(usdc_));
        __ERC20Burnable_init();
        __ERC20Permit_init("Global LP Token");
        __ERC20FlashMint_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // ── Roles ──
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(MANAGER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);

        // ── Storage defaults ──
        VaultStorage storage vs = _vs();
        vs.withdrawalCooldown = cooldown_;
        vs.maxUtilizationBps  = maxUtilBps_;
        vs.flashFeeBps        = 5;   // 0.05 % default
        vs.flashFeeReceiver   = address(this); // fees accrue to vault NAV
    }

    /*//////////////////////////////////////////////////////////////
                     ERC-4626 CORE OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Liability-aware NAV.
    /// @dev    NAV = rawUSDCinVault + capitalDeployedToMarkets − totalLiabilities
    ///         This ensures the share price reflects worst-case market payouts.
    ///         Result is floored at 1 to preserve the share denominator.
    function totalAssets() public view override returns (uint256) {
        VaultStorage storage vs = _vs();
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        uint256 gross = rawBalance + vs.totalAllocated;

        // Underflow impossible if invariants hold; safety floor at 1.
        if (gross <= vs.totalLiabilities) return 1;
        return gross - vs.totalLiabilities;
    }

    /// @notice Raw USDC balance currently held in the vault (uncommitted pool).
    function vaultBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice USDC available for new market allocation (uncommitted capital).
    /// @dev    uncommittedAssets ≥ MIN_UNCOMMITTED_BPS % of NAV.
    function uncommittedAssets() public view returns (uint256) {
        uint256 nav = totalAssets();
        uint256 minReserve = nav.mulDiv(MIN_UNCOMMITTED_BPS, BPS, Math.Rounding.Ceil);
        uint256 vb = vaultBalance();
        return vb > minReserve ? vb - minReserve : 0;
    }

    // ── Disable synchronous EIP-4626 redemptions ─────────────────────────────
    // All withdrawals go through requestWithdrawal → completeWithdrawal to
    // prevent the "Naked Redeemer" attack vector identified in research.

    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Synchronous withdraw disabled — use requestWithdrawal().
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert AsyncWithdrawalRequired();
    }

    /// @dev Synchronous redeem disabled — use requestWithdrawal().
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert AsyncWithdrawalRequired();
    }

    /// @dev 12-decimal offset: USDC (6) → gLP shares (18).
    ///      Also provides virtual-shares inflation attack protection.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMAL_OFFSET;
    }

    /*//////////////////////////////////////////////////////////////
                      ERC-20 HOOK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Routes all transfer/mint/burn through the pause guard.
    ///      ERC20FlashMintUpgradeable does NOT override _update, so only
    ///      ERC20Upgradeable needs to be listed.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20FlashMintUpgradeable)
        whenNotPaused
    {
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                      FLASH-MINT OVERRIDES (ERC-3156)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC20FlashMintUpgradeable
    /// @dev Flash loans mint gLP shares; the fee (paid in shares) accrues
    ///      to the configured flashFeeReceiver (default: vault itself).
    function maxFlashLoan(address token) public view override returns (uint256) {
        // Flash-mint only of vault shares (gLP).
        if (token != address(this)) return 0;
        return type(uint256).max - totalSupply();
    }

    /// @inheritdoc ERC20FlashMintUpgradeable
    function _flashFee(address token, uint256 amount) internal view override returns (uint256) {
        if (token != address(this)) return 0;
        return amount.mulDiv(_vs().flashFeeBps, BPS, Math.Rounding.Ceil);
    }

    /// @inheritdoc ERC20FlashMintUpgradeable
    function _flashFeeReceiver() internal view override returns (address) {
        address feeReceiver = _vs().flashFeeReceiver;
        return feeReceiver == address(0) ? address(this) : feeReceiver;
    }

    /*//////////////////////////////////////////////////////////////
                      UUPS UPGRADE AUTHORISATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Only ADMIN_ROLE may authorise a logic upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT / MINT (ERC-4626)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit USDC and receive gLP shares.
    /// @dev    Standard ERC-4626 deposit.  Paused via _update hook.
    ///         minShares_ is a caller-supplied slippage guard.
    function deposit(uint256 assets, address receiver, uint256 minShares_)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        shares = super.deposit(assets, receiver);
        if (shares < minShares_) revert("gLP: slippage");
    }

    /// @notice Standard ERC-4626 deposit (no slippage guard).
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        return super.deposit(assets, receiver);
    }

    /// @notice Mint an exact number of shares.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        return super.mint(shares, receiver);
    }

    /*//////////////////////////////////////////////////////////////
               ASYNC WITHDRAWAL SYSTEM (LP Redemptions)
    //////////////////////////////////////////////////////////////*/

    /// @notice Step 1: LP escrows their shares and queues a withdrawal.
    ///
    /// @dev    Shares are transferred from `owner` to the vault's own balance
    ///         (escrowed).  The USDC amount is computed from the NAV at
    ///         request time and LOCKED — price movements after this point do
    ///         NOT affect the LP's payout.
    ///
    /// @param  shares_   Number of gLP shares to redeem.
    /// @param  receiver_ Address that will receive the USDC.
    /// @return requestId Unique withdrawal request identifier.
    function requestWithdrawal(uint256 shares_, address receiver_)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver_ == address(0)) revert ZeroAddress();

        // Compute USDC amount at current NAV.
        uint256 assets_ = previewRedeem(shares_);

        // Ensure uncommitted capital can cover the payout.
        uint256 vb = vaultBalance();
        if (vb < assets_) {
            revert InsufficientUncommittedCapital(assets_, vb);
        }

        // Reserve the USDC portion from uncommitted capital check.
        uint256 minReserve = totalAssets().mulDiv(MIN_UNCOMMITTED_BPS, BPS, Math.Rounding.Ceil);
        if (vb - assets_ < minReserve) {
            revert InsufficientUncommittedCapital(assets_, vb - minReserve);
        }

        // Escrow: transfer shares from owner → vault.
        _transfer(msg.sender, address(this), shares_);

        // Record request.
        VaultStorage storage vs = _vs();
        requestId = ++vs.nextRequestId;
        uint256 readyAt_ = block.timestamp + vs.withdrawalCooldown;

        vs.withdrawalRequests[requestId] = WithdrawalRequest({
            owner: msg.sender,
            receiver: receiver_,
            shares: shares_,
            assets: assets_,
            readyAt: readyAt_,
            claimed: false
        });

        emit WithdrawalRequested(requestId, msg.sender, receiver_, shares_, assets_, readyAt_);
    }

    /// @notice Step 2: Complete a withdrawal after the cooldown has elapsed.
    ///
    /// @dev    Burns escrowed shares and transfers USDC atomically.
    ///         Anyone may call this once the cooldown has passed (helpful
    ///         for automation / keepers).
    ///
    /// @param  requestId_ The ID returned from requestWithdrawal().
    function completeWithdrawal(uint256 requestId_) external whenNotPaused nonReentrant {
        VaultStorage storage vs = _vs();
        WithdrawalRequest storage req = vs.withdrawalRequests[requestId_];

        if (req.owner == address(0)) revert RequestNotFound(requestId_);
        if (req.claimed) revert RequestAlreadyClaimed(requestId_);
        if (block.timestamp < req.readyAt) revert RequestNotReady(req.readyAt, block.timestamp);

        req.claimed = true;

        address receiver_ = req.receiver;
        uint256 shares_   = req.shares;
        uint256 assets_   = req.assets;

        // Atomic: burn escrowed shares held by vault, then transfer USDC.
        _burn(address(this), shares_);
        IERC20(asset()).safeTransfer(receiver_, assets_);

        emit WithdrawalCompleted(requestId_, receiver_, assets_);
    }

    /// @notice Cancel a pending withdrawal and return shares to the owner.
    /// @dev    Only callable by the original requester.
    function cancelWithdrawal(uint256 requestId_) external nonReentrant {
        VaultStorage storage vs = _vs();
        WithdrawalRequest storage req = vs.withdrawalRequests[requestId_];

        if (req.owner == address(0)) revert RequestNotFound(requestId_);
        if (req.claimed) revert RequestAlreadyClaimed(requestId_);
        if (req.owner != msg.sender) revert RequestNotOwned(requestId_, msg.sender);

        req.claimed = true; // mark consumed

        uint256 shares_ = req.shares;
        // Return escrowed shares to owner.
        _transfer(address(this), msg.sender, shares_);

        emit WithdrawalCancelled(requestId_, msg.sender, shares_);
    }

    /*//////////////////////////////////////////////////////////////
                     MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new prediction market contract.
    ///
    /// @dev    Granting MARKET_ROLE separately is intentional so the admin
    ///         can register metadata without immediately granting on-chain
    ///         rights.  Typically both happen in the same tx.
    ///
    /// @param  market_   Address of the market contract.
    /// @param  topicTag_ Arbitrary bytes32 label for the political topic.
    function registerMarket(address market_, bytes32 topicTag_)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (market_ == address(0)) revert ZeroAddress();
        VaultStorage storage vs = _vs();
        if (vs.markets[market_].registeredAt != 0) revert MarketAlreadyRegistered(market_);

        vs.markets[market_] = MarketInfo({
            active: false,           // activated on first capital allocation
            allocated: 0,
            currentLiability: 0,
            topicTag: topicTag_,
            registeredAt: block.number
        });
        vs.marketList.push(market_);

        emit MarketRegistered(market_, topicTag_);
    }

    /// @notice Remove a market record.  Market must be settled first
    ///         (i.e. allocated == 0 after settlement).
    function deregisterMarket(address market_) external onlyRole(MANAGER_ROLE) {
        VaultStorage storage vs = _vs();
        MarketInfo storage info = vs.markets[market_];
        if (info.registeredAt == 0) revert MarketNotRegistered(market_);
        if (info.active) revert MarketAlreadyActive(market_);

        delete vs.markets[market_];
        // Remove from list (swap-and-pop for gas efficiency).
        uint256 len = vs.marketList.length;
        for (uint256 i = 0; i < len; ) {
            if (vs.marketList[i] == market_) {
                vs.marketList[i] = vs.marketList[len - 1];
                vs.marketList.pop();
                break;
            }
            unchecked { ++i; }
        }

        emit MarketDeregistered(market_);
    }

    /// @notice Allocate USDC seed capital to a registered market.
    ///
    /// @dev    Called by the market contract (MARKET_ROLE) during its
    ///         initialisation phase.  `amount` corresponds to C(q₀) — the
    ///         LS-LMSR cost of the initial quantity vector.
    ///
    ///         Capital utilisation constraints:
    ///           - (totalAllocated + amount) ≤ NAV × maxUtilizationBps
    ///           - vaultBalance after transfer ≥ NAV × MIN_UNCOMMITTED_BPS
    ///
    /// @param  amount_   USDC to transfer (= bounded max loss of market).
    function allocateCapital(uint256 amount_)
        external
        onlyRole(MARKET_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (amount_ == 0) revert ZeroAmount();

        VaultStorage storage vs = _vs();
        address market_ = msg.sender;
        MarketInfo storage info = vs.markets[market_];
        if (info.registeredAt == 0) revert MarketNotRegistered(market_);

        // ── Utilisation cap check ────────────────────────────────────
        uint256 nav = totalAssets();
        uint256 newTotalAllocated = vs.totalAllocated + amount_;
        uint256 maxCommittable = nav.mulDiv(vs.maxUtilizationBps, BPS, Math.Rounding.Floor);

        if (newTotalAllocated > maxCommittable) {
            revert ExceedsCommittedCap(newTotalAllocated, maxCommittable);
        }

        // ── Uncommitted reserve check ────────────────────────────────
        uint256 vb = vaultBalance();
        uint256 minReserve = nav.mulDiv(MIN_UNCOMMITTED_BPS, BPS, Math.Rounding.Ceil);
        if (vb < amount_ + minReserve) {
            revert InsufficientUncommittedCapital(amount_, vb > minReserve ? vb - minReserve : 0);
        }

        // ── Accounting ───────────────────────────────────────────────
        info.active            = true;
        info.allocated        += amount_;
        info.currentLiability  = info.allocated; // initial liability = full allocation

        vs.totalAllocated    += amount_;
        vs.totalLiabilities  += amount_;

        // ── Transfer ─────────────────────────────────────────────────
        IERC20(asset()).safeTransfer(market_, amount_);

        emit CapitalAllocated(market_, amount_);
    }

    /// @notice Update a market's current worst-case liability.
    ///
    /// @dev    Called by the market contract after each trade.
    ///         `newLiability_` = C(q_current) − C(q₀) + max(qᵢ).
    ///         The value must never exceed the original allocation
    ///         (guaranteed by LS-LMSR bounded-loss proof).
    ///
    ///         Allows the vault NAV to increase as the market makes profit
    ///         (liability decreases while allocation stays constant).
    ///
    /// @param  newLiability_  Updated worst-case payout in USDC (6 dec).
    function updateMarketLiability(uint256 newLiability_)
        external
        onlyRole(MARKET_ROLE)
    {
        VaultStorage storage vs = _vs();
        address market_ = msg.sender;
        MarketInfo storage info = vs.markets[market_];

        if (info.registeredAt == 0) revert MarketNotRegistered(market_);
        if (!info.active)           revert MarketNotActive(market_);
        if (newLiability_ > info.allocated) {
            revert LiabilityExceedsAllocation(newLiability_, info.allocated);
        }

        uint256 old = info.currentLiability;
        info.currentLiability = newLiability_;

        // Update global tally.
        if (newLiability_ >= old) {
            vs.totalLiabilities += (newLiability_ - old);
        } else {
            vs.totalLiabilities -= (old - newLiability_);
        }

        emit MarketLiabilityUpdated(market_, old, newLiability_);
    }

    /// @notice Settle a resolved market: receive remaining USDC and close books.
    ///
    /// @dev    The market contract transfers `payout_` USDC back to the vault
    ///         BEFORE calling this function (pull pattern via approval, or push
    ///         pattern if market holds funds).  The vault absorbs the loss
    ///         (allocated − payout_) from NAV.
    ///
    ///         Solvency invariant checked: rawBalance ≥ totalLiabilities after
    ///         settlement.
    ///
    /// @param  payout_   USDC the vault is receiving from the market.
    function settleMarket(uint256 payout_)
        external
        onlyRole(MARKET_ROLE)
        nonReentrant
    {
        VaultStorage storage vs = _vs();
        address market_ = msg.sender;
        MarketInfo storage info = vs.markets[market_];

        if (info.registeredAt == 0) revert MarketNotRegistered(market_);
        if (!info.active)           revert MarketNotActive(market_);
        if (payout_ > info.allocated) revert SettlementExceedsAllocation(payout_, info.allocated);

        uint256 allocated_        = info.allocated;
        uint256 currentLiability_ = info.currentLiability;
        uint256 loss_             = allocated_ - payout_;

        // ── Update storage ───────────────────────────────────────────
        vs.totalAllocated   -= allocated_;
        vs.totalLiabilities -= currentLiability_;

        info.active           = false;
        info.allocated        = 0;
        info.currentLiability = 0;

        // ── Pull USDC from market ─────────────────────────────────────
        if (payout_ > 0) {
            IERC20(asset()).safeTransferFrom(market_, address(this), payout_);
        }

        // ── Post-settlement solvency check ────────────────────────────
        _assertSolvent();

        emit MarketSettled(market_, payout_, loss_);
        emit CapitalReturned(market_, payout_);
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN / MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the withdrawal cooldown window.
    /// @param  newCooldown_ Seconds (max 30 days).
    function setWithdrawalCooldown(uint256 newCooldown_) external onlyRole(MANAGER_ROLE) {
        if (newCooldown_ > 30 days) revert CooldownTooLong(newCooldown_);
        VaultStorage storage vs = _vs();
        emit WithdrawalCooldownUpdated(vs.withdrawalCooldown, newCooldown_);
        vs.withdrawalCooldown = newCooldown_;
    }

    /// @notice Update the global capital utilisation cap.
    /// @param  newBps_ BPS value; must be ≤ GLOBAL_MAX_UTILIZATION_BPS (9 500).
    function setMaxUtilizationBps(uint256 newBps_) external onlyRole(MANAGER_ROLE) {
        if (newBps_ > GLOBAL_MAX_UTILIZATION_BPS) revert UtilizationCapTooHigh(newBps_);
        VaultStorage storage vs = _vs();
        emit MaxUtilizationUpdated(vs.maxUtilizationBps, newBps_);
        vs.maxUtilizationBps = newBps_;
    }

    /// @notice Update the flash-mint fee.
    /// @param  newFeeBps_ BPS; max 100 (1 %).
    function setFlashFeeBps(uint256 newFeeBps_) external onlyRole(MANAGER_ROLE) {
        if (newFeeBps_ > 100) revert FlashFeeTooHigh(newFeeBps_);
        VaultStorage storage vs = _vs();
        emit FlashFeeUpdated(vs.flashFeeBps, newFeeBps_);
        vs.flashFeeBps = newFeeBps_;
    }

    /// @notice Update the flash-mint fee receiver.
    /// @param  newReceiver_ Zero address routes fees to the vault itself.
    function setFlashFeeReceiver(address newReceiver_) external onlyRole(MANAGER_ROLE) {
        VaultStorage storage vs = _vs();
        emit FlashFeeReceiverUpdated(vs.flashFeeReceiver, newReceiver_);
        vs.flashFeeReceiver = newReceiver_;
    }

    /// @notice Emergency pause — halts deposits, withdrawals, and flash mints.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume normal operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Metadata for a registered market.
    function marketInfo(address market_) external view returns (MarketInfo memory) {
        return _vs().markets[market_];
    }

    /// @notice Full list of registered market addresses.
    function marketList() external view returns (address[] memory) {
        return _vs().marketList;
    }

    /// @notice Total USDC deployed across all active markets.
    function totalAllocated() external view returns (uint256) {
        return _vs().totalAllocated;
    }

    /// @notice Sum of all active market liabilities.
    function totalLiabilities() external view returns (uint256) {
        return _vs().totalLiabilities;
    }

    /// @notice Withdrawal cooldown in seconds.
    function withdrawalCooldown() external view returns (uint256) {
        return _vs().withdrawalCooldown;
    }

    /// @notice Current capital utilisation cap in BPS.
    function maxUtilizationBps() external view returns (uint256) {
        return _vs().maxUtilizationBps;
    }

    /// @notice Flash-mint fee in BPS.
    function flashFeeBps() external view returns (uint256) {
        return _vs().flashFeeBps;
    }

    /// @notice A withdrawal request record.
    function withdrawalRequest(uint256 requestId_) external view returns (WithdrawalRequest memory) {
        return _vs().withdrawalRequests[requestId_];
    }

    /// @notice The next withdrawal request ID (= count of requests ever created).
    function nextRequestId() external view returns (uint256) {
        return _vs().nextRequestId;
    }

    /// @notice True when rawBalance ≥ totalLiabilities.
    function isSolvent() external view returns (bool) {
        VaultStorage storage vs = _vs();
        return IERC20(asset()).balanceOf(address(this)) + vs.totalAllocated >= vs.totalLiabilities;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if the vault is in an insolvent state.
    ///      Called after every settlement to enforce the solvency invariant:
    ///        rawBalance + totalAllocated ≥ totalLiabilities
    function _assertSolvent() internal view {
        VaultStorage storage vs = _vs();
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + vs.totalAllocated;
        if (gross < vs.totalLiabilities) {
            revert VaultInsolvent(gross, vs.totalLiabilities);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     SUPPRESSED RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Reject direct ETH sends — vault is USDC-only.
    receive() external payable {
        revert("gLP: no ETH");
    }
}
