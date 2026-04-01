// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title  IOptimisticRequester
/// @notice Callback interface that UMA's Optimistic Oracle V2 invokes on the requester contract.
///         BlieverUmaAdapter implements this to receive the priceDisputed notification.
///
///         The adapter enables only the `priceDisputed` callback via setCallbacks().
///         priceProposed and priceSettled are implemented as no-ops to satisfy the interface.
interface IOptimisticRequester {
    /// @notice Called by the OO when a price is proposed.
    ///         The adapter does NOT enable this callback — implemented as a no-op.
    function priceProposed(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData
    ) external;

    /// @notice Called by the OO immediately after a dispute is filed against a proposal.
    ///         The adapter DOES enable this callback.
    ///         On the first dispute the adapter resets the question (new OO request).
    ///         On the second dispute the question escalates to the DVM — adapter sets refund flag.
    /// @param identifier    The price identifier of the disputed request.
    /// @param timestamp     The request timestamp.
    /// @param ancillaryData The request ancillary data (keccak256 → questionId).
    /// @param refund        Amount refunded to the requester by the OO (implementation-defined).
    function priceDisputed(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData,
        uint256      refund
    ) external;

    /// @notice Called by the OO when a price is settled.
    ///         The adapter does NOT enable this callback — implemented as a no-op.
    function priceSettled(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData,
        int256       price
    ) external;
}
