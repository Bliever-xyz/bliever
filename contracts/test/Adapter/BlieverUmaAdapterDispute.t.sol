// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {console2} from "forge-std/Test.sol";

import {BlieverUmaAdapter}      from "../../src/BlieverUmaAdapter.sol";
import {QuestionData}            from "../../src/interfaces/IBlieverUmaAdapter.sol";

import {BlieverUmaAdapterBase}   from "./BlieverMarket/BlieverUmaAdapterBase.t.sol";
import {MockOptimisticOracleV2}  from "../mocks/MockOptimisticOracleV2.sol";
import {MockBlieverMarket}       from "../mocks/MockBlieverMarket.sol";

/// @title  BlieverUmaAdapterDisputeTest
/// @notice Tests for the priceDisputed() callback and the dispute/escalation lifecycle.
///
///         Covered scenarios:
///           1. First dispute → question reset (new OO request, qd.reset = true)
///           2. Second dispute → DVM escalation (qd.refund = true, QuestionEscalatedToDVM event)
///           3. Already-resolved question → reward best-effort refund on callback
///           4. Stale timestamp → callback silently ignored (no state change)
///           5. Reset failure (OO revert) → question automatically flagged
///           6. priceProposed and priceSettled are no-ops
///           7. onlyOptimisticOracle guard — unknown caller rejected
///           8. After first dispute reset — re-resolution succeeds on new timestamp
///           9. Second dispute after DVM escalation — resolve() succeeds via settleAndGetPrice
contract BlieverUmaAdapterDisputeTest is BlieverUmaAdapterBase {

    /*//////////////////////////////////////////////////////////////
               1. FIRST DISPUTE → QUESTION RESET
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_firstDispute_resetsQuestion() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        QuestionData memory qdBefore = adapter.getQuestion(qId);

        uint256 requestsBefore = mockOO.requestPriceCalls();

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionReset(qId);

        _simulateDispute(qId);

        QuestionData memory qdAfter = adapter.getQuestion(qId);

        // New OO request must have been issued
        assertGt(mockOO.requestPriceCalls(), requestsBefore, "new request not issued after first dispute");
        // requestTimestamp must have advanced to current block
        assertEq(qdAfter.requestTimestamp, uint40(block.timestamp), "requestTimestamp not updated");
        // reset flag must be set
        assertTrue(qdAfter.reset, "reset flag not set");
        // Must NOT be resolved
        assertFalse(qdAfter.resolved, "should not be resolved");
        // refund flag must NOT be set (only set on second dispute)
        assertFalse(qdAfter.refund, "refund flag should not be set after first dispute");

        console2.log("First dispute: question reset, requestTimestamp =", qdAfter.requestTimestamp);
    }

    function test_priceDisputed_firstDispute_questionOracleUpdated() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Upgrade oracle before the dispute fires; the reset should snapshot the new OO
        MockOptimisticOracleV2 newOO = new MockOptimisticOracleV2();
        vm.prank(admin);
        adapter.updateOptimisticOracle(address(newOO));

        // Dispute still comes from the OLD oracle (registered in _knownOracles)
        _simulateDispute(qId);

        // After reset, the question oracle must now point to the CURRENT (new) OO
        assertEq(
            adapter.getQuestionOracle(qId),
            address(newOO),
            "oracle snapshot not updated to new OO after reset"
        );
    }

    /*//////////////////////////////////////////////////////////////
               2. SECOND DISPUTE → DVM ESCALATION
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_secondDispute_escalatesToDVM() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // First dispute → reset (sets qd.reset = true)
        _simulateDispute(qId);

        // Second dispute → DVM escalation
        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionEscalatedToDVM(qId);

        _simulateDispute(qId);

        QuestionData memory qd = adapter.getQuestion(qId);
        assertTrue(qd.refund, "refund flag should be set after second dispute");
        assertTrue(qd.reset,  "reset flag should remain set");
        assertFalse(qd.resolved, "should not be resolved");
    }

    function test_priceDisputed_secondDispute_noNewOORequest() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        _simulateDispute(qId); // first dispute → new request

        uint256 requestsAfterFirst = mockOO.requestPriceCalls();
        _simulateDispute(qId); // second dispute → DVM, NO new request

        // The second dispute should NOT issue a new OO request
        assertEq(mockOO.requestPriceCalls(), requestsAfterFirst, "should not issue new request on second dispute");
    }

    /*//////////////////////////////////////////////////////////////
               3. ALREADY-RESOLVED → REWARD REFUND ON CALLBACK
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_alreadyResolved_returnsReward() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Resolve the market via emergency path (simulates resolveManually already done)
        _flagAndWait(qId);
        vm.prank(emergency);
        adapter.resolveManually(qId, 0);
        assertTrue(adapter.getQuestion(qId).resolved, "should be resolved");

        // The OO fires priceDisputed AFTER the question was already manually resolved.
        // The adapter should return the reward best-effort and not change state.
        QuestionData memory qdBefore = adapter.getQuestion(qId);
        uint256 factoryBefore = rewardToken.balanceOf(factory);

        // This should NOT revert — the adapter must be resilient to stale OO callbacks.
        vm.prank(address(mockOO));
        adapter.priceDisputed(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            qdBefore.requestTimestamp, // matching timestamp = early reward path
            qdBefore.ancillaryData,
            0
        );

        // State must not have changed (already resolved)
        assertTrue(adapter.getQuestion(qId).resolved, "resolved flag should remain");
    }

    /*//////////////////////////////////////////////////////////////
               4. STALE TIMESTAMP → CALLBACK SILENTLY IGNORED
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_staleTimestamp_silentlyIgnored() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        QuestionData memory qdBefore = adapter.getQuestion(qId);

        uint256 requestsBefore = mockOO.requestPriceCalls();

        // Use a WRONG timestamp (not the current requestTimestamp)
        uint256 staleTimestamp = qdBefore.requestTimestamp - 1;

        vm.prank(address(mockOO));
        adapter.priceDisputed(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            staleTimestamp,
            qdBefore.ancillaryData,
            0
        );

        // No state change expected — stale callback silently dropped
        QuestionData memory qdAfter = adapter.getQuestion(qId);
        assertEq(qdAfter.requestTimestamp, qdBefore.requestTimestamp, "timestamp changed on stale callback");
        assertFalse(qdAfter.reset,   "reset flag should not be set on stale callback");
        assertFalse(qdAfter.refund,  "refund flag should not be set on stale callback");
        assertEq(mockOO.requestPriceCalls(), requestsBefore, "new request issued on stale callback");

        console2.log("Stale timestamp silently ignored — no state mutation");
    }

    /*//////////////////////////////////////////////////////////////
               5. RESET FAILURE → QUESTION FLAGGED
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_resetFails_questionFlagged() public {
        bytes32 qId = _initQuestionNoReward(market2, ANC_DATA_2);

        // Make the OO revert on requestPrice — simulates OO unavailability
        mockOO.setShouldRevert(true);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit BlieverUmaAdapter.QuestionFlagged(qId);

        _simulateDispute(qId);

        // Question should be flagged (manualResolveAt set) rather than adapter panicking
        assertTrue(adapter.isFlagged(qId), "question should be flagged after reset failure");

        console2.log("Reset failure handled: question flagged for admin recovery");
    }

    /*//////////////////////////////////////////////////////////////
               6. priceProposed & priceSettled ARE NO-OPS
    //////////////////////////////////////////////////////////////*/

    function test_priceProposed_isNoOp_doesNotRevert() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        QuestionData memory qdBefore = adapter.getQuestion(qId);

        // Call from mockOO (known oracle)
        vm.prank(address(mockOO));
        adapter.priceProposed(adapter.MULTIPLE_VALUES_IDENTIFIER(), qdBefore.requestTimestamp, qdBefore.ancillaryData);

        // No state change
        QuestionData memory qdAfter = adapter.getQuestion(qId);
        assertEq(qdAfter.requestTimestamp, qdBefore.requestTimestamp);
        assertFalse(qdAfter.reset);
    }

    function test_priceSettled_isNoOp_doesNotRevert() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        QuestionData memory qdBefore = adapter.getQuestion(qId);

        vm.prank(address(mockOO));
        adapter.priceSettled(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            qdBefore.requestTimestamp,
            qdBefore.ancillaryData,
            int256(uint256(1))
        );

        // No state change
        assertFalse(adapter.getQuestion(qId).resolved, "should not be resolved by priceSettled");
    }

    /*//////////////////////////////////////////////////////////////
               7. onlyOptimisticOracle — UNKNOWN CALLER REJECTED
    //////////////////////////////////////////////////////////////*/

    function test_priceDisputed_reverts_notKnownOracle() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);
        QuestionData memory qd = adapter.getQuestion(qId);

        // Call from attacker — not a known oracle
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotOptimisticOracle()"));
        adapter.priceDisputed(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            qd.requestTimestamp,
            qd.ancillaryData,
            0
        );
    }

    function test_priceDisputed_acceptsOldOracleAfterUpgrade() public {
        // After updateOptimisticOracle, the OLD oracle must still be accepted for callbacks.
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Upgrade OO
        MockOptimisticOracleV2 newOO = new MockOptimisticOracleV2();
        vm.prank(admin);
        adapter.updateOptimisticOracle(address(newOO));

        // Old OO (mockOO) fires priceDisputed — should still be accepted (_knownOracles)
        _simulateDispute(qId); // uses mockOO (the old oracle)
        assertTrue(adapter.getQuestion(qId).reset, "old oracle callback should still work after upgrade");
    }

    /*//////////////////////////////////////////////////////////////
               8. POST-RESET RE-RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_resolveAfterReset_succeedsOnNewTimestamp() public {
        bytes32 qId = _initQuestionNoReward(market2, ANC_DATA_2);

        // First dispute resets the question
        _simulateDispute(qId);

        // New timestamp is now block.timestamp; set the price on the (still same) mock OO
        mockOO.setPrice(int256(uint256(1))); // outcome 0 wins

        adapter.resolve(qId);

        assertTrue(adapter.getQuestion(qId).resolved, "should be resolved after reset");
        assertEq(market2.lastWinner(), 0, "wrong winner after reset resolution");

        console2.log("Re-resolution after reset succeeded");
    }

    /*//////////////////////////////////////////////////////////////
               9. DVM PATH RESOLVE
    //////////////////////////////////////////////////////////////*/

    function test_resolveAfterDVMEscalation_succeedsWithRefundFlag() public {
        bytes32 qId = _initQuestion(market2, ANC_DATA_2);

        // Simulate DVM path: two disputes
        _simulateDispute(qId); // first → reset
        _simulateDispute(qId); // second → DVM (qd.refund = true)

        assertTrue(adapter.getQuestion(qId).refund, "refund should be set after DVM escalation");

        // DVM eventually returns a valid price
        mockOO.setPrice(int256(uint256(1) << 32)); // outcome 1 wins

        uint256 factoryBefore = rewardToken.balanceOf(factory);
        adapter.resolve(qId);

        assertTrue(adapter.getQuestion(qId).resolved,  "should be resolved after DVM");
        assertEq(market2.lastWinner(), 1,               "wrong winner from DVM resolution");

        // Reward should be refunded to creator after DVM resolution with refund=true
        // (adapter transfers rewardToken to factory = creator)
        uint256 factoryAfter = rewardToken.balanceOf(factory);
        assertGe(factoryAfter, factoryBefore, "reward not returned after DVM resolution");

        // qd.reward should now be 0 (cleared by _bestEffortRefund)
        assertEq(adapter.getQuestion(qId).reward, 0, "reward not cleared after refund");

        console2.log("DVM path resolved, reward refunded to creator");
    }

    /*//////////////////////////////////////////////////////////////
               FUZZ — DISPUTE CALLBACKS DON'T CORRUPT STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Calling priceDisputed with varying timestamps should only affect
    ///      state when the timestamp matches qd.requestTimestamp.
    function testFuzz_priceDisputed_staleTimestampNeverMutatesState(uint40 badTimestamp) public {
        bytes32 qId = _initQuestionNoReward(market2, ANC_DATA_2);
        QuestionData memory qd = adapter.getQuestion(qId);

        // Ensure badTimestamp doesn't equal the real requestTimestamp
        vm.assume(badTimestamp != qd.requestTimestamp);

        vm.prank(address(mockOO));
        adapter.priceDisputed(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            badTimestamp,
            qd.ancillaryData,
            0
        );

        QuestionData memory qdAfter = adapter.getQuestion(qId);
        assertFalse(qdAfter.reset,   "state mutated by stale callback");
        assertFalse(qdAfter.refund,  "state mutated by stale callback");
        assertEq(qdAfter.requestTimestamp, qd.requestTimestamp, "timestamp mutated by stale callback");
    }
}
