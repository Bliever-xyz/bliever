// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN — STANDARD
//////////////////////////////////////////////////////////////*/
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}         from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard}  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones}           from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}        from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                       INTERNAL — INTERFACES
//////////////////////////////////////////////////////////////*/
import {IBlieverV1Pool}      from "./interfaces/IBlieverV1Pool.sol";
import {IBlieverUmaAdapter}  from "./interfaces/IBlieverUmaAdapter.sol";
import {IDeployableMarket} from "./interfaces/IDeployableMarket.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  DEPLOYMENT PARAMETER BUNDLE
//  A calldata struct reduces ABI decoding overhead vs. 10 individual arguments
//  and is especially meaningful on Base chain where L1 data-availability fees
//  make calldata byte count a first-class cost driver.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice All parameters required to deploy a single prediction-market clone.
struct DeployParams {
    // ── Identity ──────────────────────────────────────────────────────────────
    /// @dev Must equal keccak256(abi.encodePacked(ancillaryData,
    ///      ",initializer:", lowerCaseHex(factoryAddress))).
    ///      The adapter re-derives and verifies this on-chain;
    ///      a mismatch reverts with QuestionIdMismatch.
    ///      Off-chain computation:
    ///        const suffix = ",initializer:" + factory.address.slice(2).toLowerCase();
    ///        const full   = concat([rawAncillaryData, toUtf8Bytes(suffix)]);
    ///        questionId   = keccak256(full);
    bytes32 questionId;

    /// @dev Raw JSON ancillary data bytes (≤ 8 086 bytes).
    ///      The adapter appends the 53-byte initializer suffix on-chain, so the
    ///      total stored length stays within the 8 139-byte OO ancillary-data cap.
    bytes   ancillaryData;

    // ── Market configuration ──────────────────────────────────────────────────
    /// @dev Number of mutually exclusive outcomes [MIN_OUTCOMES, MAX_OUTCOMES].
    ///      UMIP-183 constrains MultiValueDecoder to 7 slots; the factory enforces this.
    uint8   nOutcomes;

    /// @dev Unix timestamp: last second at which buy / sell is accepted.
    ///      block.timestamp >= tradingDeadline → TradingClosed revert on the clone.
    uint40  tradingDeadline;

    /// @dev Unix timestamp: resolver must call resolve() before this second.
    ///      After this second passes, the factory may call expireUnresolved().
    uint40  resolutionDeadline;

    // ── Oracle reward ─────────────────────────────────────────────────────────
    /// @dev ERC-20 token used for the UMA OO proposer reward.
    ///      Must be a non-zero address when reward > 0.
    address rewardToken;

    /// @dev Proposer reward in rewardToken decimals (0 = no incentive).
    ///      If > 0, caller must approve THIS factory for this amount before calling deployMarket.
    uint256 reward;

    // ── Deployment addressing ─────────────────────────────────────────────────
    // The CREATE2 salt is derived automatically inside deployMarket as
    // keccak256(abi.encode(questionId)).  Pre-compute the clone address with
    // predictMarketAddress(questionId) before broadcasting the deployment tx.

    /// @dev Proposer / disputer bond in rewardToken decimals.
    ///      Enforced by the OO during the liveness window.
    uint256 bond;

    /// @dev Optimistic-liveness window in seconds.
    ///      Minimum value is enforced by the UMA Optimistic Oracle.
    uint256 liveness;

    // ── Market-specific AMM parameters ────────────────────────────────────────
    /// @dev LS-LMSR commission / spread parameter α for this market (18-dec fixed-point).
    ///      Independent of the vault's global alpha setting; baked into this market's
    ///      q⁰ seed and stored in the clone's own storage at initialization.
    ///      Must be in [BlieverV1Pool.MIN_ALPHA, BlieverV1Pool.MAX_ALPHA] = [1e12, 2e17].
    ///      Example: 3e16 = 3 % spread.
    uint256 alpha;

    /// @dev Per-market worst-case USDC loss budget (6-dec).
    ///      Determines C(q⁰) = R for this market independently of the vault's global
    ///      maxRiskPerMarket setting.  Stored as riskBudget in the pool's MarketInfo.
    ///      Must be > 0; subject to the pool's live capacity check at registration time.
    ///      Example: 1_000_000 = $1 USDC maximum vault loss for this market.
    uint256 maxRisk;

}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

