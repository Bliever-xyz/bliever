// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {LSMath} from "../../../src/LSMath.sol";

/// @title LSMathHarness
/// @notice Thin wrapper contract that exposes LSMath's internal pure functions
///         as external calls so Foundry tests can invoke them.
/// @dev    LSMath is a Solidity `library` with `internal pure` functions.
///         Foundry cannot call internal functions directly from test contracts.
///         This harness makes every function reachable via an external call,
///         enabling normal `vm.expectRevert`, return-value assertions, and fuzz testing.
///         No state, no logic — just pass-through delegation.
contract LSMathHarness {

    /*//////////////////////////////////////////////////////////////
                        CORE LS-LMSR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function liquidityParameter(
        uint256[] memory quantities,
        uint256 alpha
    ) external pure returns (uint256 b, uint256 sumQ) {
        return LSMath.liquidityParameter(quantities, alpha);
    }

    function costFunction(
        uint256[] memory quantities,
        uint256 alpha
    ) external pure returns (uint256 cost) {
        return LSMath.costFunction(quantities, alpha);
    }

    function getPrice(
        uint256[] memory quantities,
        uint256 outcomeIndex,
        uint256 alpha
    ) external pure returns (uint256 price) {
        return LSMath.getPrice(quantities, outcomeIndex, alpha);
    }

    function getAllPrices(
        uint256[] memory quantities,
        uint256 alpha
    ) external pure returns (uint256[] memory prices) {
        return LSMath.getAllPrices(quantities, alpha);
    }

    function calculateTradeCost(
        uint256[] memory quantitiesFrom,
        uint256[] memory quantitiesTo,
        uint256 alpha
    ) external pure returns (int256 tradeCost) {
        return LSMath.calculateTradeCost(quantitiesFrom, quantitiesTo, alpha);
    }

    function sumOfPrices(
        uint256[] memory quantities,
        uint256 alpha
    ) external pure returns (uint256 sum) {
        return LSMath.sumOfPrices(quantities, alpha);
    }

    /*//////////////////////////////////////////////////////////////
                        MATHEMATICAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function exp(uint256 x) external pure returns (uint256 result) {
        return LSMath.exp(x);
    }

    function ln(uint256 x) external pure returns (uint256 result) {
        return LSMath.ln(x);
    }

    function mulScale(uint256 a, uint256 bVal) external pure returns (uint256 result) {
        return LSMath.mulScale(a, bVal);
    }

    function divScale(uint256 a, uint256 bVal) external pure returns (uint256 result) {
        return LSMath.divScale(a, bVal);
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION & UTILITY
    //////////////////////////////////////////////////////////////*/

    function validateQuantities(
        uint256[] memory quantities
    ) external pure returns (bool valid) {
        return LSMath.validateQuantities(quantities);
    }

    function validateAlpha(uint256 alpha) external pure returns (bool valid) {
        return LSMath.validateAlpha(alpha);
    }

    function calculateWorstCaseLoss(
        uint256[] memory quantities,
        uint256[] memory initialQuantities,
        uint256 alpha
    ) external pure returns (uint256 worstCaseLoss) {
        return LSMath.calculateWorstCaseLoss(quantities, initialQuantities, alpha);
    }

    function hasOutcomeIndependentProfit(
        uint256[] memory quantities,
        uint256[] memory initialQuantities,
        uint256 alpha
    ) external pure returns (bool hasProfit, uint256 profit) {
        return LSMath.hasOutcomeIndependentProfit(quantities, initialQuantities, alpha);
    }
}
