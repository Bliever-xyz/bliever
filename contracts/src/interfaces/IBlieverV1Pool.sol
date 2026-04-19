// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title  IBlieverV1Pool
/// @author Believer Protocol
/// @notice Minimal interface that BlieverMarket uses to interact with the central
///         BlieverV1Pool liquidity vault.
///
///         Design note — Why this interface is intentionally narrow
///         ────────────────────────────────────────────────────────
///         BlieverMarket is a pure math wrapper. It knows NOTHING about LP shares,
///         vault NAV, reserve buffers, or role administration.  It exposes only the
///         four trade-flow hooks that the vault already guards with MARKET_ROLE, plus
///         one read-only query (`asset`) needed to surface the USDC address to traders.
///
///         Every function here maps 1-to-1 to a function in BlieverV1Pool.sol.
///         Any change to those function signatures MUST be reflected here.
interface IBlieverV1Pool {
    /*//////////////////////////////////////////////////////////////
                            TRADE FLOW HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull `cost` USDC from `trader` into the vault and update live liability.
    /// @dev    Guarded by MARKET_ROLE on the vault.
    ///         The vault executes `safeTransferFrom(trader, vault, cost)`.
    ///         ⚠️  The TRADER must have pre-approved the vault address for ≥ cost USDC.
    ///             The market contract is NOT in the transfer path.
    ///
    /// @param trader        Address whose USDC is collected (must have approved vault)
    /// @param cost          USDC to collect from trader (6-dec; may be 0)
    /// @param newLiability  Updated worst-case loss after trade (6-dec USDC, ≤ riskBudget)
    function collectTradeCost(
        address trader,
        uint256 cost,
        uint256 newLiability
    ) external;

    /// @notice Push `refundAmount` USDC from vault to `trader` and update live liability.
    /// @dev    Guarded by MARKET_ROLE on the vault.
    ///         The vault executes `safeTransfer(trader, refundAmount)`.
    ///
    /// @param trader        Address that receives the USDC refund
    /// @param refundAmount  USDC to transfer from vault to trader (6-dec; may be 0)
    /// @param newLiability  Updated worst-case loss after sell trade (6-dec USDC, ≤ riskBudget)
    function distributeRefund(
        address trader,
        uint256 refundAmount,
        uint256 newLiability
    ) external;

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalise a resolved market: record the total winner payout and
    ///         release the market's currentLiability from totalLiability.
    /// @dev    Guarded by MARKET_ROLE on the vault. NOT pause-gated.
    ///         Vault profit = riskBudget − totalPayout ≥ 0 (Proposition 4.9).
    ///
    /// @param totalPayout  Total USDC claimable by all winning share-holders (6-dec, ≤ riskBudget)
    function settleMarket(uint256 totalPayout) external;

    /// @notice Transfer `amount` USDC to a verified winner.
    /// @dev    Guarded by MARKET_ROLE on the vault. NOT pause-gated.
    ///         The market validates winner eligibility and share balance.
    ///         The vault enforces the aggregate settlement budget.
    ///         When the last winner claims (claimedPayout == settledPayout),
    ///         the vault auto-revokes MARKET_ROLE.
    ///
    /// @param winner  Recipient of the USDC payout
    /// @param amount  USDC to transfer (6-dec; must not exceed remaining settlement budget)
    function claimWinnings(address winner, uint256 amount) external;


    /*//////////////////////////////////////////////////////////////
                           READ-ONLY QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the underlying USDC token.
    /// @dev    Used by BlieverMarket to surface the USDC address to external callers
    ///         via `usdcToken()` without storing a redundant copy.
    function asset() external view returns (address);

    function alpha() external view returns (uint256);

    function maxRiskPerMarket() external view returns (uint256);

    function registerMarket(address market, uint32 nOutcomes) external;
    
    function deregisterMarket(address market) external;
}
