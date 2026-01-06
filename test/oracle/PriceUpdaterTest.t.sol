// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";

/// @title PriceUpdaterTest
/// @notice Tests the priceUpdater role for fast internal price updates
/// @dev Verifies fix for Cyfrin Issue #5 - multisig can't maintain 15min freshness
contract PriceUpdaterTest is Test {
    OracleAdapter internal adapter;

    address internal constant OWNER = address(0x1000);
    address internal constant PRICE_UPDATER = address(0x2000);
    address internal constant RANDOM_USER = address(0x3000);

    event PriceUpdaterUpdated(address indexed priceUpdater);
    event InternalPriceUpdated(uint256 price, uint256 updatedAt);

    function setUp() public {
        vm.prank(OWNER);
        adapter = new OracleAdapter(OWNER);
    }

    /// @notice Owner can set the priceUpdater address
    function test_OwnerCanSetPriceUpdater() public {
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, false);
        emit PriceUpdaterUpdated(PRICE_UPDATER);
        adapter.setPriceUpdater(PRICE_UPDATER);

        assertEq(adapter.priceUpdater(), PRICE_UPDATER);
    }

    /// @notice Non-owner cannot set priceUpdater
    function test_Revert_NonOwnerCannotSetPriceUpdater() public {
        vm.expectRevert();
        vm.prank(RANDOM_USER);
        adapter.setPriceUpdater(PRICE_UPDATER);
    }

    /// @notice priceUpdater can call setInternalPrice
    function test_PriceUpdaterCanSetInternalPrice() public {
        // Owner sets priceUpdater
        vm.prank(OWNER);
        adapter.setPriceUpdater(PRICE_UPDATER);

        // priceUpdater sets internal price
        uint256 newPrice = 0.95e18; // $0.95
        vm.prank(PRICE_UPDATER);
        vm.expectEmit(false, false, false, true);
        emit InternalPriceUpdated(newPrice, block.timestamp);
        adapter.setInternalPrice(newPrice);

        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, newPrice);
        assertEq(updatedAt, block.timestamp);
    }

    /// @notice Owner can still set internal price directly
    function test_OwnerCanStillSetInternalPrice() public {
        uint256 newPrice = 0.98e18;
        vm.prank(OWNER);
        adapter.setInternalPrice(newPrice);

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, newPrice);
    }

    /// @notice Random user cannot set internal price
    function test_Revert_RandomUserCannotSetInternalPrice() public {
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        vm.prank(RANDOM_USER);
        adapter.setInternalPrice(1e18);
    }

    /// @notice priceUpdater cannot set internal price before being assigned
    function test_Revert_UnassignedPriceUpdaterCannotSetInternalPrice() public {
        // priceUpdater not set yet (address(0))
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        vm.prank(PRICE_UPDATER);
        adapter.setInternalPrice(1e18);
    }

    /// @notice Owner can change priceUpdater to a new address
    function test_OwnerCanChangePriceUpdater() public {
        address newUpdater = address(0x4000);

        vm.startPrank(OWNER);
        adapter.setPriceUpdater(PRICE_UPDATER);
        adapter.setPriceUpdater(newUpdater);
        vm.stopPrank();

        assertEq(adapter.priceUpdater(), newUpdater);

        // Old priceUpdater can no longer update
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        vm.prank(PRICE_UPDATER);
        adapter.setInternalPrice(1e18);

        // New priceUpdater can update
        vm.prank(newUpdater);
        adapter.setInternalPrice(0.99e18);
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0.99e18);
    }

    /// @notice Owner can revoke priceUpdater by setting to address(0)
    function test_OwnerCanRevokePriceUpdater() public {
        vm.startPrank(OWNER);
        adapter.setPriceUpdater(PRICE_UPDATER);
        adapter.setPriceUpdater(address(0));
        vm.stopPrank();

        assertEq(adapter.priceUpdater(), address(0));

        // Former priceUpdater can no longer update
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        vm.prank(PRICE_UPDATER);
        adapter.setInternalPrice(1e18);
    }

    /// @notice Simulate rapid price updates during stress (the use case this solves)
    function test_RapidPriceUpdatesDuringStress() public {
        vm.prank(OWNER);
        adapter.setPriceUpdater(PRICE_UPDATER);

        // Simulate 15-minute update cadence during CR < 1 stress period
        uint256[] memory prices = new uint256[](4);
        prices[0] = 0.95e18;
        prices[1] = 0.94e18;
        prices[2] = 0.96e18;
        prices[3] = 0.97e18;

        for (uint256 i = 0; i < prices.length; i++) {
            vm.warp(block.timestamp + 15 minutes);
            vm.prank(PRICE_UPDATER);
            adapter.setInternalPrice(prices[i]);

            (uint256 price, uint256 updatedAt) = adapter.latestPrice();
            assertEq(price, prices[i]);
            assertEq(updatedAt, block.timestamp);
        }
    }
}
