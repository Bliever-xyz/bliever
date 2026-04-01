// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IOptimisticOracleV2
/// @notice Minimal interface for the UMA Optimistic Oracle V2 (and ManagedOptimisticOracleV2).
///         Contains only the functions called by BlieverUmaAdapter.
///
///         Full specification: https://github.com/UMAprotocol/protocol/tree/master/packages/core
interface IOptimisticOracleV2 {

    // ── Request lifecycle ───────────────────────────────────────────────────

    /// @notice Submits a new price request.
    /// @param identifier    The price identifier (e.g. bytes32("MULTIPLE_VALUES")).
    /// @param timestamp     Timestamp associated with the request.
    /// @param ancillaryData Ancillary data supplying resolution context (JSON for MULTIPLE_VALUES).
    /// @param currency      ERC-20 reward token (must be whitelisted in DVM).
    /// @param reward        Reward paid to a successful proposer. Pulled from caller if > 0.
    /// @return totalBond    Default bond amount (final fee × 2) proposers must post.
    function requestPrice(
        bytes32        identifier,
        uint256        timestamp,
        bytes memory   ancillaryData,
        IERC20         currency,
        uint256        reward
    ) external returns (uint256 totalBond);

    /// @notice Marks a request as event-based, allowing proposals before block.timestamp.
    ///         Proposals submitted before the event's timestamp resolve as type(int256).min.
    function setEventBased(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData
    ) external;

    /// @notice Configures which lifecycle callbacks to invoke on the requester contract.
    /// @param callbackOnPriceProposed  If true, calls requester.priceProposed() after proposal.
    /// @param callbackOnPriceDisputed  If true, calls requester.priceDisputed() after dispute.
    /// @param callbackOnPriceSettled   If true, calls requester.priceSettled() after settlement.
    function setCallbacks(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData,
        bool         callbackOnPriceProposed,
        bool         callbackOnPriceDisputed,
        bool         callbackOnPriceSettled
    ) external;

    /// @notice Overrides the default proposal bond for a specific request.
    /// @return totalBond  New total bond amount.
    function setBond(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData,
        uint256      bond
    ) external returns (uint256 totalBond);

    /// @notice Overrides the default liveness (challenge window) for a specific request.
    /// @param customLiveness  Challenge window in seconds (must be ≥ ManagedOO minimumLiveness).
    function setCustomLiveness(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData,
        uint256      customLiveness
    ) external;

    // ── Query and settlement ────────────────────────────────────────────────

    /// @notice Returns true once a valid price has been proposed and the liveness period has
    ///         elapsed without a dispute, OR after DVM resolution is complete.
    /// @param requester     Address that originally called requestPrice.
    /// @param identifier    The price identifier.
    /// @param timestamp     Request timestamp.
    /// @param ancillaryData Request ancillary data.
    function hasPrice(
        address      requester,
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData
    ) external view returns (bool);

    /// @notice Settles the request (pays out bonds) and returns the resolved price.
    ///         Reverts if the price is not yet available.
    /// @return price  The settled int256 price (MULTIPLE_VALUES encoded for our use case).
    function settleAndGetPrice(
        bytes32      identifier,
        uint256      timestamp,
        bytes memory ancillaryData
    ) external returns (int256 price);
}