/// @title  BlieverMarketFactory
/// @author Bliever Protocol
/// @notice Deterministic factory that mass-deploys EIP-1167 minimal-proxy clones of
///         BlieverMarket and atomically wires each clone into the Bliever protocol.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ROLE IN THE ARCHITECTURE
///         ─────────────────────────────────────────────────────────────────────────
///         The factory is the sole entry point for creating new prediction markets.
///         It is the ONLY address that may:
///           • Call market.initialize()           (clone is uninitialized until this runs)
///           • Call market.pause() / unpause()    (guarded by `onlyFactory` in the clone)
///           • Call market.expireUnresolved()     (guarded by `onlyFactory` in the clone)
///           • Call pool.registerMarket()         (requires MARKET_MANAGER_ROLE on pool)
///           • Call adapter.initializeQuestion()  (requires FACTORY_ROLE on adapter)
///
///         The factory does NOT:
///           • Hold, mint, or burn any ERC-20 tokens beyond routing UMA OO rewards.
///           • Participate in trade execution, LS-LMSR cost calculation, or liability tracking.
///           • Duplicate or shadow any state that already lives in BlieverV1Pool.
///           • Have upgrade logic — it is intentionally immutable (non-UUPS).
///             If new factory logic is needed, a new factory contract is deployed and
///             fresh role grants are issued on pool and adapter.
///
///         ─────────────────────────────────────────────────────────────────────────
///         DEPLOYMENT ATOMICITY
///         ─────────────────────────────────────────────────────────────────────────
///         deployMarket executes 5 sequential steps — all succeed or all revert:
///           1. Validate inputs + pull OO reward tokens from caller.
///           2. Deploy EIP-1167 clone via CREATE2  (~41 k gas).
///           3. Initialize the clone (q-vector seeded, config pinned).
///           4. Register clone in BlieverV1Pool  (reserves riskBudget, grants MARKET_ROLE).
///           5. Initialize oracle question in BlieverUmaAdapter  (submits OO price request).
///         There is no "half-deployed" state possible.
///
///         ─────────────────────────────────────────────────────────────────────────
///         EPSILON COMPUTATION
///         ─────────────────────────────────────────────────────────────────────────
///         ε is computed on-chain from params.alpha and params.maxRisk — per-market
///         values supplied in DeployParams — using the LS-LMSR seed formula:
///         ε = R / (1 + α · n · ln n), where R = params.maxRisk (the market's
///         individual worst-case loss budget).  Natural-log values for n ∈ {2..7} are
///         stored in a precomputed lookup table — no external math library required.
///         ε is never a caller-supplied input (prevents invalid seeds).
///
///         ─────────────────────────────────────────────────────────────────────────
///         MARKET MODEL: TEAM-CURATED (Polymarket-style)
///         ─────────────────────────────────────────────────────────────────────────
///         Only addresses holding OPERATOR_ROLE may deploy markets.  End users suggest
///         ideas via social channels (X / Discord); the Bliever team reviews and deploys
///         approved markets via the OPERATOR_ROLE multisig.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ACCESS CONTROL
///         ─────────────────────────────────────────────────────────────────────────
///         DEFAULT_ADMIN_ROLE — grant / revoke roles; deregisterMarket (destructive).
///         OPERATOR_ROLE      — deployMarket.
///         PAUSER_ROLE        — pause / unpause factory; pauseMarket / unpauseMarket.
///
///         ─────────────────────────────────────────────────────────────────────────
///         NON-UPGRADEABILITY RATIONALE
///         ─────────────────────────────────────────────────────────────────────────
///         Individual BlieverMarket clones are immutable — traders have a cryptographic
///         guarantee that trading rules cannot change mid-market.  Making the factory
///         upgradeable would allow a compromised admin key to swap the factory logic and
///         re-enter active clones via the onlyFactory gate.  Instead, factory evolution
///         is achieved by deploying a new factory contract and migrating role grants.
///
/// @dev    Inherits: AccessControl, Pausable, ReentrancyGuard (all non-upgradeable OZ).
///         Immutables: implementation, pool, adapter.
///         No storage gaps needed — contract is not upgradeable.
contract BlieverMarketFactory is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice May call deployMarket to create new prediction-market clones.
    ///         In production, should be held by an N-of-M multisig.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice May pause / unpause the factory globally and individual market clones.
    ///         In production, should be a lower-quorum multisig than DEFAULT_ADMIN_ROLE
    ///         to enable rapid circuit-breaker response.
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum valid outcome count (binary market).
    uint8   public constant MIN_OUTCOMES = 2;

    /// @notice Maximum outcome count — hard cap imposed by UMIP-183 / MultiValueDecoder.
    ///         MultiValueDecoder encodes at most 7 winning-outcome labels in one int256 price
    ///         word.  Deploying a market with > 7 outcomes would cause adapter.initializeQuestion
    ///         to revert.  The factory enforces this cap early to fail-fast before any gas
    ///         is spent on clone deployment.
    uint8   public constant MAX_OUTCOMES = 7;

    /// @notice Fixed-point scale used by LSMath (1e18).
    ///         Mirrors BlieverMarket.MATH_SCALE; kept local to avoid cross-contract coupling.
    uint256 internal constant MATH_SCALE   = 1e18;

    /// @notice Conversion: 18-dec LS-LMSR shares → 6-dec USDC.
    ///         Mirrors BlieverMarket.SHARE_TO_USDC; kept local to avoid cross-contract coupling.
    uint256 internal constant SHARE_TO_USDC = 1e12;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BlieverMarket master implementation address.
    ///         Every deployed clone points here via the EIP-1167 DELEGATECALL proxy.
    ///         Immutable: if the implementation must change, a new factory is deployed.
    address public immutable implementation;

    /// @notice BlieverV1Pool — the single USDC vault for all prediction markets.
    ///         Factory requires MARKET_MANAGER_ROLE on this contract (see constructor docs).
    IBlieverV1Pool public immutable pool;

    /// @notice BlieverUmaAdapter — UMA OO bridge for oracle-based resolution.
    ///         Factory requires FACTORY_ROLE on this contract (see constructor docs).
    IBlieverUmaAdapter public immutable adapter;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice True if and only if `market` was deployed by THIS factory instance.
    ///         Guards all lifecycle functions (pause, expire, deregister) from acting on
    ///         contracts not created by this factory (replay / spoofing protection).
    mapping(address => bool) public isDeployedMarket;

    /// @notice Total markets deployed by this factory. Strictly monotonically increasing
    ///         (not decremented on deregistration — preserves historical count).
    uint256 public marketCount;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once per successful deployMarket call.
    /// @param market             Address of the newly deployed EIP-1167 clone.
    /// @param questionId         Oracle question identifier bound to this market.
    /// @param nOutcomes          Number of mutually exclusive outcomes.
    /// @param tradingDeadline    Unix timestamp at which trading closes.
    /// @param resolutionDeadline Unix timestamp by which oracle must resolve.
    event MarketDeployed(
        address indexed market,
        bytes32 indexed questionId,
        uint8           nOutcomes,
        uint40          tradingDeadline,
        uint40          resolutionDeadline
    );

    /// @notice Emitted when expireUnresolved successfully expires a timed-out market.
    /// @param market     Address of the expired clone.
    /// @param questionId Oracle question identifier of the expired market.
    /// @param timestamp  block.timestamp at the time of expiry.
    event MarketExpiredByFactory(
        address indexed market,
        bytes32 indexed questionId,
        uint40          timestamp
    );

    /// @notice Emitted when a market clone is paused via this factory.
    event MarketPausedByFactory(address indexed market);

    /// @notice Emitted when a market clone is unpaused via this factory.
    event MarketUnpausedByFactory(address indexed market);

    /// @notice Emitted when a trade-free market is removed from the pool's active roster.
    event MarketDeregisteredByFactory(address indexed market);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev A required address argument was the zero address.
    error BlieverMarketFactory__ZeroAddress();

    /// @dev The implementation address has no deployed bytecode (not a contract).
    error BlieverMarketFactory__NotAContract(address account);

    /// @dev The caller tried to act on a market not deployed by this factory.
    error BlieverMarketFactory__NotDeployedMarket(address market);

    /// @dev nOutcomes is outside [MIN_OUTCOMES, MAX_OUTCOMES].
    error BlieverMarketFactory__InvalidOutcomeCount(uint8 count);

    /// @dev Deadline configuration is inconsistent or in the past.
    ///      tradingDeadline must be: (a) in the future, (b) < resolutionDeadline.
    error BlieverMarketFactory__InvalidDeadlines();

    /// @dev questionId is bytes32(0) — not a valid oracle question identifier.
    error BlieverMarketFactory__InvalidQuestionId();

    /// @dev ancillaryData is empty — not a valid oracle question payload.
    error BlieverMarketFactory__InvalidAncillaryData();

    /// @dev A market for this questionId has already been deployed by this factory.
    /// @param questionId The duplicate oracle question identifier.
    /// @param existing   The address already occupied by the prior deployment.
    error BlieverMarketFactory__QuestionAlreadyDeployed(bytes32 questionId, address existing);

    /// @dev computeEpsilon returned 0 — pool params may be misconfigured.
    error BlieverMarketFactory__ZeroEpsilon();

    /// @dev params.alpha is outside [MIN_ALPHA, MAX_ALPHA] = [1e12, 2e17].
    error BlieverMarketFactory__InvalidAlpha(uint256 value);

    /// @dev reward > 0 but rewardToken is the zero address.
    error BlieverMarketFactory__RewardTokenRequired();

    /// @dev expireUnresolved called on a market that is already resolved.
    error BlieverMarketFactory__MarketAlreadyResolved(address market);

    /// @dev expireUnresolved called before resolutionDeadline has passed.
    /// @param deadline    The market's resolutionDeadline.
    /// @param currentTime block.timestamp at call time.
    error BlieverMarketFactory__ResolutionDeadlineNotPassed(
        uint40 deadline,
        uint40 currentTime
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy the factory and assign all initial roles to `admin`.
    ///
    ///         ── Post-deployment prerequisites ──────────────────────────────────
    ///         The factory cannot deploy markets until TWO external role grants are made
    ///         by their respective contract admins:
    ///
    ///         1. BlieverV1Pool admin must run:
    ///               pool.grantRole(pool.MARKET_MANAGER_ROLE(), address(factory))
    ///            → Enables factory to call pool.registerMarket() and pool.deregisterMarket().
    ///
    ///         2. BlieverUmaAdapter admin must run:
    ///               adapter.grantRole(adapter.FACTORY_ROLE(), address(factory))
    ///            → Enables factory to call adapter.initializeQuestion().
    ///
    ///         Until both grants are made, deployMarket will revert at pool step (no role)
    ///         or adapter step (no role) respectively.  No other side-effects occur because
    ///         the token transfer and clone deployment are earlier in the call — but Solidity
    ///         rolls back the entire transaction on any revert, so no partial state persists.
    ///
    ///         ⚠️  PRODUCTION: `admin` MUST be a multisig — never a plain EOA.
    ///            Distribute OPERATOR_ROLE and PAUSER_ROLE to separate multisigs after deployment
    ///            to enforce separation of concerns between market creation and emergency response.
    ///
    /// @param _implementation  BlieverMarket master implementation address (must have code)
    /// @param _pool            BlieverV1Pool proxy address
    /// @param _adapter         BlieverUmaAdapter proxy address
    /// @param admin            Address receiving DEFAULT_ADMIN, OPERATOR, and PAUSER roles
    constructor(
        address _implementation,
        address _pool,
        address _adapter,
        address admin
    ) {
        // ── Zero-address guards ───────────────────────────────────────────────
        if (_implementation == address(0)) revert BlieverMarketFactory__ZeroAddress();
        if (_pool           == address(0)) revert BlieverMarketFactory__ZeroAddress();
        if (_adapter        == address(0)) revert BlieverMarketFactory__ZeroAddress();
        if (admin           == address(0)) revert BlieverMarketFactory__ZeroAddress();

        // ── Implementation must be a deployed contract ────────────────────────
        // EIP-1167 proxies forward ALL calls to `implementation` via DELEGATECALL.
        // Pointing at an EOA would silently succeed on deploy but revert on every
        // initialize() call, wasting gas and producing orphaned clones.
        if (_implementation.code.length == 0)
            revert BlieverMarketFactory__NotAContract(_implementation);

        // ── Immutable assignments ─────────────────────────────────────────────
        implementation = _implementation;
        pool           = IBlieverV1Pool(_pool);
        adapter        = IBlieverUmaAdapter(_adapter);

        // ── Role grants ───────────────────────────────────────────────────────
        // All three roles granted to `admin` at launch.  In production, transfer
        // OPERATOR_ROLE and PAUSER_ROLE to separate multisigs after deployment.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE,      admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING — DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new prediction-market clone and atomically wire it into the protocol.
    ///
    ///         Execution steps (all-or-nothing — any revert cancels the entire transaction):
    ///         ─────────────────────────────────────────────────────────────────────────────
    ///         1. Validate all input parameters  (fail-fast, zero state mutations).
    ///            Includes bounds-checking params.alpha and params.maxRisk.
    ///         2. Compute LS-LMSR ε from params.alpha + params.maxRisk (per-market values).
    ///         3. Pull OO reward tokens from caller into factory  (if params.reward > 0).
    ///         4. Deploy EIP-1167 clone via CREATE2  (~41 k gas, deterministic address).
    ///         5. Initialize the clone  (sets resolver, factory, q-vector, deadlines, alpha).
    ///         6. Register clone in BlieverV1Pool  (reserves params.maxRisk as riskBudget; grants MARKET_ROLE).
    ///         7. Approve adapter then call adapter.initializeQuestion  (submits UMA OO request).
    ///         8. Record deployment in factory state; emit MarketDeployed.
    ///
    ///         ── Caller responsibilities ───────────────────────────────────────────
    ///         • Must hold OPERATOR_ROLE.
    ///         • Factory must NOT be paused.
    ///         • params.alpha must be in [MIN_ALPHA, MAX_ALPHA] = [1e12, 2e17] (18-dec).
    ///         • params.maxRisk must be > 0 (6-dec USDC) and must pass the pool's
    ///           live capacity check: totalLiability + maxRisk ≤ activeCap.
    ///         • If params.reward > 0: BEFORE calling, approve THIS factory as spender
    ///           for ≥ params.reward of params.rewardToken.
    ///         • params.questionId must be correctly pre-computed off-chain:
    ///               full = ancillaryData ++ ",initializer:" ++ lowerCaseHex(factoryAddress)
    ///               questionId = keccak256(full)
    ///           The adapter validates this on-chain and reverts with QuestionIdMismatch if wrong.
    ///         • The CREATE2 salt is derived automatically as keccak256(abi.encode(questionId)).
    ///           Pre-compute the clone address with predictMarketAddress(questionId) before
    ///           broadcasting. Each questionId maps to exactly one market address — a duplicate
    ///           questionId reverts with QuestionAlreadyDeployed before any gas is spent on
    ///           token transfers or clone deployment.
    ///
    ///         ── Gas profile (approx., Base chain) ────────────────────────────────
    ///         ~320 k–380 k gas total:
    ///           Clone deploy (CREATE2)           ~41 k
    ///           market.initialize()              ~120 k (n SSTOREs for q-vector)
    ///           pool.registerMarket()            ~60 k
    ///           adapter.initializeQuestion()     ~250 k (dominant; includes OO price request)
    ///
    /// @param params  Packed deployment parameters (see DeployParams struct)
    /// @return market Address of the newly deployed EIP-1167 clone
    function deployMarket(DeployParams calldata params)
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        returns (address market)
    {
        // ── 1. Pre-flight checks (fail-fast — no state changes yet) ───────────
        if (params.questionId == bytes32(0))
            revert BlieverMarketFactory__InvalidQuestionId();

        if (params.ancillaryData.length == 0)
            revert BlieverMarketFactory__InvalidAncillaryData();

        if (params.nOutcomes < MIN_OUTCOMES || params.nOutcomes > MAX_OUTCOMES)
            revert BlieverMarketFactory__InvalidOutcomeCount(params.nOutcomes);

        // tradingDeadline must be: strictly in the future AND < resolutionDeadline.
        // block.timestamp is always > 0 post-merge, so the == 0 cases are subsumed.
        if (
            params.tradingDeadline    >= params.resolutionDeadline   ||
            uint40(block.timestamp)   >= params.tradingDeadline
        ) {
            revert BlieverMarketFactory__InvalidDeadlines();
        }

        if (params.reward > 0 && params.rewardToken == address(0))
            revert BlieverMarketFactory__RewardTokenRequired();

        // Validate per-market AMM parameters.
        // alpha bounds mirror BlieverV1Pool.MIN_ALPHA / MAX_ALPHA to guarantee the clone
        // initialises with a valid liquidity parameter and that epsilon rounds to non-zero.
        if (params.alpha < 1e12 || params.alpha > 2e17)
            revert BlieverMarketFactory__InvalidAlpha(params.alpha);
        if (params.maxRisk == 0)
            revert BlieverMarketFactory__ZeroEpsilon(); // maxRisk=0 ⟹ epsilon=0 ⟹ degenerate market

        // Derive the CREATE2 salt deterministically from questionId.
        // This enforces a strict 1-to-1 bijection: one oracle question → one market address.
        // No operator can accidentally supply a duplicate or mismatched salt.
        bytes32 salt = keccak256(abi.encode(params.questionId));

        // Fail-fast duplicate guard: predict the CREATE2 address and verify it is unoccupied
        // BEFORE any token transfers or clone deployments.  Yields a descriptive revert
        // (QuestionAlreadyDeployed) instead of a generic low-level CREATE2 collision error.
        {
            address predicted = Clones.predictDeterministicAddress(
                implementation, salt, address(this)
            );
            if (predicted.code.length > 0)
                revert BlieverMarketFactory__QuestionAlreadyDeployed(params.questionId, predicted);
        }

        // ── 2. Compute ε from per-market parameters ───────────────────────────
        // params.alpha and params.maxRisk are market-specific values supplied by the operator.
        // They are independent of the vault's global alpha / maxRiskPerMarket storage slots.
        // params.alpha is forwarded directly to market.initialize() so the clone stores the
        // identical value that ε was computed for — guaranteeing C(q⁰) = params.maxRisk.
        uint256 epsilon = _computeEpsilon(params.nOutcomes, params.alpha, params.maxRisk);
        if (epsilon == 0) revert BlieverMarketFactory__ZeroEpsilon();

        // ── 3. Pull reward tokens from caller ─────────────────────────────────
        // Executed BEFORE clone deployment so a transfer failure (insufficient
        // allowance / balance) reverts the transaction cleanly with no orphaned clone.
        if (params.reward > 0) {
            IERC20(params.rewardToken).safeTransferFrom(
                msg.sender, address(this), params.reward
            );
        }

        // ── 4. Deploy EIP-1167 clone via CREATE2 ─────────────────────────────
        // Deploys a 45-byte proxy shell forwarding all DELEGATECALL logic to `implementation`.
        // Deployment cost is ~41 k gas (>90 % cheaper than full contract deployment).
        // The address is deterministic: predictMarketAddress(params.questionId) == market.
        market = Clones.cloneDeterministic(implementation, salt);

        // ── 5. Initialize the clone ───────────────────────────────────────────
        // params.alpha is the per-market value supplied in DeployParams — the same one
        // used for ε above.  The clone stores it in its own alpha slot so every
        // trade executed against this clone uses the alpha it was seeded with.
        IDeployableMarket(market).initialize(
            address(pool),
            params.questionId,
            params.nOutcomes,
            params.alpha,             // per-market alpha — identical to epsilon's alpha
            params.tradingDeadline,
            params.resolutionDeadline,
            epsilon,
            address(adapter),         // resolver = UMA adapter
            address(this)             // factory  = this contract
        );

        // ── 6. Register clone in BlieverV1Pool ───────────────────────────────
        // registerMarket: (a) validates contract + capacity, (b) reserves params.maxRisk
        // as this market's riskBudget against totalLiability, (c) grants MARKET_ROLE.
        // Each market carries its own bespoke riskBudget independent of the vault global.
        // Requires MARKET_MANAGER_ROLE on pool (must be pre-granted to this factory).
        pool.registerMarket(market, uint32(params.nOutcomes), params.maxRisk);

        // ── 7. Approve adapter and initialize oracle question ─────────────────
        // forceApprove resets any stale allowance to exactly params.reward — prevents
        // the ERC-20 approval-race vulnerability on tokens requiring zero-then-new-value.
        // Must execute AFTER pool.registerMarket because adapter.initializeQuestion
        // reads market.outcomeCount() which is only valid after initialize() runs.
        if (params.reward > 0) {
            IERC20(params.rewardToken).forceApprove(address(adapter), params.reward);
        }

        // Requires FACTORY_ROLE on adapter (must be pre-granted to this factory).
        // The adapter appends ",initializer:<factory_hex>" to ancillaryData on-chain
        // and verifies keccak256(fullAncillaryData) == params.questionId.
        adapter.initializeQuestion(
            params.questionId,
            market,
            params.ancillaryData,
            params.rewardToken,
            params.reward,
            params.bond,
            params.liveness
        );

        // ── 8. Record deployment and emit ─────────────────────────────────────
        isDeployedMarket[market] = true;
        unchecked { ++marketCount; }  // cannot overflow — uint256 exhaustion is infeasible

        emit MarketDeployed(
            market,
            params.questionId,
            params.nOutcomes,
            params.tradingDeadline,
            params.resolutionDeadline
        );
    }

    /*//////////////////////////////////////////////////////////////
               EXTERNAL STATE-CHANGING — MARKET LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Expire a market whose oracle resolution deadline has passed with no resolution.
    ///
    ///         Permissionless — any EOA may call once block.timestamp > resolutionDeadline.
    ///         The factory validates the market is protocol-owned before forwarding the call.
    ///
    ///         Effect chain:
    ///           expireUnresolved() on clone  →  pool.settleMarket(0 payout)
    ///         The full riskBudget is reclaimed into LP NAV as profit.
    ///         No trader receives any USDC payout.
    ///
    ///         Typical triggers:
    ///         • The oracle question was marked unresolvable (event canceled, bad ancillary data).
    ///         • The resolver bot failed to propose within the resolution window.
    ///         • The UMA DVM was congested and did not settle in time.
    ///
    /// @param market  Address of the BlieverMarket clone to expire
    function expireUnresolved(address market) external nonReentrant {
        _assertDeployedMarket(market);

        IDeployableMarket m = IDeployableMarket(market);

        // Guard against double-expiry or calling after successful oracle resolution.
        if (m.resolved()) revert BlieverMarketFactory__MarketAlreadyResolved(market);

        uint40 deadline    = m.resolutionDeadline();
        uint40 currentTime = uint40(block.timestamp);

        if (currentTime <= deadline)
            revert BlieverMarketFactory__ResolutionDeadlineNotPassed(deadline, currentTime);

        // Forward the expiry to the clone (onlyFactory guarded in the clone).
        // Internally calls pool.settleMarket(0) — vault releases riskBudget as LP profit.
        m.expireUnresolved();

        emit MarketExpiredByFactory(market, m.questionId(), currentTime);
    }

    /*//////////////////////////////////////////////////////////////
               EXTERNAL STATE-CHANGING — ADMIN MARKET CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause trading on a specific market clone.
    ///
    ///         Halts buy(), sell(), and claim() on the target clone immediately.
    ///         Does NOT affect the vault, other markets, or the factory itself.
    ///         Use for:
    ///         • Oracle anomalies that may produce a manipulated resolution.
    ///         • Front-end exploit vectors under investigation.
    ///         • Regulatory compliance holds.
    ///
    ///         Trading resumes only when unpauseMarket is called by PAUSER_ROLE.
    ///
    /// @param market  Address of the BlieverMarket clone to pause
    function pauseMarket(address market) external onlyRole(PAUSER_ROLE) {
        _assertDeployedMarket(market);
        IDeployableMarket(market).pause();
        emit MarketPausedByFactory(market);
    }

    /// @notice Resume trading on a previously paused market clone.
    ///
    /// @param market  Address of the BlieverMarket clone to unpause
    function unpauseMarket(address market) external onlyRole(PAUSER_ROLE) {
        _assertDeployedMarket(market);
        IDeployableMarket(market).unpause();
        emit MarketUnpausedByFactory(market);
    }

    /// @notice Remove a registered, trade-free market from the vault's active roster.
    ///
    ///         The vault enforces the critical constraint: only markets where hasTrades == false
    ///         can be deregistered.  If any trader has executed a buy or sell, pool.deregisterMarket
    ///         reverts with MarketHasTrades — this is the vault's own safety net.
    ///
    ///         Effect: releases the riskBudget back to LP capital (decreases totalLiability).
    ///         After deregistration the market contract still exists on-chain at its address
    ///         but holds no active pool registration and cannot collect or distribute USDC.
    ///
    ///         Use case: cancel a market before any trading activity — e.g., the event was
    ///         called off before trading opened, or the question was discovered to be malformed.
    ///
    ///         Gated by DEFAULT_ADMIN_ROLE (strongest role) because deregistration is irreversible
    ///         once the market has been initialized and registered: OPERATOR_ROLE alone is
    ///         insufficient for this destructive action.
    ///
    /// @param market  Address of the BlieverMarket clone to deregister from the pool
    function deregisterMarket(address market) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertDeployedMarket(market);
        pool.deregisterMarket(market);
        emit MarketDeregisteredByFactory(market);
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING — FACTORY PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the factory globally — blocks new market deployments.
    ///
    ///         Only affects deployMarket (guarded by whenNotPaused).
    ///         Does NOT affect markets already live; their lifecycle functions
    ///         (expireUnresolved, pauseMarket, unpauseMarket, deregisterMarket) remain active.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume new market deployments after a global factory pause.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                         EXTERNAL — READ-ONLY VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pre-compute the deterministic address a clone will receive for a given questionId.
    ///
    ///         Mathematically equivalent to the CREATE2 computation performed inside
    ///         deployMarket.  The salt is derived as keccak256(abi.encode(questionId)),
    ///         mirroring the derivation in deployMarket exactly.
    ///
    ///         Off-chain systems (order engines, frontends) can use this to route limit orders
    ///         and display market data at the pre-computed address BEFORE the deployment
    ///         transaction is broadcast — the "lazy deployment" pattern described in the research.
    ///
    ///         If the returned address already contains bytecode, a deployment for this
    ///         questionId has already succeeded (deployMarket will revert with
    ///         QuestionAlreadyDeployed).
    ///
    /// @param questionId  Oracle question identifier (must match the future DeployParams.questionId)
    /// @return predicted  The address the clone will occupy after deployment
    function predictMarketAddress(bytes32 questionId)
        external
        view
        returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(questionId));
        predicted = Clones.predictDeterministicAddress(
            implementation, salt, address(this)
        );
    }

    /// @notice Compute the LS-LMSR epsilon (ε) seed quantity for a given set of
    ///         per-market parameters.
    ///
    ///         ε seeds every outcome slot of the AMM's initial quantity vector q⁰ = [ε,...,ε].
    ///         The value is chosen so that the LS-LMSR cost function evaluates to:
    ///
    ///             C(q⁰) = maxRisk  (expressed in 18-dec USDC units internally)
    ///
    ///         establishing the vault's worst-case loss bound R = maxRisk from block 0.
    ///
    ///         ── Formula derivation ──────────────────────────────────────────────
    ///         For any n-outcome LS-LMSR with liquidity parameter b = α·Σq_i = α·n·ε:
    ///
    ///             C([ε,...,ε])  =  b · ln(n · exp(ε/b))
    ///                           =  α·n·ε · (ln n + 1/(α·n))
    ///                           =  ε · (1 + α·n·ln n)
    ///
    ///         Solving for ε given C = R:
    ///
    ///             ε  =  R / (1 + α·n·ln n)
    ///
    ///         where:
    ///           R    = maxRisk × SHARE_TO_USDC  (6-dec → 18-dec)
    ///           α    = alpha_                   (18-dec, e.g. 3e16 = 3%)
    ///           n    = nOutcomes                (integer ∈ [2, 7])
    ///           lnN  = _lnLookup(n)             (18-dec precomputed exact value)
    ///
    ///         ── Why exposed as a public pure view ───────────────────────────────
    ///         Operators call this off-chain before constructing a DeployParams to
    ///         verify the ε that deployMarket will use for any (alpha, maxRisk) combination.
    ///         Because each market now carries its own parameters, the function accepts
    ///         explicit inputs rather than reading from pool storage — making it a pure
    ///         function that operators can query without any pool dependency.
    ///
    /// @param nOutcomes  Number of mutually exclusive outcomes [MIN_OUTCOMES, MAX_OUTCOMES]
    /// @param alpha_     Per-market LS-LMSR α (18-dec, must be in [1e12, 2e17])
    /// @param maxRisk    Per-market worst-case USDC loss budget (6-dec, must be > 0)
    /// @return epsilon   Initial per-outcome seed quantity (18-dec, LSMath scale)
    function computeEpsilon(uint8 nOutcomes, uint256 alpha_, uint256 maxRisk)
        public
        pure
        returns (uint256 epsilon)
    {
        if (nOutcomes < MIN_OUTCOMES || nOutcomes > MAX_OUTCOMES)
            revert BlieverMarketFactory__InvalidOutcomeCount(nOutcomes);
        if (alpha_ < 1e12 || alpha_ > 2e17)
            revert BlieverMarketFactory__InvalidAlpha(alpha_);
        if (maxRisk == 0)
            revert BlieverMarketFactory__ZeroEpsilon();

        epsilon = _computeEpsilon(nOutcomes, alpha_, maxRisk);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL — HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Revert if `market` was not deployed by this factory.
    ///      Prevents the factory from acting as a lifecycle controller for arbitrary contracts,
    ///      which would allow an attacker to point the factory at a malicious contract and
    ///      exploit the onlyFactory gate on BlieverMarket clones.
    function _assertDeployedMarket(address market) internal view {
        if (!isDeployedMarket[market])
            revert BlieverMarketFactory__NotDeployedMarket(market);
    }

    /// @dev Core LS-LMSR epsilon arithmetic.  Accepts per-market parameters so that both
    ///      deployMarket (passing params.alpha / params.maxRisk directly) and the public
    ///      computeEpsilon view (accepting explicit inputs) share one implementation.
    ///
    ///      Formula: ε = R / (1 + α·n·ln n)
    ///
    ///      Overflow analysis (same as computeEpsilon NatSpec):
    ///        alpha_ * nOutcomes * lnN ≤ 2e17 * 7 * 1.946e18 ≈ 2.72e36 < 2^256 ✓
    ///        R18 * MATH_SCALE         ≤ 1e12 * 1e12 * 1e18 = 1e42 < 2^256 ✓
    ///
    /// @param nOutcomes  Pre-validated outcome count ∈ [2, 7]
    /// @param alpha_     Per-market LS-LMSR α in 18-dec fixed-point
    /// @param maxRisk    Per-market worst-case USDC loss budget in 6-dec USDC
    /// @return epsilon   ε in 18-dec fixed-point
    function _computeEpsilon(uint8 nOutcomes, uint256 alpha_, uint256 maxRisk)
        internal
        pure
        returns (uint256 epsilon)
    {
        // Scale 6-dec USDC maxRisk to 18-dec to match LSMath SCALE.
        uint256 R18 = maxRisk * SHARE_TO_USDC;

        // denominator = (1 + α·n·ln n) in 18-dec fixed-point.
        uint256 lnN         = _lnLookup(nOutcomes);
        uint256 denominator = MATH_SCALE + (alpha_ * nOutcomes * lnN) / MATH_SCALE;

        // ε = R / (1 + α·n·ln n) in 18-dec.
        epsilon = (R18 * MATH_SCALE) / denominator;
    }

    /// @dev Precomputed natural-log lookup table for n ∈ [2, 7], 18-dec fixed-point.
    ///
    ///      Values are floor(ln(n) × 10^18), verified against Wolfram Alpha and
    ///      cross-checked with Python's `math.log(n) * 1e18` at full float precision.
    ///      Used exclusively inside computeEpsilon — no external library dependency.
    ///
    ///      n │ ln(n)                  │ 18-dec integer
    ///      ──┼────────────────────────┼─────────────────────
    ///      2 │ 0.693147180559945309…  │   693 147 180 559 945 309
    ///      3 │ 1.098612288668109691…  │ 1 098 612 288 668 109 691
    ///      4 │ 1.386294361119890619…  │ 1 386 294 361 119 890 619
    ///      5 │ 1.609437912434100374…  │ 1 609 437 912 434 100 374
    ///      6 │ 1.791759469228327070…  │ 1 791 759 469 228 327 070
    ///      7 │ 1.945910149009313492…  │ 1 945 910 149 009 313 492
    ///
    ///      Note: n is pre-validated ∈ [2, 7] by computeEpsilon before this call.
    ///      The final `return` is n == 7 by construction (the only remaining case).
    ///
    /// @param n  Outcome count (pre-validated as ∈ [2, 7] by caller)
    /// @return   ln(n) in 18-dec fixed-point
    function _lnLookup(uint8 n) internal pure returns (uint256) {
        if (n == 2) return   693_147_180_559_945_309;
        if (n == 3) return 1_098_612_288_668_109_691;
        if (n == 4) return 1_386_294_361_119_890_619;
        if (n == 5) return 1_609_437_912_434_100_374;
        if (n == 6) return 1_791_759_469_228_327_070;
        return              1_945_910_149_009_313_492; // n == 7
    }
}
