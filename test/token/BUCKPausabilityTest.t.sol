// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Mock KYC Registry
contract MockAccessRegistry {
    mapping(address => bool) public allowed;
    mapping(address => bool) public isDenylisted;

    function isAllowed(address account) external view returns (bool) {
        return allowed[account];
    }

    function setAllowed(address account, bool status) external {
        allowed[account] = status;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

// Mock Rewards Hook
contract MockRewardsHook {
    function onBalanceChange(address, address, uint256) external {}
}

/// @title STRCPausabilityTest
/// @notice Tests for STRC token pausability functionality
contract BUCKPausabilityTest is BaseTest {
    Buck public buck;
    MockAccessRegistry public accessRegistry;
    MockRewardsHook public rewardsHook;

    address constant TIMELOCK = address(0x1000);
    address constant LIQUIDITY_WINDOW = address(0x2000);
    address constant LIQUIDITY_RESERVE = address(0x3000);
    address constant TREASURY = address(0x4000);
    address constant POLICY_MANAGER = address(0x5000);
    address constant USER1 = address(0x8001);
    address constant USER2 = address(0x8002);

    event Paused(address account);
    event Unpaused(address account);

    // Pausable errors from OpenZeppelin
    error EnforcedPause();
    error ExpectedPause();

    function setUp() public {
        // Deploy mocks
        accessRegistry = new MockAccessRegistry();
        rewardsHook = new MockRewardsHook();

        // Deploy STRC
        buck = deployBUCK(TIMELOCK);

        // Configure modules
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            address(accessRegistry),
            address(rewardsHook)
        );

        // KYC the users
        accessRegistry.setAllowed(USER1, true);
        accessRegistry.setAllowed(USER2, true);

        // Mint some tokens to users for testing
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 1000e18);
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER2, 1000e18);
    }

    // -------------------------------------------------------------------------
    // Pause/Unpause Authorization Tests
    // -------------------------------------------------------------------------

    function testOnlyTimelockCanPause() public {
        // Non-timelock should fail
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER1));
        buck.pause();

        // Timelock should succeed
        vm.prank(TIMELOCK);
        buck.pause();
        assertTrue(buck.paused());
    }

    function testOnlyTimelockCanUnpause() public {
        // First pause
        vm.prank(TIMELOCK);
        buck.pause();

        // Non-timelock should fail to unpause
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER1));
        buck.unpause();

        // Timelock should succeed
        vm.prank(TIMELOCK);
        buck.unpause();
        assertFalse(buck.paused());
    }

    // -------------------------------------------------------------------------
    // Transfer Pausability Tests
    // -------------------------------------------------------------------------

    function testTransferFailsWhenPaused() public {
        // Pause the token
        vm.prank(TIMELOCK);
        buck.pause();

        // Transfer should fail
        vm.prank(USER1);
        vm.expectRevert(EnforcedPause.selector);
        buck.transfer(USER2, 100e18);
    }

    function testTransferFromFailsWhenPaused() public {
        // Setup approval
        vm.prank(USER1);
        buck.approve(USER2, 100e18);

        // Pause the token
        vm.prank(TIMELOCK);
        buck.pause();

        // TransferFrom should fail
        vm.prank(USER2);
        vm.expectRevert(EnforcedPause.selector);
        buck.transferFrom(USER1, USER2, 100e18);
    }

    function testTransferWorksAfterUnpause() public {
        uint256 user1BalBefore = buck.balanceOf(USER1);
        uint256 user2BalBefore = buck.balanceOf(USER2);

        // Pause
        vm.prank(TIMELOCK);
        buck.pause();

        // Transfer fails when paused
        vm.prank(USER1);
        vm.expectRevert(EnforcedPause.selector);
        buck.transfer(USER2, 100e18);

        // Unpause
        vm.prank(TIMELOCK);
        buck.unpause();

        // Transfer works after unpause
        vm.prank(USER1);
        assertTrue(buck.transfer(USER2, 100e18));

        // Verify balances
        assertEq(buck.balanceOf(USER1), user1BalBefore - 100e18);
        assertEq(buck.balanceOf(USER2), user2BalBefore + 100e18);
    }

    // -------------------------------------------------------------------------
    // Mint/Burn Pausability Tests
    // -------------------------------------------------------------------------

    function testMintFailsWhenPaused() public {
        // Pause the token
        vm.prank(TIMELOCK);
        buck.pause();

        // Mint should fail
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(EnforcedPause.selector);
        buck.mint(USER1, 100e18);
    }

    function testBurnFailsWhenPaused() public {
        // Pause the token
        vm.prank(TIMELOCK);
        buck.pause();

        // Burn should fail
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(EnforcedPause.selector);
        buck.burn(USER1, 100e18);
    }

    function testMintWorksAfterUnpause() public {
        uint256 balBefore = buck.balanceOf(USER1);

        // Pause
        vm.prank(TIMELOCK);
        buck.pause();

        // Mint fails when paused
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(EnforcedPause.selector);
        buck.mint(USER1, 100e18);

        // Unpause
        vm.prank(TIMELOCK);
        buck.unpause();

        // Mint works after unpause
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER1, 100e18);

        assertEq(buck.balanceOf(USER1), balBefore + 100e18);
    }

    // -------------------------------------------------------------------------
    // Allowance Operations During Pause
    // -------------------------------------------------------------------------

    function testApproveWorksWhenPaused() public {
        // Initial approval
        vm.prank(USER1);
        buck.approve(USER2, 50e18);
        assertEq(buck.allowance(USER1, USER2), 50e18);

        // Pause the token
        vm.prank(TIMELOCK);
        buck.pause();

        // Approve (change allowance) should still work when paused
        vm.prank(USER1);
        assertTrue(buck.approve(USER2, 100e18));
        assertEq(buck.allowance(USER1, USER2), 100e18);

        // Can also reduce allowance
        vm.prank(USER1);
        assertTrue(buck.approve(USER2, 25e18));
        assertEq(buck.allowance(USER1, USER2), 25e18);
    }

    // -------------------------------------------------------------------------
    // Event Emission Tests
    // -------------------------------------------------------------------------

    function testPauseEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(TIMELOCK);

        vm.prank(TIMELOCK);
        buck.pause();
    }

    function testUnpauseEmitsEvent() public {
        // First pause
        vm.prank(TIMELOCK);
        buck.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(TIMELOCK);

        vm.prank(TIMELOCK);
        buck.unpause();
    }

    // -------------------------------------------------------------------------
    // State Consistency Tests
    // -------------------------------------------------------------------------

    function testPauseStateConsistency() public {
        // Initially not paused
        assertFalse(buck.paused());

        // Pause
        vm.prank(TIMELOCK);
        buck.pause();
        assertTrue(buck.paused());

        // Unpause
        vm.prank(TIMELOCK);
        buck.unpause();
        assertFalse(buck.paused());
    }

    function testDoublePauseReverts() public {
        // First pause
        vm.prank(TIMELOCK);
        buck.pause();
        assertTrue(buck.paused());

        // Second pause should revert with EnforcedPause
        vm.prank(TIMELOCK);
        vm.expectRevert(EnforcedPause.selector);
        buck.pause();
    }

    function testDoubleUnpauseReverts() public {
        // Pause
        vm.prank(TIMELOCK);
        buck.pause();

        // First unpause
        vm.prank(TIMELOCK);
        buck.unpause();
        assertFalse(buck.paused());

        // Second unpause should revert with ExpectedPause
        vm.prank(TIMELOCK);
        vm.expectRevert(ExpectedPause.selector);
        buck.unpause();
    }

    // -------------------------------------------------------------------------
    // Configuration During Pause Tests
    // -------------------------------------------------------------------------

    function testConfigurationWorksWhenPaused() public {
        // Pause
        vm.prank(TIMELOCK);
        buck.pause();

        // Configuration should still work
        // Note: DEX fees now on PolicyManager, test only fee split configuration
        vm.prank(TIMELOCK);
        buck.setFeeSplit(8000);
        assertEq(buck.feeToReservePct(), 8000);
    }

    // -------------------------------------------------------------------------
    // Emergency Scenario Test
    // -------------------------------------------------------------------------

    function testEmergencyPauseScenario() public {
        // Simulate normal operation
        vm.prank(USER1);
        buck.transfer(USER2, 10e18);

        // EMERGENCY: Pause all operations
        vm.prank(TIMELOCK);
        buck.pause();

        // Verify no transfers possible
        vm.prank(USER1);
        vm.expectRevert(EnforcedPause.selector);
        buck.transfer(USER2, 10e18);

        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(EnforcedPause.selector);
        buck.mint(USER1, 100e18);

        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(EnforcedPause.selector);
        buck.burn(USER1, 10e18);

        // After emergency resolved, unpause
        vm.prank(TIMELOCK);
        buck.unpause();

        // Verify operations resume
        vm.prank(USER1);
        assertTrue(buck.transfer(USER2, 10e18));
    }
}
