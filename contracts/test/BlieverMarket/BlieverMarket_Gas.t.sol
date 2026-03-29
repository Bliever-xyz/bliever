// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";

import {BlieverMarket}  from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Gas Profiling Tests
/// @notice Measures and enforces upper bounds on gas consumption for
///         the critical hot paths: buy, sell, resolve, claim.
///
///         Purpose
///         ───────
///         • Catches accidental gas regressions during refactors.
///         • Documents expected on-chain cost for the Base L2 deployment.
///         • Provides a baseline for optimizer changes.
///
///         How to use
///         ──────────
///         Generate a snapshot:   forge snapshot --evm-version cancun
///         Detect regressions:    forge snapshot --check --evm-version cancun
///         View diff:             forge snapshot --diff .gas-snapshot --evm-version cancun
///
///         Gas caps in this file are deliberately generous (~2× observed cost)
///         to avoid flaky CI failures due to minor EVM version changes while
///         still catching large accidental regressions.
///
/// @dev    Run: forge test --match-contract BlieverMarket_GasTest --evm-version cancun -vvv --gas-report
contract BlieverMarket_GasTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                      GAS — BUY (HOT PATH)
    //////////////////////////////////////////////////////////////*/

    /// @dev Warm buy: second call in the same transaction (warm storage slots).
    function test_gas_buy_2outcomes_1share() public {
        _setupTrader(alice, TRADER_USDC);

        // Warm up storage — first call touches all slots cold
        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        usdc.mint(alice, TRADER_USDC); // top up

        // Measure warm call
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("buy() 2-outcome warm gas:", gasUsed);
        // Target: < 150 000 gas on Cancun (generous cap for CI stability)
        assertLt(gasUsed, 150_000, "buy() gas regression detected");
    }

    /// @dev Cold buy: first call on a fresh market (all slots cold).
    function test_gas_buy_2outcomes_cold() public {
        _setupTrader(alice, TRADER_USDC * 10);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("buy() 2-outcome cold gas:", gasUsed);
        // Cold is typically 2–3× warm; allow up to 250 000
        assertLt(gasUsed, 250_000, "cold buy() gas regression detected");
    }

    /// @dev Buy on 7-outcome market (n=7 array passes).
    function test_gas_buy_7outcomes_1share() public {
        _setupTrader(alice, TRADER_USDC);

        // Warm up
        vm.prank(alice);
        market7.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        usdc.mint(alice, TRADER_USDC);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market7.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("buy() 7-outcome warm gas:", gasUsed);
        assertLt(gasUsed, 250_000, "7-outcome buy() gas regression");
    }

    /*//////////////////////////////////////////////////////////////
                      GAS — SELL (HOT PATH)
    //////////////////////////////////////////////////////////////*/

    /// @dev Standard sell (refund path, no CSS): warm gas measurement.
    function test_gas_sell_standard_2outcomes() public {
        _buy(market2, alice, 0, 3 * SHARE_1);
        usdc.mint(alice, MAX_COST); // top up for any CSS edge case

        // Warm up by selling once
        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("sell() standard warm gas:", gasUsed);
        assertLt(gasUsed, 150_000, "sell() gas regression detected");
    }

    /// @dev CSS sell on 7-outcome market (most expensive sell path — touches all n outcome slots).
    function test_gas_sell_css_7outcomes() public {
        // Warm up all state: buy into outcome 0 first
        _buy(market7, alice, 0, SHARE_1);
        _setupTrader(alice, TRADER_USDC);

        // Warm up CSS sell
        vm.prank(alice);
        market7.sell(0, 3 * SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        // Buy again to have shares for second measurement
        usdc.mint(alice, TRADER_USDC);
        vm.prank(alice);
        market7.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market7.sell(0, 3 * SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("sell() CSS 7-outcome warm gas:", gasUsed);
        assertLt(gasUsed, 350_000, "CSS sell 7-outcome gas regression");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS — RESOLVE / CLAIM (SETTLEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @dev resolve() gas (no prior trades, zero payout path).
    function test_gas_resolve_noTrades() public {
        uint256 gasBefore = gasleft();
        vm.prank(resolver);
        market2.resolve(0);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("resolve() no-trades gas:", gasUsed);
        assertLt(gasUsed, 80_000, "resolve() no-trades gas regression");
    }

    /// @dev resolve() gas with one prior trade.
    function test_gas_resolve_withTrade() public {
        _buy(market2, alice, 0, SHARE_1);

        uint256 gasBefore = gasleft();
        vm.prank(resolver);
        market2.resolve(0);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("resolve() with-trade gas:", gasUsed);
        assertLt(gasUsed, 100_000, "resolve() with-trade gas regression");
    }

    /// @dev claim() gas for a winning trader.
    function test_gas_claim_winner() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        market2.claim();
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("claim() winner gas:", gasUsed);
        assertLt(gasUsed, 100_000, "claim() gas regression");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS — VIEWS (READ-ONLY CALLS)
    //////////////////////////////////////////////////////////////*/

    /// @dev getPrice() view gas.
    function test_gas_getPrice() public {
        uint256 gasBefore = gasleft();
        market2.getPrice(0);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("getPrice() gas:", gasUsed);
        assertLt(gasUsed, 30_000, "getPrice() gas regression");
    }

    /// @dev getAllPrices() view gas for 7-outcome market.
    function test_gas_getAllPrices_7outcomes() public {
        uint256 gasBefore = gasleft();
        market7.getAllPrices();
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("getAllPrices() 7-outcome gas:", gasUsed);
        assertLt(gasUsed, 80_000, "getAllPrices() 7-outcome gas regression");
    }

    /// @dev getBuyCost() view gas.
    function test_gas_getBuyCost() public {
        uint256 gasBefore = gasleft();
        market2.getBuyCost(0, SHARE_1);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("getBuyCost() gas:", gasUsed);
        assertLt(gasUsed, 40_000, "getBuyCost() gas regression");
    }

    /// @dev getMarketStatus() view gas.
    function test_gas_getMarketStatus() public {
        uint256 gasBefore = gasleft();
        market2.getMarketStatus();
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("getMarketStatus() gas:", gasUsed);
        assertLt(gasUsed, 30_000, "getMarketStatus() gas regression");
    }
}
