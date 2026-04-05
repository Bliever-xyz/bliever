// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title  MultiValueDecoder
/// @notice Pure library for encoding and decoding UMIP-183 `MULTIPLE_VALUES` prices.
///
///         ─────────────────────────────────────────────────────────────────────────
///         ENCODING CONTRACT (UMIP-183)
///         ─────────────────────────────────────────────────────────────────────────
///         The oracle returns a single int256 that packs up to 7 × uint32 values:
///
///           int256
///           | 32 bits  | 32 bits | 32 bits | … | 32 bits |
///           | unused   | value6  | value5  | … | value0  |
///           | 224–255  | 192–223 | 160–191 | … |  0–31   |
///
///         labels[0] → bits  0–31   (value0)
///         labels[1] → bits 32–63   (value1)
///         …
///         labels[6] → bits 192–223 (value6)
///         bits 224–255 are ALWAYS zero (collision guard).
///
///         Special sentinel values (must be checked BEFORE decoding):
///           type(int256).min  →  "too early" / event-based expiry before game start
///           type(int256).max  →  "unresolvable" / event canceled / ancillary data invalid
///
///         ─────────────────────────────────────────────────────────────────────────
///         BLIEVER WINNING-OUTCOME CONTRACT
///         ─────────────────────────────────────────────────────────────────────────
///         For a prediction market with N outcomes the adapter encodes the result as:
///           labels[winningOutcome] = 1
///           labels[all others]     = 0
///
///         `decodeWinningOutcome` enforces this contract:
///           • Exactly one value must equal 1.
///           • All other values must equal 0.
///           • Values in positions [outcomeCount, 7) and the top 32 bits must be 0.
///           • Reverts with InvalidOracleEncoding on any violation.
///
/// @dev    All functions are `pure` — no state reads, no external calls.
///         Designed to be called inline from BlieverUmaAdapter._decodeAndResolve().
library MultiValueDecoder {

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Maximum number of outcomes supported by MULTIPLE_VALUES in V1.
    ///      UMIP-183 supports up to 7 labels; V1 enforces this hard limit.
    uint8 internal constant MAX_OUTCOMES = 7;

    /// @dev Sentinel: oracle returned before the event started (event-based expiry).
    int256 internal constant TOO_EARLY_PRICE = type(int256).min;

    /// @dev Sentinel: event canceled, ancillary data invalid, or > 7 labels.
    int256 internal constant UNRESOLVABLE_PRICE = type(int256).max;

    /// @dev Mask for a single uint32 slot (bits 0–31 of the shifted value).
    uint256 internal constant UINT32_MASK = 0xFFFFFFFF;

    /// @dev Mask for the top 32 bits of the 256-bit word (bits 224–255).
    ///      These must always be zero per UMIP-183 to prevent collision with
    ///      the `UNRESOLVABLE_PRICE` sentinel (which sets ALL bits including these).
    uint256 internal constant TOP_BITS_MASK = uint256(0xFFFFFFFF) << 224;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The decoded int256 does not satisfy the single-winner contract.
    ///         Emitted when: no winner found, multiple winners, trailing garbage bits,
    ///         or any uint32 slot > 1 in a position within [0, outcomeCount).
    error InvalidOracleEncoding();

    /*//////////////////////////////////////////////////////////////
                           PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true if the oracle price is the "too early" sentinel.
    ///         MUST be checked before calling decodeWinningOutcome.
    /// @param price  Raw int256 returned by settleAndGetPrice().
    function isTooEarly(int256 price) internal pure returns (bool) {
        return price == TOO_EARLY_PRICE;
    }

    /// @notice Returns true if the oracle price is the "unresolvable" sentinel.
    ///         MUST be checked before calling decodeWinningOutcome.
    /// @param price  Raw int256 returned by settleAndGetPrice().
    function isUnresolvable(int256 price) internal pure returns (bool) {
        return price == UNRESOLVABLE_PRICE;
    }

    /// @notice Decode a MULTIPLE_VALUES-encoded int256 price and return the index
    ///         of the single outcome with value = 1.
    ///
    ///         Validation rules (all must pass, else InvalidOracleEncoding):
    ///           1. Top 32 bits (bits 224–255) must be 0.
    ///           2. All slots in [outcomeCount, MAX_OUTCOMES) must be 0 (trailing garbage guard).
    ///           3. Exactly one slot in [0, outcomeCount) must equal 1.
    ///           4. All other slots in [0, outcomeCount) must equal 0.
    ///              (Binary winner representation: 1 = winner, 0 = loser.)
    ///
    /// @param encodedPrice  Settled int256 price from the OO (pre-checked: not sentinel).
    /// @param outcomeCount  Number of outcomes [2, MAX_OUTCOMES] registered for this market.
    /// @return winningOutcome  Index of the winning outcome [0, outcomeCount).
    function decodeWinningOutcome(
        int256 encodedPrice,
        uint8  outcomeCount
    ) internal pure returns (uint8 winningOutcome) {
        // Cast once: we've already excluded both sentinels (min and max), so this
        // is a non-negative int256 with bits 255–224 never all set to 1.
        // The top-bit-zero guard below provides an additional correctness check.
        uint256 raw = uint256(encodedPrice);

        // ── Rule 1: Top 32 bits must be zero ────────────────────────────────
        // UMIP-183 §Implementation: "The most significant 32 bits are always unused
        // to prevent collisions with the other valid responses."
        if (raw & TOP_BITS_MASK != 0) revert InvalidOracleEncoding();

        // ── Rule 2: Trailing slots [outcomeCount, MAX_OUTCOMES) must be zero ─
        // Prevents garbage data in unused label positions from masking a corrupt encoding.
        unchecked {
            for (uint256 i = outcomeCount; i < MAX_OUTCOMES; ++i) {
                if (_slotAt(raw, i) != 0) revert InvalidOracleEncoding();
            }
        }

        // ── Rules 3 & 4: Exactly one slot in [0, outcomeCount) equals 1 ─────
        bool found = false;
        unchecked {
            for (uint256 i = 0; i < outcomeCount; ++i) {
                uint32 val = _slotAt(raw, i);
                if (val == 1) {
                    if (found) revert InvalidOracleEncoding(); // duplicate winner
                    found = true;
                    winningOutcome = uint8(i);
                } else if (val != 0) {
                    revert InvalidOracleEncoding(); // slot value not 0 or 1
                }
            }
        }

        if (!found) revert InvalidOracleEncoding(); // no winner
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Extract the uint32 value stored at slot `index` (0-based) of a packed uint256.
    ///      Equivalent to UMIP-183 decoding: uint32(raw >> (32 * index)) & 0xFFFFFFFF.
    function _slotAt(uint256 raw, uint256 index) private pure returns (uint32) {
        return uint32((raw >> (32 * index)) & UINT32_MASK);
    }
}
