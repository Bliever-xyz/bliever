// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IOptimisticOracleV2} from "./IOptimisticOracleV2.sol";
// ── Struct ──────────────────────────────────────────────────────────────────

/// @notice Complete state for a registered oracle question.
///
/// Storage layout is optimized for tight packing — reordering fields will
/// corrupt deployed proxy storage; do NOT modify order across upgrades.
///
/// Slot 0 (31 bytes): market(20) + requestTimestamp(5) + manualResolveAt(5) + outcomeCount(1)
/// Slot 1 (25 bytes): resolved(1) + paused(1) + reset(1) + refund(1) + unresolvable(1) + rewardToken(20)
/// Slot 2 (20 bytes): creator(20)
/// Slot 3 (32 bytes): reward
/// Slot 4 (32 bytes): proposalBond
/// Slot 5 (32 bytes): liveness
/// Dynamic:           ancillaryData
struct QuestionData {
    // ── Slot 0 ──────────────────────────────────────────────────────────────
    address market;               ///< BlieverMarket proxy that this question resolves.
    uint40  requestTimestamp;     ///< block.timestamp at OO requestPrice (updated on reset).
    uint40  manualResolveAt;      ///< Safety-period end for manual resolution (0 = not flagged).
    uint8   outcomeCount;         ///< Cached from market.outcomeCount() [2, MAX_OUTCOMES].

    // ── Slot 1 ──────────────────────────────────────────────────────────────
    bool    resolved;             ///< True once market.resolve() or resolveManually() succeeds.
    bool    paused;               ///< True while admin has paused resolution of this question.
    bool    reset;                ///< True after the first dispute (second dispute → DVM).
    bool    refund;               ///< True when reward must be returned to creator on resolution.
    bool    unresolvable;         ///< True when oracle returned type(int256).max (canceled event).
    address rewardToken;          ///< ERC-20 used for OO reward and bond.

    // ── Slot 2 ──────────────────────────────────────────────────────────────
    address creator;              ///< Address that called initializeQuestion (factory).

    // ── Slots 3–5 ───────────────────────────────────────────────────────────
    uint256 reward;               ///< OO proposer reward amount (rewardToken units).
    uint256 proposalBond;         ///< OO proposer / disputer bond (rewardToken units).
    uint256 liveness;             ///< OO challenge window in seconds (0 → OO default).

    // ── Dynamic ─────────────────────────────────────────────────────────────
    bytes   ancillaryData;        ///< MULTIPLE_VALUES JSON. keccak256(ancillaryData) == questionId.
}

// ── Interface ───────────────────────────────────────────────────────────────

/// @title  IBlieverUmaAdapter
/// @notice Public interface for the Bliever UMA Resolution Adapter.
///
///         The adapter is the sole `resolver` for all BlieverMarket clones.
///         It bridges the UMA Optimistic Oracle V2 (ManagedOptimisticOracleV2) to the
///         LS-LMSR market's `resolve(winningOutcome)` entry point.
///
///         MULTIPLE_VALUES (UMIP-183) encoding contract:
///         ─────────────────────────────────────────────
///         For an N-outcome market the oracle packs N uint32 values in one int256:
///           value[i] = uint32(encodedPrice >> (32 * i))
///         Exactly one value must equal 1 (the winning outcome); all others must be 0.
///         Special values: type(int256).min → too early, type(int256).max → unresolvable.
interface IBlieverUmaAdapter {

    // ────────────────────────────────────────────────────────────────────────
    //                              EVENTS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new question is registered and an OO price request is submitted.
    event QuestionInitialized(
        bytes32 indexed questionId,
        uint256         requestTimestamp,
        address indexed market,
        address indexed creator,
        bytes           ancillaryData,
        address         rewardToken,
        uint256         reward,
        uint256         proposalBond,
        uint256         liveness
    );

    /// @notice Emitted when a question is successfully resolved via the oracle.
    event QuestionResolved(
        bytes32 indexed questionId,
        int256          encodedPrice,
        uint8           winningOutcome
    );

    /// @notice Emitted when a question is manually resolved by the EMERGENCY_ROLE.
    ///         `resolver` is the msg.sender (EMERGENCY_ROLE holder) that executed the call,
    ///         providing an immutable on-chain audit trail of which admin wallet acted.
    event QuestionManuallyResolved(
        bytes32 indexed questionId,
        uint8           winningOutcome,
        address indexed resolver
    );

    /// @notice Emitted when the oracle returns type(int256).max (canceled / unresolvable event).
    ///         The question is marked unresolvable; the factory may call market.expireUnresolved().
    event QuestionUnresolvable(bytes32 indexed questionId);

    /// @notice Emitted when a disputed proposal triggers a question reset (new OO request).
    event QuestionReset(bytes32 indexed questionId);

    /// @notice Emitted when an admin flags a question for manual resolution.
    event QuestionFlagged(bytes32 indexed questionId);

    /// @notice Emitted when an admin unflags a question before the safety period ends.
    event QuestionUnflagged(bytes32 indexed questionId);

    /// @notice Emitted when an admin pauses resolution for a single question.
    event QuestionPaused(bytes32 indexed questionId);

