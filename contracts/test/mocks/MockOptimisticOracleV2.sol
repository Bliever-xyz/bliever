// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV2} from "../../src/interfaces/IOptimisticOracleV2.sol";

/// @title  MockOptimisticOracleV2
/// @notice Controllable stub implementing IOptimisticOracleV2.
///         Used to drive BlieverUmaAdapter tests without a live UMA deployment.
///
///         Controllable state:
///           • defaultPrice     — returned by settleAndGetPrice()
///           • defaultHasPrice  — returned by hasPrice()
///           • requestShouldRevert — makes requestPrice() revert (tests reset-failure path)
///
///         Call counters:
///           • requestPriceCalls, settleAndGetPriceCalls, setBondCalls, setLivenessCalls
///           — used in spy assertions to verify the adapter drives the OO correctly.
contract MockOptimisticOracleV2 is IOptimisticOracleV2 {
    /*//////////////////////////////////////////////////////////////
                           CONTROLLABLE STATE
    //////////////////////////////////////////////////////////////*/

    int256  public defaultPrice;
    bool    public defaultHasPrice;
    bool    public requestShouldRevert;

    /*//////////////////////////////////////////////////////////////
                             CALL COUNTERS
    //////////////////////////////////////////////////////////////*/

    uint256 public requestPriceCalls;
    uint256 public settleAndGetPriceCalls;
    uint256 public setBondCalls;
    uint256 public setLivenessCalls;
    uint256 public setEventBasedCalls;
    uint256 public setCallbacksCalls;

    /*//////////////////////////////////////////////////////////////
                          LAST-CALL ARGS
    //////////////////////////////////////////////////////////////*/

    bytes32 public lastIdentifier;
    uint256 public lastTimestamp;
    uint256 public lastReward;

    /*//////////////////////////////////////////////////////////////
                          TEST CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @dev Set a settled price (implies hasPrice = true).
    function setPrice(int256 price) external {
        defaultPrice    = price;
        defaultHasPrice = true;
    }

    /// @dev Mark the price as unavailable (settleAndGetPrice will revert).
    function setPriceNotAvailable() external {
        defaultHasPrice = false;
    }

    /// @dev Make requestPrice revert — simulates OO unavailability for reset-failure tests.
    function setShouldRevert(bool shouldRevert) external {
        requestShouldRevert = shouldRevert;
    }

    /*//////////////////////////////////////////////////////////////
                        IOptimisticOracleV2
    //////////////////////////////////////////////////////////////*/

    function requestPrice(
        bytes32        identifier,
        uint256        timestamp,
        bytes memory   /*ancillaryData*/,
        IERC20         /*currency*/,
        uint256        reward
    ) external override returns (uint256 totalBond) {
        if (requestShouldRevert) revert("MockOO: requestPrice reverted");
        requestPriceCalls++;
        lastIdentifier = identifier;
        lastTimestamp  = timestamp;
        lastReward     = reward;
        return 0;
    }

    function setEventBased(
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/
    ) external override {
        setEventBasedCalls++;
    }

    function setCallbacks(
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/,
        bool         /*priceProposed*/,
        bool         /*priceDisputed*/,
        bool         /*priceSettled*/
    ) external override {
        setCallbacksCalls++;
    }

    function setBond(
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/,
        uint256      /*bond*/
    ) external override returns (uint256 totalBond) {
        setBondCalls++;
        return 0;
    }

    function setCustomLiveness(
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/,
        uint256      /*customLiveness*/
    ) external override {
        setLivenessCalls++;
    }

    function hasPrice(
        address      /*requester*/,
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/
    ) external view override returns (bool) {
        return defaultHasPrice;
    }

    function settleAndGetPrice(
        bytes32      /*identifier*/,
        uint256      /*timestamp*/,
        bytes memory /*ancillaryData*/
    ) external override returns (int256 price) {
        require(defaultHasPrice, "MockOO: price not available");
        settleAndGetPriceCalls++;
        return defaultPrice;
    }
}
