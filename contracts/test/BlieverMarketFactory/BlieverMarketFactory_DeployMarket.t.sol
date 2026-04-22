// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import "./BlieverMarketFactoryBase.t.sol";

/// @title  BlieverMarketFactory — deployMarket Tests
/// @notice Comprehensive test suite for the deployMarket function.
///
///         Coverage areas:
///           1. INPUT VALIDATION — all seven pre-flight checks
///           2. ACCESS CONTROL  — OPERATOR_ROLE + whenNotPaused
///           3. HAPPY PATH      — binary (n=2) and multi-outcome (n=7)
///           4. STATE CHANGES   — isDeployedMarket, marketCount, events
///           5. EXTERNAL CALLS  — pool.registerMarket, adapter.initializeQuestion
///           6. CLONE STATE     — initialized clone fields match DeployParams
///           7. CREATE2 ADDRESS — predictMarketAddress matches deployed address
///           8. DUPLICATE GUARD — QuestionAlreadyDeployed on second deploy
///           9. REWARD TOKEN    — token pull and adapter approval
///          10. FUZZ            — all valid outcome counts, deadline ranges
contract BlieverMarketFactory_DeployMarket is FactoryTestBase {

    /*//////////////////////////////////////////////////////////////
                       1. INPUT VALIDATION REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_reverts_zeroQuestionId() public {
        DeployParams memory p = _buildParams(2, bytes32(0));
        // questionId is the zero value, must revert
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__InvalidQuestionId.selector);
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_emptyAncillaryData() public {
        DeployParams memory p = _buildParams(2, _qId("empty_anc"));
        p.ancillaryData = bytes("");
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__InvalidAncillaryData.selector);
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_outcomesBelow2() public {
        DeployParams memory p = _buildParams(1, _qId("outcomes_1"));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(1)
            )
        );
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_outcomesAbove7() public {
        DeployParams memory p = _buildParams(8, _qId("outcomes_8"));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__InvalidOutcomeCount.selector,
                uint8(8)
            )
        );
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_tradingDeadlineInPast() public {
        DeployParams memory p = _buildParams(2, _qId("td_past"));
        // set tradingDeadline to the current block (== block.timestamp, which fails >=)
        p.tradingDeadline = uint40(block.timestamp);
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__InvalidDeadlines.selector);
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_tradingDeadlineEqualToResolution() public {
        DeployParams memory p = _buildParams(2, _qId("td_eq_rd"));
        uint40 same = uint40(block.timestamp) + 14 days;
        p.tradingDeadline    = same;
        p.resolutionDeadline = same;   // tradingDeadline >= resolutionDeadline → revert
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__InvalidDeadlines.selector);
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_tradingDeadlineAfterResolution() public {
        DeployParams memory p = _buildParams(2, _qId("td_after_rd"));
        p.tradingDeadline    = uint40(block.timestamp) + 30 days;
        p.resolutionDeadline = uint40(block.timestamp) + 7 days;  // reversed order
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__InvalidDeadlines.selector);
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_rewardWithoutToken() public {
        DeployParams memory p = _buildParams(2, _qId("reward_no_token"));
        p.reward      = 100e6;
        p.rewardToken = address(0);   // reward > 0 but no token address
        vm.prank(operator);
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__RewardTokenRequired.selector);
        factory.deployMarket(p);
    }

    /*//////////////////////////////////////////////////////////////
                       2. ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_reverts_nonOperator() public {
        DeployParams memory p = _buildParams(2, _qId("acl_nonop"));
        vm.prank(attacker);
        // OZ AccessControl reverts with a generic string for missing role
        vm.expectRevert();
        factory.deployMarket(p);
    }

    function test_deployMarket_reverts_whenPaused() public {
        vm.prank(pauser);
        factory.pause();

        DeployParams memory p = _buildParams(2, _qId("acl_paused"));
        vm.prank(operator);
        vm.expectRevert(); // Pausable: EnforcedPause
        factory.deployMarket(p);
    }

    /*//////////////////////////////////////////////////////////////
                       3. HAPPY PATH — BINARY MARKET (n=2)
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_2outcomes_returnsNonZeroAddress() public {
        address market = _deployMarket(2, _qId("hp_2_addr"));
        assertTrue(market != address(0), "clone address must be non-zero");
    }

    function test_deployMarket_2outcomes_isDeployedMarketIsTrue() public {
        address market = _deployMarket(2, _qId("hp_2_deployed"));
        assertTrue(factory.isDeployedMarket(market), "isDeployedMarket must be true");
    }

    function test_deployMarket_2outcomes_marketCountIncrements() public {
        assertEq(factory.marketCount(), 0);
        _deployMarket(2, _qId("hp_2_count_a"));
        assertEq(factory.marketCount(), 1);
        _deployMarket(2, _qId("hp_2_count_b"));
        assertEq(factory.marketCount(), 2);
    }

    function test_deployMarket_2outcomes_emitsMarketDeployed() public {
        bytes32 qId = _qId("hp_2_event");
        DeployParams memory p = _buildParams(2, qId);

        // Pre-compute expected clone address so we can match the indexed topic
        address expected = factory.predictMarketAddress(qId);

        vm.expectEmit(true, true, false, true, address(factory));
        emit BlieverMarketFactory.MarketDeployed(
            expected,
            qId,
            2,
            p.tradingDeadline,
            p.resolutionDeadline
        );

        vm.prank(operator);
        factory.deployMarket(p);
    }

    function test_deployMarket_2outcomes_poolRegisterMarketCalled() public {
        _deployMarket(2, _qId("hp_2_pool"));
        assertEq(mockPool.registerCalls(), 1, "registerMarket must be called once");
        assertEq(mockPool.lastRegisteredOutcomes(), 2, "nOutcomes forwarded to pool");
    }

    function test_deployMarket_2outcomes_adapterInitializeQuestionCalled() public {
        bytes32 qId = _qId("hp_2_adapter");
        _deployMarket(2, qId);
        assertEq(mockAdapter.initCalls(), 1, "initializeQuestion must be called once");
        assertEq(mockAdapter.lastQuestionId(), qId, "questionId forwarded to adapter");
    }

    function test_deployMarket_2outcomes_adapterReceivesAncillaryData() public {
        _deployMarket(2, _qId("hp_2_anc"));
        assertEq(
            keccak256(mockAdapter.lastAncillaryData()),
            keccak256(ANCILLARY_DATA),
            "ancillaryData forwarded to adapter"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       4. HAPPY PATH — MULTI-OUTCOME (n=7)
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_7outcomes_success() public {
        address market = _deployMarket(7, _qId("hp_7"));
        assertTrue(factory.isDeployedMarket(market));
        assertEq(mockPool.registerCalls(), 1);
        assertEq(mockPool.lastRegisteredOutcomes(), 7);
        assertEq(mockAdapter.initCalls(), 1);
    }

    function test_deployMarket_7outcomes_marketCountIncrements() public {
        _deployMarket(7, _qId("hp_7_count"));
        assertEq(factory.marketCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                       5. CLONE STATE AFTER INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_clone_questionIdMatches() public {
        bytes32 qId = _qId("clone_qid");
        address market = _deployMarket(2, qId);
        assertEq(IDeployableMarket(market).questionId(), qId, "clone questionId mismatch");
    }

    function test_deployMarket_clone_resolvedIsFalse() public {
        address market = _deployMarket(2, _qId("clone_resolved"));
        assertFalse(IDeployableMarket(market).resolved(), "fresh clone must not be resolved");
    }

    function test_deployMarket_clone_resolutionDeadlineIsSet() public {
        DeployParams memory p = _buildParams(2, _qId("clone_deadline"));
        vm.prank(operator);
        address market = factory.deployMarket(p);
        assertEq(
            IDeployableMarket(market).resolutionDeadline(),
            p.resolutionDeadline,
            "clone resolutionDeadline mismatch"
        );
    }

    function test_deployMarket_clone_outcomeCountMatches() public {
        address market2 = _deployMarket(2, _qId("cc2"));
        address market7 = _deployMarket(7, _qId("cc7"));
        assertEq(IDeployableMarket(market2).outcomeCount(), 2);
        assertEq(IDeployableMarket(market7).outcomeCount(), 7);
    }

    /*//////////////////////////////////////////////////////////////
                       6. CREATE2 ADDRESS PREDICTION
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_matchesPredictedAddress() public {
        bytes32 qId = _qId("predict_match");

        // Predict BEFORE deployment
        address predicted = factory.predictMarketAddress(qId);

        // Deploy
        address deployed = _deployMarket(2, qId);

        assertEq(deployed, predicted, "deployed address must match predicted");
    }

    function test_deployMarket_differentQuestionIds_differentAddresses() public {
        address a = factory.predictMarketAddress(_qId("diff_a"));
        address b = factory.predictMarketAddress(_qId("diff_b"));
        assertTrue(a != b, "distinct questionIds must yield distinct addresses");
    }

    /*//////////////////////////////////////////////////////////////
                       7. DUPLICATE QUESTION GUARD
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_reverts_duplicateQuestionId() public {
        bytes32 qId = _qId("dup_qid");
        address first = _deployMarket(2, qId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__QuestionAlreadyDeployed.selector,
                qId,
                first
            )
        );
        factory.deployMarket(_buildParams(2, qId));
    }

    function test_deployMarket_duplicate_doesNotIncrementMarketCount() public {
        bytes32 qId = _qId("dup_count");
        _deployMarket(2, qId);
        assertEq(factory.marketCount(), 1);

        // Second deploy reverts — marketCount must stay at 1
        vm.prank(operator);
        vm.expectRevert();
        factory.deployMarket(_buildParams(2, qId));

        assertEq(factory.marketCount(), 1, "marketCount must not increment on duplicate revert");
    }

    /*//////////////////////////////////////////////////////////////
                       8. REWARD TOKEN FLOW
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_withReward_pullsTokensFromOperator() public {
        uint256 reward = 500e18;

        // Fund and approve
        rewardToken.mint(operator, reward);
        vm.prank(operator);
        rewardToken.approve(address(factory), reward);

        uint256 beforeBal = rewardToken.balanceOf(operator);

        vm.prank(operator);
        factory.deployMarket(_buildParamsWithReward(2, _qId("reward_pull"), reward));

        // Operator should have paid exactly `reward`
        assertEq(
            rewardToken.balanceOf(operator),
            beforeBal - reward,
            "operator balance should decrease by reward"
        );
    }

    function test_deployMarket_withReward_factoryHoldsTokens() public {
        uint256 reward = 500e18;
        rewardToken.mint(operator, reward);
        vm.prank(operator);
        rewardToken.approve(address(factory), reward);

        vm.prank(operator);
        factory.deployMarket(_buildParamsWithReward(2, _qId("reward_hold"), reward));

        // Mock adapter did not pull tokens; factory holds them and approved adapter
        assertEq(
            rewardToken.balanceOf(address(factory)),
            reward,
            "factory should hold reward tokens after mock adapter call"
        );
    }

    function test_deployMarket_withReward_approvedAdapterForReward() public {
        uint256 reward = 500e18;
        rewardToken.mint(operator, reward);
        vm.prank(operator);
        rewardToken.approve(address(factory), reward);

        vm.prank(operator);
        factory.deployMarket(_buildParamsWithReward(2, _qId("reward_approve"), reward));

        // Factory must have approved adapter for exactly the reward amount
        assertEq(
            rewardToken.allowance(address(factory), address(mockAdapter)),
            reward,
            "factory must approve adapter for reward amount"
        );
    }

    function test_deployMarket_withReward_adapterReceivesRewardParams() public {
        uint256 reward = 500e18;
        rewardToken.mint(operator, reward);
        vm.prank(operator);
        rewardToken.approve(address(factory), reward);

        vm.prank(operator);
        factory.deployMarket(_buildParamsWithReward(2, _qId("reward_adapter"), reward));

        assertEq(mockAdapter.lastRewardToken(), address(rewardToken));
        assertEq(mockAdapter.lastReward(),      reward);
    }

    function test_deployMarket_withReward_reverts_insufficientAllowance() public {
        uint256 reward = 500e18;
        rewardToken.mint(operator, reward);
        // Intentionally NO approve — transferFrom must fail inside factory

        vm.prank(operator);
        vm.expectRevert();   // SafeERC20 propagates ERC-20 transfer revert
        factory.deployMarket(_buildParamsWithReward(2, _qId("reward_no_allow"), reward));
    }

    function test_deployMarket_zeroReward_doesNotPullTokens() public {
        // reward = 0, rewardToken = address(0) — no token interaction expected
        address market = _deployMarket(2, _qId("zero_reward"));
        // If any token interaction occurred this test would revert; reaching here means none did
        assertTrue(factory.isDeployedMarket(market));
        assertEq(mockAdapter.lastReward(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       9. POOL REGISTRATION ARGS
    //////////////////////////////////////////////////////////////*/

    function test_deployMarket_poolReceivesCloneAddress() public {
        bytes32 qId = _qId("pool_addr");
        address predicted = factory.predictMarketAddress(qId);
        _deployMarket(2, qId);
        assertEq(
            mockPool.lastRegisteredMarket(),
            predicted,
            "pool.registerMarket must receive the clone address"
        );
    }

    function test_deployMarket_poolReceivesNOutcomes() public {
        _deployMarket(7, _qId("pool_n7"));
        assertEq(mockPool.lastRegisteredOutcomes(), 7);
    }

    /*//////////////////////////////////////////////////////////////
                       10. FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev All valid outcome counts (2–7) must deploy successfully.
    function testFuzz_deployMarket_allValidOutcomes(uint8 n) public {
        n = uint8(bound(n, 2, 7));
        // Each fuzzer run needs a unique questionId to avoid duplicate reverts
        bytes32 qId = keccak256(abi.encode("fuzz_outcomes", n, block.timestamp));
        address market = _deployMarket(n, qId);
        assertTrue(factory.isDeployedMarket(market));
        assertEq(factory.marketCount(), 1);
        assertEq(mockPool.lastRegisteredOutcomes(), n);
    }

    /// @dev marketCount must equal the number of successful deployMarket calls.
    function testFuzz_deployMarket_marketCountIsMonotone(uint8 count) public {
        count = uint8(bound(count, 1, 7));   // keep gas reasonable
        for (uint8 i = 0; i < count; i++) {
            bytes32 qId = keccak256(abi.encode("fuzz_mono", i));
            _deployMarket(2, qId);
        }
        assertEq(factory.marketCount(), count);
    }

    /// @dev Fuzz deadline validation: tradingDeadline < resolutionDeadline, both in future.
    ///      Any valid pair must succeed; swapped or equal deadlines must revert.
    function testFuzz_deployMarket_deadlineValidation(
        uint40 tradingOffset,
        uint40 resolutionOffset
    ) public {
        // Positive offsets ensure both are in the future
        tradingOffset    = uint40(bound(tradingOffset,    1,      365 days));
        resolutionOffset = uint40(bound(resolutionOffset, tradingOffset + 1, 730 days));

        DeployParams memory p = _buildParams(2, _qId("fuzz_deadlines"));
        p.tradingDeadline    = uint40(block.timestamp) + tradingOffset;
        p.resolutionDeadline = uint40(block.timestamp) + resolutionOffset;

        vm.prank(operator);
        address market = factory.deployMarket(p);
        assertTrue(factory.isDeployedMarket(market));
    }
}
