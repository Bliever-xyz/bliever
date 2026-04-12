// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IBlieverMarket} from "../../src/interfaces/IBlieverMarket.sol";

/// @title  MockBlieverMarket
/// @notice Controllable stub implementing IBlieverMarket.
///         Used to isolate BlieverUmaAdapter from full BlieverMarket complexity.
///
///         Key controls:
///           • Set questionId, outcomeCount, resolutionDeadline at construction.
///           • resolveShouldRevert — makes resolve() revert to test failure paths.
///           • resolveCalls / lastWinner — spy counters for resolve() assertions.
contract MockBlieverMarket is IBlieverMarket {
    /*//////////////////////////////////////////////////////////////
                          CONFIGURABLE STATE
    //////////////////////////////////////////////////////////////*/

    bytes32 public questionId;
    uint8   public outcomeCount;
    bool    public resolved;
    uint40  public resolutionDeadline;

    /*//////////////////////////////////////////////////////////////
                          SPY STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public resolveCalls;
    uint8   public lastWinner;
    bool    public resolveShouldRevert;

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(bytes32 _questionId, uint8 _outcomeCount, uint40 _resolutionDeadline) {
        questionId         = _questionId;
        outcomeCount       = _outcomeCount;
        resolutionDeadline = _resolutionDeadline;
    }

    /*//////////////////////////////////////////////////////////////
                         TEST CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @dev Override the stored questionId (useful when computing full ancillary hash in tests).
    function setQuestionId(bytes32 qId) external {
        questionId = qId;
    }

    /// @dev Make resolve() revert for failure-path tests.
    function setShouldRevert(bool shouldRevert) external {
        resolveShouldRevert = shouldRevert;
    }

    /// @dev Reset spy counters between sub-tests.
    function resetCounters() external {
        resolveCalls = 0;
    }

    /*//////////////////////////////////////////////////////////////
                         IBlieverMarket
    //////////////////////////////////////////////////////////////*/

    function resolve(uint8 winningOutcome) external override {
        if (resolveShouldRevert) revert("MockMarket: resolve reverted");
        resolveCalls++;
        lastWinner = winningOutcome;
        resolved   = true;
    }
}
