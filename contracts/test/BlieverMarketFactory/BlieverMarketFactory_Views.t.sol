// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import "./BlieverMarketFactoryBase.t.sol";

/// @title  BlieverMarketFactory — View & Pure Function Tests
/// @notice Tests for computeEpsilon (public view) and predictMarketAddress (external view).
///
///         computeEpsilon
///           • Validates exact 18-dec values for each n ∈ [2,7] against the
///             closed-form formula: ε = R / (1 + α·n·ln n)
///           • Confirms the function reverts for n < 2 and n > 7
///           • Fuzz tests the valid range to assert ε > 0 and monotone-decreasing
///
///         predictMarketAddress
///           • Confirms the predicted address equals the actual deployed address
///           • Confirms two different questionIds yield distinct addresses
///           • Confirms the prediction is stable (same questionId → same result)
contract BlieverMarketFactory_Views is FactoryTestBase {

    /*//////////////////////////////////////////////////////////////
                   HELPERS — MANUAL EPSILON COMPUTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Reproduce _computeEpsilon in Solidity for cross-checking.
    ///      Formula: ε = (maxRisk * 1e12 * 1e18) / (1e18 + alpha * n * lnN / 1e18)
    function _manualEpsilon(
        uint8   n,
        uint256 alpha_,
        uint256 maxRisk
    ) internal pure returns (uint256) {
        uint256 MATH_SCALE   = 1e18;
        uint256 SHARE_TO_USDC = 1e12;

        uint256 R18 = maxRisk * SHARE_TO_USDC;
        uint256 lnN = _manualLn(n);
        uint256 denominator = MATH_SCALE + (alpha_ * uint256(n) * lnN) / MATH_SCALE;
        return (R18 * MATH_SCALE) / denominator;
    }

    function _manualLn(uint8 n) internal pure returns (uint256) {
        if (n == 2) return   693_147_180_559_945_309;
        if (n == 3) return 1_098_612_288_668_109_691;
        if (n == 4) return 1_386_294_361_119_890_619;
        if (n == 5) return 1_609_437_912_434_100_374;
        if (n == 6) return 1_791_759_469_228_327_070;
        return              1_945_910_149_009_313_492; // n == 7
    }

    /*//////////////////////////////////////////////////////////////
                   computeEpsilon — EXACT VALUE PER N
    //////////////////////////////////////////////////////////////*/

    function test_computeEpsilon_n2_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(2);
        uint256 expected = _manualEpsilon(2, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=2");

        // Sanity check: ε_2 should be approximately 480e18 (as documented in BlieverMarketBase)
        assertApproxEqRel(actual, 480e18, 5e15, "n=2 epsilon must be near 480e18");
    }

    function test_computeEpsilon_n3_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(3);
        uint256 expected = _manualEpsilon(3, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=3");
        assertGt(actual, 0, "epsilon must be non-zero");
    }

    function test_computeEpsilon_n4_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(4);
        uint256 expected = _manualEpsilon(4, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=4");
        assertGt(actual, 0);
    }

    function test_computeEpsilon_n5_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(5);
        uint256 expected = _manualEpsilon(5, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=5");
        assertGt(actual, 0);
    }

    function test_computeEpsilon_n6_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(6);
        uint256 expected = _manualEpsilon(6, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=6");
        assertGt(actual, 0);
    }

    function test_computeEpsilon_n7_exactValue() public view {
        uint256 actual   = factory.computeEpsilon(7);
        uint256 expected = _manualEpsilon(7, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "epsilon mismatch for n=7");

        // Sanity check: ε_7 should be approximately 355e18 (as documented in BlieverMarketBase)
        assertApproxEqRel(actual, 355e18, 5e15, "n=7 epsilon must be near 355e18");
    }

    /// @dev LS-LMSR property: ε is a decreasing function of n.
    ///      More outcomes → lower per-outcome seed (same total budget spread thinner).
    function test_computeEpsilon_strictlyDecreasingWithN() public view {
        uint256 prev = factory.computeEpsilon(2);
        for (uint8 n = 3; n <= 7; n++) {
            uint256 curr = factory.computeEpsilon(n);
            assertGt(prev, curr, "epsilon must decrease as n increases");
            prev = curr;
        }
    }

    /*//////////////////////////////////////////////////////////////
                   computeEpsilon — BOUNDS REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_computeEpsilon_reverts_n0() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(0)
            )
        );
        factory.computeEpsilon(0);
    }

    function test_computeEpsilon_reverts_n1() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(1)
            )
        );
        factory.computeEpsilon(1);
    }

    function test_computeEpsilon_reverts_n8() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(8)
            )
        );
        factory.computeEpsilon(8);
    }

    function test_computeEpsilon_reverts_maxUint8() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(255)
            )
        );
        factory.computeEpsilon(255);
    }

    /*//////////////////////////////////////////////////////////////
                   computeEpsilon — POOL PARAMETER SENSITIVITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Doubling maxRiskPerMarket must exactly double epsilon (linearity in R).
    function test_computeEpsilon_doublingMaxRisk_doublesEpsilon() public {
        uint256 eps1 = factory.computeEpsilon(2);

        // Double the pool's maxRiskPerMarket
        mockPool.setMaxRisk(MAX_RISK_USDC * 2);

        uint256 eps2 = factory.computeEpsilon(2);

        // ε = R/(...) is linear in R — doubling R must double ε (exact integer division)
        assertApproxEqAbs(eps2, eps1 * 2, 1, "epsilon must double when maxRisk doubles");
    }

    /// @dev Higher alpha means more market-maker spread → larger denominator → smaller ε.
    function test_computeEpsilon_higherAlpha_yieldsLowerEpsilon() public {
        uint256 eps_low  = factory.computeEpsilon(2);   // alpha = 3e16

        mockPool.setAlpha(6e16);   // double alpha
        uint256 eps_high = factory.computeEpsilon(2);

        assertGt(eps_low, eps_high, "higher alpha must yield lower epsilon");
    }

    /*//////////////////////////////////////////////////////////////
                   computeEpsilon — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For any n ∈ [2,7] the result must:
    ///   (a) be non-zero
    ///   (b) match the manually computed formula exactly
    function testFuzz_computeEpsilon_alwaysMatchesFormula(uint8 n) public view {
        n = uint8(bound(n, 2, 7));
        uint256 actual   = factory.computeEpsilon(n);
        uint256 expected = _manualEpsilon(n, ALPHA, MAX_RISK_USDC);
        assertEq(actual, expected, "fuzz: epsilon must match formula");
        assertGt(actual, 0, "fuzz: epsilon must be non-zero");
    }

    /// @dev Epsilon must always be strictly less than R (proof: denominator > 1).
    function testFuzz_computeEpsilon_alwaysLessThanR(uint8 n) public view {
        n = uint8(bound(n, 2, 7));
        uint256 R18 = MAX_RISK_USDC * 1e12;          // 500e18
        uint256 eps = factory.computeEpsilon(n);
        assertLt(eps, R18, "epsilon must be strictly less than R");
    }

    /*//////////////////////////////////////////////////////////////
                   predictMarketAddress
    //////////////////////////////////////////////////////////////*/

    function test_predictMarketAddress_matchesDeployedAddress() public {
        bytes32 qId = _qId("predict_exact");

        address predicted = factory.predictMarketAddress(qId);
        address deployed  = _deployMarket(2, qId);

        assertEq(deployed, predicted, "predicted address must match deployed");
    }

    function test_predictMarketAddress_deterministicForSameQuestionId() public view {
        bytes32 qId = _qId("predict_deterministic");

        address first  = factory.predictMarketAddress(qId);
        address second = factory.predictMarketAddress(qId);

        assertEq(first, second, "prediction must be deterministic");
    }

    function test_predictMarketAddress_differentForDifferentQuestionIds() public view {
        address a = factory.predictMarketAddress(_qId("predict_a"));
        address b = factory.predictMarketAddress(_qId("predict_b"));
        assertTrue(a != b, "distinct questionIds must yield distinct addresses");
    }

    function test_predictMarketAddress_noBytecodeBeforeDeployment() public view {
        bytes32 qId = _qId("predict_no_code");
        address predicted = factory.predictMarketAddress(qId);
        // Address should have no code before deployment
        assertEq(predicted.code.length, 0, "address must be empty before deployment");
    }

    function test_predictMarketAddress_hasBytecodeAfterDeployment() public {
        bytes32 qId = _qId("predict_has_code");
        address predicted = factory.predictMarketAddress(qId);

        _deployMarket(2, qId);

        // EIP-1167 minimal proxy has exactly 45 bytes of bytecode
        assertEq(predicted.code.length, 45, "EIP-1167 clone must be 45 bytes");
    }

    /*//////////////////////////////////////////////////////////////
                   predictMarketAddress — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The predicted address for any two distinct bytes32 values must differ.
    function testFuzz_predictMarketAddress_uniquePerQuestionId(
        bytes32 qId1,
        bytes32 qId2
    ) public view {
        vm.assume(qId1 != qId2);
        address a = factory.predictMarketAddress(qId1);
        address b = factory.predictMarketAddress(qId2);
        assertTrue(a != b, "distinct questionIds must predict distinct addresses");
    }
}
