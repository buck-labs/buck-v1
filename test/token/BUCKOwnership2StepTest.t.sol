// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BUCKOwnership2StepTest
/// @notice Comprehensive tests for Ownable2Step ownership transfer functionality
/// @dev Tests two-step ownership transfer pattern for security
contract BUCKOwnership2StepTest is BaseTest {
    Buck public buck;

    address constant TIMELOCK = address(0x1000);
    address constant NEW_OWNER = address(0x2000);
    address constant ATTACKER = address(0x3000);
    address constant LIQUIDITY_WINDOW = address(0x4000);
    address constant LIQUIDITY_RESERVE = address(0x5000);
    address constant TREASURY = address(0x6000);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
    }

    // =========================================================================
    // OWNERSHIP TRANSFER INITIATION TESTS
    // =========================================================================

    function testTransferOwnershipSetssPendingOwner() public {
        assertEq(buck.owner(), TIMELOCK);
        assertEq(buck.pendingOwner(), address(0));

        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        // Owner should remain unchanged
        assertEq(buck.owner(), TIMELOCK);
        // Pending owner should be set
        assertEq(buck.pendingOwner(), NEW_OWNER);
    }

    function testTransferOwnershipEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(TIMELOCK, NEW_OWNER);

        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);
    }

    function testOnlyOwnerCanInitiateTransfer() public {
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER)
        );
        buck.transferOwnership(NEW_OWNER);

        // Pending owner cannot initiate transfer
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.transferOwnership(ATTACKER);
    }

    function testTransferOwnershipToZeroAddressIsAllowed() public {
        // NOTE: Ownable2Step allows transferring to zero address as a way to renounce
        // This is different from Ownable which prevents zero address transfers
        vm.prank(TIMELOCK);
        buck.transferOwnership(address(0));

        assertEq(buck.pendingOwner(), address(0));
        assertEq(buck.owner(), TIMELOCK); // Owner doesn't change until accepted
    }

    // =========================================================================
    // OWNERSHIP ACCEPTANCE TESTS
    // =========================================================================

    function testAcceptOwnershipCompletesTransfer() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        assertEq(buck.owner(), TIMELOCK);
        assertEq(buck.pendingOwner(), NEW_OWNER);

        // Accept ownership as new owner
        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        assertEq(buck.owner(), NEW_OWNER);
        assertEq(buck.pendingOwner(), address(0));
    }

    function testAcceptOwnershipEmitsEvent() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(TIMELOCK, NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();
    }

    function testOnlyPendingOwnerCanAccept() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        // Random attacker cannot accept
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER)
        );
        buck.acceptOwnership();

        // Old owner cannot accept (no longer pending)
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TIMELOCK)
        );
        buck.acceptOwnership();
    }

    function testCannotAcceptOwnershipWhenNotPending() public {
        // No pending ownership transfer
        assertEq(buck.pendingOwner(), address(0));

        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.acceptOwnership();
    }

    // =========================================================================
    // PENDING OWNER RESTRICTIONS TESTS
    // =========================================================================

    function testPendingOwnerCannotCallOwnerFunctions() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        // Pending owner cannot configure modules
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.configureModules(
            LIQUIDITY_WINDOW, LIQUIDITY_RESERVE, TREASURY, address(0), address(0), address(0)
        );

        // Pending owner cannot pause
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.pause();

        // Pending owner cannot set fee split
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.setFeeSplit(5000);
    }

    function testOldOwnerCanStillCallFunctionsBeforeAcceptance() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        // Old owner can still call owner functions before acceptance
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW, LIQUIDITY_RESERVE, TREASURY, address(0), address(0), address(0)
        );

        assertEq(buck.liquidityWindow(), LIQUIDITY_WINDOW);
    }

    function testNewOwnerCanCallFunctionsAfterAcceptance() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        // New owner can now call owner functions
        vm.prank(NEW_OWNER);
        buck.setFeeSplit(7500);

        assertEq(buck.feeToReservePct(), 7500);
    }

    function testOldOwnerCannotCallFunctionsAfterAcceptance() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        // Old owner can no longer call owner functions
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TIMELOCK)
        );
        buck.setFeeSplit(5000);
    }

    // =========================================================================
    // OWNERSHIP TRANSFER CANCELLATION TESTS
    // =========================================================================

    function testOwnerCanCancelTransferByTransferringToSelf() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        assertEq(buck.pendingOwner(), NEW_OWNER);

        // Owner transfers to self to cancel
        vm.prank(TIMELOCK);
        buck.transferOwnership(TIMELOCK);

        // Pending owner should be set to timelock (effectively cancelling)
        assertEq(buck.pendingOwner(), TIMELOCK);
        assertEq(buck.owner(), TIMELOCK);
    }

    function testOwnerCanChangeTargetBeforeAcceptance() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        assertEq(buck.pendingOwner(), NEW_OWNER);

        // Owner changes mind and transfers to different address
        address newTarget = address(0x7777);
        vm.prank(TIMELOCK);
        buck.transferOwnership(newTarget);

        assertEq(buck.pendingOwner(), newTarget);

        // Original pending owner can no longer accept
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.acceptOwnership();

        // New target can accept
        vm.prank(newTarget);
        buck.acceptOwnership();

        assertEq(buck.owner(), newTarget);
    }

    // =========================================================================
    // RENOUNCE OWNERSHIP TESTS
    // =========================================================================

    /// @notice Verify renounceOwnership is disabled to prevent accidental lockout
    function testRenounceOwnershipIsDisabled() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.RenounceOwnershipDisabled.selector);
        buck.renounceOwnership();

        // Owner should remain unchanged
        assertEq(buck.owner(), TIMELOCK);
    }

    /// @notice Verify even non-owners get the disabled error (not unauthorized)
    function testRenounceOwnershipDisabledForEveryone() public {
        vm.prank(ATTACKER);
        vm.expectRevert(Buck.RenounceOwnershipDisabled.selector);
        buck.renounceOwnership();

        vm.prank(NEW_OWNER);
        vm.expectRevert(Buck.RenounceOwnershipDisabled.selector);
        buck.renounceOwnership();
    }

    // =========================================================================
    // COMPLEX OWNERSHIP SCENARIOS
    // =========================================================================

    function testMultipleOwnershipTransfers() public {
        // First transfer
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        assertEq(buck.owner(), NEW_OWNER);

        // Second transfer
        address secondOwner = address(0x8888);
        vm.prank(NEW_OWNER);
        buck.transferOwnership(secondOwner);

        vm.prank(secondOwner);
        buck.acceptOwnership();

        assertEq(buck.owner(), secondOwner);

        // Third transfer
        address thirdOwner = address(0x9999);
        vm.prank(secondOwner);
        buck.transferOwnership(thirdOwner);

        vm.prank(thirdOwner);
        buck.acceptOwnership();

        assertEq(buck.owner(), thirdOwner);
    }

    function testOwnershipTransferDuringEmergency() public {
        // Setup modules
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW, LIQUIDITY_RESERVE, TREASURY, address(0), address(0), address(0)
        );

        // Emergency: pause contract
        vm.prank(TIMELOCK);
        buck.pause();

        // Owner can still transfer ownership while paused
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        assertEq(buck.owner(), NEW_OWNER);

        // New owner can unpause
        vm.prank(NEW_OWNER);
        buck.unpause();

        assertFalse(buck.paused());
    }

    function testOwnershipTransferDuringProductionMode() public {
        // Setup for production mode
        vm.startPrank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW, LIQUIDITY_RESERVE, TREASURY, address(0), address(0), address(0)
        );
        buck.enableProductionMode();
        vm.stopPrank();

        assertTrue(buck.productionMode());

        // Ownership can still be transferred in production mode
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        vm.prank(NEW_OWNER);
        buck.acceptOwnership();

        assertEq(buck.owner(), NEW_OWNER);

        // New owner still bound by production mode rules
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Buck.CriticalAddressCannotBeZero.selector, "liquidityWindow")
        );
        buck.configureModules(
            address(0), // Cannot set to zero in production mode
            LIQUIDITY_RESERVE,
            TREASURY,
            address(0),
            address(0),
            address(0)
        );
    }

    // =========================================================================
    // EDGE CASES
    // =========================================================================

    function testTransferOwnershipToCurrentOwner() public {
        vm.prank(TIMELOCK);
        buck.transferOwnership(TIMELOCK);

        // Pending owner set to current owner (effectively no-op)
        assertEq(buck.pendingOwner(), TIMELOCK);
        assertEq(buck.owner(), TIMELOCK);

        // Current owner can "accept" to clear pending
        vm.prank(TIMELOCK);
        buck.acceptOwnership();

        assertEq(buck.owner(), TIMELOCK);
        assertEq(buck.pendingOwner(), address(0));
    }

    function testPendingOwnerGetsOverwritten() public {
        // First transfer
        vm.prank(TIMELOCK);
        buck.transferOwnership(NEW_OWNER);

        assertEq(buck.pendingOwner(), NEW_OWNER);

        // Owner changes mind immediately
        address differentOwner = address(0xAAAA);
        vm.prank(TIMELOCK);
        buck.transferOwnership(differentOwner);

        // Pending owner overwritten
        assertEq(buck.pendingOwner(), differentOwner);

        // Original pending owner cannot accept
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER)
        );
        buck.acceptOwnership();
    }
}
