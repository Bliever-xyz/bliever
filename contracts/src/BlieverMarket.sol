// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                    OPENZEPPELIN — UPGRADEABLE
//////////////////////////////////////////////////////////////*/
import {Initializable}        from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable}  from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                    OPENZEPPELIN — STANDARD
//////////////////////////////////////////////////////////////*/
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20}                   from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit}             from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/*//////////////////////////////////////////////////////////////
                    INTERNAL
//////////////////////////////////////////////////////////////*/
import {LSMath}         from "./LSMath.sol";
import {IBlieverV1Pool} from "./interfaces/IBlieverV1Pool.sol";
import {IDeployableMarket} from "./interfaces/IDeployableMarket.sol";

/// @title  BlieverMarket — LS-LMSR Prediction Market Implementation
/// @author Believer Protocol
/// @notice Ephemeral, lightweight master implementation contract for a single prediction
///         market event. Designed to be cloned thousands of times via EIP-1167 Minimal
///         Proxy (CREATE2 + clone) by the BlieverMarketFactory.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ARCHITECTURE PRINCIPLE: PURE MATH WRAPPER
///         ─────────────────────────────────────────────────────────────────────────
///         This contract holds NO USDC. Every dollar lives in BlieverV1Pool.
///         BlieverMarket is responsible for:
///           1. Maintaining the AMM's quantity vector (q-vector) per LS-LMSR.
///           2. Maintaining the per-trader Internal Ledger (Covered Short Selling).
///           3. Computing trade costs / refunds via LSMath (pure math, no state).
///           4. Routing USDC movements to BlieverV1Pool via MARKET_ROLE calls.
///           5. Accepting a single resolution signal from the Resolution Adapter.
///         This contract does NOT:
///           • Format or submit UMA oracle requests.
///           • Interpret oracle payloads or ancillary data.
///           • Hold, mint, or burn any ERC-20 tokens.
///           • Duplicate LP, reserve, or vault NAV logic.
///
///         ─────────────────────────────────────────────────────────────────────────
///         INTERNAL LEDGER RULE & COVERED SHORT SELLING (CSS)
///         ─────────────────────────────────────────────────────────────────────────
///         Shares are non-transferable internal balances (mappings), NOT ERC-20 tokens.
///         This is mandatory for CSS correctness: the AMM must always know a trader's
///         exact per-outcome position (q^t) to enforce the positive-orthant invariant.
///
///         When a trader sells more of outcome i than they hold, CSS automatically
///         translates the trade: t_bar = shareAmount − q^t[i] extra "guaranteed
///         payout" shares are purchased across ALL outcomes, making q^t[i] = 0
///         and q^t[j] += t_bar for j ≠ i.  Net effect: the trader can never hold a
///         negative balance on any outcome. No punitive "no-selling" friction applies.
///
///         ─────────────────────────────────────────────────────────────────────────
///         DECIMAL CONVENTION
///         ─────────────────────────────────────────────────────────────────────────
///         • Shares / quantities:  18-decimal fixed point  (LSMath SCALE = 1e18)
///         • USDC amounts:          6-decimal               (USDC native)
///         • Conversion constant:  SHARE_TO_USDC = 1e12    (= 10^(18−6))
///         • 1 winning share (1e18 units) = 1 USDC (1e6 units) at settlement.
///
///         ─────────────────────────────────────────────────────────────────────────
///         EIP-1167 CLONE COMPATIBILITY
///         ─────────────────────────────────────────────────────────────────────────
///         • Constructor calls `_disableInitializers()` — the master contract must
///           never be usable in isolation.
///         • `initialize()` replaces the constructor and is called exactly once per clone.
///         • All storage mutated after `initialize()` lives in the CLONE's storage.
///         • The master's code is shared but never executes with its own storage.
///
/// @dev    Inheritance stack: Initializable → ReentrancyGuardTransient → PausableUpgradeable.
///         No UUPS upgrade logic — clones are immutable by design (security requirement).
///         ReentrancyGuardTransient uses EIP-1153 transient storage: no persistent slot consumed
///         and no initialiser call required, saving ~2 000 gas on every guarded function.
contract BlieverMarket is Initializable, ReentrancyGuardTransient, PausableUpgradeable, IDeployableMarket {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Scale factor bridging 18-dec LSMath quantities and 6-dec USDC amounts.
    ///         cost_usdc  = cost_18dec  / SHARE_TO_USDC  (floor → vault-protective on refunds)
    ///         cost_usdc  = (cost_18dec + SHARE_TO_USDC - 1) / SHARE_TO_USDC  (ceil → on buys)
    uint256 internal constant SHARE_TO_USDC = 1e12;

    /// @notice LSMath fixed-point scale (1e18).  Imported explicitly for readability.
    uint256 internal constant MATH_SCALE = 1e18;

    /// @notice Minimum share amount accepted by buy() and sell() (18-dec).
    ///         Prevents dust positions that consume an SSTORE and emit an event for an
    ///         economically negligible amount.  0.001 shares = 1e15 units (18-dec).
    uint256 internal constant MIN_SHARE_AMOUNT = 1e15;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the Resolution Adapter
    error NotResolver();
    /// @notice Caller is not the Market Factory (admin)
    error NotFactory();
    /// @notice A required address parameter was the zero address
    error ZeroAddress();
    /// @notice A required uint256 parameter was zero
    error ZeroAmount();
    /// @notice The initial epsilon seed was zero
    error ZeroEpsilon();
    /// @notice outcomeIndex is out of bounds [0, outcomeCount)
    error InvalidOutcomeIndex(uint256 index, uint256 max);
    /// @notice outcomeCount is not in the allowed range [2, 100]
    error InvalidOutcomeCount(uint256 count);
    /// @notice alpha is outside [MIN_ALPHA, MAX_ALPHA] from LSMath
    error InvalidAlpha(uint256 value);
    /// @notice tradingDeadline or resolutionDeadline are inconsistent or in the past
    error InvalidDeadlines();
    /// @notice Trade submitted after the trading deadline
    error TradingClosed();
    /// @notice resolve() was called but the market is already resolved
    error MarketAlreadyResolved();
    /// @notice claim() was called but the market is not yet resolved
    error MarketNotResolved();
    /// @notice This address has already claimed their winnings
    error AlreadyClaimed();
    /// @notice Caller has zero winning shares and nothing to claim
    error NoWinningShares();
    /// @notice Trade cost / refund fell outside the trader's slippage tolerance
    /// @param actual  The real cost/refund computed by the AMM (6-dec USDC)
    /// @param limit   The slippage limit provided by the trader (6-dec USDC)
    error SlippageExceeded(uint256 actual, uint256 limit);
    /// @notice Resolution deadline has already passed (resolver was too slow)
    error ResolutionDeadlinePassed();
    /// @notice Resolution deadline has NOT yet passed (too early to expire)
    error ResolutionDeadlineNotPassed();
    /// @notice The AMM's q-vector would go negative (AMM accounting invariant)
    error InsufficientMarketQuantity();
    /// @notice C(qNew) < C(qOld) on a buy — should never happen; indicates LSMath bug
    error NegativeBuyCost();
    /// @notice share amount is below MIN_SHARE_AMOUNT (dust-trade guard)
    error ShareAmountTooSmall(uint256 amount, uint256 minimum);
    /// @notice Permit signature was consumed (front-run) and existing allowance is insufficient
    error InsufficientPermitAllowance();

    /*//////////////////////////////////////////////////////////////
                          TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reason an unresolved market was expired by the factory via expireUnresolved().
    ///         TIMEOUT: resolutionDeadline passed with no oracle resolution.
    ///         Reserved for future oracle-failure variants (e.g. ORACLE_ERROR) without
    ///         ABI breakage — callers must handle unknown enum values gracefully.
    enum ExpiryReason { TIMEOUT }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once when the clone is initialised by the factory.
    event MarketInitialized(
        bytes32 indexed questionId,
        address indexed pool,
        uint8           outcomeCount,
        uint256         alpha,
        uint40          tradingDeadline,
        uint40          resolutionDeadline,
        uint256         epsilon
    );

    /// @notice Emitted on every successful buy trade.
    /// @param trader        Buyer address
    /// @param outcomeIndex  Which outcome was purchased
    /// @param shareAmount   Shares minted to the trader's internal ledger (18-dec)
    /// @param costUsdc      USDC collected from trader via pool (6-dec)
    event Bought(
        address indexed trader,
        uint256 indexed outcomeIndex,
        uint256         shareAmount,
        uint256         costUsdc
    );

    /// @notice Emitted on every successful sell trade (including CSS-translated sells).
    /// @param trader               Seller address
    /// @param outcomeIndex         Primary outcome being reduced
    /// @param requestedSellAmount  Shares the trader requested to sell (18-dec)
    /// @param cssTranslation       CSS t_bar applied; 0 if trader had sufficient shares (18-dec)
    /// @param netRefundUsdc        Net USDC refunded from pool (0 if trader paid instead)
    /// @param netCostUsdc          Net USDC collected from trader (0 if trader received refund)
    event Sold(
        address indexed trader,
        uint256 indexed outcomeIndex,
        uint256         requestedSellAmount,
        uint256         cssTranslation,
        uint256         netRefundUsdc,
        uint256         netCostUsdc
    );

    /// @notice Emitted when the Resolution Adapter calls resolve().
    /// @param winningOutcome   Index of the outcome that resolved as true
    /// @param totalPayoutUsdc  USDC reserved for all winning share-holders (6-dec)
    event MarketResolved(
        uint8   indexed winningOutcome,
        uint256         totalPayoutUsdc
    );

    /// @notice Emitted when a winner successfully claims their payout.
    /// @param winner          Address receiving USDC
    /// @param winningOutcome  Winning outcome index (for indexing convenience)
    /// @param shareAmount     Winner's internal ledger balance (18-dec) that was redeemed
    /// @param payoutUsdc      USDC transferred from vault to winner (6-dec)
    event WinningsClaimed(
        address indexed winner,
        uint8   indexed winningOutcome,
        uint256         shareAmount,
        uint256         payoutUsdc
    );

    /// @notice Emitted when the factory expires an unresolved market past its deadline.
    /// @param reason  Classification of why the market was expired — aids off-chain indexing
    ///                and post-mortem analytics without requiring callers to infer cause from
    ///                context.  Currently always TIMEOUT; reserved for future oracle-error paths.
    event MarketExpired(address indexed factory, uint40 timestamp, ExpiryReason reason);

    /// @notice Emitted when a winner's share balance rounds to zero USDC (dust position).
    ///         The caller's `_claimed` flag is set to `true`; no USDC is transferred and
    ///         the pool's `claimWinnings` is never called.  The dust share value is already
    ///         excluded from `settledPayout` (floor division in `resolve()`) and is silently
    ///         absorbed into LP NAV as part of the market-making cost — no funds are locked.
    /// @param winner          Address whose dust claim was processed
    /// @param winningOutcome  Winning outcome index
    /// @param shareAmount     Dust balance (18-dec); convertible USDC value = 0
    event DustForfeited(
        address indexed winner,
        uint8   indexed winningOutcome,
        uint256         shareAmount
    );

    /*//////////////////////////////////////////////////////////////
                     STORAGE — CAREFULLY LAID OUT FOR CLONES
         Order is critical: Solidity packs smaller types into shared slots.
         Reordering would corrupt every deployed clone's storage.
    //////////////////////////////////////////////////////////////*/

    // ── Packed Slot A ── (20 + 1 + 1 + 1 = 23 bytes, 9 bytes free in same slot)
    /// @notice BlieverV1Pool vault this market routes all USDC through.
    address public pool;            // 20 bytes
    /// @notice Number of mutually exclusive outcomes  ∈ [2, 100].
    uint8   public outcomeCount;    // 1 byte
    /// @notice True after resolve() succeeds.
    bool    public resolved;        // 1 byte
    /// @notice Winning outcome index. Only valid when resolved == true.
    uint8   public winningOutcome;  // 1 byte

    // ── Packed Slot B ── (20 + 5 + 5 = 30 bytes, 2 bytes free)
    /// @notice Resolution Adapter address.  Only address that may call resolve().
    address public resolver;          // 20 bytes
    /// @notice Unix timestamp (seconds): first second at which buy / sell is no longer accepted.
    ///         Trading is permitted while block.timestamp < tradingDeadline; the deadline second
    ///         itself is closed (TradingClosed reverts at block.timestamp >= tradingDeadline).
    uint40  public tradingDeadline;   // 5 bytes
    /// @notice Unix timestamp (seconds): first second at which resolve() is no longer accepted.
    ///         The resolver must call resolve() before this timestamp.
    ///         After this second passes without resolution, the factory may call expireUnresolved().
    uint40  public resolutionDeadline; // 5 bytes

    // ── Slot C ── (20 bytes, 12 free — factory address, padded)
    /// @notice MarketFactory address.  Only address that may pause / unpause / expire.
    address public factory;  // 20 bytes

    // ── Slot D ── (32 bytes — UMA oracle question identifier)
    /// @notice Unique identifier linking this market to its UMA oracle request.
    ///         Passed to the Resolution Adapter when the DVM returns a result.
    bytes32 public questionId;

    // ── Slot E ── (32 bytes — LS-LMSR alpha)
    /// @notice LS-LMSR commission parameter α (18-dec, range [1e12, 2e17]).
    ///         Set once at initialization from pool.alpha at registration time.
    ///         Determines price sensitivity and worst-case loss bound.
    uint256 public alpha;

    // ── Slot F ── (20 bytes — USDC token address, padded to 32)
    /// @notice USDC token address, fetched from `pool.asset()` exactly once during
    ///         `initialize()` and cached here.  Eliminates a live external call to the
    ///         pool on every permit-path `buy()` and on every `usdcToken()` view call.
    address public usdc;

    // ── Dynamic Array Slots ───────────────────────────────────────────────────

    /// @notice Current AMM quantity vector q (18-dec).
    ///         q[i] = total shares outstanding for outcome i across ALL traders.
    ///         Starts at [ε, ε, ..., ε]; updated on every buy and sell.
    uint256[] internal _quantities;

    /// @notice Initial AMM quantity vector q⁰ (18-dec), set once in initialize().
    ///         Retained for the getInitialQuantities() view. Not read in the trading hot path.
    ///         Satisfies: C(q⁰) / SHARE_TO_USDC = pool.maxRiskPerMarket.
    uint256[] internal _initialQuantities;

    /// @notice C(q⁰) — the LS-LMSR cost function evaluated at the initial quantity vector.
    ///         Computed and stored exactly once in initialize(). Never mutated afterwards.
    ///         On every buy/sell, worst-case vault liability is computed via
    ///         LSMath.calculateWorstCaseLossFromCosts(costNew, _initialCost, qNew), which
    ///         replaces the full _loadInitialQuantities() + costFunction(q⁰) sequence with
    ///         a single warm SLOAD — saving ~40,000–60,000 gas per trade on a 10-outcome market.
    uint256 internal _initialCost;

    // ── Mapping Slots ─────────────────────────────────────────────────────────

    /// @notice Per-trader, per-outcome share balance (18-dec, always ≥ 0).
    ///         Internal ledger enforcing CSS: shares[trader][i] = q^t_i.
    ///         NOT an ERC-20: no transfer(), approve(), or transferFrom() methods exist.
    mapping(address => mapping(uint256 => uint256)) internal _shares;

    /// @notice Tracks total shares held by ALL traders for each outcome (18-dec).
    ///         Excludes the initial epsilon seed — used to compute the exact winner payout
    ///         and prevent epsilon dust from blocking MARKET_ROLE revocation on the pool.
    mapping(uint256 => uint256) internal _totalTraderShares;

    /// @notice Claim-once guard per address.  True after a winner has called claim().
    mapping(address => bool) internal _claimed;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Disables all initializers on the master implementation contract.
    ///      This prevents the master itself from being used as a live market —
    ///      only EIP-1167 clones (with their own storage) are valid markets.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if trading is no longer permitted.
    ///      Trading closes at tradingDeadline OR when the market is resolved.
    ///      Logic is delegated to _tradingOpen() so the compiler emits the check
    ///      body once rather than inlining it at every call site (code-size saving).
    modifier tradingOpen() {
        _tradingOpen();
        _;
    }

    /// @dev Reverts if the caller is not the Resolution Adapter.
    ///      Logic delegated to _onlyResolver() for code-size efficiency.
    modifier onlyResolver() {
        _onlyResolver();
        _;
    }

    /// @dev Reverts if the caller is not the Market Factory.
    ///      Logic delegated to _onlyFactory() for code-size efficiency.
    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time initialiser — called by the MarketFactory immediately after
    ///         deploying each EIP-1167 clone via CREATE2.
    ///
    ///         Seeding the AMM: Why ε matters
    ///         ─────────────────────────────────
    ///         q⁰ = [ε, ε, ..., ε] is a uniform prior that seeds the AMM with symmetric
    ///         liquidity.  The factory computes ε off-chain so that C(q⁰) = R exactly:
    ///
    ///             For n = 2 outcomes:
    ///             C([ε, ε]) = b * ln(2 · exp(ε/b)) = ε(1 + 2α·ln 2)
    ///             ⟹  ε = R / (1 + α·n·ln n) in 18-dec fixed-point
    ///
    ///         where R = pool.maxRiskPerMarket · SHARE_TO_USDC (converted to 18-dec).
    ///         This guarantees the vault's riskBudget = C(q⁰) / SHARE_TO_USDC = maxRiskPerMarket.
    ///
    ///         USDC Approval Note
    ///         ─────────────────────────────────
    ///         Traders MUST approve the BlieverV1Pool address (not this contract) for USDC.
    ///         The vault's collectTradeCost() calls safeTransferFrom(trader, vault, cost).
    ///
    /// @param _pool               BlieverV1Pool address (all USDC routed here)
    /// @param _questionId         UMA oracle question ID, bound at market creation
    /// @param _nOutcomes          Number of mutually exclusive outcomes [2, 100]
    /// @param _alpha              LS-LMSR α from pool at registration time (18-dec)
    /// @param _tradingDeadline    Unix timestamp: trading closes at this second (inclusive — block.timestamp >= tradingDeadline reverts)
    /// @param _resolutionDeadline Unix timestamp: resolution closes at this second; resolver must call resolve() before this timestamp
    /// @param _epsilon            Per-outcome seed quantity (18-dec).
    ///                            Satisfies: C([ε,...,ε]) / SHARE_TO_USDC ≈ maxRiskPerMarket
    /// @param _resolver           Resolution Adapter address (sole right to call resolve())
    /// @param _factory            MarketFactory address (pause / unpause / expireUnresolved)
    function initialize(
        address _pool,
        bytes32 _questionId,
        uint8   _nOutcomes,
        uint256 _alpha,
        uint40  _tradingDeadline,
        uint40  _resolutionDeadline,
        uint256 _epsilon,
        address _resolver,
        address _factory
    ) external initializer {
        // ── Input Validation ────────────────────────────────────────────────
        if (_pool     == address(0)) revert ZeroAddress();
        if (_resolver == address(0)) revert ZeroAddress();
        if (_factory  == address(0)) revert ZeroAddress();
        if (_nOutcomes < 2 || _nOutcomes > 100)     revert InvalidOutcomeCount(_nOutcomes);
        if (!LSMath.validateAlpha(_alpha))            revert InvalidAlpha(_alpha);
        if (_epsilon == 0)                            revert ZeroEpsilon();
        if (_tradingDeadline   <= uint40(block.timestamp)) revert InvalidDeadlines();
        if (_resolutionDeadline <= _tradingDeadline)       revert InvalidDeadlines();

        // ── OpenZeppelin Upgradeable Initialisers ────────────────────────────
        // ReentrancyGuardTransient uses EIP-1153 transient storage — no init call needed.
        __Pausable_init();

        // ── Config (write once) ──────────────────────────────────────────────
        pool               = _pool;
        questionId         = _questionId;
        outcomeCount       = _nOutcomes;
        alpha              = _alpha;
        tradingDeadline    = _tradingDeadline;
        resolutionDeadline = _resolutionDeadline;
        resolver           = _resolver;
        factory            = _factory;
        usdc               = IBlieverV1Pool(_pool).asset();  // cache once — no live call in hot path

        // ── Seed the AMM with the symmetric initial quantity vector q⁰ ───────
        // All n outcomes initialised to ε (uniform prior, positive orthant entry point).
        uint256 n = _nOutcomes;
        uint256[] memory initQ = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            initQ[i] = _epsilon;
            unchecked { ++i; }
        }

        // Validate that q⁰ produces a valid, non-degenerate liquidity parameter.
        // LSMath.liquidityParameter reverts on ZeroQuantitySum or invalid alpha.
        LSMath.liquidityParameter(initQ, _alpha);

        // Write q and q⁰ to storage (two independent copies — q will be mutated).
        _quantities        = initQ;
        _initialQuantities = initQ;

        // Cache C(q⁰) once — used on every subsequent buy/sell via calculateWorstCaseLossFromCosts.
        // initQ is already in memory here; no additional storage reads required.
        _initialCost = LSMath.costFunction(initQ, _alpha);

        emit MarketInitialized(
            _questionId,
            _pool,
            _nOutcomes,
            _alpha,
            _tradingDeadline,
            _resolutionDeadline,
            _epsilon
        );
    }

    /*//////////////////////////////////////////////////////////////
                          TRADING — BUY
    //////////////////////////////////////////////////////////////*/

    /// @notice Purchase `shareAmount` shares of outcome `outcomeIndex` via the LS-LMSR AMM.
    ///
    ///         Mathematical flow (buy is the simplest case — no CSS translation needed):
    ///         1. Load q (market's current quantity vector from storage → memory).
    ///         2. Build q_new: q_new[outcomeIndex] += shareAmount; all others unchanged.
    ///         3. (tradeCost18, costNew) = LSMath.calculateTradeCostDetailed(qOld, qNew, α)
    ///            Returns C(qNew)−C(qOld) and C(qNew) in one pass — costFunction(qNew) runs once.
    ///            Always > 0 for a buy: C is monotonically increasing in each qi.
    ///         4. cost_usdc  = ⌈tradeCost18 / SHARE_TO_USDC⌉  (ceiling — vault protective).
    ///         5. newLiability = calculateWorstCaseLossFromCosts(costNew, _initialCost, qNew)
    ///            _initialCost = C(q⁰) was cached in initialize(). One warm SLOAD; zero exp/ln math.
    ///         6. Write q_new[outcomeIndex] to storage (single slot), credit shares to ledger.
    ///         7. Call pool.collectTradeCost(trader, cost_usdc, newLiability_usdc).
    ///            The vault pulls cost_usdc USDC from trader (trader must approve VAULT).
    ///
    ///         ── Permit (optional) ──────────────────────────────────────────────
    ///         Pass `v != 0` to attempt an EIP-2612 permit before the transfer.
    ///         If the permit signature has already been consumed (e.g. front-run griefing),
    ///         the call falls back silently to any pre-existing allowance the trader holds.
    ///         Pass `v = 0, r = 0, s = 0, deadline = 0` to skip the permit attempt entirely
    ///         and rely on a pre-existing `USDC.approve(pool, amount)` call.
    ///
    ///        
    ///             (not this contract) for ≥ maxCostUsdc USDC before calling buy(),
    ///             OR supply a valid permit signature via the v/r/s/deadline parameters.
    ///
    /// @param outcomeIndex  Outcome to purchase shares of [0, outcomeCount)
    /// @param shareAmount   Shares to buy (18-dec, ≥ MIN_SHARE_AMOUNT)
    /// @param maxCostUsdc   Maximum USDC the trader will pay (6-dec); slippage guard
    /// @param deadline      EIP-2612 permit deadline (0 = skip permit)
    /// @param v             EIP-2612 permit signature v (0 = skip permit)
    /// @param r             EIP-2612 permit signature r
    /// @param s             EIP-2612 permit signature s
    function buy(
        uint256 outcomeIndex,
        uint256 shareAmount,
        uint256 maxCostUsdc,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused tradingOpen {
        // ── Pre-condition Checks ─────────────────────────────────────────────
        if (shareAmount < MIN_SHARE_AMOUNT)  revert ShareAmountTooSmall(shareAmount, MIN_SHARE_AMOUNT);
        if (outcomeIndex >= outcomeCount)     revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);

        // ── Load AMM State into Memory (single combined loop) ────────────────
        // _loadQuantitiesForBuy reads all n slots once and returns both qOld and qNew,
        // with qNew[outcomeIndex] already incremented by shareAmount.  This replaces the
        // previous separate _loadQuantities + _copyArray pass (2 loops → 1 loop).
        uint256 n      = outcomeCount;
        uint256 _alpha = alpha;

        (uint256[] memory qOld, uint256[] memory qNew) =
            _loadQuantitiesForBuy(n, outcomeIndex, shareAmount);

        // ── Cost Calculation (18-dec → 6-dec USDC) ──────────────────────────
        // calculateTradeCostDetailed returns both tradeCost18 = C(qNew)−C(qOld) and
        // costNew = C(qNew), so the result is reused for the liability update below
        // — costFunction(qNew) runs exactly once.
        (int256 tradeCost18, uint256 costNew) =
            LSMath.calculateTradeCostDetailed(qOld, qNew, _alpha);

        // A buy must always cost ≥ 0 (C is monotone increasing).
        // Negative would indicate a library bug — surface it explicitly.
        if (tradeCost18 < 0) revert NegativeBuyCost();

        // Convert to USDC, rounding UP to protect the vault.
        // forge-lint: disable-next-line(unsafe-typecast)
        // casting to 'uint256' is safe because tradeCost18 >= 0 is proven by the
        // NegativeBuyCost revert directly above; the int256 → uint256 cast cannot truncate.
        uint256 costUsdc = _ceilToUsdc(uint256(tradeCost18));

        // ── Slippage Guard ───────────────────────────────────────────────────
        if (costUsdc > maxCostUsdc) revert SlippageExceeded(costUsdc, maxCostUsdc);

        // ── Compute Updated Vault Liability ──────────────────────────────────
        // Uses the pre-computed costNew (C(qNew)) and the cached _initialCost (C(q⁰)).
        // No _loadInitialQuantities() call; no redundant costFunction(qNew) or costFunction(q⁰).
        // One warm SLOAD for _initialCost replaces n SLOADs + a full O(n) exp/ln pass.
        uint256 newLiability18   = LSMath.calculateWorstCaseLossFromCosts(costNew, _initialCost, qNew);
        uint256 newLiabilityUsdc = _floorToUsdc(newLiability18);

        // ── Effects: Update AMM & Internal Ledger (CEI — before any external call) ──
        // State is committed here, before both the optional permit call and the pool
        // interaction below.  If either external call re-enters (blocked by nonReentrant)
        // or reverts, Solidity unwinds all writes — no partial-state corruption is possible.
        // Only the single mutated slot is written back to storage.
        // All other n-1 slots are unchanged — no wasted SSTOREs.
        _quantities[outcomeIndex] += shareAmount;

        // Credit shares to internal ledger (non-transferable).
        _shares[msg.sender][outcomeIndex] += shareAmount;
        _totalTraderShares[outcomeIndex]  += shareAmount;

        // ── Optional EIP-2612 Permit ─────────────────────────────────────────
        // Attempted only when a real signature is supplied (v != 0).
        // Uses the `usdc` slot cached at initialization — zero external calls here.
        // If the nonce was already consumed by a front-runner, fall back silently
        // to any allowance the trader already holds rather than reverting the buy.
        if (v != 0) {
            try IERC20Permit(usdc).permit(
                msg.sender, pool, maxCostUsdc, deadline, v, r, s
            ) {} catch {
                if (IERC20(usdc).allowance(msg.sender, pool) < maxCostUsdc)
                    revert InsufficientPermitAllowance();
            }
        }

        // ── Interactions: Route USDC Collection to Vault ─────────────────────
        // Vault pulls cost_usdc from trader (trader must have approved vault).
        IBlieverV1Pool(pool).collectTradeCost(msg.sender, costUsdc, newLiabilityUsdc);

        emit Bought(msg.sender, outcomeIndex, shareAmount, costUsdc);
    }

    /*//////////////////////////////////////////////////////////////
                          TRADING — SELL (CSS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Reduce position in outcome `outcomeIndex` by up to `shareAmount` shares.
    ///         Applies Covered Short Selling (CSS) if the trader holds fewer shares
    ///         than requested — see @dev for the full CSS mechanics.
    ///
    ///         CSS Translation Mechanics (Othman et al., Section 3.3.2)
    ///         ─────────────────────────────────────────────────────────
    ///         Let q^t[i] = trader's shares for outcome i.
    ///         Desired sell: delta = [0,..., −shareAmount, ..., 0] at index `outcomeIndex`.
    ///         If q^t[outcomeIndex] < shareAmount:
    ///             t_bar = shareAmount − q^t[outcomeIndex]   (CSS translation scalar)
    ///             actual_delta[outcomeIndex] = −shareAmount + t_bar = −q^t[outcomeIndex]
    ///             actual_delta[i ≠ outcomeIndex] = +t_bar
    ///             ⟹ Trader sells all of outcome `outcomeIndex`, buys t_bar of all others.
    ///         If q^t[outcomeIndex] ≥ shareAmount:
    ///             t_bar = 0  (no translation; trader simply sells shareAmount).
    ///
    ///         After translation, every component of q^t remains ≥ 0 (positive orthant).
    ///
    ///         Cost sign convention:
    ///           - Negative tradeCost18 → vault REFUNDS the trader (typical sell).
    ///           - Positive tradeCost18 → trader PAYS the vault (unusual; large t_bar).
    ///         `minRefundUsdc` guards against unfavourable slippage on the refund side;
    ///         `maxCostUsdc` guards against unexpected CSS cost on the payment side.
    ///
    ///         ── Permit (optional, CSS cost path only) ──────────────────────────
    ///         Pass `v != 0` to attempt an EIP-2612 permit ONLY when a net payment
    ///         is detected (isRefund == false).  The permit is never attempted on
    ///         standard refund sells — saving gas on the overwhelming majority of
    ///         sell transactions.
    ///         If the permit signature has already been consumed (e.g. front-run),
    ///         the call falls back silently to any pre-existing allowance.
    ///         Pass `v = 0, r = 0, s = 0, deadline = 0` to skip permit entirely and
    ///         rely on a pre-existing `USDC.approve(pool, amount)` call, or when a
    ///         refund is expected (no approval required for standard sells).
    ///
    /// @param outcomeIndex    Primary outcome to reduce position in [0, outcomeCount)
    /// @param shareAmount     Shares to sell from outcomeIndex (18-dec, ≥ MIN_SHARE_AMOUNT)
    /// @param minRefundUsdc   Minimum USDC refund expected (6-dec).
    ///                        Set to 0 if the caller accepts paying (e.g. large CSS translation).
    /// @param maxCostUsdc     Maximum USDC the trader will pay if CSS causes a net cost (6-dec).
    ///                        Acts as both slippage guard and permit amount on the CSS path.
    ///                        Pass 0 if a refund is expected (standard sell, cost path unreachable).
    /// @param deadline        EIP-2612 permit deadline (0 = skip permit)
    /// @param v               EIP-2612 permit signature v (0 = skip permit)
    /// @param r               EIP-2612 permit signature r
    /// @param s               EIP-2612 permit signature s
    function sell(
        uint256 outcomeIndex,
        uint256 shareAmount,
        uint256 minRefundUsdc,
        uint256 maxCostUsdc,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused tradingOpen {
        // ── Pre-condition Checks ─────────────────────────────────────────────
        if (shareAmount < MIN_SHARE_AMOUNT)  revert ShareAmountTooSmall(shareAmount, MIN_SHARE_AMOUNT);
        if (outcomeIndex >= outcomeCount)     revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);

        address trader = msg.sender;
        uint256 n      = outcomeCount;
        uint256 _alpha = alpha;

        // ── Load Only the Required Trader Balance ────────────────────────────
        // Only _shares[trader][outcomeIndex] is needed to compute tBar and update
        // the sold-outcome balance.  Loading the full n-slot array via
        // _loadTraderShares(trader, n) is unnecessary: all other outcome slots are
        // only incremented by +tBar in the effects step and never read here.
        // This replaces n mapping SLOADs with 1 in the standard sell (tBar = 0).
        uint256 traderBal = _shares[trader][outcomeIndex];

        // ── CSS Translation ──────────────────────────────────────────────────
        //
        //   tBar = max(0, shareAmount − traderBal)
        //
        //   If traderBal ≥ shareAmount: tBar = 0 (ordinary sell).
        //   Otherwise:                  tBar > 0 (translation applied).
        //
        uint256 tBar      = (traderBal >= shareAmount) ? 0 : shareAmount - traderBal;

        // Net reduction in the sold outcome's market quantity.
        // = shareAmount − tBar = traderBal (if tBar > 0) or shareAmount.
        // Always ≤ qOld[outcomeIndex] — proven by the Internal Ledger invariant:
        //   sum of all traders' shares = market q ≥ any single trader's position.
        uint256 netReduce = shareAmount - tBar;

        // ── Build q_old and q_new (single combined loop) ─────────────────────
        // _loadQuantitiesForSell reads all n quantity slots once and simultaneously
        // constructs qOld and qNew, applying netReduce and tBar in the same pass.
        // Replaces the former three-step pattern: _loadQuantities(n) +
        // _copyArray(qOld, n) + CSS mutation loop (three memory passes → one).
        (uint256[] memory qOld, uint256[] memory qNew) =
            _loadQuantitiesForSell(n, outcomeIndex, netReduce, tBar);

        // ── Trade Cost Calculation ───────────────────────────────────────────
        // tradeCost18 = C(qNew) − C(qOld).
        // Negative  ⟹ refund (vault pays trader).
        // Positive  ⟹ payment (trader pays vault; rare with large CSS translation).
        // calculateTradeCostDetailed also returns costNew = C(qNew) for reuse below.
        (int256 tradeCost18, uint256 costNew) =
            LSMath.calculateTradeCostDetailed(qOld, qNew, _alpha);

        // ── Compute Updated Vault Liability ──────────────────────────────────
        // Reuses costNew from above; reads _initialCost = C(q⁰) from a single warm SLOAD.
        // Eliminates _loadInitialQuantities() (n SLOADs) and costFunction(q⁰) on every sell.
        uint256 newLiability18   = LSMath.calculateWorstCaseLossFromCosts(costNew, _initialCost, qNew);
        uint256 newLiabilityUsdc = _floorToUsdc(newLiability18);

        // ── Determine Refund or Payment ──────────────────────────────────────
        bool isRefund = (tradeCost18 < 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        // casting to 'uint256' is safe on both branches:
        //   isRefund branch: tradeCost18 < 0, so -tradeCost18 > 0; negation of a negative
        //     int256 that fits in uint256 (LSMath bounds cost values well below int256.max).
        //   !isRefund branch: tradeCost18 >= 0 by definition; int256 → uint256 is lossless.
        uint256 absAmount18   = isRefund ? uint256(-tradeCost18) : uint256(tradeCost18);
        // Refund: floor conversion (vault keeps more). Payment: ceil (vault collects more).
        uint256 absAmountUsdc = isRefund ? _floorToUsdc(absAmount18) : _ceilToUsdc(absAmount18);

        // ── Slippage Guards ──────────────────────────────────────────────────
        // Refund guard: revert if the refund is below the trader's minimum.
        if (isRefund && absAmountUsdc < minRefundUsdc) {
            revert SlippageExceeded(absAmountUsdc, minRefundUsdc);
        }
        // Cost guard: revert if the net CSS payment exceeds the trader's cap.
        if (!isRefund && absAmountUsdc > maxCostUsdc) {
            revert SlippageExceeded(absAmountUsdc, maxCostUsdc);
        }

        // ── Effects: Update AMM & Internal Ledger (CEI) ─────────────────────
        _storeQuantities(qNew, n);

        // CSS actual_delta proof (Othman et al. §3.3.2):
        //   actual_delta[outcomeIndex] = −shareAmount + tBar = −netReduce
        //   actual_delta[j ≠ outcomeIndex] = +tBar
        //
        // Update sold outcome's trader balance (= old + actual_delta[i]):
        //   new = traderBal + (−shareAmount + tBar) = traderBal − netReduce
        //   Case tBar = 0 (traderBal ≥ shareAmount): new = traderBal − shareAmount ≥ 0 ✓
        //   Case tBar > 0 (tBar = shareAmount − traderBal): new = 0 ✓ (sold everything)
        //   Underflow impossible by invariant; unchecked saves gas.
        unchecked {
            _shares[trader][outcomeIndex]    = traderBal + tBar - shareAmount;
            // _totalTraderShares[outcomeIndex] ≥ traderBal ≥ shareAmount − tBar, so safe.
            _totalTraderShares[outcomeIndex] = _totalTraderShares[outcomeIndex] + tBar - shareAmount;
        }

        // For all other outcomes, apply actual_delta[j≠i] = +tBar:
        if (tBar > 0) {
            for (uint256 i = 0; i < n;) {
                if (i != outcomeIndex) {
                    _shares[trader][i]    += tBar;
                    _totalTraderShares[i] += tBar;
                }
                unchecked { ++i; }
            }
        }

        // ── Interactions: Route USDC Movement to Vault ───────────────────────
        if (isRefund) {
            // Standard sell: vault pushes refund to trader. No permit needed.
            IBlieverV1Pool(pool).distributeRefund(trader, absAmountUsdc, newLiabilityUsdc);
        } else {
            // Net-cost sell (CSS): trader pays vault.
            // Attempt permit ONLY when a signature is supplied (v != 0) — saves gas
            // on the 95%+ of sells that are standard refunds and never reach this branch.
            // Uses the `usdc` slot cached at initialization — no external call to pool.
            // Falls back silently to any pre-existing allowance if nonce was consumed.
            if (v != 0) {
                try IERC20Permit(usdc).permit(
                    trader, pool, maxCostUsdc, deadline, v, r, s
                ) {} catch {
                    if (IERC20(usdc).allowance(trader, pool) < absAmountUsdc)
                        revert InsufficientPermitAllowance();
                }
            }
            IBlieverV1Pool(pool).collectTradeCost(trader, absAmountUsdc, newLiabilityUsdc);
        }

        emit Sold(
            trader,
            outcomeIndex,
            shareAmount,
            tBar,
            isRefund ? absAmountUsdc : 0,
            isRefund ? 0 : absAmountUsdc
        );
    }

    /*//////////////////////////////////////////////////////////////
                           RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Record the winning outcome and settle the market with the vault.
    ///
    ///         This function is called EXCLUSIVELY by the Resolution Adapter
    ///         (resolver) once the UMA oracle (or any future oracle source)
    ///         has finalised the event outcome.
    ///
    ///         Settlement Accounting:
    ///         ──────────────────────
    ///         totalPayoutUsdc = _totalTraderShares[winningOutcome] / SHARE_TO_USDC
    ///
    ///         Using _totalTraderShares rather than _quantities[winningOutcome]
    ///         ensures the epsilon seed (the vault's own market-making cost) is
    ///         excluded from the payout, preventing MARKET_ROLE from being held
    ///         by this contract indefinitely after all legitimate claims are made.
    ///
    ///         The vault's profit = riskBudget − totalPayoutUsdc ≥ 0 (Prop. 4.9).
    ///         The epsilon component is implicitly absorbed into LP NAV as part of
    ///         the market-making cost that the vault pre-committed at registration.
    ///
    ///         Resolution is NOT pause-gated: markets must always be settleable,
    ///         even during operational vault pauses (mirrors the pool's design).
    ///
    /// @param _winningOutcome  Index of the outcome that resolved as true [0, outcomeCount)
    function resolve(uint8 _winningOutcome) external onlyResolver {
        // ── Checks ──────────────────────────────────────────────────────────
        if (resolved)                            revert MarketAlreadyResolved();
        if (block.timestamp >= resolutionDeadline) revert ResolutionDeadlinePassed();
        if (_winningOutcome >= outcomeCount)
            revert InvalidOutcomeIndex(_winningOutcome, outcomeCount);

        // ── Effects ─────────────────────────────────────────────────────────
        resolved       = true;
        winningOutcome = _winningOutcome;

        // Total claimable USDC = sum of all trader positions for the winning outcome.
        // Excludes epsilon seed (market maker's own liquidity provision).
        uint256 totalPayoutUsdc = _floorToUsdc(_totalTraderShares[_winningOutcome]);

        // ── Interaction: Notify the vault (releases live liability → LP NAV rises) ──
        // NOT pause-gated on the pool side either.
        IBlieverV1Pool(pool).settleMarket(totalPayoutUsdc);

        emit MarketResolved(_winningOutcome, totalPayoutUsdc);
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM WINNINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeem winning shares for USDC.  Pull-payment pattern.
    ///
    ///         Payout formula:
    ///         ───────────────
    ///         payoutUsdc = _shares[caller][winningOutcome] / SHARE_TO_USDC
    ///
    ///         Each winning share (1e18 units) is worth exactly 1 USDC (1e6 units).
    ///         The floor division means shares < 1e12 yield 0 USDC — such tiny
    ///         positions are economically negligible (< 1 USDC-wei), and no funds
    ///         are ever lost (they remain as vault LP profit).
    ///
    ///         Claim is NOT pause-gated (matches pool.claimWinnings behaviour).
    ///         One call per address; guard enforced by `_claimed[caller]`.
    ///
    ///         When all legitimate winners have claimed, the vault auto-revokes
    ///         MARKET_ROLE from this contract (pool-side logic).
    function claim() external nonReentrant {
        // ── Checks ──────────────────────────────────────────────────────────
        if (!resolved)             revert MarketNotResolved();

        address caller = msg.sender;
        if (_claimed[caller])      revert AlreadyClaimed();

        uint8   wo       = winningOutcome;
        uint256 shares18 = _shares[caller][wo];
        if (shares18 == 0)         revert NoWinningShares();

        uint256 payoutUsdc = _floorToUsdc(shares18);

        // ── Dust path: shares18 < SHARE_TO_USDC (< 1 USDC-wei) ──────────────
        // Floor conversion yields zero.  Rather than reverting, mark as claimed
        // (prevents repeated failed attempts), emit DustForfeited, and return without
        // touching the pool.  The dust value is already excluded from pool.settledPayout
        // via the identical floor division in resolve() — no funds are locked, and
        // pool.claimWinnings is deliberately NOT called (amount = 0 would revert there).
        if (payoutUsdc == 0) {
            _claimed[caller] = true;
            emit DustForfeited(caller, wo, shares18);
            return;
        }

        // ── Effects (before interaction — CEI) ───────────────────────────────
        _claimed[caller] = true;

        // ── Interaction: Pool transfers USDC to winner ────────────────────────
        IBlieverV1Pool(pool).claimWinnings(caller, payoutUsdc);

        emit WinningsClaimed(caller, wo, shares18, payoutUsdc);
    }

    /*//////////////////////////////////////////////////////////////
                      EXPIRY — UNRESOLVED MARKET SAFETY HATCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Expire and settle a market that was not resolved before resolutionDeadline.
    ///
    ///         This is an emergency safety hatch for oracle failures (e.g. permanent
    ///         UMA DVM dispute loop, lost resolver key, or force-majeure).
    ///
    ///         Effect:
    ///         ────────
    ///         Calls pool.settleMarket(0) — zero payout to traders; the vault
    ///         absorbs the full riskBudget as a loss (worst case for LPs, but
    ///         traders' USDC already collected from buys is kept by the vault as
    ///         the spread revenue earned before expiry).
    ///
    ///         Only the factory may call this, and only after resolutionDeadline
    ///         has passed.  The factory's governance process is responsible for
    ///         ensuring this is not called prematurely.
    ///
    ///         Not pause-gated: must be callable even during emergencies.
    function expireUnresolved() external onlyFactory {
        if (resolved)                                revert MarketAlreadyResolved();
        if (block.timestamp <= resolutionDeadline)   revert ResolutionDeadlineNotPassed();

        // ── Effects ─────────────────────────────────────────────────────────
        resolved       = true;
        winningOutcome = outcomeCount;
        // winningOutcome is set to outcomeCount as an explicit out-of-bounds sentinel value.
        // Valid outcome indices are [0, outcomeCount), so this value can never be matched by
        // claim() when it reads winningOutcome, ensuring no winning shares exist.
        // pool.settleMarket(0) means claimWinnings will always revert (amount=0 hits ZeroAmount
        // or PayoutExceedsSettlement with remaining=0). No trader funds are at risk.

        // ── Interaction: Settle with zero payout ─────────────────────────────
        IBlieverV1Pool(pool).settleMarket(0);

        emit MarketExpired(factory, uint40(block.timestamp), ExpiryReason.TIMEOUT);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — PAUSE / UNPAUSE (FACTORY ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all buy and sell trades on this market.
    /// @dev    Only the factory may pause.  Resolution and claims remain active.
    ///         This mirrors the pool's asymmetric pause design (operational pause
    ///         never blocks settlement or winner payouts).
    function pause() external onlyFactory {
        _pause();
    }

    /// @notice Resume trading on this market.
    /// @dev    Only the factory may unpause.
    function unpause() external onlyFactory {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW / PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Instantaneous price of outcome `i` under the current AMM state (18-dec).
    /// @dev    Price = ∂C(q)/∂qi — derived from LS-LMSR formula in LSMath.getPrice().
    ///         Note: Σ prices > 1 (LS-LMSR property; spread is the AMM's revenue).
    /// @param outcomeIndex  Outcome to query [0, outcomeCount)
    /// @return price  Instantaneous price in 18-dec fixed point
    function getPrice(uint256 outcomeIndex) external view returns (uint256 price) {
        if (outcomeIndex >= outcomeCount)
            revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);
        uint256[] memory q = _loadQuantities(outcomeCount);
        return LSMath.getPrice(q, outcomeIndex, alpha);
    }

    /// @notice Prices for all outcomes simultaneously (18-dec array).
    ///         More gas-efficient than calling getPrice() n times.
    function getAllPrices() external view returns (uint256[] memory prices) {
        uint256[] memory q = _loadQuantities(outcomeCount);
        return LSMath.getAllPrices(q, alpha);
    }

    /// @notice Estimate USDC cost (6-dec) for buying `shareAmount` of `outcomeIndex`.
    ///         View-only — does not modify state.  Use for UI quote computation.
    ///         Uses _loadQuantitiesForBuy to build qOld and qNew in a single storage pass,
    ///         consistent with the buy() write path.
    /// @param outcomeIndex  Outcome to buy [0, outcomeCount)
    /// @param shareAmount   Number of shares to simulate (18-dec)
    /// @return costUsdc  Estimated USDC cost (6-dec, ceiling rounded)
    function getBuyCost(
        uint256 outcomeIndex,
        uint256 shareAmount
    ) external view returns (uint256 costUsdc) {
        if (outcomeIndex >= outcomeCount)
            revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);
        if (shareAmount == 0) return 0;

        uint256 n = outcomeCount;
        (uint256[] memory qOld, uint256[] memory qNew) =
            _loadQuantitiesForBuy(n, outcomeIndex, shareAmount);

        int256 cost18 = LSMath.calculateTradeCost(qOld, qNew, alpha);
        if (cost18 < 0) return 0; // should not happen for a pure buy
        // forge-lint: disable-next-line(unsafe-typecast)
        // casting to 'uint256' is safe because cost18 >= 0 is enforced by the early
        // return directly above; the int256 → uint256 cast cannot truncate.
        costUsdc = _ceilToUsdc(uint256(cost18));
    }

    /// @notice Estimate the USDC outcome of selling `shareAmount` of `outcomeIndex`
    ///         for a specific trader (applies CSS automatically).
    ///         Negative return value would mean a payment — callers interpret sign.
    ///
    /// @param trader        Trader to simulate sell for (needed for CSS translation)
    /// @param outcomeIndex  Outcome to sell [0, outcomeCount)
    /// @param shareAmount   Number of shares to simulate selling (18-dec)
    /// @return refundUsdc   Estimated USDC refund (6-dec, floor).  Returns 0 if net payment.
    /// @return costUsdc     Estimated USDC cost if CSS causes a net payment (6-dec, ceil).
    ///                      Returns 0 if net refund.
    function getSellEstimate(
        address trader,
        uint256 outcomeIndex,
        uint256 shareAmount
    ) external view returns (uint256 refundUsdc, uint256 costUsdc) {
        if (outcomeIndex >= outcomeCount)
            revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);
        if (shareAmount == 0) return (0, 0);

        uint256 n = outcomeCount;
        uint256[] memory qTrader = _loadTraderShares(trader, n);

        uint256 tBar     = (qTrader[outcomeIndex] >= shareAmount)
            ? 0 : shareAmount - qTrader[outcomeIndex];
        uint256 netReduce = shareAmount - tBar;

        uint256[] memory qOld = _loadQuantities(n);
        uint256[] memory qNew = _copyArray(qOld, n);
        if (netReduce > 0) {
            if (qOld[outcomeIndex] < netReduce) return (0, 0); // defensive
            unchecked { qNew[outcomeIndex] -= netReduce; }
        }
        // actual_delta[j≠outcomeIndex] = +tBar; actual_delta[outcomeIndex] = −netReduce (already applied above).
        // tBar is NOT added to the sold outcome: netReduce already encodes the full CSS delta for that slot.
        if (tBar > 0) {
            for (uint256 i = 0; i < n;) {
                if (i != outcomeIndex) { qNew[i] += tBar; }
                unchecked { ++i; }
            }
        }

        int256 tradeCost18 = LSMath.calculateTradeCost(qOld, qNew, alpha);
        if (tradeCost18 < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            // casting to 'uint256' is safe: tradeCost18 < 0 guarantees -tradeCost18 > 0
            // and LSMath bounds cost magnitudes well within uint256 range.
            refundUsdc = _floorToUsdc(uint256(-tradeCost18));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            // casting to 'uint256' is safe: else-branch guarantees tradeCost18 >= 0.
            costUsdc = _ceilToUsdc(uint256(tradeCost18));
        }
    }

    /// @notice Returns the CSS translation amount for a hypothetical sell.
    ///         Useful for UI to display "you will also buy N shares of other outcomes".
    /// @param trader        Trader address
    /// @param outcomeIndex  Outcome to sell [0, outcomeCount)
    /// @param shareAmount   Shares to sell (18-dec)
    /// @return tBar  CSS translation scalar (18-dec); 0 if trader has sufficient shares
    function getCssTranslation(
        address trader,
        uint256 outcomeIndex,
        uint256 shareAmount
    ) external view returns (uint256 tBar) {
        if (outcomeIndex >= outcomeCount) return 0;
        uint256 held = _shares[trader][outcomeIndex];
        tBar = (held >= shareAmount) ? 0 : shareAmount - held;
    }

    /// @notice Trader's internal ledger balance for a specific outcome (18-dec).
    /// @param trader        Address to query
    /// @param outcomeIndex  Outcome index [0, outcomeCount)
    function getShares(address trader, uint256 outcomeIndex) external view returns (uint256) {
        if (outcomeIndex >= outcomeCount)
            revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);
        return _shares[trader][outcomeIndex];
    }

    /// @notice All internal ledger balances for a trader across all outcomes (18-dec).
    function getAllShares(address trader) external view returns (uint256[] memory balances) {
        uint256 n = outcomeCount;
        balances  = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            balances[i] = _shares[trader][i];
            unchecked { ++i; }
        }
    }

    /// @notice Current AMM quantity vector snapshot (18-dec).
    ///         q[i] = total shares outstanding for outcome i (including epsilon seed).
    function getQuantities() external view returns (uint256[] memory) {
        return _loadQuantities(outcomeCount);
    }

    /// @notice Initial AMM quantity vector q⁰ (18-dec).
    ///         Used for worst-case loss calculation.  Immutable after initialization.
    function getInitialQuantities() external view returns (uint256[] memory) {
        return _loadInitialQuantities(outcomeCount);
    }

    /// @notice Total trader-owned shares per outcome (18-dec, excludes epsilon seed).
    ///         This is the value used to compute totalPayoutUsdc at resolution.
    /// @param outcomeIndex  Outcome index [0, outcomeCount)
    function getTotalTraderShares(uint256 outcomeIndex) external view returns (uint256) {
        if (outcomeIndex >= outcomeCount)
            revert InvalidOutcomeIndex(outcomeIndex, outcomeCount);
        return _totalTraderShares[outcomeIndex];
    }

    /// @notice Current sum of all prices Σ pi(q) (18-dec).
    ///         Always > 1 for LS-LMSR.  Excess above 1 = AMM's instantaneous spread.
    function getSumOfPrices() external view returns (uint256) {
        return LSMath.sumOfPrices(_loadQuantities(outcomeCount), alpha);
    }

    /// @notice USDC token address (cached from pool at initialization — no external call).
    function usdcToken() external view returns (address) {
        return usdc;
    }

    /// @notice True if the trader has already claimed their winnings.
    function hasClaimed(address trader) external view returns (bool) {
        return _claimed[trader];
    }

    /// @notice Compact market state summary for frontends and off-chain indexers.
    /// @return _resolved            True if oracle has resolved the market
    /// @return _winningOutcome      Winning outcome index (valid only when _resolved)
    /// @return _tradingOpen         True if trading is currently permitted
    /// @return _tradingDeadline_    Unix timestamp trading closes
    /// @return _resolutionDeadline_ Unix timestamp resolver must act by
    /// @return _totalVolumeShares   Sum of q-vector (total shares across all outcomes)
    function getMarketStatus() external view returns (
        bool    _resolved,
        uint8   _winningOutcome,
        bool    _tradingOpen,
        uint40  _tradingDeadline_,
        uint40  _resolutionDeadline_,
        uint256 _totalVolumeShares
    ) {
        _resolved            = resolved;
        _winningOutcome      = winningOutcome;
        _tradingOpen         = !resolved && block.timestamp < tradingDeadline;
        _tradingDeadline_    = tradingDeadline;
        _resolutionDeadline_ = resolutionDeadline;

        uint256 n = outcomeCount;
        uint256[] memory q = _loadQuantities(n);
        uint256 vol;
        for (uint256 i = 0; i < n;) { vol += q[i]; unchecked { ++i; } }
        _totalVolumeShares = vol;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                      INTERNAL — MODIFIER BODIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Extracted body of the `tradingOpen` modifier.
    ///      Extracting to an internal function means the compiler emits this
    ///      bytecode once; each modifier call-site jumps here instead of
    ///      receiving an inlined copy, reducing overall contract code size.
    ///      Trading is permitted while block.timestamp < tradingDeadline.
    ///      At block.timestamp == tradingDeadline the condition fires (>=) and trading is closed.
    function _tradingOpen() internal view {
        if (resolved || block.timestamp >= tradingDeadline) revert TradingClosed();
    }

    /// @dev Extracted body of the `onlyResolver` modifier.
    function _onlyResolver() internal view {
        if (msg.sender != resolver) revert NotResolver();
    }

    /// @dev Extracted body of the `onlyFactory` modifier.
    function _onlyFactory() internal view {
        if (msg.sender != factory) revert NotFactory();
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL — QUANTITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Load the current quantity vector from storage into a fresh memory array.
    ///      Each storage SLOAD is ~2100 gas (cold) / 100 gas (warm). Minimising
    ///      cold SLOADs is the primary reason we cache in memory at the top of each trade.
    function _loadQuantities(uint256 n) internal view returns (uint256[] memory q) {
        q = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            q[i] = _quantities[i];
            unchecked { ++i; }
        }
    }

    /// @dev Load the initial quantity vector (q⁰) into memory.
    function _loadInitialQuantities(uint256 n) internal view returns (uint256[] memory q0) {
        q0 = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            q0[i] = _initialQuantities[i];
            unchecked { ++i; }
        }
    }

    /// @dev Load a specific trader's per-outcome share balances into memory.
    function _loadTraderShares(address trader, uint256 n)
        internal
        view
        returns (uint256[] memory qt)
    {
        qt = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            qt[i] = _shares[trader][i];
            unchecked { ++i; }
        }
    }

    /// @dev Write a memory array back to the quantity storage array.
    ///      Only called after all checks and cost calculations (CEI pattern).
    function _storeQuantities(uint256[] memory qNew, uint256 n) internal {
        for (uint256 i = 0; i < n;) {
            _quantities[i] = qNew[i];
            unchecked { ++i; }
        }
    }

    /// @dev Shallow copy of a memory array (avoids mutating the original).
    function _copyArray(uint256[] memory src, uint256 n)
        internal
        pure
        returns (uint256[] memory dst)
    {
        dst = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            dst[i] = src[i];
            unchecked { ++i; }
        }
    }

    /// @dev Load the current quantity vector and simultaneously produce q_new for a buy,
    ///      incrementing only the single changed index.  Replaces the two-step pattern of
    ///      _loadQuantities(n) followed by _copyArray(qOld, n) + mutation, cutting the
    ///      memory traversal from two passes to one.
    /// @param n     Number of outcomes (= outcomeCount, cached by caller)
    /// @param idx   The outcome index being purchased
    /// @param delta The share amount being added (= shareAmount, 18-dec)
    /// @return qOld Current quantity vector snapshot (all n slots, unmodified)
    /// @return qNew New quantity vector after the buy (qOld[idx] + delta at position idx)
    function _loadQuantitiesForBuy(uint256 n, uint256 idx, uint256 delta)
        internal
        view
        returns (uint256[] memory qOld, uint256[] memory qNew)
    {
        qOld = new uint256[](n);
        qNew = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            uint256 q = _quantities[i];
            qOld[i] = q;
            qNew[i] = (i == idx) ? q + delta : q;
            unchecked { ++i; }
        }
    }

    /// @dev Load the current quantity vector and simultaneously produce q_new for a sell,
    ///      applying the CSS translation in a single loop.  Replaces the three-step pattern
    ///      of _loadQuantities(n) + _copyArray(qOld, n) + CSS mutation loop:
    ///        • Three separate memory traversals → one combined pass.
    ///        • The InsufficientMarketQuantity guard is applied inline at idx.
    ///
    ///      CSS q-vector delta derivation (Othman et al. §3.3.2):
    ///        actual_delta[idx]  = −shareAmount + tBar = −netReduce
    ///        actual_delta[j≠idx] = +tBar
    ///      Therefore:
    ///        qNew[idx]  = qOld[idx] − netReduce          ← NOT − netReduce + tBar
    ///        qNew[j≠idx] = qOld[j]  + tBar
    ///
    ///      When tBar = 0 (standard sell, no CSS), both branches simplify to:
    ///        qNew[idx]  = qOld[idx] − shareAmount
    ///        qNew[j≠idx] = qOld[j]  (unchanged)
    ///
    /// @param n          Number of outcomes (= outcomeCount, cached by caller)
    /// @param idx        The outcome index being sold
    /// @param netReduce  Net decrease to q[idx] (= shareAmount − tBar = actual_delta[idx] negated)
    /// @param tBar       CSS translation scalar applied to all OTHER outcomes (0 for standard sell)
    /// @return qOld  Current quantity vector snapshot (all n slots, unmodified)
    /// @return qNew  New quantity vector after the CSS-adjusted sell (one combined pass)
    function _loadQuantitiesForSell(uint256 n, uint256 idx, uint256 netReduce, uint256 tBar)
        internal
        view
        returns (uint256[] memory qOld, uint256[] memory qNew)
    {
        qOld = new uint256[](n);
        qNew = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            uint256 q = _quantities[i];
            qOld[i] = q;
            if (i == idx) {
                // actual_delta[idx] = −netReduce.  tBar is NOT added to the sold outcome:
                // the paper's translation vector adds tBar to ALL outcomes in the trader's
                // holdings, but for the sold outcome the net effect is already encoded in
                // netReduce (= shareAmount − tBar).  Adding tBar again would inflate q[idx]
                // by tBar units beyond the correct LS-LMSR market state.
                // Safe: netReduce ≤ traderBal ≤ _totalTraderShares[idx] ≤ q[idx] (invariant).
                if (netReduce > 0 && q < netReduce) revert InsufficientMarketQuantity();
                unchecked { qNew[i] = q - netReduce; }
            } else {
                // actual_delta[j≠idx] = +tBar.
                qNew[i] = q + tBar;
            }
            unchecked { ++i; }
        }
    }

    /// @dev Convert 18-dec amount to 6-dec USDC, rounding DOWN (floor).
    ///      Used for refund and liability computations (vault-protective).
    function _floorToUsdc(uint256 amount18) internal pure returns (uint256) {
        return amount18 / SHARE_TO_USDC;
    }

    /// @dev Convert 18-dec amount to 6-dec USDC, rounding UP (ceiling).
    ///      Used for buy cost computations (vault-protective).
    function _ceilToUsdc(uint256 amount18) internal pure returns (uint256) {
        return (amount18 + SHARE_TO_USDC - 1) / SHARE_TO_USDC;
    }
}
