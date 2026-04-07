// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                    OPENZEPPELIN — UPGRADEABLE
//////////////////////////////////////////////////////////////*/
import {Initializable}           from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}     from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable}         from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                    OPENZEPPELIN — STANDARD
//////////////////////////////////////////////////////////////*/
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20}                   from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                    INTERNAL — INTERFACES
//////////////////////////////////////////////////////////////*/
import {IBlieverMarket}       from "./interfaces/IBlieverMarket.sol";
import {IBlieverUmaAdapter, QuestionData} from "./interfaces/IBlieverUmaAdapter.sol";
import {IOptimisticOracleV2}  from "./interfaces/IOptimisticOracleV2.sol";
import {IOptimisticRequester} from "./interfaces/IOptimisticRequester.sol";

/*//////////////////////////////////////////////////////////////
                    INTERNAL — MIXINS & LIBRARIES
//////////////////////////////////////////////////////////////*/
import {BulletinBoard}      from "./mixins/BulletinBoard.sol";
import {MultiValueDecoder}  from "./libraries/MultiValueDecoder.sol";
import {AncillaryDataLib}   from "./libraries/AncillaryDataLib.sol";

/// @title  BlieverUmaAdapter
/// @author Bliever Protocol
/// @notice Resolution Adapter that bridges UMA's ManagedOptimisticOracleV2 to the
///         BlieverMarket LS-LMSR prediction market clones.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ROLE IN THE ARCHITECTURE
///         ─────────────────────────────────────────────────────────────────────────
///         The adapter is stored as `resolver` in every BlieverMarket clone.
///         It is the ONLY address permitted to call `market.resolve(winningOutcome)`.
///
///         The adapter does NOT:
///           • Hold, mint, or burn any ERC-20 tokens (beyond routing OO rewards).
///           • Touch BlieverV1Pool or the vault in any way.
///           • Duplicate any AMM state, share ledger, or liability tracking.
///           • Interpret ancillary data content beyond appending the factory initializer
///             suffix and deriving keccak256(fullAncillaryData) == questionId.
///
///         The adapter DOES:
///           • Register oracle questions and submit MULTIPLE_VALUES price requests to the OO.
///           • Implement the IOptimisticRequester callback (priceDisputed) to handle the
///             optimistic dispute → reset escalation flow.
///           • Decode settled int256 MULTIPLE_VALUES prices (UMIP-183) into a uint8 winning
///             outcome and call market.resolve().
///           • Manage an admin path (flag / resolveManually) for oracle emergencies.
///           • Expose the BulletinBoard on-chain update registry for DVM dispute quality.
///           • Support upgrading the OO address when UMA releases a new oracle version,
///             without requiring every market's resolver to change.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ORACLE LIFECYCLE PER QUESTION
///         ─────────────────────────────────────────────────────────────────────────
///
///         Phase 1 — Initialization (Factory calls initializeQuestion):
///           a. Adapter stores QuestionData and submits OO.requestPrice (MULTIPLE_VALUES).
///           b. OO is configured: event-based, priceDisputed callback only, custom bond & liveness.
///
///         Phase 2 — Proposal (Whitelisted resolver bot calls OO.proposePriceFor):
///           a. Bot proposes the encoded winning outcome during the 2-hour liveness window.
///           b. Anyone may dispute by posting the same bond within the liveness window.
///
///         Phase 3a — Fast path (no dispute, 2-hour liveness expires):
///           a. Any EOA calls adapter.resolve(questionId).
///           b. Adapter calls OO.settleAndGetPrice → gets int256 encodedPrice.
///           c. MultiValueDecoder.decodeWinningOutcome → uint8 winnerIndex.
///           d. Adapter calls market.resolve(winnerIndex).
///           e. Market calls pool.settleMarket(totalPayoutUsdc) — vault accounting complete.
///
///         Phase 3b — Dispute path (first dispute filed):
///           a. OO calls adapter.priceDisputed (callback).
///           b. Adapter issues a fresh OO.requestPrice with a new timestamp (question reset).
///           c. Bot must propose again; the dispute cycle can occur once more.
///
///         Phase 3c — DVM path (second dispute filed):
///           a. Adapter sets questionData.refund = true (reward will be returned on resolution).
///           b. UMA token-holders vote over 48–96 hours.
///           c. Any EOA calls adapter.resolve(questionId) after DVM settles.
///
///         Phase 4 — Emergency (oracle failure or governance attack):
///           a. EMERGENCY_ROLE admin calls flag(questionId) → pauses optimistic path.
///           b. After SAFETY_PERIOD (1 hour), EMERGENCY_ROLE calls resolveManually(questionId, winner).
///           c. market.resolve(winner) is called directly, bypassing the OO entirely.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ACCESS CONTROL
///         ─────────────────────────────────────────────────────────────────────────
///         DEFAULT_ADMIN_ROLE — upgrade proxy, grant / revoke other roles, update OO address.
///         FACTORY_ROLE       — initializeQuestion (only the MarketFactory).
///         EMERGENCY_ROLE     — flag, unflag, resolveManually, reset, pause/unpause questions.
///
///         ─────────────────────────────────────────────────────────────────────────
///         UPGRADE PATH
///         ─────────────────────────────────────────────────────────────────────────
///         The adapter is UUPS upgradeable. Individual BlieverMarket clones are immutable
///         (EIP-1167 with no upgrade logic) — they pin a single resolver address. When a
///         new oracle version is released, the admin:
///           1. Calls updateOptimisticOracle(newOO) on this adapter proxy (no market changes).
///           2. New questions use newOO; their _questionOracle snapshot is set at init time.
///           3. Already-initialized questions retain their _questionOracle snapshot (old OO).
///              hasPrice and settleAndGetPrice for those questions still route to the old OO.
///              priceDisputed callbacks from the old OO are accepted via _knownOracles tracking.
///           4. No active questions are bricked by an OO upgrade. Upgrades are safe at any time.
///
/// @dev    Inherits:
///           Initializable          — UUPS-compatible upgradeable init guard.
///           AccessControlUpgradeable — role-based access control (OZ).
///           PausableUpgradeable    — global circuit breaker (pauses all resolution).
///           UUPSUpgradeable        — UUPS upgrade mechanism.
///           ReentrancyGuardTransient — EIP-1153 transient reentrancy guard.
///           BulletinBoard          — Polymarket's on-chain update registry.
///           IOptimisticRequester   — UMA callback interface.
///           IBlieverUmaAdapter     — public adapter interface.
contract BlieverUmaAdapter is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    BulletinBoard,
    IOptimisticRequester,
    IBlieverUmaAdapter
{
    using SafeERC20 for IERC20;
    using MultiValueDecoder for int256;

    /*//////////////////////////////////////////////////////////////
          EVENTS — SUPPLEMENT TO IBlieverUmaAdapter INTERFACE
    //////////////////////////////////////////////////////////////
      These events are defined here rather than in IBlieverUmaAdapter
      because they were introduced after the initial interface cut.
      IBlieverUmaAdapter.sol should be updated to include them so
      external ABI consumers (SDKs, subgraphs) see a complete ABI.
    //////////////////////////////////////////////////////////////*/

    // ── Implementation-only error ────────────────────────────────────────────
    /// @dev Reverts when _tryResetQuestion is called by any address other than
    ///      the adapter itself. This function is external only to satisfy
    ///      Solidity's try/catch requirement (which only works on external calls).
    ///      No external caller should ever invoke it directly.
    error BlieverUmaAdapter__OnlySelf();

    /// @notice Emitted in priceDisputed when a second dispute escalates the question
    ///         to full UMA DVM arbitration (48–96-hour token-holder vote).
    ///         Indexers and monitoring bots must listen for this event to detect DVM
    ///         escalation, since no other on-chain signal marks this state transition.
    event QuestionEscalatedToDVM(bytes32 indexed questionId);

    /// @notice Emitted when a best-effort reward refund fails (e.g. creator is
    ///         USDC-blacklisted). Market settlement is unaffected — the market is
    ///         already resolved by the time this fires.
    ///         `amount` is the number of `token` units stranded on the adapter.
    ///         An admin can recover them via a future upgrade or emergency function.
    event RefundFailed(
        bytes32 indexed questionId,
        address indexed creator,
        uint256         amount,
        address indexed token
    );

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Bytes32 price identifier for UMA Optimistic Oracle — UMIP-183.
    bytes32 public constant MULTIPLE_VALUES_IDENTIFIER = bytes32("MULTIPLE_VALUES");

    /// @notice Safety delay (seconds) between flagging and manual resolution.
    ///         1 hour — sufficient for the community to verify the flag is legitimate.
    uint256 public constant SAFETY_PERIOD = 1 hours;

    /// @notice Maximum ancillary data length enforced by OOV2.
    ///         From OOV2: OO_ANCILLARY_DATA_LIMIT.
    uint256 public constant MAX_ANCILLARY_DATA = 8139;

    /// @notice Maximum number of outcomes per market (V1 constraint, UMIP-183 supports 7 max).
    uint8 public constant MAX_OUTCOMES = MultiValueDecoder.MAX_OUTCOMES;

    /// @notice Byte-length of the ",initializer:<40-char-hex-address>" suffix appended to
    ///         raw ancillaryData by AncillaryDataLib._appendAncillaryData before hashing.
    ///         Breakdown: 13 bytes (",initializer:") + 40 bytes (lower-case hex address) = 53.
    ///         Raw ancillaryData passed by the factory must not exceed MAX_ANCILLARY_DATA − 53.
    uint256 public constant INITIALIZER_SUFFIX_LENGTH = 53;

    // ── Role identifiers ────────────────────────────────────────────────────

    /// @notice Role granted to the MarketFactory.
    ///         Only address that may call initializeQuestion().
    bytes32 public constant FACTORY_ROLE   = keccak256("FACTORY_ROLE");

    /// @notice Role granted to the protocol's emergency multisig / DAO.
    ///         May flag, resolveManually, reset, pause, and unpause questions.
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The UMA ManagedOptimisticOracleV2 used for all NEW price requests.
    ///         Updatable by DEFAULT_ADMIN_ROLE to support OO version upgrades.
    ///         Per-question oracle tracking (_questionOracle) ensures historical questions
    ///         always resolve against the exact OO instance they were submitted to.
    IOptimisticOracleV2 public optimisticOracle;

    /// @notice Registry of all registered questions.
    ///         Key: keccak256(fullAncillaryData) == questionId == market.questionId().
    ///         fullAncillaryData = raw JSON ancillaryData ++ ",initializer:" ++ hex(factory).
    mapping(bytes32 => QuestionData) public questions;

    /// @notice Records every OO address ever assigned to this adapter.
    ///         Used by the onlyOptimisticOracle modifier so that priceDisputed callbacks
    ///         from a previously-active oracle (before an upgrade) are still accepted for
    ///         questions that were initialized on that oracle.
    mapping(address => bool) private _knownOracles;

    /// @notice Records the OO instance active at the time each question was initialized
    ///         (or last reset). All hasPrice and settleAndGetPrice calls for a given question
    ///         route to this address, not the current global optimisticOracle.
    ///         Prevents resolution failure after an oracle upgrade while live questions exist.
    mapping(bytes32 => IOptimisticOracleV2) private _questionOracle;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Disable direct initialization on the implementation contract.
    ///      Only the proxy (deployed by the factory's admin setup) may be initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time proxy initializer called immediately after proxy deployment.
    ///
    /// @param _optimisticOracle  ManagedOptimisticOracleV2 address on Base.
    /// @param _admin             DEFAULT_ADMIN_ROLE — controls upgrades, role management, OO update.
    /// @param _factory           FACTORY_ROLE — only address that may register questions.
    /// @param _emergency         EMERGENCY_ROLE — emergency multisig / DAO.
    function initialize(
        address _optimisticOracle,
        address _admin,
        address _factory,
        address _emergency
    ) external initializer {
        if (_optimisticOracle == address(0)) revert ZeroAddress();
        if (_admin            == address(0)) revert ZeroAddress();
        if (_factory          == address(0)) revert ZeroAddress();
        if (_emergency        == address(0)) revert ZeroAddress();

        // ── OZ Upgradeable Initialisers ─────────────────────────────────────
        __AccessControl_init();
        __Pausable_init();

        // ── Role Setup ───────────────────────────────────────────────────────
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACTORY_ROLE,       _factory);
        _grantRole(EMERGENCY_ROLE,     _emergency);

        // ── Oracle ───────────────────────────────────────────────────────────
        optimisticOracle              = IOptimisticOracleV2(_optimisticOracle);
        _knownOracles[_optimisticOracle] = true;
    }

    /*//////////////////////////////////////////////////////////////
                      FACTORY-FACING — QUESTION INIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a market question and submit the initial OO price request.
    ///
    ///         Called by the MarketFactory in the same transaction that deploys the
    ///         EIP-1167 clone market. Atomically:
    ///           1. Appends ",initializer:<hex(msg.sender)>" to ancillaryData via AncillaryDataLib,
    ///              producing fullAncillaryData that carries UMA attribution for DVM voters.
    ///           2. Validates that questionId == keccak256(fullAncillaryData) == market.questionId().
    ///           3. Validates outcomeCount ∈ [2, MAX_OUTCOMES].
    ///           4. Persists QuestionData (market, requestTimestamp, outcomeCount, OO params, creator).
    ///           5. Transfers reward from caller → adapter if reward > 0.
    ///           6. Calls OO.requestPrice (MULTIPLE_VALUES, event-based, priceDisputed callback).
    ///           7. Applies custom bond and liveness overrides via OO.setBond / OO.setCustomLiveness.
    ///
    ///         Reward handling:
    ///           If reward > 0, the factory (caller) must have approved this adapter as spender.
    ///           The adapter holds the reward temporarily and approves the OO as spender.
    ///           On resolution (or refund), the reward is either consumed by the OO or returned
    ///           to the creator.
    ///
    /// @param questionId     keccak256(fullAncillaryData) where fullAncillaryData is the raw JSON
    ///                       with ",initializer:<hex(msg.sender)>" appended by this function.
    ///                       Must equal market.questionId().
    /// @param market         BlieverMarket proxy. resolver must equal address(this).
    /// @param ancillaryData  Raw MULTIPLE_VALUES JSON: {title, description, labels[N]}.
    ///                       This function appends ",initializer:<hex(msg.sender)>" before hashing
    ///                       and submitting to the OO. Raw length must be ≤ MAX_ANCILLARY_DATA −
    ///                       INITIALIZER_SUFFIX_LENGTH. The factory must pre-compute questionId
    ///                       from the full (appended) bytes off-chain.
    /// @param rewardToken    DVM-whitelisted ERC-20 for OO reward and bond.
    /// @param reward         OO proposer reward (rewardToken units; 0 is valid).
    /// @param proposalBond   Bond override (0 → OO-managed default).
    /// @param liveness       Challenge window in seconds (0 → OO default; min enforced by managed OO).
    function initializeQuestion(
        bytes32        questionId,
        address        market,
        bytes calldata ancillaryData,
        address        rewardToken,
        uint256        reward,
        uint256        proposalBond,
        uint256        liveness
    ) external nonReentrant onlyRole(FACTORY_ROLE) whenNotPaused {
        // ── Input Validation ────────────────────────────────────────────────

        if (market      == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();
        if (ancillaryData.length == 0 || ancillaryData.length > MAX_ANCILLARY_DATA - INITIALIZER_SUFFIX_LENGTH)
            revert InvalidAncillaryData();

        // Append the factory initializer suffix for UMA attribution on the DVM voter UI.
        // Polymarket pattern: keccak256(raw JSON ++ ",initializer:" ++ hex(factory)) == questionId.
        // The factory must compute questionId from fullAncillaryData off-chain before calling.
        bytes memory fullAncillaryData = AncillaryDataLib._appendAncillaryData(msg.sender, ancillaryData);
        if (keccak256(fullAncillaryData) != questionId) revert QuestionIdMismatch();

        // The market's questionId must match — ensures this adapter is the right resolver.
        if (IBlieverMarket(market).questionId() != questionId) revert QuestionIdMismatch();

        // Prevent duplicate registration.
        if (_isInitialized(questions[questionId])) revert AlreadyInitialized();

        // outcomeCount is validated by BlieverMarket.initialize; we re-check here
        // to ensure the MULTIPLE_VALUES path will work (V1 cap: MAX_OUTCOMES = 7).
        uint8 outcomeCount = IBlieverMarket(market).outcomeCount();
        if (outcomeCount < 2 || outcomeCount > MAX_OUTCOMES)
            revert InvalidOutcomeCount(outcomeCount);

        // ── Persist Question Data ────────────────────────────────────────────
        uint40 requestTimestamp = uint40(block.timestamp);

        questions[questionId] = QuestionData({
            market:               market,
            requestTimestamp:     requestTimestamp,
            manualResolveAt:      0,
            outcomeCount:         outcomeCount,
            resolved:             false,
            paused:               false,
            reset:                false,
            refund:               false,
            unresolvable:         false,
            rewardToken:          rewardToken,
            creator:              msg.sender,
            reward:               reward,
            proposalBond:         proposalBond,
            liveness:             liveness,
            ancillaryData:        fullAncillaryData
        });

        // Snapshot the active oracle for this question's entire lifecycle.
        // _hasPrice and settleAndGetPrice always use this address, not the
        // current global optimisticOracle, so oracle upgrades never break
        // the resolution path for in-flight questions.
        _questionOracle[questionId] = optimisticOracle;

        // ── Submit OO Price Request ──────────────────────────────────────────
        _requestPrice(
            msg.sender,
            requestTimestamp,
            fullAncillaryData,
            rewardToken,
            reward,
            proposalBond,
            liveness
        );

        emit QuestionInitialized(
            questionId,
            requestTimestamp,
            market,
            msg.sender,
            fullAncillaryData,
            rewardToken,
            reward,
            proposalBond,
            liveness
        );
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLUTION — PUBLIC (PERMISSIONLESS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true when the OO has a settled price and the question is ready
    ///         to be resolved (initialized, unpaused, not flagged, not yet resolved or unresolvable).
    /// @param questionId  The oracle question identifier.
    function ready(bytes32 questionId) external view returns (bool) {
        return _ready(questionId, questions[questionId]);
    }

    /// @notice Settle the OO request and dispatch the result to the BlieverMarket.
    ///
    ///         Permissionless — any EOA may call once ready() == true.
    ///
    ///         MULTIPLE_VALUES dispatch logic:
    ///           int256.min (too early, reward == 0) → _resetQuestion (new OO request at new timestamp).
    ///           int256.min (too early, reward  > 0) → flag for admin: reward was consumed by the OO;
    ///                                                  adapter cannot self-fund a new request safely.
    ///           int256.max (unresolvable) → mark unresolvable, emit QuestionUnresolvable.
    ///                                        Factory must call market.expireUnresolved().
    ///           valid price → MultiValueDecoder.decodeWinningOutcome → market.resolve(winner).
    ///
    ///         CEI pattern: all state writes precede the external market.resolve() call.
    ///         market.resolve() executes before _bestEffortRefund() — the primary settlement must never
    ///         be blocked by a secondary reward-return transfer.
    ///
    ///         Price availability: _hasPrice() is NOT called here. If the OO has not yet
    ///         settled the request, settleAndGetPrice() inside _decodeAndResolve() will
    ///         revert with the OO's native error. Use ready() for off-chain polling.
    ///
    /// @param questionId  The oracle question identifier.
    function resolve(bytes32 questionId) external nonReentrant whenNotPaused {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd))  revert NotInitialized();
        // qd.paused   → operational halt via pauseQuestion() (trading suspended, OO path frozen).
        // _isFlagged  → pending manual resolution via flag() (admin intervention in progress).
        // These are independent states; both independently block permissionless resolution.
        if (qd.paused)             revert QuestionIsPaused();
        if (_isFlagged(qd))        revert Flagged();
        if (qd.resolved)           revert AlreadyResolved();
        if (qd.unresolvable)       revert Unresolvable();
        // Price availability is not checked here. settleAndGetPrice() in _decodeAndResolve
        // reverts with the OO's native error when the liveness window has not yet closed.
        // Callers should verify ready(questionId) == true off-chain before submitting.

        _decodeAndResolve(questionId, qd);
    }

    /*//////////////////////////////////////////////////////////////
              UMA CALLBACK — IOptimisticRequester
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op — the adapter does not enable priceProposed callbacks.
    function priceProposed(bytes32, uint256, bytes memory) external override {}

    /// @notice Invoked by the OO immediately after a dispute is filed.
    ///
    ///         First dispute  → _resetQuestion: issues a fresh OO request with a new timestamp.
    ///                          Sets qd.reset = true (tracks we are on the second attempt).
    ///         Second dispute → sets qd.refund = true and emits QuestionEscalatedToDVM.
    ///                          The DVM arbitration process begins (48–96-hour token-holder vote).
    ///                          No further OO request is issued by the adapter; the DVM
    ///                          will settle the existing managed request.
    ///
    ///         If the question was already resolved via resolveManually() (admin acted
    ///         before the callback fired), the reward is returned to the creator best-effort.
    ///         The refund uses a try/catch so that a blacklisted creator address cannot cause
    ///         the OO's dispute transaction to revert.
    ///
    /// @param ancillaryData  The full ancillary bytes echoed back by the OO (raw JSON ++
    ///                       ",initializer:" suffix). keccak256(ancillaryData) == questionId.
    function priceDisputed(
        bytes32,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256
    ) external override onlyOptimisticOracle {
        bytes32 questionId = keccak256(ancillaryData);
        QuestionData storage qd = questions[questionId];

        // Timestamp guard: silently ignore callbacks that do not match the active
        // request timestamp. Defends against stale OO callbacks from a superseded
        // request (e.g. a callback arriving after the question was already reset)
        // triggering erroneous state transitions on the current question state.
        if (timestamp != qd.requestTimestamp) return;

        // If already manually resolved, return the reward to the creator best-effort.
        // Use try/catch so a blacklisted creator cannot cause this OO callback to revert,
        // which would block the disputer's transaction from landing on-chain.
        if (qd.resolved) {
            if (qd.reward > 0) {
                _bestEffortRefund(questionId, qd);
            }
            return;
        }

        if (qd.reset) {
            // Second dispute: escalate to DVM — reward will be returned on resolution.
            qd.refund = true;
            // Emit so indexers and bots can detect the 48–96-hour DVM arbitration window.
            // Without this event there is no on-chain signal distinguishing "first dispute
            // reset" from "second dispute escalated to full DVM vote".
            emit QuestionEscalatedToDVM(questionId);
            return;
        }

        // First dispute: attempt reset (new OO request).
        //
        // _resetQuestion routes through _requestPrice, which may revert if the reward
        // token is paused or the OO is temporarily unavailable. If it reverts, the
        // disputer's OO transaction would also revert — permanently blocking dispute
        // economics for this question. Wrapping the call in try/catch ensures the OO
        // callback ALWAYS lands. On failure, the question is flagged for admin recovery
        // via reset() rather than silently blocking the dispute system.
        //
        // _tryResetQuestion is an external self-call wrapper (this.X) required because
        // Solidity try/catch only works on external ABI calls, not internal functions.
        // It is access-guarded to reject any caller other than address(this).
        try this._tryResetQuestion(address(this), questionId, false) {
            // Reset succeeded — new OO request issued with updated requestTimestamp.
        } catch {
            // Reset failed — flag for EMERGENCY_ROLE recovery via reset().
            qd.manualResolveAt = uint40(block.timestamp + SAFETY_PERIOD);
            emit QuestionFlagged(questionId);
        }
    }

    /// @notice No-op — the adapter does not enable priceSettled callbacks.
    function priceSettled(bytes32, uint256, bytes memory, int256) external override {}

    /*//////////////////////////////////////////////////////////////
                    ADMIN — EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Flag a question for manual resolution after a 1-hour safety delay.
    ///
    ///         Sets qd.manualResolveAt, which causes resolve() to revert with Flagged.
    ///         The permissionless resolve() path is blocked; EMERGENCY_ROLE must call
    ///         resolveManually() after SAFETY_PERIOD elapses.
    ///
    ///         This function intentionally does NOT touch qd.paused. The pause state
    ///         managed by pauseQuestion() is independent of the flag state. An admin
    ///         calling unflag() will never silently undo a prior pauseQuestion() call.
    ///
    ///         Use cases:
    ///           • The UMA DVM returns a result that is demonstrably incorrect (e.g.
    ///             governance attack — see Research.txt "Ukraine Mineral Agreement").
    ///           • A market ancillary data is fatally ambiguous and the OO cannot resolve.
    ///
    /// @param questionId  The oracle question identifier.
    function flag(bytes32 questionId)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd)) revert NotInitialized();
        if (_isFlagged(qd))      revert Flagged();
        if (qd.resolved)         revert AlreadyResolved();

        qd.manualResolveAt = uint40(block.timestamp + SAFETY_PERIOD);

        emit QuestionFlagged(questionId);
    }

    /// @notice Unflag a question before the safety period has elapsed.
    ///         Clears qd.manualResolveAt so the optimistic OO path resumes.
    ///         Cannot be called after the safety period ends (to prevent admin indecision).
    ///
    ///         Does NOT modify qd.paused. If the question was explicitly paused via
    ///         pauseQuestion() before or after flag(), that pause state is preserved.
    ///
    /// @param questionId  The oracle question identifier.
    function unflag(bytes32 questionId)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd))                      revert NotInitialized();
        if (!_isFlagged(qd))                           revert NotFlagged();
        if (qd.resolved)                               revert AlreadyResolved();
        if (block.timestamp >= qd.manualResolveAt)     revert SafetyPeriodPassed();

        qd.manualResolveAt = 0;

        emit QuestionUnflagged(questionId);
    }

    /// @notice Resolve a flagged question manually, bypassing the OO entirely.
    ///
    ///         Available ONLY after the SAFETY_PERIOD has elapsed since flag() was called.
    ///         The 1-hour delay gives the community time to contest the admin's intent.
    ///
    ///         CEI: all QuestionData writes precede the external market.resolve() call.
    ///
    ///         Interaction ordering: market.resolve() executes BEFORE _bestEffortRefund().
    ///         The market settlement is the critical invariant; the reward refund is a
    ///         secondary concern. If the creator's address is unable to receive the reward
    ///         token (e.g. USDC blacklist), the market still settles and winners can claim.
    ///
    /// @param questionId     The oracle question identifier.
    /// @param winningOutcome The winning outcome index [0, outcomeCount).
    function resolveManually(bytes32 questionId, uint8 winningOutcome)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd))                  revert NotInitialized();
        if (!_isFlagged(qd))                       revert NotFlagged();
        if (qd.resolved)                           revert AlreadyResolved();
        if (block.timestamp < qd.manualResolveAt)  revert SafetyPeriodNotPassed();
        if (winningOutcome >= qd.outcomeCount)
            revert InvalidOutcome(winningOutcome, qd.outcomeCount);

        // ── Effects (CEI) ────────────────────────────────────────────────────
        qd.resolved = true;

        // ── Critical interaction — must never be blocked ─────────────────────
        IBlieverMarket(qd.market).resolve(winningOutcome);

        // ── Secondary interaction — reward refund is best-effort after settle ─
        // Uses try/catch so a blacklisted creator address cannot revert this tx
        // and undo the market settlement above.
        if (qd.refund && qd.reward > 0) {
            _bestEffortRefund(questionId, qd);
        }

        emit QuestionManuallyResolved(questionId, winningOutcome);
    }

    /// @notice Admin failsafe: manually reset a question and issue a fresh OO request.
    ///
    ///         Used when the priceDisputed OO callback fails to fire due to an OO-side
    ///         bug or an edge-case in the managed oracle's callback routing.
    ///         Also used to recover from a TOO_EARLY + reward > 0 flag, where the
    ///         caller (EMERGENCY_ROLE) funds the new request from their own balance.
    ///         The caller (EMERGENCY_ROLE) pays for the new price request reward.
    ///
    /// @param questionId  The oracle question identifier.
    function reset(bytes32 questionId)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd)) revert NotInitialized();
        if (qd.resolved)         revert AlreadyResolved();

        // If reward is sitting on the adapter, return it before resetting.
        if (qd.refund && qd.reward > 0) {
            _refund(qd);
        }

        // If the question was flagged (e.g. by the TOO_EARLY + reward > 0 path),
        // clear the flag so the fresh OO request can proceed normally.
        if (_isFlagged(qd)) {
            qd.manualResolveAt = 0;
            emit QuestionUnflagged(questionId);
        }

        // Reset, paying for new request from the caller (emergency admin).
        _resetQuestion(msg.sender, questionId, true, qd);
    }

    /// @notice Pause oracle resolution for a single question.
    ///         Does NOT prevent manual resolution via resolveManually().
    ///
    /// @param questionId  The oracle question identifier.
    function pauseQuestion(bytes32 questionId) external onlyRole(EMERGENCY_ROLE) {
        QuestionData storage qd = questions[questionId];
        if (!_isInitialized(qd)) revert NotInitialized();
        if (qd.resolved)         revert AlreadyResolved();
        qd.paused = true;
        emit QuestionPaused(questionId);
    }

    /// @notice Unpause oracle resolution for a single question.
    ///
    /// @param questionId  The oracle question identifier.
    function unpauseQuestion(bytes32 questionId) external onlyRole(EMERGENCY_ROLE) {
        QuestionData storage qd = questions[questionId];
        if (!_isInitialized(qd)) revert NotInitialized();
        qd.paused = false;
        emit QuestionUnpaused(questionId);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — GLOBAL PAUSE (DEFAULT_ADMIN_ROLE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all initializeQuestion() and resolve() calls globally.
    ///         Does NOT prevent manual resolution or admin operations.
    /// @dev    Uses OZ PausableUpgradeable.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume normal operation globally.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — ORACLE UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the OO address when UMA releases a new oracle version.
    ///
    ///         New questions will use the updated OO; their _questionOracle snapshot
    ///         is recorded at initializeQuestion time so they always route to newOracle.
    ///
    ///         Already-initialized questions are unaffected: each question's
    ///         _questionOracle snapshot still points to the OO it was submitted to.
    ///         Their hasPrice and settleAndGetPrice calls continue to route to the
    ///         original oracle. priceDisputed callbacks from the old OO are still
    ///         accepted because _knownOracles tracks every OO ever assigned here.
    ///
    ///         This means oracle upgrades are safe at any time — live questions
    ///         will continue resolving via their pinned OO instance.
    ///
    ///         Security note: only DEFAULT_ADMIN_ROLE (governance multisig) can call this.
    ///         Any existing price request allowances on the old OO must be revoked manually
    ///         if the old OO address is distrusted after the upgrade.
    ///
    /// @param newOracle  Address of the new ManagedOptimisticOracleV2.
    function updateOptimisticOracle(address newOracle)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (newOracle == address(0)) revert ZeroAddress();
        address oldOracle = address(optimisticOracle);
        optimisticOracle             = IOptimisticOracleV2(newOracle);
        _knownOracles[newOracle]     = true;
        emit OptimisticOracleUpdated(oldOracle, newOracle);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the full QuestionData struct for a registered question.
    function getQuestion(bytes32 questionId)
        external
        view
        returns (QuestionData memory)
    {
        return questions[questionId];
    }

    /// @notice Returns true if the question has been registered.
    function isInitialized(bytes32 questionId) external view returns (bool) {
        return _isInitialized(questions[questionId]);
    }

    /// @notice Returns true if the question has been flagged for manual resolution.
    function isFlagged(bytes32 questionId) external view returns (bool) {
        return _isFlagged(questions[questionId]);
    }

    /// @notice Returns the OO instance that this question's price request was submitted to.
    ///         This is the address used for all hasPrice and settleAndGetPrice calls
    ///         for this question, regardless of any subsequent updateOptimisticOracle calls.
    function getQuestionOracle(bytes32 questionId)
        external
        view
        returns (address)
    {
        return address(_questionOracle[questionId]);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — RESOLUTION CORE
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls OO.settleAndGetPrice, decodes the MULTIPLE_VALUES price, and
    ///      dispatches to market.resolve(winningOutcome).  Called by the public resolve().
    ///
    ///      Routes settleAndGetPrice to _questionOracle[questionId], not the global
    ///      optimisticOracle. This guarantees resolution succeeds even after an oracle
    ///      upgrade, since the per-question snapshot always points to the OO instance
    ///      that holds the actual settled request.
    ///
    ///      CEI pattern:
    ///        1. Write all QuestionData state changes.
    ///        2. Call market.resolve() — the critical settlement that must never be blocked.
    ///        3. Optionally transfer reward (_bestEffortRefund) — secondary, non-reverting.
    ///
    ///      Interaction ordering: market.resolve() runs BEFORE _bestEffortRefund(). This ensures that
    ///      even if the creator's address cannot receive the reward token (e.g. USDC blacklist),
    ///      the market settles and winners can claim. A stuck refund never bricks the market.
    ///
    ///      The OO.settleAndGetPrice call happens first (before CEI writes) because:
    ///        a. It is required to obtain the price — no alternative.
    ///        b. ReentrancyGuardTransient blocks any re-entrant call.
    ///        c. The OO is a trusted UMA contract; we accept its price or revert.
    ///
    /// @param questionId  The oracle question identifier.
    /// @param qd          Storage pointer to the question's data.
    function _decodeAndResolve(
        bytes32               questionId,
        QuestionData storage  qd
    ) internal {
        // ── Fetch settled price from the question's pinned OO instance ────────
        // Route to _questionOracle[questionId], not the global optimisticOracle,
        // so that an oracle upgrade between question init and resolution does not
        // cause this call to target an OO that knows nothing about the request.
        // OO.settleAndGetPrice also distributes bonds; must be called once to
        // finalize the request. Reverts if price is not yet available.
        int256 encodedPrice = _questionOracle[questionId].settleAndGetPrice(
            MULTIPLE_VALUES_IDENTIFIER,
            qd.requestTimestamp,
            qd.ancillaryData
        );

        // ── Special sentinels (check BEFORE decoding per UMIP-183) ──────────

        // Too early (event-based expiry before game start).
        // The OO returns type(int256).min when a proposal was submitted before
        // the event's anchor timestamp.
        //
        // Branch on reward to avoid draining the adapter:
        //   reward == 0 → auto-reset is safe; no token transfer risk.
        //   reward  > 0 → UMA consumed the reward on TOO_EARLY settlement and will
        //                 not refund it. The adapter balance is now 0 for this token.
        //                 A self-funded reset (_requestPrice(address(this), ...))
        //                 would revert on safeTransferFrom. Flag for admin recovery
        //                 via reset(), which pulls fresh funds from EMERGENCY_ROLE.
        if (encodedPrice.isTooEarly()) {
            if (qd.reward > 0) {
                qd.manualResolveAt = uint40(block.timestamp + SAFETY_PERIOD);
                emit QuestionFlagged(questionId);
            } else {
                _resetQuestion(address(this), questionId, true, qd);
            }
            return;
        }

        // Unresolvable (canceled event, invalid ancillary data, or > 7 labels).
        // Mark the question so the factory can call market.expireUnresolved().
        if (encodedPrice.isUnresolvable()) {
            qd.unresolvable = true;
            emit QuestionUnresolvable(questionId);
            return;
        }

        // ── Decode winning outcome ───────────────────────────────────────────
        // Reverts with InvalidOracleEncoding if the encoding is malformed.
        uint8 winningOutcome = encodedPrice.decodeWinningOutcome(qd.outcomeCount);

        // ── CEI: Effects ─────────────────────────────────────────────────────
        qd.resolved = true;

        // ── Critical interaction — must never be blocked ──────────────────────
        // market.resolve() settles the market and releases vault liability.
        // It executes before _bestEffortRefund() so that even if the refund fails
        // (e.g. USDC blacklist on the creator address), the market is already settled
        // and winners can claim without waiting for admin intervention.
        IBlieverMarket(qd.market).resolve(winningOutcome);

        // ── Secondary interaction — best-effort reward refund ─────────────────
        // Uses try/catch internally. If the creator cannot receive the reward token,
        // RefundFailed is emitted and the reward remains on the adapter for recovery.
        // The market settlement above is not affected regardless of refund outcome.
        if (qd.refund && qd.reward > 0) {
            _bestEffortRefund(questionId, qd);
        }

        emit QuestionResolved(questionId, encodedPrice, winningOutcome);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — OO REQUEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Submit a new MULTIPLE_VALUES price request to the OO.
    ///
    ///      Configures the request as event-based and sets the priceDisputed callback.
    ///      Applies custom bond and liveness overrides if provided.
    ///      Pulls the reward from the requestor if reward > 0.
    ///
    /// @param requestor       Address paying for the request (factory on init; adapter on reset).
    /// @param requestTimestamp Timestamp used as the OO request anchor.
    /// @param ancillaryData   Full ancillary bytes (raw JSON ++ ",initializer:" ++ hex(factory)).
    /// @param rewardToken     DVM-whitelisted ERC-20.
    /// @param reward          Proposer reward (0 is valid).
    /// @param bond            Custom bond override (0 → OO default).
    /// @param liveness        Challenge window (0 → OO default).
    function _requestPrice(
        address      requestor,
        uint256      requestTimestamp,
        bytes memory ancillaryData,
        address      rewardToken,
        uint256      reward,
        uint256      bond,
        uint256      liveness
    ) internal {
        IOptimisticOracleV2 oo = optimisticOracle;
        IERC20 token = IERC20(rewardToken);

        // Pull reward from the requestor → adapter, then approve OO as spender.
        if (reward > 0) {
            if (requestor != address(this)) {
                token.safeTransferFrom(requestor, address(this), reward);
            }
            // Ensure infinite approval rather than repeatedly resetting to exact amounts.
            // The OO is a trusted UMA contract; unlimited approval is the Polymarket pattern.
            if (token.allowance(address(this), address(oo)) < reward) {
                token.forceApprove(address(oo), type(uint256).max);
            }
        }

        // Submit the MULTIPLE_VALUES price request.
        oo.requestPrice(
            MULTIPLE_VALUES_IDENTIFIER,
            requestTimestamp,
            ancillaryData,
            token,
            reward
        );

        // Configure request as event-based: proposals before the event anchor
        // timestamp resolve as type(int256).min (TOO_EARLY_PRICE), not as a valid outcome.
        oo.setEventBased(MULTIPLE_VALUES_IDENTIFIER, requestTimestamp, ancillaryData);

        // Enable ONLY the priceDisputed callback.
        // priceProposed and priceSettled are no-ops; enabling them adds gas with no benefit.
        oo.setCallbacks(
            MULTIPLE_VALUES_IDENTIFIER,
            requestTimestamp,
            ancillaryData,
            false, // priceProposed: no-op
            true,  // priceDisputed: ENABLED — adapter must react to disputes
            false  // priceSettled:  no-op
        );

        // Apply custom bond if provided (overrides the managed OO's default).
        if (bond > 0) {
            oo.setBond(
                MULTIPLE_VALUES_IDENTIFIER,
                requestTimestamp,
                ancillaryData,
                bond
            );
        }

        // Apply custom liveness (must be ≥ ManagedOptimisticOracleV2.minimumLiveness).
        if (liveness > 0) {
            oo.setCustomLiveness(
                MULTIPLE_VALUES_IDENTIFIER,
                requestTimestamp,
                ancillaryData,
                liveness
            );
        }
    }

    /// @dev External self-call wrapper that enables try/catch around _resetQuestion
    ///      in priceDisputed. Solidity try/catch only wraps genuine external ABI calls;
    ///      internal function calls cannot be wrapped. By routing through `this.X`,
    ///      the adapter catches reversion without propagating it to the disputer's tx.
    ///
    ///      Access guard: rejects any caller that is not address(this). The function
    ///      is only valid inside the `try this._tryResetQuestion(...)` block in
    ///      priceDisputed. Exposing it publicly (required by `external` visibility)
    ///      is safe because the access guard prevents unauthorized calls.
    ///
    ///      Storage: questionId is re-resolved via the `questions` mapping inside the
    ///      external frame. Solidity prohibits passing storage pointers cross-frame
    ///      to external functions; re-resolving the storage pointer is equivalent and
    ///      writes to the same proxy storage slots.
    ///
    /// @param requestor    Address paying for the new OO request (typically address(this)).
    /// @param questionId   The oracle question identifier.
    /// @param resetRefund  If true, clear the refund flag.
    function _tryResetQuestion(
        address requestor,
        bytes32 questionId,
        bool    resetRefund
    ) external {
        if (msg.sender != address(this)) revert BlieverUmaAdapter__OnlySelf();
        _resetQuestion(requestor, questionId, resetRefund, questions[questionId]);
    }

    /// @dev Reset a question: update requestTimestamp, set reset flag, issue new OO request.
    ///
    ///      Called on:
    ///        1. First dispute (priceDisputed callback, resetRefund = false).
    ///        2. TOO_EARLY_PRICE resolution with reward == 0 (_decodeAndResolve, resetRefund = true).
    ///        3. Admin reset() failsafe (resetRefund = true).
    ///
    ///      The new requestTimestamp is block.timestamp at the time of reset.
    ///      This aligns the new OO request anchor with the current block, ensuring
    ///      event-based proposals for the reset request are correctly time-gated.
    ///
    ///      After issuing the new request, _questionOracle[questionId] is updated to
    ///      the current global optimisticOracle so future hasPrice and settleAndGetPrice
    ///      calls for this question route to the correct OO instance.
    ///
    /// @param requestor    Address paying for the new OO request (adapter or admin).
    /// @param questionId   The oracle question identifier.
    /// @param resetRefund  If true, clear the refund flag (reward has already been returned).
    /// @param qd           Storage pointer to the question's data.
    function _resetQuestion(
        address              requestor,
        bytes32              questionId,
        bool                 resetRefund,
        QuestionData storage qd
    ) internal {
        uint40 newTimestamp = uint40(block.timestamp);
        qd.requestTimestamp = newTimestamp;
        qd.reset            = true;
        if (resetRefund) qd.refund = false;

        // Snapshot the current global oracle for this question's new request.
        // Subsequent _hasPrice and settleAndGetPrice calls will route here.
        _questionOracle[questionId] = optimisticOracle;

        _requestPrice(
            requestor,
            newTimestamp,
            qd.ancillaryData,
            qd.rewardToken,
            qd.reward,
            qd.proposalBond,
            qd.liveness
        );

        emit QuestionReset(questionId);
    }

    /// @dev Best-effort reward refund — never reverts.
    ///
    ///      Used in all settlement-critical paths where a failed refund must not
    ///      unwind a market settlement or block an OO callback from landing.
    ///
    ///      Why `.transfer()` instead of `safeTransfer`:
    ///        `safeTransfer` is an internal function injected by the `using SafeERC20`
    ///        directive. Solidity's try/catch only wraps *external* ABI calls.
    ///        Wrapping an internal library call in try/catch does not compile.
    ///        The raw `IERC20.transfer()` is an external call on the token contract
    ///        and CAN be wrapped in try/catch. The return bool is explicitly captured
    ///        in the `returns` clause so that non-reverting tokens which signal failure
    ///        by returning false (rather than reverting) are correctly detected — a
    ///        false return fires RefundFailed just as a hard revert does.
    ///
    ///      CEI: `qd.reward` is zeroed BEFORE the external transfer. Even though
    ///        `ReentrancyGuardTransient` and `qd.resolved = true` already block
    ///        reentry, clearing the amount first is belt-and-suspenders practice.
    ///        The `RefundFailed` event carries the amount for admin recovery.
    ///
    ///      Recovery: if the catch fires, the reward tokens remain on the adapter.
    ///        An admin can locate the stuck amount via the `RefundFailed` event log
    ///        and recover via a future upgrade or a dedicated admin rescue function.
    ///
    /// @param questionId  Used for the RefundFailed event index.
    /// @param qd          Storage pointer to the question's data.
    function _bestEffortRefund(bytes32 questionId, QuestionData storage qd) internal {
        uint256 amount  = qd.reward;
        qd.reward       = 0; // CEI: clear before external call
        try IERC20(qd.rewardToken).transfer(qd.creator, amount) returns (bool success) {
            if (!success) {
                // Non-reverting failure: token returned false without reverting.
                // Market is already settled — this event is the admin's recovery signal.
                emit RefundFailed(questionId, qd.creator, amount, qd.rewardToken);
            }
        } catch {
            // Hard revert path: creator cannot receive the token (e.g. USDC blacklist).
            // Market is already settled — this event is the admin's recovery signal.
            emit RefundFailed(questionId, qd.creator, amount, qd.rewardToken);
        }
    }

    /// @dev Hard-reverting reward refund. Used ONLY in admin-path functions (reset())
    ///      where reverting is acceptable — the market is not yet settled and admin
    ///      can address the root cause (blacklist, token pause) before retrying.
    ///      Do NOT call this from settlement-critical paths; use _bestEffortRefund instead.
    function _refund(QuestionData storage qd) internal {
        IERC20(qd.rewardToken).safeTransfer(qd.creator, qd.reward);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — PREDICATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A question is initialized when it has non-empty ancillaryData.
    function _isInitialized(QuestionData storage qd) internal view returns (bool) {
        return qd.ancillaryData.length > 0;
    }

    /// @dev A question is flagged for manual resolution when manualResolveAt > 0.
    function _isFlagged(QuestionData storage qd) internal view returns (bool) {
        return qd.manualResolveAt > 0;
    }

    /// @dev Returns true when all preconditions for permissionless resolve() are met.
    function _ready(bytes32 questionId, QuestionData storage qd) internal view returns (bool) {
        if (!_isInitialized(qd)) return false;
        if (qd.paused)           return false;
        if (_isFlagged(qd))      return false;
        if (qd.resolved)         return false;
        if (qd.unresolvable)     return false;
        return _hasPrice(questionId, qd);
    }

    /// @dev Checks whether the question's pinned OO instance holds a settled price
    ///      for this question's active request. Routes to _questionOracle[questionId]
    ///      so that an oracle upgrade never causes the check to query the wrong OO.
    function _hasPrice(bytes32 questionId, QuestionData storage qd) internal view returns (bool) {
        return _questionOracle[questionId].hasPrice(
            address(this),
            MULTIPLE_VALUES_IDENTIFIER,
            qd.requestTimestamp,
            qd.ancillaryData
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if the caller is not a known optimistic oracle address.
    ///      Accepts callbacks from any OO ever assigned to this adapter, not only the
    ///      current global optimisticOracle. This is required because a priceDisputed
    ///      callback for a question initialized on the old OO will still come from the
    ///      old OO address even after updateOptimisticOracle has been called. Restricting
    ///      to the current OO only would silently drop those legitimate callbacks.
    modifier onlyOptimisticOracle() {
        if (!_knownOracles[msg.sender]) revert NotOptimisticOracle();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    UUPS — UPGRADE AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Only DEFAULT_ADMIN_ROLE may authorize a proxy upgrade.
    ///      Guards the UUPS _authorizeUpgrade hook (OZ pattern).
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
