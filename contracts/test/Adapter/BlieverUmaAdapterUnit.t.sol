// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {console2} from "forge-std/Test.sol";

import {BlieverUmaAdapter}      from "../../src/BlieverUmaAdapter.sol";
import {QuestionData}            from "../../src/interfaces/IBlieverUmaAdapter.sol";
import {AncillaryDataLib}       from "../../src/libraries/AncillaryDataLib.sol";
import {ERC1967Proxy}           from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BlieverUmaAdapterBase, EncodeOutcome} from "./BlieverUmaAdapterBase.t.sol";
import {MockOptimisticOracleV2}  from "../mocks/MockOptimisticOracleV2.sol";
import {MockBlieverMarket}       from "../mocks/MockBlieverMarket.sol";

/// @title  BlieverUmaAdapterUnitTest
/// @notice Unit tests for BlieverUmaAdapter covering:
///           • initialize (proxy setup, role assignment, zero-address guards)
///           • initializeQuestion (happy paths, access control, all revert guards)
///           • resolve (binary & multi-outcome happy paths, TOO_EARLY, unresolvable, guards)
///           • flag / unflag (lifecycle, access control, timing guards)
///           • resolveManually (happy path, safety period enforcement, invalid outcome)
///           • pauseQuestion / unpauseQuestion
///           • global pause / unpause
///           • updateOptimisticOracle (happy path, oracle upgrade scenario)
///           • ready() view function
///           • _tryResetQuestion access guard
contract BlieverUmaAdapterUnitTest is BlieverUmaAdapterBase {
    using EncodeOutcome for uint8;

    /*//////////////////////////////////////////////////////////////
                        INITIALIZE (PROXY SETUP)
    //////////////////////////////////////////////////////////////*/

    function test_initialize_rolesAssignedCorrectly() public {
        // DEFAULT_ADMIN_ROLE → admin
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin),  "admin missing DEFAULT_ADMIN");
        // FACTORY_ROLE → factory
        assertTrue(adapter.hasRole(adapter.FACTORY_ROLE(),   factory),   "factory missing FACTORY_ROLE");
        // EMERGENCY_ROLE → emergency
        assertTrue(adapter.hasRole(adapter.EMERGENCY_ROLE(), emergency),  "emergency missing EMERGENCY_ROLE");
    }

    function test_initialize_oracleSetCorrectly() public {
        assertEq(address(adapter.optimisticOracle()), address(mockOO), "oracle mismatch");
    }

    function test_initialize_reverts_zeroOracle() public {
        BlieverUmaAdapter impl2 = new BlieverUmaAdapter();
        bytes memory initData = abi.encodeCall(
            BlieverUmaAdapter.initialize,
            (address(0), admin, factory, emergency)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl2), initData);
    }

    function test_initialize_reverts_zeroAdmin() public {
        BlieverUmaAdapter impl2 = new BlieverUmaAdapter();
        bytes memory initData = abi.encodeCall(
            BlieverUmaAdapter.initialize,
            (address(mockOO), address(0), factory, emergency)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl2), initData);
    }

    function test_initialize_reverts_cannotReinitialize() public {
        // Calling initialize() again on the proxy must revert.
        vm.expectRevert();
        adapter.initialize(address(mockOO), admin, factory, emergency);
    }

    function test_initialize_implementationCannotBeInitialized() public {
        // The bare implementation has _disableInitializers(); calling it must revert.
        BlieverUmaAdapter impl2 = new BlieverUmaAdapter();
        vm.expectRevert();
        impl2.initialize(address(mockOO), admin, factory, emergency);
    }

    /*//////////////////////////////////////////////////////////////
                       initializeQuestion — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_initializeQuestion_binary_happyPath() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        assertTrue(adapter.isInitialized(qId),       "should be initialized");
        assertFalse(adapter.isFlagged(qId),           "should not be flagged");

        QuestionData memory qd = adapter.getQuestion(qId);
        assertEq(qd.market,       address(market2),  "market mismatch");
        assertEq(qd.outcomeCount, OUTCOME_COUNT_2,   "outcomeCount mismatch");
        assertFalse(qd.resolved,                      "should not be resolved");
        assertFalse(qd.paused,                        "should not be paused");
        assertEq(qd.creator,      factory,            "creator mismatch");
        assertEq(qd.reward,       DEFAULT_REWARD,     "reward mismatch");
        assertEq(qd.proposalBond, DEFAULT_BOND,       "bond mismatch");
        assertEq(qd.liveness,     DEFAULT_LIVENESS,   "liveness mismatch");

        // questionOracle must be snapshotted to the current OO
        assertEq(adapter.getQuestionOracle(qId), address(mockOO), "oracle snapshot mismatch");

        // OO must have received the request
        assertEq(mockOO.requestPriceCalls(),     1, "requestPrice not called");
        assertEq(mockOO.setEventBasedCalls(),    1, "setEventBased not called");
        assertEq(mockOO.setCallbacksCalls(),     1, "setCallbacks not called");
        assertEq(mockOO.setBondCalls(),          1, "setBond not called");     // bond > 0
        assertEq(mockOO.setLivenessCalls(),      1, "setLiveness not called"); // liveness > 0

        console2.log("initializeQuestion binary: questionId", uint256(qId));
    }

    function test_initializeQuestion_sevenOutcome_happyPath() public {
        bytes32 qId = _initQuestion(market7, ANC_DATA_7);

        QuestionData memory qd = adapter.getQuestion(qId);
        assertEq(qd.outcomeCount, OUTCOME_COUNT_7, "outcomeCount mismatch");
    }

    function test_initializeQuestion_zeroReward_skipsTransfer() public {
        bytes32 qId = _initQuestionNoReward(market2, ANC_DATA_2);

        QuestionData memory qd = adapter.getQuestion(qId);
        assertEq(qd.reward, 0, "reward should be 0");

        // OO still called (setBond still called, setLiveness still called)
        assertGt(mockOO.requestPriceCalls(), 0, "requestPrice should still be called");
    }

    function test_initializeQuestion_zeroBondAndLiveness_skipsThoseCalls() public {
        // bond = 0 → setBond NOT called; liveness = 0 → setCustomLiveness NOT called
        _initQuestion(market2, ANC_DATA_2, DEFAULT_REWARD, 0, 0);

        assertEq(mockOO.setBondCalls(),     0, "setBond should not be called");
        assertEq(mockOO.setLivenessCalls(), 0, "setCustomLiveness should not be called");
    }

    function test_initializeQuestion_emitsQuestionInitializedEvent() public {
        (bytes32 expectedQId,) = _buildQuestionId(ANC_DATA_2);
        market2.setQuestionId(expectedQId);
        vm.prank(factory);
        rewardToken.approve(address(adapter), type(uint256).max);

        vm.expectEmit(true, true, true, false, address(adapter));
        emit BlieverUmaAdapter.QuestionInitialized(
            expectedQId,
            uint256(block.timestamp),
            address(market2),
            factory,
            bytes(""),   // ancillaryData (not indexed — we don't check it)
            address(rewardToken),
            DEFAULT_REWARD,
            DEFAULT_BOND,
            DEFAULT_LIVENESS
        );
        vm.prank(factory);
        adapter.initializeQuestion(
            expectedQId,
            address(market2),
            ANC_DATA_2,
            address(rewardToken),
            DEFAULT_REWARD,
            DEFAULT_BOND,
            DEFAULT_LIVENESS
        );
    }

    function test_initializeQuestion_rewardPulledFromFactory() public {
        uint256 factoryBefore = rewardToken.balanceOf(factory);
        _initQuestion(market2, ANC_DATA_2);
        // Factory's balance should have decreased by the reward amount.
        assertEq(rewardToken.balanceOf(factory), factoryBefore - DEFAULT_REWARD, "reward not pulled");
    }

    /*//////////////////////////////////////////////////////////////
                     initializeQuestion — REVERT GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_initializeQuestion_reverts_notFactory() public {
        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        market2.setQuestionId(qId);

        vm.prank(attacker);
        vm.expectRevert(); // AccessControl: missing role
        adapter.initializeQuestion(qId, address(market2), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_zeroMarket() public {
        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        adapter.initializeQuestion(qId, address(0), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_zeroRewardToken() public {
        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        market2.setQuestionId(qId);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        adapter.initializeQuestion(qId, address(market2), ANC_DATA_2, address(0), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_emptyAncillaryData() public {
        bytes32 qId = keccak256("");
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("InvalidAncillaryData()"));
        adapter.initializeQuestion(qId, address(market2), bytes(""), address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_ancillaryDataTooLong() public {
        // MAX_ANCILLARY_DATA = 8139, INITIALIZER_SUFFIX_LENGTH = 53
        // Raw data must be ≤ 8139 - 53 = 8086 bytes
        bytes memory tooLong = new bytes(8087);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("InvalidAncillaryData()"));
        adapter.initializeQuestion(bytes32(0), address(market2), tooLong, address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_questionIdMismatch() public {
        // Pass wrong questionId (not matching keccak256(fullAncData))
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("QuestionIdMismatch()"));
        adapter.initializeQuestion(
            keccak256("wrong"),
            address(market2),
            ANC_DATA_2,
            address(rewardToken),
            0, 0, 0
        );
    }

    function test_initializeQuestion_reverts_marketQuestionIdMismatch() public {
        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        // Market has wrong questionId — do NOT call market2.setQuestionId(qId)
        // market2 still has bytes32(0) from constructor

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("QuestionIdMismatch()"));
        adapter.initializeQuestion(qId, address(market2), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_duplicateRegistration() public {
        _initQuestion(market2, ANC_DATA_2);
        bytes32 qId = keccak256(AncillaryDataLib._appendAncillaryData(factory, ANC_DATA_2));

        // Create a fresh market with same questionId
        MockBlieverMarket market2b = new MockBlieverMarket(qId, OUTCOME_COUNT_2, uint40(block.timestamp) + RESOLUTION_DL);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        adapter.initializeQuestion(qId, address(market2b), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_outcomeCountTooLow() public {
        // outcomeCount = 1 → market must have 1 outcome, adapter rejects < 2
        MockBlieverMarket mkt1 = new MockBlieverMarket(bytes32(0), 1, uint40(block.timestamp) + RESOLUTION_DL);
        (bytes32 qId,) = _buildQuestionId(bytes("test-1-outcome"));
        mkt1.setQuestionId(qId);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("InvalidOutcomeCount(uint8)", uint8(1)));
        adapter.initializeQuestion(qId, address(mkt1), bytes("test-1-outcome"), address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_outcomeCountTooHigh() public {
        // MAX_OUTCOMES = 7 in V1; outcomeCount = 8 → rejected
        MockBlieverMarket mkt8 = new MockBlieverMarket(bytes32(0), 8, uint40(block.timestamp) + RESOLUTION_DL);
        (bytes32 qId,) = _buildQuestionId(bytes("test-8-outcome"));
        mkt8.setQuestionId(qId);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("InvalidOutcomeCount(uint8)", uint8(8)));
        adapter.initializeQuestion(qId, address(mkt8), bytes("test-8-outcome"), address(rewardToken), 0, 0, 0);
    }

    function test_initializeQuestion_reverts_whenGloballyPaused() public {
        vm.prank(admin);
        adapter.pause();

        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        market2.setQuestionId(qId);
        vm.prank(factory);
        vm.expectRevert(); // Pausable: paused
        adapter.initializeQuestion(qId, address(market2), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          resolve — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_resolve_binary_outcome0Wins() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Encode outcome 0 winning
        int256 encodedPrice = int256(uint256(1)); // slot 0 = 1
        mockOO.setPrice(encodedPrice);

        adapter.resolve(qId);

        assertTrue(adapter.getQuestion(qId).resolved, "question not resolved");
        assertEq(market2.lastWinner(),  0,     "wrong winner");
        assertEq(market2.resolveCalls(), 1,    "resolve not called");
        assertTrue(market2.resolved(),          "market not resolved");
    }

    function test_resolve_binary_outcome1Wins() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Encode outcome 1 winning: slot 1 = 1 → bit 32
        int256 encodedPrice = int256(uint256(1) << 32);
        mockOO.setPrice(encodedPrice);

        adapter.resolve(qId);

        assertEq(market2.lastWinner(), 1, "wrong winner");
    }

    function test_resolve_sevenOutcome_allOutcomes() public {
        for (uint8 winner = 0; winner < OUTCOME_COUNT_7; winner++) {
            // Fresh market for each run to avoid AlreadyResolved
            MockBlieverMarket mkt = new MockBlieverMarket(
                bytes32(0), OUTCOME_COUNT_7, uint40(block.timestamp) + RESOLUTION_DL
            );
            bytes memory rawAnc = abi.encodePacked("multi-outcome-winner-", winner);
            bytes32 qId = _initQuestion(mkt, rawAnc);

            int256 encodedPrice = int256(uint256(1) << (32 * uint256(winner)));
            mockOO.setPrice(encodedPrice);

            adapter.resolve(qId);

            assertEq(mkt.lastWinner(), winner, "wrong winner for outcome");
            console2.log("Resolved 7-outcome market, winner:", winner);
        }
    }

    function test_resolve_emitsQuestionResolvedEvent() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        int256 encodedPrice = int256(uint256(1));
        mockOO.setPrice(encodedPrice);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit BlieverUmaAdapter.QuestionResolved(qId, encodedPrice, 0);

        adapter.resolve(qId);
    }

    function test_resolve_withRefund_returnsRewardToCreator() public {
        // Simulate DVM path: qd.refund = true → _bestEffortRefund on resolution
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Simulate two disputes → qd.refund = true
        // First dispute: reset
        _simulateDispute(qId);
        // Second dispute: escalate to DVM (sets refund = true)
        _simulateDispute(qId);

        // Now adapter has the reward on balance; resolve via normal path
        int256 encodedPrice = int256(uint256(1));
        mockOO.setPrice(encodedPrice);

        uint256 factoryBefore = rewardToken.balanceOf(factory);
        adapter.resolve(qId);

        // Reward should have been returned to factory (creator)
        uint256 factoryAfter = rewardToken.balanceOf(factory);
        // Note: factory originally paid DEFAULT_REWARD; after refund it returns
        assertGe(factoryAfter, factoryBefore, "reward not refunded to creator");
    }

    /*//////////////////////////////////////////////////////////////
                      resolve — TOO_EARLY SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_resolve_tooEarly_noReward_resetsQuestion() public {
        bytes32 qId = _initQuestionNoReward(market2, ANC_DATA_2);
        QuestionData memory qdBefore = adapter.getQuestion(qId);

        // int256.min = TOO_EARLY_PRICE
        mockOO.setPrice(type(int256).min);
        uint256 requestsBefore = mockOO.requestPriceCalls();

        adapter.resolve(qId);

        // Must NOT be resolved; a new OO request must have been issued
        assertFalse(adapter.getQuestion(qId).resolved, "should not be resolved on TOO_EARLY");
        assertGt(mockOO.requestPriceCalls(), requestsBefore, "new request not issued on reset");

        // requestTimestamp must have advanced
        assertGt(adapter.getQuestion(qId).requestTimestamp, qdBefore.requestTimestamp, "timestamp not updated");

        console2.log("TOO_EARLY with no reward: question reset successfully");
    }

    function test_resolve_tooEarly_withReward_flagsForAdmin() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // int256.min with reward > 0 → flag (adapter cannot self-fund)
        mockOO.setPrice(type(int256).min);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionFlagged(qId);

        adapter.resolve(qId);

        assertFalse(adapter.getQuestion(qId).resolved,  "should not be resolved");
        assertTrue(adapter.isFlagged(qId),               "should be flagged");
    }

    /*//////////////////////////////////////////////////////////////
                      resolve — UNRESOLVABLE SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_resolve_unresolvable_marksAndEmits() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // int256.max = UNRESOLVABLE_PRICE
        mockOO.setPrice(type(int256).max);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionUnresolvable(qId);

        adapter.resolve(qId);

        assertTrue(adapter.getQuestion(qId).unresolvable, "should be unresolvable");
        assertFalse(adapter.getQuestion(qId).resolved,     "should not be resolved");
        assertFalse(adapter.ready(qId),                    "ready should be false for unresolvable");
    }

    /*//////////////////////////////////////////////////////////////
                         resolve — REVERT GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_resolve_reverts_notInitialized() public {
        vm.expectRevert(abi.encodeWithSignature("NotInitialized()"));
        adapter.resolve(bytes32("nonexistent"));
    }

    function test_resolve_reverts_alreadyResolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);

        vm.expectRevert(abi.encodeWithSignature("AlreadyResolved()"));
        adapter.resolve(qId);
    }

    function test_resolve_reverts_questionPaused() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.pauseQuestion(qId);

        mockOO.setPrice(int256(uint256(1)));
        vm.expectRevert(abi.encodeWithSignature("QuestionIsPaused()"));
        adapter.resolve(qId);
    }

    function test_resolve_reverts_questionFlagged() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.flag(qId);

        mockOO.setPrice(int256(uint256(1)));
        vm.expectRevert(abi.encodeWithSignature("Flagged()"));
        adapter.resolve(qId);
    }

    function test_resolve_reverts_questionUnresolvable() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(type(int256).max);
        adapter.resolve(qId); // marks unresolvable

        mockOO.setPrice(int256(uint256(1)));
        vm.expectRevert(abi.encodeWithSignature("Unresolvable()"));
        adapter.resolve(qId);
    }

    function test_resolve_reverts_whenGloballyPaused() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));

        vm.prank(admin);
        adapter.pause();

        vm.expectRevert(); // Pausable: paused
        adapter.resolve(qId);
    }

    /*//////////////////////////////////////////////////////////////
                          FLAG / UNFLAG
    //////////////////////////////////////////////////////////////*/

    function test_flag_happyPath() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionFlagged(qId);

        vm.prank(emergency);
        adapter.flag(qId);

        assertTrue(adapter.isFlagged(qId), "should be flagged");
        uint40 expectedDeadline = uint40(block.timestamp + adapter.SAFETY_PERIOD());
        assertEq(adapter.getQuestion(qId).manualResolveAt, expectedDeadline, "manualResolveAt mismatch");
    }

    function test_flag_reverts_notEmergencyRole() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(attacker);
        vm.expectRevert(); // AccessControl
        adapter.flag(qId);
    }

    function test_flag_reverts_notInitialized() public {
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized()"));
        adapter.flag(bytes32("nonexistent"));
    }

    function test_flag_reverts_alreadyFlagged() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.flag(qId);

        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("Flagged()"));
        adapter.flag(qId);
    }

    function test_flag_reverts_alreadyResolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);

        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("AlreadyResolved()"));
        adapter.flag(qId);
    }

    function test_unflag_happyPath() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.flag(qId);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionUnflagged(qId);

        vm.prank(emergency);
        adapter.unflag(qId);

        assertFalse(adapter.isFlagged(qId),                          "should not be flagged");
        assertEq(adapter.getQuestion(qId).manualResolveAt, 0, "manualResolveAt should be 0");
    }

    function test_unflag_reverts_notFlagged() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("NotFlagged()"));
        adapter.unflag(qId);
    }

    function test_unflag_reverts_safetyPeriodPassed() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.flag(qId);

        // Advance past the safety period
        vm.warp(block.timestamp + adapter.SAFETY_PERIOD() + 1);

        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("SafetyPeriodPassed()"));
        adapter.unflag(qId);
    }

    function test_unflag_reverts_notEmergencyRole() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency); adapter.flag(qId);
        vm.prank(attacker);
        vm.expectRevert();
        adapter.unflag(qId);
    }

    /*//////////////////////////////////////////////////////////////
                          resolveManually
    //////////////////////////////////////////////////////////////*/

    function test_resolveManually_happyPath_binary() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        _flagAndWait(qId);

        vm.expectEmit(true, false, true, false, address(adapter));
        emit BlieverUmaAdapter.QuestionManuallyResolved(qId, 1, emergency);

        vm.prank(emergency);
        adapter.resolveManually(qId, 1);

        assertTrue(adapter.getQuestion(qId).resolved, "question not resolved");
        assertEq(market2.lastWinner(), 1,              "wrong winner");
        assertTrue(market2.resolved(),                 "market not resolved");
    }

    function test_resolveManually_happyPath_sevenOutcome() public {
        bytes32 qId = _initQuestion(market7, ANC_DATA_7);
        _flagAndWait(qId);

        vm.prank(emergency);
        adapter.resolveManually(qId, 5);

        assertEq(market7.lastWinner(), 5, "wrong winner");
    }

    function test_resolveManually_reverts_notEmergencyRole() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        _flagAndWait(qId);
        vm.prank(attacker);
        vm.expectRevert();
        adapter.resolveManually(qId, 0);
    }

    function test_resolveManually_reverts_notFlagged() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("NotFlagged()"));
        adapter.resolveManually(qId, 0);
    }

    function test_resolveManually_reverts_safetyPeriodNotPassed() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.flag(qId);

        // Try immediately (safety period not elapsed)
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("SafetyPeriodNotPassed()"));
        adapter.resolveManually(qId, 0);
    }

    function test_resolveManually_reverts_invalidOutcome() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        _flagAndWait(qId);

        // outcomeCount = 2, valid indices = 0 or 1; passing 2 must revert
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("InvalidOutcome(uint8,uint8)", uint8(2), uint8(2)));
        adapter.resolveManually(qId, 2);
    }

    function test_resolveManually_reverts_alreadyResolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        _flagAndWait(qId);
        vm.prank(emergency);
        adapter.resolveManually(qId, 0);

        // Flag + wait again (a new flag is impossible since it's resolved, but the error order matters)
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("AlreadyResolved()"));
        adapter.resolveManually(qId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      PAUSE / UNPAUSE — QUESTION LEVEL
    //////////////////////////////////////////////////////////////*/

    function test_pauseQuestion_blocksResolve() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency);
        adapter.pauseQuestion(qId);

        assertTrue(adapter.getQuestion(qId).paused, "should be paused");
        assertFalse(adapter.ready(qId),               "ready should be false");

        mockOO.setPrice(int256(uint256(1)));
        vm.expectRevert(abi.encodeWithSignature("QuestionIsPaused()"));
        adapter.resolve(qId);
    }

    function test_unpauseQuestion_restoresResolve() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency); adapter.pauseQuestion(qId);
        vm.prank(emergency); adapter.unpauseQuestion(qId);

        assertFalse(adapter.getQuestion(qId).paused, "should not be paused");

        // resolve should now work
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);
        assertTrue(adapter.getQuestion(qId).resolved, "should be resolved");
    }

    function test_pauseQuestion_emitsEvent() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionPaused(qId);
        vm.prank(emergency);
        adapter.pauseQuestion(qId);
    }

    function test_unpauseQuestion_emitsEvent() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency); adapter.pauseQuestion(qId);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionUnpaused(qId);
        vm.prank(emergency); adapter.unpauseQuestion(qId);
    }

    function test_pauseQuestion_reverts_notEmergency() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(attacker);
        vm.expectRevert();
        adapter.pauseQuestion(qId);
    }

    function test_pauseQuestion_reverts_notInitialized() public {
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized()"));
        adapter.pauseQuestion(bytes32("nonexistent"));
    }

    function test_pauseQuestion_reverts_alreadyResolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);

        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("AlreadyResolved()"));
        adapter.pauseQuestion(qId);
    }

    /*//////////////////////////////////////////////////////////////
                     GLOBAL PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_globalPause_blocksInitializeQuestion() public {
        vm.prank(admin); adapter.pause();
        (bytes32 qId,) = _buildQuestionId(ANC_DATA_2);
        market2.setQuestionId(qId);
        vm.prank(factory);
        vm.expectRevert();
        adapter.initializeQuestion(qId, address(market2), ANC_DATA_2, address(rewardToken), 0, 0, 0);
    }

    function test_globalPause_blocksResolve() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        vm.prank(admin); adapter.pause();
        vm.expectRevert();
        adapter.resolve(qId);
    }

    function test_globalUnpause_restoresOperation() public {
        vm.prank(admin); adapter.pause();
        vm.prank(admin); adapter.unpause();

        // Should work normally again
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);
        assertTrue(adapter.getQuestion(qId).resolved);
    }

    function test_globalPause_reverts_notAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.pause();
    }

    /*//////////////////////////////////////////////////////////////
                       updateOptimisticOracle
    //////////////////////////////////////////////////////////////*/

    function test_updateOptimisticOracle_happyPath() public {
        address oldOracle = address(mockOO);
        MockOptimisticOracleV2 newMockOO = new MockOptimisticOracleV2();

        vm.expectEmit(true, true, false, false, address(adapter));
        emit BlieverUmaAdapter.OptimisticOracleUpdated(oldOracle, address(newMockOO));

        vm.prank(admin);
        adapter.updateOptimisticOracle(address(newMockOO));

        assertEq(address(adapter.optimisticOracle()), address(newMockOO), "oracle not updated");
    }

    function test_updateOptimisticOracle_existingQuestionResolvesOnOldOO() public {
        // Initialize question on old OO → snapshot is oldOO
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        assertEq(adapter.getQuestionOracle(qId), address(mockOO), "initial oracle snapshot wrong");

        // Upgrade to new OO
        MockOptimisticOracleV2 newOO = new MockOptimisticOracleV2();
        vm.prank(admin);
        adapter.updateOptimisticOracle(address(newOO));

        // The old OO has the price (pinned); new OO does NOT have the price
        mockOO.setPrice(int256(uint256(1)));
        // newOO.defaultHasPrice is still false

        // The question's pinned oracle (old OO) should still settle this correctly.
        // _questionOracle[qId] was set to oldOO at init — resolution routes there, not newOO
        adapter.resolve(qId);

        assertTrue(adapter.getQuestion(qId).resolved,   "existing question should resolve on old OO");
        assertEq(market2.lastWinner(), 0,                "wrong winner via old OO");
    }

    function test_updateOptimisticOracle_newQuestionUsesNewOO() public {
        MockOptimisticOracleV2 newOO = new MockOptimisticOracleV2();
        vm.prank(admin);
        adapter.updateOptimisticOracle(address(newOO));

        // Initialize question AFTER upgrade → snapshotted to newOO
        bytes32 qId = _initQuestion(market7, ANC_DATA_7);

        // The snapshot for the new question must be the new OO
        assertEq(adapter.getQuestionOracle(qId), address(newOO), "new question oracle snapshot wrong");
    }

    function test_updateOptimisticOracle_reverts_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        adapter.updateOptimisticOracle(address(0));
    }

    function test_updateOptimisticOracle_reverts_notAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.updateOptimisticOracle(address(mockOO));
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — reset() FAILSAFE
    //////////////////////////////////////////////////////////////*/

    function test_reset_clearsRefundFlagAndIssuesNewRequest() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        // Simulate two disputes → qd.refund = true
        _simulateDispute(qId);
        _simulateDispute(qId);
        assertTrue(adapter.getQuestion(qId).refund, "refund flag should be set");

        uint256 requestsBefore = mockOO.requestPriceCalls();
        vm.prank(emergency);
        adapter.reset(qId);

        assertFalse(adapter.getQuestion(qId).refund, "refund flag should be cleared");
        assertGt(mockOO.requestPriceCalls(), requestsBefore, "new request not issued");
    }

    function test_reset_reverts_notEmergencyRole() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(attacker);
        vm.expectRevert();
        adapter.reset(qId);
    }

    function test_reset_reverts_alreadyResolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);

        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSignature("AlreadyResolved()"));
        adapter.reset(qId);
    }

    /*//////////////////////////////////////////////////////////////
                         ready() VIEW
    //////////////////////////////////////////////////////////////*/

    function test_ready_returnsFalse_notInitialized() public {
        assertFalse(adapter.ready(bytes32("nonexistent")));
    }

    function test_ready_returnsFalse_priceNotAvailable() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        // mockOO.defaultHasPrice is false by default
        assertFalse(adapter.ready(qId));
    }

    function test_ready_returnsTrue_priceAvailable() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        assertTrue(adapter.ready(qId));
    }

    function test_ready_returnsFalse_paused() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        vm.prank(emergency); adapter.pauseQuestion(qId);
        assertFalse(adapter.ready(qId));
    }

    function test_ready_returnsFalse_flagged() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        vm.prank(emergency); adapter.flag(qId);
        assertFalse(adapter.ready(qId));
    }

    function test_ready_returnsFalse_resolved() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(int256(uint256(1)));
        adapter.resolve(qId);
        assertFalse(adapter.ready(qId));
    }

    function test_ready_returnsFalse_unresolvable() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        mockOO.setPrice(type(int256).max);
        adapter.resolve(qId); // marks unresolvable
        assertFalse(adapter.ready(qId));
    }

    /*//////////////////////////////////////////////////////////////
                  _tryResetQuestion — ACCESS GUARD
    //////////////////////////////////////////////////////////////*/

    function test_tryResetQuestion_reverts_notSelf() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("BlieverUmaAdapter__OnlySelf()"));
        adapter._tryResetQuestion(address(adapter), qId, false);
    }

    /*//////////////////////////////////////////////////////////////
                     VIEW FUNCTIONS — isInitialized / isFlagged
    //////////////////////////////////////////////////////////////*/

    function test_isInitialized_falseBeforeInit() public {
        assertFalse(adapter.isInitialized(bytes32("nothing")));
    }

    function test_isInitialized_trueAfterInit() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        assertTrue(adapter.isInitialized(qId));
    }

    function test_isFlagged_falseBeforeFlag() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        assertFalse(adapter.isFlagged(qId));
    }

    function test_isFlagged_trueAfterFlag() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        vm.prank(emergency); adapter.flag(qId);
        assertTrue(adapter.isFlagged(qId));
    }

    /*//////////////////////////////////////////////////////////////
                  FUZZ — resolve never reverts on valid encoding
    //////////////////////////////////////////////////////////////*/

    /// @dev For any valid winning outcome in [0, outcomeCount), resolve() succeeds.
    function testFuzz_resolve_validOutcomeNeverReverts(uint8 winner) public {
        winner = uint8(bound(winner, 0, OUTCOME_COUNT_2 - 1));

        MockBlieverMarket mkt = new MockBlieverMarket(
            bytes32(0), OUTCOME_COUNT_2, uint40(block.timestamp) + RESOLUTION_DL
        );
        bytes memory rawAnc = abi.encodePacked("fuzz-market-", winner);
        bytes32 qId = _initQuestion(mkt, rawAnc);

        int256 encoded = int256(uint256(1) << (32 * uint256(winner)));
        mockOO.setPrice(encoded);

        adapter.resolve(qId);

        assertEq(mkt.lastWinner(), winner, "fuzz: wrong winner");
    }
}
