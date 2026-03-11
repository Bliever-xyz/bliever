// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {BlieverV1Pool} from "../../src/BlieverV1Pool.sol";

/// @dev Minimal market stub used as a test double for prediction-market contracts.
///
///      Two purposes:
///        1. Satisfies `market.code.length > 0` required by registerMarket.
///        2. Relays vault calls (collectTradeCost / settleMarket / claimWinnings)
///           as msg.sender = address(this), which must hold MARKET_ROLE after
///           registerMarket is called.
///
///      Each test that needs market interaction should deploy a fresh instance
///      via `new MockMarket(address(pool))` before registering.
contract MockMarket {
    BlieverV1Pool public immutable vault;

    constructor(address _vault) {
        vault = BlieverV1Pool(_vault);
    }

    /// @dev Calls vault.collectTradeCost — caller of this function need not be privileged;
    ///      msg.sender seen by the vault is address(this), which holds MARKET_ROLE.
    function doCollectTrade(
        address trader,
        uint256 cost,
        uint256 newLiability
    ) external {
        vault.collectTradeCost(trader, cost, newLiability);
    }

    /// @dev Calls vault.settleMarket.
    function doSettle(uint256 totalPayout) external {
        vault.settleMarket(totalPayout);
    }

    /// @dev Calls vault.claimWinnings.
    function doClaim(address winner_, uint256 amount) external {
        vault.claimWinnings(winner_, amount);
    }
}
