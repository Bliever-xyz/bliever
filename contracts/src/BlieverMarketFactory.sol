// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/**
 * @custom:security-contact security@bliever.xyz
 * @custom:audit-status      Unaudited — do NOT deploy to mainnet without a full audit.
 */

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

// ─────────────────────────────────────────────────────────────────────────────
//  FACTORY-LOCAL INTERFACE
//  Covers the BlieverMarket entry-points that ONLY the factory calls.
//  The adapter's share of the market surface (resolve, questionId, outcomeCount)
//  lives in the existing IBlieverMarket.sol; this is intentionally non-overlapping.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal interface for the factory-specific calls into BlieverMarket clones.
interface IDeployableMarket {
    /// @dev Called once, immediately after clone deployment.
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
    ) external;

    /// @dev Halts buy / sell / claim on the clone. Callable only by `factory`.
    function pause()   external;

    /// @dev Resumes trading on the clone. Callable only by `factory`.
    function unpause() external;

    /// @dev Forces a zero-payout settlement once resolutionDeadline has passed.
    ///      Callable only by `factory`.
    function expireUnresolved() external;

    /// @dev Unix timestamp past which resolve() may no longer be called.
    function resolutionDeadline() external view returns (uint40);

    /// @dev True after resolve() has succeeded on this clone.
    function resolved() external view returns (bool);

    /// @dev keccak256 of the full ancillary data (set at initialize).
    function questionId() external view returns (bytes32);
}

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

    /// @dev Proposer / disputer bond in rewardToken decimals.
    ///      Enforced by the OO during the liveness window.
    uint256 bond;

    /// @dev Optimistic-liveness window in seconds.
    ///      Minimum value is enforced by the UMA Optimistic Oracle.
    uint256 liveness;

    // ── Deployment addressing ─────────────────────────────────────────────────
    /// @dev CREATE2 salt that deterministically fixes the clone's address.
    ///      Recommended derivation: keccak256(abi.encode(questionId)).
    ///      Pre-compute the address with predictMarketAddress(salt) before broadcasting.
    bytes32 salt;
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
///         ε is computed on-chain from pool.alpha and pool.maxRiskPerMarket using the
///         LS-LMSR seed formula: ε = R / (1 + α · n · ln n), where R is the vault's
///         worst-case loss budget per market.  Natural-log values for n ∈ {2..7} are
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
    /// @param salt               CREATE2 salt used to derive the clone address.
    event MarketDeployed(
        address indexed market,
        bytes32 indexed questionId,
        uint8           nOutcomes,
        uint40          tradingDeadline,
        uint40          resolutionDeadline,
        bytes32         salt
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

    /// @dev The CREATE2 address for this salt already contains deployed bytecode.
    /// @param salt     The colliding salt.
    /// @param existing The address already occupied.
    error BlieverMarketFactory__SaltAlreadyUsed(bytes32 salt, address existing);

    /// @dev computeEpsilon returned 0 — pool params may be misconfigured.
    error BlieverMarketFactory__ZeroEpsilon();

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
    ///         2. Compute LS-LMSR ε from on-chain pool.alpha + pool.maxRiskPerMarket.
    ///         3. Pull OO reward tokens from caller into factory  (if params.reward > 0).
    ///         4. Deploy EIP-1167 clone via CREATE2  (~41 k gas, deterministic address).
    ///         5. Initialize the clone  (sets resolver, factory, q-vector, deadlines, alpha).
    ///         6. Register clone in BlieverV1Pool  (reserves riskBudget; grants MARKET_ROLE).
    ///         7. Approve adapter then call adapter.initializeQuestion  (submits UMA OO request).
    ///         8. Record deployment in factory state; emit MarketDeployed.
    ///
    ///         ── Caller responsibilities ───────────────────────────────────────────
    ///         • Must hold OPERATOR_ROLE.
    ///         • Factory must NOT be paused.
    ///         • If params.reward > 0: BEFORE calling, approve THIS factory as spender
    ///           for ≥ params.reward of params.rewardToken.
    ///         • params.questionId must be correctly pre-computed off-chain:
    ///               full = ancillaryData ++ ",initializer:" ++ lowerCaseHex(factoryAddress)
    ///               questionId = keccak256(full)
    ///           The adapter validates this on-chain and reverts with QuestionIdMismatch if wrong.
    ///         • params.salt should be unique — recommended: keccak256(abi.encode(questionId)).
    ///           The factory pre-checks for address collision and reverts with SaltAlreadyUsed
    ///           before any token movements or clone deployments occur.
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

        if (params.nOutcomes < MIN_OUTCOMES || params.nOutcomes > MAX_OUTCOMES)
            revert BlieverMarketFactory__InvalidOutcomeCount(params.nOutcomes);

        // tradingDeadline must be: strictly in the future AND < resolutionDeadline.
        if (
            params.tradingDeadline    == 0                           ||
            params.resolutionDeadline == 0                           ||
            params.tradingDeadline    >= params.resolutionDeadline   ||
            uint40(block.timestamp)   >= params.tradingDeadline
        ) {
            revert BlieverMarketFactory__InvalidDeadlines();
        }

        if (params.reward > 0 && params.rewardToken == address(0))
            revert BlieverMarketFactory__RewardTokenRequired();

        // Fail-fast salt-collision guard: predict the CREATE2 address and verify
        // it is unoccupied BEFORE any token transfers or clone deployments.
        // This yields a descriptive revert (SaltAlreadyUsed) instead of a generic
        // low-level CREATE2 collision revert from within the Clones library.
        {
            address predicted = Clones.predictDeterministicAddress(
                implementation, params.salt, address(this)
            );
            if (predicted.code.length > 0)
                revert BlieverMarketFactory__SaltAlreadyUsed(params.salt, predicted);
        }

        // ── 2. Compute ε from on-chain pool parameters ───────────────────────
        // computeEpsilon reads pool.alpha() and pool.maxRiskPerMarket() and applies
        // the LS-LMSR seed formula.  ε is never caller-supplied — protects against
        // operator error and guarantees C(q⁰) ≈ pool.maxRiskPerMarket.
        uint256 epsilon = computeEpsilon(params.nOutcomes);
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
        // The address is deterministic: predictMarketAddress(params.salt) == market.
        market = Clones.cloneDeterministic(implementation, params.salt);

        // ── 5. Initialize the clone ───────────────────────────────────────────
        // Snapshot pool.alpha() at deployment time (LS-LMSR: spread is fixed at creation).
        // The clone sets its internal state: pool, resolver, factory, q-vector, deadlines.
        IDeployableMarket(market).initialize(
            address(pool),
            params.questionId,
            params.nOutcomes,
            pool.alpha(),             // alpha snapshot — immutable per market
            params.tradingDeadline,
            params.resolutionDeadline,
            epsilon,
            address(adapter),         // resolver = UMA adapter
            address(this)             // factory  = this contract
        );

        // ── 6. Register clone in BlieverV1Pool ───────────────────────────────
        // registerMarket: (a) validates contract + capacity, (b) reserves riskBudget
        // against totalLiability, (c) grants MARKET_ROLE to the clone.
        // Requires MARKET_MANAGER_ROLE on pool (must be pre-granted to this factory).
        pool.registerMarket(market, uint32(params.nOutcomes));

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
            params.resolutionDeadline,
            params.salt
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

    /// @notice Pre-compute the deterministic address a clone will receive for a given salt.
    ///
    ///         This is mathematically equivalent to the CREATE2 computation performed inside
    ///         deployMarket.  Off-chain systems (order engines, frontends) can use this to
    ///         route limit orders and liquidity to the market address BEFORE the deployment
    ///         transaction is broadcast — the "lazy deployment" pattern described in the research.
    ///
    ///         If the returned address already contains bytecode, the salt cannot be reused
    ///         (deployMarket will revert with SaltAlreadyUsed).
    ///
    ///         Recommended salt derivation: keccak256(abi.encode(questionId)).
    ///
    /// @param salt  CREATE2 salt (must match the `salt` field in the future DeployParams)
    /// @return predicted  The address the clone will occupy after deployment
    function predictMarketAddress(bytes32 salt)
        external
        view
        returns (address predicted)
    {
        predicted = Clones.predictDeterministicAddress(
            implementation, salt, address(this)
        );
    }

    /// @notice Compute the LS-LMSR epsilon (ε) seed quantity from current pool parameters.
    ///
    ///         ε seeds every outcome slot of the AMM's initial quantity vector q⁰ = [ε,...,ε].
    ///         The value is chosen so that the LS-LMSR cost function evaluates to:
    ///
    ///             C(q⁰) = pool.maxRiskPerMarket  (in 18-dec USDC units)
    ///
    ///         establishing the vault's worst-case loss bound R from block 0.
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
    ///           R   = pool.maxRiskPerMarket × SHARE_TO_USDC  (6-dec → 18-dec)
    ///           α   = pool.alpha                             (18-dec, e.g. 3e16 = 3%)
    ///           n   = nOutcomes                              (integer ∈ [2, 7])
    ///           lnN = _lnLookup(n)                          (18-dec precomputed exact value)
    ///
    ///         ── Why exposed as a public view ────────────────────────────────────
    ///         Operators can call this off-chain before constructing a DeployParams to
    ///         verify the ε that deployMarket will use.  The same computation runs inside
    ///         deployMarket — ε is never caller-supplied.
    ///
    /// @param nOutcomes  Number of mutually exclusive outcomes [MIN_OUTCOMES, MAX_OUTCOMES]
    /// @return epsilon   Initial per-outcome seed quantity (18-dec, LSMath scale)
    function computeEpsilon(uint8 nOutcomes)
        public
        view
        returns (uint256 epsilon)
    {
        if (nOutcomes < MIN_OUTCOMES || nOutcomes > MAX_OUTCOMES)
            revert BlieverMarketFactory__InvalidOutcomeCount(nOutcomes);

        uint256 alpha_  = pool.alpha();
        uint256 maxRisk = pool.maxRiskPerMarket();

        // Scale 6-dec USDC maxRisk to 18-dec to match LSMath SCALE.
        // maxRisk (e.g. 1e9 = $1 000 USDC) → R18 (e.g. 1e21, 18-dec).
        uint256 R18 = maxRisk * SHARE_TO_USDC;

        // Natural log of nOutcomes in 18-dec fixed-point.
        uint256 lnN = _lnLookup(nOutcomes);

        // denominator = (1 + α·n·ln n) expressed in 18-dec fixed-point.
        //
        // Overflow analysis:
        //   alpha_ ≤ MAX_ALPHA = 2e17
        //   nOutcomes ≤ 7
        //   lnN ≤ ln(7) × 1e18 ≈ 1.946e18
        //   alpha_ * nOutcomes * lnN ≤ 2e17 * 7 * 1.946e18 = 2.72e36 < 2^256 ✓
        //   After dividing by MATH_SCALE: ≤ 2.72e18, well within uint256 range ✓
        uint256 denominator = MATH_SCALE + (alpha_ * nOutcomes * lnN) / MATH_SCALE;

        // ε = R / (1 + α·n·ln n) in 18-dec.
        //
        // Overflow analysis:
        //   R18 = maxRisk * 1e12 (maxRisk is 6-dec USDC)
        //   For a realistic maxRisk of $1M USDC: maxRisk = 1e12, R18 = 1e24.
        //   R18 * MATH_SCALE = 1e24 * 1e18 = 1e42 < 2^256 ✓
        epsilon = (R18 * MATH_SCALE) / denominator;
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
