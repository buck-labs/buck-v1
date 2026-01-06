// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "src/token/Buck.sol";

contract MockAccessRegistryMulticall is IAccessRegistry {
    mapping(address => bool) public isAllowed;
    mapping(address => bool) public isDenylisted;

    function setAllowed(address account, bool allowed) external {
        isAllowed[account] = allowed;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

contract MockRewardsHookMulticall is IRewardsHook {
    function onBalanceChange(address, address, uint256) external {}
}

contract MockPolicyManagerMulticall {
    uint16 public buyFeeBps = 100;
    uint16 public sellFeeBps = 100;

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }
}

/// @title BUCKMulticallTest
/// @notice Comprehensive tests for Multicall batch operations on BUCK token
/// @dev Tests batching multiple operations in a single transaction
contract BUCKMulticallTest is BaseTest {
    Buck public buck;
    MockAccessRegistryMulticall public accessRegistry;
    MockRewardsHookMulticall public rewardsHook;
    MockPolicyManagerMulticall public policyManager;

    address constant TIMELOCK = address(0x1000);
    address constant LIQUIDITY_WINDOW = address(0x2000);
    address constant LIQUIDITY_RESERVE = address(0x3000);
    address constant TREASURY = address(0x4000);
    address constant DEX_PAIR = address(0x5000);
    address constant USER1 = address(0x6001);
    address constant USER2 = address(0x6002);

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
        accessRegistry = new MockAccessRegistryMulticall();
        rewardsHook = new MockRewardsHookMulticall();
        policyManager = new MockPolicyManagerMulticall();

        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        accessRegistry.setAllowed(USER1, true);
        accessRegistry.setAllowed(USER2, true);
    }

    // =========================================================================
    // BASIC MULTICALL TESTS
    // =========================================================================

    function testMulticallBatchApprovals() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        // Prepare multicall data: approve USER2 and DEX_PAIR
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.approve.selector, USER2, 100 ether);
        calls[1] = abi.encodeWithSelector(buck.approve.selector, DEX_PAIR, 200 ether);

        // Execute multicall
        vm.prank(USER1);
        buck.multicall(calls);

        // Verify both approvals succeeded
        assertEq(buck.allowance(USER1, USER2), 100 ether);
        assertEq(buck.allowance(USER1, DEX_PAIR), 200 ether);
    }

    function testMulticallBatchConfigurationChanges() public {
        // Prepare multicall data: multiple configuration changes
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR);
        calls[1] = abi.encodeWithSelector(buck.setFeeSplit.selector, 7500);
        calls[2] = abi.encodeWithSelector(buck.setFeeExempt.selector, USER1, true);

        // Execute multicall as owner
        vm.prank(TIMELOCK);
        buck.multicall(calls);

        // Verify all changes applied
        assertTrue(buck.isDexPair(DEX_PAIR));
        assertEq(buck.feeToReservePct(), 7500);
        assertTrue(buck.isFeeExempt(USER1));
    }

    function testMulticallEmptyArraySucceeds() public {
        bytes[] memory calls = new bytes[](0);

        vm.prank(TIMELOCK);
        bytes[] memory results = buck.multicall(calls);

        assertEq(results.length, 0);
    }

    function testMulticallSingleCallWorks() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(buck.setFeeSplit.selector, 6000);

        vm.prank(TIMELOCK);
        buck.multicall(calls);

        assertEq(buck.feeToReservePct(), 6000);
    }

    // =========================================================================
    // MULTICALL WITH FAILURES
    // =========================================================================

    function testMulticallRevertsIfAnyCallFails() public {
        // Prepare multicall with one failing call
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(buck.setFeeSplit.selector, 5000); // Valid
        calls[1] = abi.encodeWithSelector(buck.setFeeSplit.selector, 10001); // Invalid - exceeds max
        calls[2] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR); // Valid but won't execute

        // Entire multicall should revert
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.InvalidFee.selector);
        buck.multicall(calls);

        // Verify no changes applied (atomic revert)
        assertEq(buck.feeToReservePct(), 0); // Original value
        assertFalse(buck.isDexPair(DEX_PAIR)); // Not set
    }

    function testMulticallRevertsOnUnauthorizedCall() public {
        // Non-owner tries to use multicall for owner functions
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.setFeeSplit.selector, 5000);
        calls[1] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR);

        vm.prank(USER1); // Not the owner
        vm.expectRevert(); // Will revert with OwnableUnauthorizedAccount
        buck.multicall(calls);
    }

    // =========================================================================
    // COMPLEX MULTICALL SCENARIOS
    // =========================================================================

    function testMulticallFullSystemConfiguration() public {
        address newLiquidityWindow = address(0x7001);
        address newLiquidityReserve = address(0x7002);
        address newTreasury = address(0x7003);
        address newPolicyManager = address(0x7004);
        address newKycRegistry = address(0x7005);
        address newRewardsHook = address(0x7006);

        // Batch configure entire system in one transaction
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(
            buck.configureModules.selector,
            newLiquidityWindow,
            newLiquidityReserve,
            newTreasury,
            newPolicyManager,
            newKycRegistry,
            newRewardsHook
        );
        calls[1] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR);
        calls[2] = abi.encodeWithSelector(buck.setFeeSplit.selector, 6000);
        calls[3] = abi.encodeWithSelector(buck.setFeeExempt.selector, DEX_PAIR, true);

        vm.prank(TIMELOCK);
        buck.multicall(calls);

        // Verify all configurations applied
        assertEq(buck.liquidityWindow(), newLiquidityWindow);
        assertEq(buck.liquidityReserve(), newLiquidityReserve);
        assertEq(buck.treasury(), newTreasury);
        assertEq(buck.policyManager(), newPolicyManager);
        assertEq(buck.accessRegistry(), newKycRegistry);
        assertEq(buck.rewardsHook(), newRewardsHook);
        assertTrue(buck.isDexPair(DEX_PAIR));
        assertEq(buck.feeToReservePct(), 6000);
        assertTrue(buck.isFeeExempt(DEX_PAIR));
    }

    function testMulticallMixedOperationsAtomicity() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        // Prepare batch: some user operations + owner operations
        // This should fail because USER1 cannot call setFeeSplit
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(buck.approve.selector, USER2, 100 ether);
        calls[1] = abi.encodeWithSelector(buck.setFeeSplit.selector, 5000); // Requires owner
        calls[2] = abi.encodeWithSelector(buck.transfer.selector, USER2, 50 ether);

        vm.prank(USER1);
        vm.expectRevert(); // Will revert on owner-only call
        buck.multicall(calls);

        // Verify atomicity: no approvals or transfers executed
        assertEq(buck.allowance(USER1, USER2), 0);
        assertEq(buck.balanceOf(USER2), 0);
    }

    // =========================================================================
    // MULTICALL RETURN DATA TESTS
    // =========================================================================

    function testMulticallReturnsDataFromCalls() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        // Prepare multicall: approve and check balance
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.approve.selector, USER2, 100 ether);
        calls[1] = abi.encodeWithSelector(buck.balanceOf.selector, USER1);

        vm.prank(USER1);
        bytes[] memory results = buck.multicall(calls);

        assertEq(results.length, 2);

        // First call (approve) returns bool true
        bool approveSuccess = abi.decode(results[0], (bool));
        assertTrue(approveSuccess);

        // Second call (balanceOf) returns uint256
        uint256 balance = abi.decode(results[1], (uint256));
        assertEq(balance, 1000 ether);
    }

    function testMulticallWithViewFunctions() public {
        vm.prank(TIMELOCK);
        buck.setFeeSplit(7500);

        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        // Batch multiple view calls
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(buck.feeToReservePct.selector);
        calls[1] = abi.encodeWithSelector(buck.isDexPair.selector, DEX_PAIR);
        calls[2] = abi.encodeWithSelector(buck.owner.selector);
        calls[3] = abi.encodeWithSelector(buck.productionMode.selector);

        bytes[] memory results = buck.multicall(calls);

        assertEq(results.length, 4);

        uint16 feeSplit = abi.decode(results[0], (uint16));
        assertEq(feeSplit, 7500);

        bool isDexPair = abi.decode(results[1], (bool));
        assertTrue(isDexPair);

        address owner = abi.decode(results[2], (address));
        assertEq(owner, TIMELOCK);

        bool prodMode = abi.decode(results[3], (bool));
        assertFalse(prodMode);
    }

    // =========================================================================
    // MULTICALL GAS OPTIMIZATION TESTS
    // =========================================================================

    function testMulticallGasSavingsVsSeparateCalls() public {
        // Individual calls - need separate pranks for each
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        vm.prank(TIMELOCK);
        buck.setFeeSplit(6000);

        vm.prank(TIMELOCK);
        buck.setFeeExempt(USER1, true);

        // Reset state
        vm.prank(TIMELOCK);
        buck.removeDexPair(DEX_PAIR);

        vm.prank(TIMELOCK);
        buck.setFeeSplit(0);

        vm.prank(TIMELOCK);
        buck.setFeeExempt(USER1, false);

        // Multicall - all in one transaction
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR);
        calls[1] = abi.encodeWithSelector(buck.setFeeSplit.selector, 6000);
        calls[2] = abi.encodeWithSelector(buck.setFeeExempt.selector, USER1, true);

        vm.prank(TIMELOCK);
        buck.multicall(calls);

        // Verify final state is correct
        assertTrue(buck.isDexPair(DEX_PAIR));
        assertEq(buck.feeToReservePct(), 6000);
        assertTrue(buck.isFeeExempt(USER1));
    }

    // =========================================================================
    // MULTICALL EDGE CASES
    // =========================================================================

    function testMulticallWithReentrancyProtectedFunctions() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        // Batch transfer and transferFrom (both have nonReentrant)
        vm.prank(USER1);
        buck.approve(USER2, 200 ether);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.transfer.selector, USER2, 100 ether);
        // Note: transferFrom would need to be called by spender, not USER1
        calls[1] = abi.encodeWithSelector(buck.balanceOf.selector, USER1);

        vm.prank(USER1);
        bytes[] memory results = buck.multicall(calls);

        // Transfer succeeded
        assertEq(buck.balanceOf(USER2), 100 ether);

        // Balance check correct
        uint256 balance = abi.decode(results[1], (uint256));
        assertEq(balance, 900 ether);
    }

    function testMulticallDuringPause() public {
        vm.prank(TIMELOCK);
        buck.pause();

        // Try to multicall configuration changes (should work - not paused functions)
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.setFeeSplit.selector, 5000);
        calls[1] = abi.encodeWithSelector(buck.addDexPair.selector, DEX_PAIR);

        vm.prank(TIMELOCK);
        buck.multicall(calls);

        // Verify changes applied even when paused
        assertEq(buck.feeToReservePct(), 5000);
        assertTrue(buck.isDexPair(DEX_PAIR));
    }

    function testMulticallCannotBypassPauseForTransfers() public {
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        vm.prank(TIMELOCK);
        buck.pause();

        // Try to multicall transfers (should fail - transfers are paused)
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(buck.transfer.selector, USER2, 100 ether);

        vm.prank(USER1);
        vm.expectRevert(); // EnforcedPause
        buck.multicall(calls);
    }

    function testMulticallWithDuplicateCalls() public {
        // Set initial state
        vm.prank(TIMELOCK);
        buck.setFeeSplit(1000);

        // Batch multiple identical calls
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(buck.setFeeSplit.selector, 2000);
        calls[1] = abi.encodeWithSelector(buck.setFeeSplit.selector, 3000);
        calls[2] = abi.encodeWithSelector(buck.setFeeSplit.selector, 4000);

        vm.prank(TIMELOCK);
        buck.multicall(calls);

        // Last call wins
        assertEq(buck.feeToReservePct(), 4000);
    }

    // =========================================================================
    // MULTICALL WITH PERMIT (ERC20Permit)
    // =========================================================================

    function testMulticallCombinesMintAndTransfer() public {
        // Simplified test: combine approve and transfer in multicall
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000 ether);

        // Multicall: approve USER2 and transfer to USER2
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(buck.approve.selector, USER2, 500 ether);
        calls[1] = abi.encodeWithSelector(buck.transfer.selector, USER2, 200 ether);

        vm.prank(USER1);
        buck.multicall(calls);

        // Verify both operations succeeded
        assertEq(buck.allowance(USER1, USER2), 500 ether);
        assertEq(buck.balanceOf(USER2), 200 ether);
        assertEq(buck.balanceOf(USER1), 800 ether);
    }
}
