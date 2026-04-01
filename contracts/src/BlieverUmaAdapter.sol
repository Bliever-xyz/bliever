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
///           • Interpret ancillary data beyond deriving keccak256(ancillaryData) == questionId.
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
///           2. New questions use the new OO. Already-initialized questions continue with the
///              old OO stored in their QuestionData.requestTimestamp / ancillaryData key.
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

    /// @notice The UMA ManagedOptimisticOracleV2 used for all price requests.
    ///         Updatable by DEFAULT_ADMIN_ROLE to support OO version upgrades.
    ///         New questions use this address; historical questions retain their stored
    ///         requestTimestamp keys (OO routes by requester+identifier+timestamp+data).
    IOptimisticOracleV2 public optimisticOracle;

    /// @notice Registry of all registered questions.
    ///         Key: keccak256(ancillaryData) == questionId == market.questionId().
    mapping(bytes32 => QuestionData) public questions;

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
        __UUPSUpgradeable_init();

        // ── Role Setup ───────────────────────────────────────────────────────
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACTORY_ROLE,       _factory);
        _grantRole(EMERGENCY_ROLE,     _emergency);

        // ── Oracle ───────────────────────────────────────────────────────────
        optimisticOracle = IOptimisticOracleV2(_optimisticOracle);
    }

    /*//////////////////////////////////////////////////////////////
                      FACTORY-FACING — QUESTION INIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a market question and submit the initial OO price request.
    ///
    ///         Called by the MarketFactory in the same transaction that deploys the
    ///         EIP-1167 clone market. Atomically:
    ///           1. Validates that questionId == keccak256(ancillaryData) == market.questionId().
    ///           2. Validates outcomeCount ∈ [2, MAX_OUTCOMES].
    ///           3. Persists QuestionData (market, requestTimestamp, outcomeCount, OO params, creator).
    ///           4. Transfers reward from caller → adapter if reward > 0.
    ///           5. Calls OO.requestPrice (MULTIPLE_VALUES, event-based, priceDisputed callback).
    ///           6. Applies custom bond and liveness overrides via OO.setBond / OO.setCustomLiveness.
    ///
    ///         Reward handling:
    ///           If reward > 0, the factory (caller) must have approved this adapter as spender.
    ///           The adapter holds the reward temporarily and approves the OO as spender.
    ///           On resolution (or refund), the reward is either consumed by the OO or returned
    ///           to the creator.
    ///
    /// @param questionId     keccak256(ancillaryData). Must equal market.questionId().
    /// @param market         BlieverMarket proxy. resolver must equal address(this).
    /// @param ancillaryData  MULTIPLE_VALUES JSON: {title, description, labels[N]}.
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
        if (ancillaryData.length == 0 || ancillaryData.length > MAX_ANCILLARY_DATA)
            revert InvalidAncillaryData();

        // The questionId passed by the factory must equal keccak256(ancillaryData).
        // This ensures the off-chain computed questionId and the on-chain hash are consistent.
        if (keccak256(ancillaryData) != questionId) revert QuestionIdMismatch();

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
            ancillaryData:        ancillaryData
        });

        // ── Submit OO Price Request ──────────────────────────────────────────
        _requestPrice(
            msg.sender,
            requestTimestamp,
            ancillaryData,
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
            ancillaryData,
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
    ///         to be resolved (initialized, unpaused, not yet resolved or unresolvable).
    /// @param questionId  The oracle question identifier.
    function ready(bytes32 questionId) external view returns (bool) {
        return _ready(questions[questionId]);
    }

    /// @notice Settle the OO request and dispatch the result to the BlieverMarket.
    ///
    ///         Permissionless — any EOA may call once ready() == true.
    ///
    ///         MULTIPLE_VALUES dispatch logic:
    ///           int256.min (too early) → _resetQuestion (new OO request at new timestamp).
    ///           int256.max (unresolvable) → mark unresolvable, emit QuestionUnresolvable.
    ///                                        Factory must call market.expireUnresolved().
    ///           valid price → MultiValueDecoder.decodeWinningOutcome → market.resolve(winner).
    ///
    ///         CEI pattern: all state writes precede the external market.resolve() call.
    ///
    /// @param questionId  The oracle question identifier.
    function resolve(bytes32 questionId) external nonReentrant whenNotPaused {
        QuestionData storage qd = questions[questionId];

        if (!_isInitialized(qd))  revert NotInitialized();
        if (qd.paused)            revert QuestionIsPaused();
        if (qd.resolved)          revert AlreadyResolved();
        if (qd.unresolvable)      revert Unresolvable();
        if (!_hasPrice(qd))       revert PriceNotAvailable();

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
    ///         Second dispute → sets qd.refund = true. The DVM arbitration process begins.
    ///                          No further OO request is issued by the adapter; the DVM
    ///                          will settle the existing managed request.
    ///
    ///         If the question was already resolved via resolveManually() (admin acted
    ///         before the callback fired), the reward is refunded to the creator and we return.
    ///
    /// @param ancillaryData  The request ancillary data (keccak256 → questionId).
    function priceDisputed(
        bytes32,
        uint256,
        bytes memory ancillaryData,
        uint256
    ) external override onlyOptimisticOracle {
        bytes32 questionId = keccak256(ancillaryData);
        QuestionData storage qd = questions[questionId];

        // If already manually resolved, just refund the reward and exit.
        if (qd.resolved) {
            if (qd.reward > 0) {
                IERC20(qd.rewardToken).safeTransfer(qd.creator, qd.reward);
            }
            return;
        }

        if (qd.reset) {
            // Second dispute: escalate to DVM — reward will be returned on resolution.
            qd.refund = true;
            return;
        }

        // First dispute: reset the question (new OO request).
        _resetQuestion(address(this), questionId, false, qd);
    }

    /// @notice No-op — the adapter does not enable priceSettled callbacks.
    function priceSettled(bytes32, uint256, bytes memory, int256) external override {}

    /*//////////////////////////////////////////////////////////////
                    ADMIN — EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Flag a question for manual resolution after a 1-hour safety delay.
    ///
    ///         Sets qd.paused = true, blocking the permissionless resolve() path.
    ///         EMERGENCY_ROLE must call resolveManually() after SAFETY_PERIOD elapses.
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
        qd.paused          = true;

        emit QuestionFlagged(questionId);
    }

    /// @notice Unflag a question before the safety period has elapsed.
    ///         Restores qd.paused = false so the optimistic OO path resumes.
    ///         Cannot be called after the safety period ends (to prevent admin indecision).
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
        qd.paused          = false;

        emit QuestionUnflagged(questionId);
    }

    /// @notice Resolve a flagged question manually, bypassing the OO entirely.
    ///
    ///         Available ONLY after the SAFETY_PERIOD has elapsed since flag() was called.
    ///         The 1-hour delay gives the community time to contest the admin's intent.
    ///
    ///         CEI: all QuestionData writes precede the external market.resolve() call.
    ///
    ///         Refund: if qd.refund == true (reward is sitting on this contract), return
    ///         the reward to the creator on manual resolution.
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

        // If reward is sitting on the adapter (refund flag set by second dispute),
        // return it to the question creator before calling into the market.
        if (qd.refund && qd.reward > 0) {
            _refund(qd);
        }

        // ── Interaction ──────────────────────────────────────────────────────
        IBlieverMarket(qd.market).resolve(winningOutcome);

        emit QuestionManuallyResolved(questionId, winningOutcome);
    }

    /// @notice Admin failsafe: manually reset a question and issue a fresh OO request.
    ///
    ///         Used when the priceDisputed OO callback fails to fire due to an OO-side
    ///         bug or an edge-case in the managed oracle's callback routing.
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
    ///         New questions will use the updated OO.
    ///         Already-initialized questions continue using their stored OO via their
    ///         requestTimestamp key; the managed OO routes by (requester, identifier,
    ///         timestamp, ancillaryData) so historical request keys remain valid on the
    ///         old OO contract.
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
        optimisticOracle  = IOptimisticOracleV2(newOracle);
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

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — RESOLUTION CORE
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls OO.settleAndGetPrice, decodes the MULTIPLE_VALUES price, and
    ///      dispatches to market.resolve(winningOutcome).  Called by the public resolve().
    ///
    ///      CEI pattern:
    ///        1. Write all QuestionData state changes.
    ///        2. Optionally transfer reward (ERC-20 external call).
    ///        3. Call market.resolve() (external call into BlieverMarket clone).
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
        // ── Fetch settled price from the OO ─────────────────────────────────
        // OO.settleAndGetPrice also distributes bonds; must be called once to
        // finalize the request. Reverts if price is not yet available.
        int256 encodedPrice = optimisticOracle.settleAndGetPrice(
            MULTIPLE_VALUES_IDENTIFIER,
            qd.requestTimestamp,
            qd.ancillaryData
        );

        // ── Special sentinels (check BEFORE decoding per UMIP-183) ──────────

        // Too early (event-based expiry before game start).
        // The OO returns type(int256).min when a proposal was submitted before
        // the event's anchor timestamp.  We reset the question to re-request.
        if (MultiValueDecoder.isTooEarly(encodedPrice)) {
            _resetQuestion(address(this), questionId, true, qd);
            return;
        }

        // Unresolvable (canceled event, invalid ancillary data, or > 7 labels).
        // Mark the question so the factory can call market.expireUnresolved().
        if (MultiValueDecoder.isUnresolvable(encodedPrice)) {
            qd.unresolvable = true;
            emit QuestionUnresolvable(questionId);
            return;
        }

        // ── Decode winning outcome ───────────────────────────────────────────
        // Reverts with InvalidOracleEncoding if the encoding is malformed.
        uint8 winningOutcome = MultiValueDecoder.decodeWinningOutcome(
            encodedPrice,
            qd.outcomeCount
        );

        // ── CEI: Effects before interaction ─────────────────────────────────
        qd.resolved = true;

        // If reward is sitting on this adapter (refund flag from second dispute),
        // return it to the creator.
        if (qd.refund && qd.reward > 0) {
            _refund(qd);
        }

        // ── Interaction: notify the BlieverMarket clone ──────────────────────
        IBlieverMarket(qd.market).resolve(winningOutcome);

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
    /// @param ancillaryData   MULTIPLE_VALUES JSON bytes.
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

    /// @dev Reset a question: update requestTimestamp, set reset flag, issue new OO request.
    ///
    ///      Called on:
    ///        1. First dispute (priceDisputed callback, resetRefund = false).
    ///        2. TOO_EARLY_PRICE resolution (_decodeAndResolve, resetRefund = true).
    ///        3. Admin reset() failsafe (resetRefund = true).
    ///
    ///      The new requestTimestamp is block.timestamp at the time of reset.
    ///      This aligns the new OO request anchor with the current block, ensuring
    ///      event-based proposals for the reset request are correctly time-gated.
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

    /// @dev Transfer the stored reward back to the question creator.
    ///      Only called when qd.refund == true AND qd.reward > 0.
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
    function _ready(QuestionData storage qd) internal view returns (bool) {
        if (!_isInitialized(qd)) return false;
        if (qd.paused)           return false;
        if (qd.resolved)         return false;
        if (qd.unresolvable)     return false;
        return _hasPrice(qd);
    }

    /// @dev Checks whether the OO holds a settled price for this question's active request.
    function _hasPrice(QuestionData storage qd) internal view returns (bool) {
        return optimisticOracle.hasPrice(
            address(this),
            MULTIPLE_VALUES_IDENTIFIER,
            qd.requestTimestamp,
            qd.ancillaryData
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL — MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if the caller is not the currently configured optimistic oracle.
    ///      Used to guard the priceDisputed callback.
    modifier onlyOptimisticOracle() {
        if (msg.sender != address(optimisticOracle)) revert NotOptimisticOracle();
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
