// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "src/token/Buck.sol";

contract MockAccessRegistryLimits is IAccessRegistry {
    function isAllowed(address) external pure override returns (bool) {
        return true;
    }

    function isDenylisted(address) external pure override returns (bool) {
        return false;
    }
}

contract MockRewardsHookLimits is IRewardsHook {
    function onBalanceChange(address, address, uint256) external pure override {}
}

contract MockPolicyManagerLimits {
    function getDexFees() external pure returns (uint16, uint16) {
        return (0, 0); // No fees for limits testing
    }
}

contract BUCKLimitsTest is BaseTest {
    Buck internal buck;
    MockAccessRegistryLimits internal accessRegistry;
    MockRewardsHookLimits internal rewardsHook;
    MockPolicyManagerLimits internal policyManager;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant LIQUIDITY_WINDOW = address(0xBEEF);
    address internal constant LIQUIDITY_RESERVE = address(0xCAFE);
    address internal constant TREASURY = address(0xFEE1);
    address internal constant USER = address(0x1234);
    address internal constant DEX_PAIR = address(0xDEAD);

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
        accessRegistry = new MockAccessRegistryLimits();
        rewardsHook = new MockRewardsHookLimits();
        policyManager = new MockPolicyManagerLimits();

        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);
    }

    function testMintUpToMaxUint() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, type(uint256).max);
        assertEq(buck.totalSupply(), type(uint256).max);
        assertEq(buck.balanceOf(USER), type(uint256).max);
    }

    function testTransferNearMax() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, type(uint256).max);
        vm.prank(USER);
        assertTrue(buck.transfer(DEX_PAIR, type(uint256).max - 1));
    }

    function testMintOverflowClamped() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, type(uint256).max);
        vm.expectRevert();
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 1);
    }

    function testTransferToSelfMax() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, type(uint256).max);
        vm.prank(USER);
        assertTrue(buck.transfer(USER, type(uint256).max));
    }

    function testAllowancesUseMaxUint() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, type(uint256).max);
        vm.prank(USER);
        assertTrue(buck.approve(address(this), type(uint256).max));
        vm.prank(address(this));
        buck.transferFrom(USER, DEX_PAIR, type(uint256).max);
    }
}