    /// @notice Emitted when an admin unpauses resolution for a single question.
    event QuestionUnpaused(bytes32 indexed questionId);

    /// @notice Emitted in priceDisputed when a second dispute escalates the question
    ///         to full UMA DVM arbitration (48–96-hour token-holder vote).
    ///         Indexers and monitoring bots must listen for this event to detect DVM
    ///         escalation, since no other on-chain signal marks this state transition.
    event QuestionEscalatedToDVM(bytes32 indexed questionId);

    /// @notice Emitted when a best-effort reward refund fails (e.g. creator is
    ///         USDC-blacklisted). Market settlement is unaffected — the market is
    ///         already resolved by the time this fires.
    ///         `amount` is the number of `token` units stranded on the adapter.
    ///         An admin can recover them via a future upgrade or emergency rescue function.
    event RefundFailed(
        bytes32 indexed questionId,
        address indexed creator,
        uint256         amount,
        address indexed token
    );

    /// @notice Emitted when the optimistic oracle address is updated.
    event OptimisticOracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ────────────────────────────────────────────────────────────────────────
    //                              ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotOptimisticOracle();
    error NotInitialized();
    error AlreadyInitialized();
    error AlreadyResolved();
    error QuestionIsPaused();
    error PriceNotAvailable();
    error InvalidAncillaryData();
    error QuestionIdMismatch();
    error InvalidOutcomeCount(uint8 count);
    error InvalidOutcome(uint8 outcome, uint8 max);
    error InvalidOraclePrice();
    error Unresolvable();
    error NotFlagged();
    error Flagged();
    error SafetyPeriodNotPassed();
    error SafetyPeriodPassed();

    // ────────────────────────────────────────────────────────────────────────
    //                         FACTORY-FACING
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Register a market question and submit the initial OO price request.
    ///         Called by the MarketFactory immediately after deploying an EIP-1167 clone.
    ///
    /// @param questionId     keccak256(ancillaryData) — must match market.questionId().
    /// @param market         BlieverMarket proxy address (resolver must equal address(this)).
    /// @param ancillaryData  MULTIPLE_VALUES JSON bytes: {title, description, labels[N]}.
    /// @param rewardToken    ERC-20 token for OO reward and bond (must be DVM-whitelisted).
    /// @param reward         OO proposer reward (0 is valid). Pulled from caller if > 0.
    /// @param proposalBond   OO bond override in rewardToken (0 → OO default).
    /// @param liveness       Challenge window in seconds (0 → OO default, min enforced by managed OO).
    function initializeQuestion(
        bytes32        questionId,
        address        market,
        bytes calldata ancillaryData,
        address        rewardToken,
        uint256        reward,
        uint256        proposalBond,
        uint256        liveness
    ) external;

    // ────────────────────────────────────────────────────────────────────────
    //                         RESOLUTION — PUBLIC
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Returns true when the oracle has a settled price and the question is
    ///         initialized, unpaused, and not yet resolved or unresolvable.
    function ready(bytes32 questionId) external view returns (bool);

    /// @notice Settle the OO request and dispatch the result to the BlieverMarket.
    ///         Permissionless — any EOA may call once ready() == true.
    ///
    ///         Outcomes:
    ///           int256.min  → reset question (too early, new OO request issued)
    ///           int256.max  → mark unresolvable, emit QuestionUnresolvable
    ///           valid price → decode winning outcome, call market.resolve(winningOutcome)
    function resolve(bytes32 questionId) external;

    // ────────────────────────────────────────────────────────────────────────
    //                         ADMIN — EMERGENCY
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Flag a question for manual resolution after a 1-hour safety delay.
    ///         Sets paused = true to block optimistic resolve() during the window.
    function flag(bytes32 questionId) external;

    /// @notice Unflag a question before the safety period has elapsed.
    ///         Restores paused = false so the oracle path resumes.
    function unflag(bytes32 questionId) external;

    /// @notice Resolve a flagged question manually after the safety period.
    ///         Calls market.resolve(winningOutcome) directly — bypasses OO.
    function resolveManually(bytes32 questionId, uint8 winningOutcome) external;

    /// @notice Admin failsafe: reset a question's OO request manually.
    ///         Used when the priceDisputed callback fails to fire (OO-side bug).
    function reset(bytes32 questionId) external;

    /// @notice Pause oracle resolution for a single question.
    function pauseQuestion(bytes32 questionId) external;

    /// @notice Unpause oracle resolution for a single question.
    function unpauseQuestion(bytes32 questionId) external;

    // ────────────────────────────────────────────────────────────────────────
    //                         VIEWS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Returns the full QuestionData struct for a given questionId.
    function getQuestion(bytes32 questionId) external view returns (QuestionData memory);

    /// @notice Returns true if a question has been registered.
    function isInitialized(bytes32 questionId) external view returns (bool);

    /// @notice Returns true if a question has been flagged for manual resolution.
    function isFlagged(bytes32 questionId) external view returns (bool);

    /// @notice The ManagedOptimisticOracleV2 address used for all price requests.
    function optimisticOracle() external view returns (IOptimisticOracleV2);
}
