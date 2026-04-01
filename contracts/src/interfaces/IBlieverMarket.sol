// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title  IBlieverMarket
/// @notice Minimal surface of BlieverMarket that the Resolution Adapter calls.
///
///         The adapter only needs to:
///           1. Read `questionId` and `outcomeCount` during question initialization.
///           2. Read `resolutionDeadline` for off-chain validation helpers.
///           3. Read `resolved` to guard duplicate resolution attempts.
///           4. Call `resolve(winningOutcome)` once the oracle has settled.
///
///         All internal ledger, trading, and vault logic remains in BlieverMarket.
///         The adapter never touches BlieverV1Pool directly — that is the market's concern.
interface IBlieverMarket {
    /// @notice The unique oracle question identifier bound at initialization.
    ///         Must equal `keccak256(ancillaryData)` passed to the adapter.
    function questionId() external view returns (bytes32);

    /// @notice Number of mutually exclusive outcomes [2, 7] for V1.
    function outcomeCount() external view returns (uint8);

    /// @notice True once the market has been successfully resolved or expired.
    function resolved() external view returns (bool);

    /// @notice Unix timestamp after which resolve() reverts and factory may expire.
    function resolutionDeadline() external view returns (uint40);

    /// @notice Record the winning outcome and settle the market with the vault.
    ///         Callable ONLY by the adapter (stored as `resolver` in BlieverMarket).
    ///         Reverts if already resolved or if resolutionDeadline has passed.
    /// @param winningOutcome  Index of the winning outcome [0, outcomeCount)
    function resolve(uint8 winningOutcome) external;
}
