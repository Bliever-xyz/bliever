// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";
import {MultiValueDecoder} from "../../src/libraries/MultiValueDecoder.sol";

/*//////////////////////////////////////////////////////////////
                    LIBRARY EXPOSER CONTRACT
//////////////////////////////////////////////////////////////*/

/// @dev MultiValueDecoder uses `internal` functions — this exposer wraps them
///      as external calls so Foundry can exercise them directly in tests.
contract MultiValueDecoderExposer {
    using MultiValueDecoder for int256;

    function isTooEarly(int256 price) external pure returns (bool) {
        return price.isTooEarly();
    }

    function isUnresolvable(int256 price) external pure returns (bool) {
        return price.isUnresolvable();
    }

    function decodeWinningOutcome(int256 encodedPrice, uint8 outcomeCount)
        external
        pure
        returns (uint8)
    {
        return encodedPrice.decodeWinningOutcome(outcomeCount);
    }
}

/*//////////////////////////////////////////////////////////////
                 ENCODING HELPERS (PURE — FOR TESTS)
//////////////////////////////////////////////////////////////*/

/// @dev Build a UMIP-183 int256 where exactly one slot equals 1.
function encodeWinner(uint8 outcomeIdx) pure returns (int256) {
    return int256(uint256(1) << (32 * uint256(outcomeIdx)));
}

/// @dev Build an int256 where TWO slots equal 1 (invalid: multiple winners).
function encodeTwoWinners(uint8 a, uint8 b) pure returns (int256) {
    return int256((uint256(1) << (32 * uint256(a))) | (uint256(1) << (32 * uint256(b))));
}

/// @dev Build an int256 where a slot has value > 1 (invalid: non-binary slot).
function encodeSlotValueGtOne(uint8 outcomeIdx, uint32 val) pure returns (int256) {
    return int256(uint256(val) << (32 * uint256(outcomeIdx)));
}

/// @dev Set the top 32 bits (bits 224–255) to a non-zero pattern (invalid).
///      Bit 255 must NOT be set (would make it negative / collide with sentinels).
function encodeGarbageTopBits() pure returns (int256) {
    // Set bit 224 only (lowest bit of the top-32-bit region), which keeps the int256 positive.
    return int256(uint256(1) << 224);
}

/// @dev Set a trailing slot in position [outcomeCount, MAX_OUTCOMES) = 1 (invalid garbage guard).
///      Used with outcomeCount = 2, so slot 2 (bits 64–95) is "trailing".
function encodeTrailingSlotGarbage(uint8 validOutcome, uint8 trailingSlot) pure returns (int256) {
    return int256((uint256(1) << (32 * uint256(validOutcome))) | (uint256(1) << (32 * uint256(trailingSlot))));
}

