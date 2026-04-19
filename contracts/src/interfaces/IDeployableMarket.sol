// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IBlieverMarket} from "./IBlieverMarket.sol";

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