/*//////////////////////////////////////////////////////////////
                    TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/// @title  MultiValueDecoderTest
/// @notice Full coverage of the MultiValueDecoder pure library.
///
///         Covers:
///           • isTooEarly   — sentinel detection
///           • isUnresolvable — sentinel detection
///           • decodeWinningOutcome — binary (N=2) all outcomes
///           • decodeWinningOutcome — multi-outcome (N=7) all outcomes
///           • Invalid: no winner
///           • Invalid: multiple winners (two slots = 1)
///           • Invalid: slot value > 1
///           • Invalid: garbage top bits
///           • Invalid: garbage in trailing slots [N, MAX_OUTCOMES)
///           • Fuzz: encoding round-trip for any valid (outcome, count) pair
contract MultiValueDecoderTest is Test {

    MultiValueDecoderExposer internal exposer;

    function setUp() public {
        exposer = new MultiValueDecoderExposer();
        vm.label(address(exposer), "MultiValueDecoderExposer");
    }

    /*//////////////////////////////////////////////////////////////
                      isTooEarly SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_isTooEarly_trueForMinInt256() public {
        assertTrue(exposer.isTooEarly(type(int256).min), "min int256 should be TOO_EARLY");
    }

    function test_isTooEarly_falseForZero() public {
        assertFalse(exposer.isTooEarly(0), "0 should not be TOO_EARLY");
    }

    function test_isTooEarly_falseForPositive() public {
        assertFalse(exposer.isTooEarly(int256(uint256(1))), "positive should not be TOO_EARLY");
    }

    function test_isTooEarly_falseForMaxInt256() public {
        assertFalse(exposer.isTooEarly(type(int256).max), "max int256 should not be TOO_EARLY (that is UNRESOLVABLE)");
    }

    /*//////////////////////////////////////////////////////////////
                    isUnresolvable SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_isUnresolvable_trueForMaxInt256() public {
        assertTrue(exposer.isUnresolvable(type(int256).max), "max int256 should be UNRESOLVABLE");
    }

    function test_isUnresolvable_falseForZero() public {
        assertFalse(exposer.isUnresolvable(0), "0 should not be UNRESOLVABLE");
    }

    function test_isUnresolvable_falseForMinInt256() public {
        assertFalse(exposer.isUnresolvable(type(int256).min), "min int256 should not be UNRESOLVABLE");
    }

    function test_isUnresolvable_falseForPositive() public {
        assertFalse(exposer.isUnresolvable(int256(uint256(1))), "positive should not be UNRESOLVABLE");
    }

    /*//////////////////////////////////////////////////////////////
              decodeWinningOutcome — BINARY (N=2) ALL OUTCOMES
    //////////////////////////////////////////////////////////////*/

    function test_decode_binary_outcome0Wins() public {
        // Slot 0: bits 0–31 = 1, slot 1 = 0
        int256 encoded = encodeWinner(0); // int256(1)
        uint8  winner  = exposer.decodeWinningOutcome(encoded, 2);
        assertEq(winner, 0, "binary: outcome 0 should win");
        console2.log("binary outcome 0: encodedPrice =", uint256(encoded));
    }

    function test_decode_binary_outcome1Wins() public {
        // Slot 1: bits 32–63 = 1, slot 0 = 0
        int256 encoded = encodeWinner(1); // int256(1 << 32)
        uint8  winner  = exposer.decodeWinningOutcome(encoded, 2);
        assertEq(winner, 1, "binary: outcome 1 should win");
    }

    /*//////////////////////////////////////////////////////////////
           decodeWinningOutcome — MULTI-OUTCOME (N=7) ALL OUTCOMES
    //////////////////////////////////////////////////////////////*/

    function test_decode_sevenOutcome_allOutcomes() public {
        uint8 n = 7;
        for (uint8 expected = 0; expected < n; expected++) {
            int256 encoded = encodeWinner(expected);
            uint8  actual  = exposer.decodeWinningOutcome(encoded, n);
            assertEq(actual, expected, "7-outcome: wrong winner");
            console2.log("7-outcome, expected winner:", expected, "decoded:", actual);
        }
    }

    /*//////////////////////////////////////////////////////////////
               INVALID: NO WINNER (all slots = 0)
    //////////////////////////////////////////////////////////////*/

    function test_decode_reverts_noWinner_allZero() public {
        // int256(0) → all slots zero → no winner found
        vm.expectRevert(
            abi.encodeWithSelector(MultiValueDecoder.InvalidOracleEncoding.selector, int256(0), uint8(2))
        );
        exposer.decodeWinningOutcome(0, 2);
    }

    function test_decode_reverts_noWinner_sevenOutcome() public {
        vm.expectRevert();
        exposer.decodeWinningOutcome(0, 7);
    }

    /*//////////////////////////////////////////////////////////////
              INVALID: MULTIPLE WINNERS (two slots = 1)
    //////////////////////////////////////////////////////////////*/

    function test_decode_reverts_multipleWinners_outcome0And1() public {
        // Both outcome 0 and outcome 1 = 1 → duplicate winner
        int256 encoded = encodeTwoWinners(0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(MultiValueDecoder.InvalidOracleEncoding.selector, encoded, uint8(2))
        );
        exposer.decodeWinningOutcome(encoded, 2);
    }

    function test_decode_reverts_multipleWinners_sevenOutcome() public {
        // Outcomes 3 and 6 both win
        int256 encoded = encodeTwoWinners(3, 6);
        vm.expectRevert();
        exposer.decodeWinningOutcome(encoded, 7);
    }

    /*//////////////////////////////////////////////////////////////
              INVALID: SLOT VALUE > 1 (non-binary encoding)
    //////////////////////////////////////////////////////////////*/

    function test_decode_reverts_slotValueTwo() public {
        // Slot 0 = 2 (binary requires 0 or 1 only)
        int256 encoded = encodeSlotValueGtOne(0, 2);
        vm.expectRevert(
            abi.encodeWithSelector(MultiValueDecoder.InvalidOracleEncoding.selector, encoded, uint8(2))
        );
        exposer.decodeWinningOutcome(encoded, 2);
    }

    function test_decode_reverts_slotValueMaxUint32() public {
        int256 encoded = encodeSlotValueGtOne(1, type(uint32).max);
        vm.expectRevert();
        exposer.decodeWinningOutcome(encoded, 2);
    }

    /*//////////////////////////////////////////////////////////////
              INVALID: GARBAGE TOP BITS (bits 224–255 ≠ 0)
    //////////////////////////////////////////////////////////////*/

    function test_decode_reverts_garbageTopBits() public {
        int256 encoded = encodeGarbageTopBits(); // bit 224 set, but int256 still positive
        vm.expectRevert(
            abi.encodeWithSelector(MultiValueDecoder.InvalidOracleEncoding.selector, encoded, uint8(2))
        );
        exposer.decodeWinningOutcome(encoded, 2);
    }

    function test_decode_reverts_garbageTopBitsPlusValidWinner() public {
        // Valid winner in slot 0 PLUS garbage in top bits → still invalid
        int256 encoded = int256(uint256(encodeWinner(0)) | (uint256(1) << 224));
        vm.expectRevert();
        exposer.decodeWinningOutcome(encoded, 2);
    }

    /*//////////////////////////////////////////////////////////////
           INVALID: GARBAGE IN TRAILING SLOTS [N, MAX_OUTCOMES)
    //////////////////////////////////////////////////////////////*/

    function test_decode_reverts_trailingSlotGarbage_N2_slot2() public {
        // N=2: slots 2–6 are trailing; slot 2 = 1 is garbage even if a valid outcome also wins
        // Outcome 0 wins legitimately but slot 2 has junk
        int256 encoded = encodeTrailingSlotGarbage(0, 2); // outcome 0 + slot 2 both = 1
        vm.expectRevert(
            abi.encodeWithSelector(MultiValueDecoder.InvalidOracleEncoding.selector, encoded, uint8(2))
        );
        exposer.decodeWinningOutcome(encoded, 2);
    }

    function test_decode_reverts_trailingSlotGarbage_N5_slot5() public {
        // N=5: slot 5 is trailing; slot 0 valid + slot 5 garbage
        int256 encoded = encodeTrailingSlotGarbage(0, 5);
        vm.expectRevert();
        exposer.decodeWinningOutcome(encoded, 5);
    }

    function test_decode_reverts_trailingSlotGarbage_N7_noTrailing() public {
        // N=7 uses all 7 slots (0–6); no trailing exists — slot 6 IS a valid outcome.
        // Encoding outcome 6 alone must succeed.
        int256 encoded = encodeWinner(6);
        uint8  winner  = exposer.decodeWinningOutcome(encoded, 7);
        assertEq(winner, 6, "7-outcome: last slot should be valid winner");
    }

    /*//////////////////////////////////////////////////////////////
                  BOUNDARY — MINIMUM OUTCOME COUNT (N=2)
    //////////////////////////////////////////////////////////////*/

    function test_decode_minimumOutcomeCount_outcome0() public {
        uint8 winner = exposer.decodeWinningOutcome(encodeWinner(0), 2);
        assertEq(winner, 0);
    }

    function test_decode_minimumOutcomeCount_outcome1() public {
        uint8 winner = exposer.decodeWinningOutcome(encodeWinner(1), 2);
        assertEq(winner, 1);
    }

    /*//////////////////////////////////////////////////////////////
             FUZZ — VALID ENCODINGS ALWAYS DECODE CORRECTLY
    //////////////////////////////////////////////////////////////*/

    /// @dev For any (outcomeIdx, outcomeCount) pair in valid ranges, encoding
    ///      and decoding must be lossless.
    function testFuzz_decode_roundTrip(uint8 outcomeIdx, uint8 outcomeCount) public {
        outcomeCount = uint8(bound(outcomeCount, 2, 7));
        outcomeIdx   = uint8(bound(outcomeIdx,   0, outcomeCount - 1));

        int256 encoded = encodeWinner(outcomeIdx);
        uint8  decoded = exposer.decodeWinningOutcome(encoded, outcomeCount);

        assertEq(decoded, outcomeIdx, "fuzz: round-trip mismatch");
    }

    /// @dev Zero-encoding always reverts regardless of outcomeCount.
    function testFuzz_decode_zeroAlwaysReverts(uint8 outcomeCount) public {
        outcomeCount = uint8(bound(outcomeCount, 2, 7));
        vm.expectRevert();
        exposer.decodeWinningOutcome(0, outcomeCount);
    }

    /// @dev Sentinels are always detected correctly regardless of any trailing data.
    function testFuzz_isTooEarly_onlyMinInt256(int256 price) public {
        if (price == type(int256).min) {
            assertTrue(exposer.isTooEarly(price));
        } else {
            assertFalse(exposer.isTooEarly(price));
        }
    }

    function testFuzz_isUnresolvable_onlyMaxInt256(int256 price) public {
        if (price == type(int256).max) {
            assertTrue(exposer.isUnresolvable(price));
        } else {
            assertFalse(exposer.isUnresolvable(price));
        }
    }
}
