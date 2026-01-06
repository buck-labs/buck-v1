// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockAltToken is ERC20 {
    constructor() ERC20("Mock Alt Token", "ALT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title LiquidityReserveUnitTest
 * @notice Comprehensive unit tests for LiquidityReserve to fill coverage gaps
 * @dev Fills missing coverage identified in Sprint 30 testing audit (33% → ~95%)
 */
contract LiquidityReserveUnitTest is BaseTest {
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;
    MockAltToken internal altToken;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant WINDOW = address(0xBEEF);
    address internal constant TREASURER = address(0xCAFE);
    address internal constant USER = address(0xD00D);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant REWARDS_ENGINE = address(0xFEED);

    function setUp() public {
        usdc = new MockUSDC();
        altToken = new MockAltToken();
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), WINDOW, TREASURER);

        // Fund reserve for tests
        usdc.mint(address(reserve), 1_000_000e6);
    }

    // =========================================================================
    // queueWithdrawal() Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: queueWithdrawal() reverts when reserve has insufficient balance
    /// @dev COVERAGE GAP: Tests InsufficientLiquidity error path (line 377)
    function test_QueueWithdrawal_InsufficientBalance() public {
        // Try to withdraw more than reserve holds
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 excessAmount = balance + 1e6; // 1 USDC more than available

        vm.expectRevert(LiquidityReserve.InsufficientLiquidity.selector);
        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, excessAmount);
    }

    /// @notice Test: queueWithdrawal() reverts on zero amount
    /// @dev COVERAGE GAP: Tests InvalidAmount error path (line 288)
    function test_QueueWithdrawal_ZeroAmount() public {
        vm.expectRevert(LiquidityReserve.InvalidAmount.selector);
        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, 0);
    }

    /// @notice Test: queueWithdrawal() reverts on zero address recipient
    function test_QueueWithdrawal_ZeroAddress() public {
        vm.expectRevert(LiquidityReserve.InvalidAddress.selector);
        vm.prank(WINDOW);
        reserve.queueWithdrawal(address(0), 1000e6);
    }

    /// @notice Test: queueWithdrawal() reverts for unauthorized caller
    function test_QueueWithdrawal_UnauthorizedCaller() public {
        vm.expectRevert(LiquidityReserve.NotAuthorized.selector);
        vm.prank(ATTACKER);
        reserve.queueWithdrawal(ATTACKER, 1000e6);
    }

    /// @notice Test: LiquidityWindow can queue instant withdrawals
    function test_QueueWithdrawal_LiquidityWindowInstant() public {
        uint256 amount = 5000e6;
        uint256 userBalanceBefore = usdc.balanceOf(USER);

        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, amount);

        // Should be instant withdrawal (no queue entry)
        assertEq(reserve.withdrawalCount(), 0, "Should not queue for LiquidityWindow");
        assertEq(
            usdc.balanceOf(USER), userBalanceBefore + amount, "User should receive USDC instantly"
        );
    }

    /// @notice Test: Treasurer withdrawals to self are now instant
    function test_QueueWithdrawal_TreasurerToSelfInstant() public {
        uint256 amount = 100_000e6; // Large withdrawal
        uint256 beforeBal = usdc.balanceOf(TREASURER);

        vm.prank(TREASURER);
        reserve.queueWithdrawal(TREASURER, amount);

        // Should be instant (no queue entry)
        assertEq(reserve.withdrawalCount(), 0, "Treasurer should withdraw instantly");
        assertEq(usdc.balanceOf(TREASURER), beforeBal + amount, "Treasurer should receive USDC");
    }

    /// @notice Test: Admin can queue withdrawals
    function test_QueueWithdrawal_AdminCanQueue() public {
        uint256 amount = 50_000e6;

        vm.prank(TIMELOCK); // Admin
        reserve.queueWithdrawal(USER, amount);

        assertEq(reserve.withdrawalCount(), 1, "Admin should be able to queue");
    }

    // =========================================================================
    // recordDeposit() Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: recordDeposit() reverts on zero amount
    /// @dev COVERAGE GAP: Tests InvalidAmount error path (line 258)
    function test_RecordDeposit_ZeroAmount() public {
        vm.expectRevert(LiquidityReserve.InvalidAmount.selector);
        vm.prank(WINDOW);
        reserve.recordDeposit(0);
    }

    /// @notice Test: recordDeposit() works for LiquidityWindow without transfer
    function test_RecordDeposit_LiquidityWindowNoTransfer() public {
        uint256 amount = 10_000e6;

        // Window doesn't transfer (assumes it already has funds)
        vm.prank(WINDOW);
        reserve.recordDeposit(amount);

        // No balance change for reserve (Window didn't transfer)
        assertEq(usdc.balanceOf(address(reserve)), 1_000_000e6, "Balance should not change");
    }

    /// @notice Test: recordDeposit() transfers for non-Window depositors
    function test_RecordDeposit_TreasurerTransfers() public {
        uint256 amount = 50_000e6;
        usdc.mint(TREASURER, amount);

        vm.startPrank(TREASURER);
        usdc.approve(address(reserve), amount);
        reserve.recordDeposit(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(reserve)), 1_050_000e6, "Should transfer from treasurer");
    }

    /// @notice Test: recordDeposit() reverts for unauthorized caller
    function test_RecordDeposit_UnauthorizedCaller() public {
        vm.expectRevert(LiquidityReserve.NotAuthorized.selector);
        vm.prank(ATTACKER);
        reserve.recordDeposit(1000e6);
    }

    // =========================================================================
    // setLiquidityWindow() Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: setLiquidityWindow() reverts for unauthorized caller
    /// @dev COVERAGE GAP: Tests access control (line 188)
    function test_SetLiquidityWindow_UnauthorizedCaller() public {
        address newWindow = address(0x123);

        vm.expectRevert();
        vm.prank(ATTACKER);
        reserve.setLiquidityWindow(newWindow);
    }

    /// @notice Test: setLiquidityWindow() reverts on zero address
    function test_SetLiquidityWindow_ZeroAddress() public {
        vm.expectRevert(LiquidityReserve.InvalidAddress.selector);
        vm.prank(TIMELOCK);
        reserve.setLiquidityWindow(address(0));
    }

    /// @notice Test: setLiquidityWindow() grants roles correctly
    function test_SetLiquidityWindow_GrantsRoles() public {
        address newWindow = address(0x123);

        vm.prank(TIMELOCK);
        reserve.setLiquidityWindow(newWindow);

        // Check DEPOSITOR_ROLE granted
        assertTrue(
            reserve.hasRole(reserve.DEPOSITOR_ROLE(), newWindow), "Should grant DEPOSITOR_ROLE"
        );
        // Check recovery sink set
        assertTrue(reserve.isRecoverySink(newWindow), "Should set recovery sink");
        // Check address updated
        assertEq(reserve.liquidityWindow(), newWindow, "Should update window address");
    }

    /// @notice Test: setLiquidityWindow() revokes roles from old window
    /// @dev Fix for Cyfrin Issue #7 - old window should lose DEPOSITOR_ROLE
    function test_SetLiquidityWindow_RevokesOldWindowRoles() public {
        address oldWindow = address(0x111);
        address newWindow = address(0x222);

        // Set initial window
        vm.prank(TIMELOCK);
        reserve.setLiquidityWindow(oldWindow);

        // Verify old window has roles
        assertTrue(reserve.hasRole(reserve.DEPOSITOR_ROLE(), oldWindow), "Old should have DEPOSITOR_ROLE");
        assertTrue(reserve.isRecoverySink(oldWindow), "Old should be recovery sink");

        // Set new window
        vm.prank(TIMELOCK);
        reserve.setLiquidityWindow(newWindow);

        // Verify old window lost roles
        assertFalse(reserve.hasRole(reserve.DEPOSITOR_ROLE(), oldWindow), "Old should lose DEPOSITOR_ROLE");
        assertFalse(reserve.isRecoverySink(oldWindow), "Old should lose recovery sink");

        // Verify new window has roles
        assertTrue(reserve.hasRole(reserve.DEPOSITOR_ROLE(), newWindow), "New should have DEPOSITOR_ROLE");
        assertTrue(reserve.isRecoverySink(newWindow), "New should be recovery sink");

        // Verify address updated
        assertEq(reserve.liquidityWindow(), newWindow, "Should update to new window");
    }

    // =========================================================================
    // recoverERC20() Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: recoverERC20() reverts when balance is zero
    /// @dev COVERAGE GAP: Tests edge case with zero balance (line 330)
    function test_RecoverERC20_ZeroBalance() public {
        // Try to recover ALT token when reserve has zero balance
        vm.expectRevert(LiquidityReserve.InvalidAmount.selector);
        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(altToken), TREASURER, 0);
    }

    /// @notice Test: recoverERC20() successfully recovers stray tokens
    function test_RecoverERC20_Success() public {
        // Send stray tokens to reserve
        uint256 amount = 1000e18;
        altToken.mint(address(reserve), amount);

        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(altToken), TREASURER, amount);

        assertEq(altToken.balanceOf(TREASURER), amount, "Treasurer should receive recovered tokens");
        assertEq(altToken.balanceOf(address(reserve)), 0, "Reserve should have zero balance");
    }

    /// @notice Test: recoverERC20() reverts when trying to recover USDC
    function test_RecoverERC20_CannotRecoverUSDC() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityReserve.UnsupportedRecoveryAsset.selector, address(usdc)
            )
        );
        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(usdc), TREASURER, 1000e6);
    }

    /// @notice Test: recoverERC20() reverts on invalid recovery sink
    function test_RecoverERC20_InvalidSink() public {
        altToken.mint(address(reserve), 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(LiquidityReserve.InvalidRecoverySink.selector, ATTACKER)
        );
        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(altToken), ATTACKER, 1000e18);
    }

    /// @notice Test: recoverERC20() reverts on zero token address
    function test_RecoverERC20_ZeroTokenAddress() public {
        vm.expectRevert(LiquidityReserve.InvalidAddress.selector);
        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(0), TREASURER, 1000e6);
    }

    /// @notice Test: recoverERC20() reverts for unauthorized caller
    function test_RecoverERC20_UnauthorizedCaller() public {
        altToken.mint(address(reserve), 1000e18);

        vm.expectRevert();
        vm.prank(ATTACKER);
        reserve.recoverERC20(address(altToken), TREASURER, 1000e18);
    }

    // =========================================================================
    // withdrawDistributionSkim() Tests
    // =========================================================================

    /// @notice Test: withdrawDistributionSkim() works for rewards engine
    function test_WithdrawDistributionSkim_Success() public {
        address rewardsEngine = address(0x456);
        address treasury = address(0x789);

        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(rewardsEngine);

        uint256 skimAmount = 5000e6;
        vm.prank(rewardsEngine);
        reserve.withdrawDistributionSkim(treasury, skimAmount);

        assertEq(usdc.balanceOf(treasury), skimAmount, "Treasury should receive skim");
    }

    /// @notice Test: withdrawDistributionSkim() reverts for non-rewards-engine
    function test_WithdrawDistributionSkim_UnauthorizedCaller() public {
        address rewardsEngine = address(0x456);
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(rewardsEngine);

        vm.expectRevert(LiquidityReserve.NotAuthorized.selector);
        vm.prank(ATTACKER);
        reserve.withdrawDistributionSkim(ATTACKER, 1000e6);
    }

    /// @notice Test: withdrawDistributionSkim() reverts on zero amount
    function test_WithdrawDistributionSkim_ZeroAmount() public {
        address rewardsEngine = address(0x456);
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(rewardsEngine);

        vm.expectRevert(LiquidityReserve.InvalidAmount.selector);
        vm.prank(rewardsEngine);
        reserve.withdrawDistributionSkim(TREASURER, 0);
    }

    /// @notice Test: withdrawDistributionSkim() reverts on zero address
    function test_WithdrawDistributionSkim_ZeroAddress() public {
        address rewardsEngine = address(0x456);
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(rewardsEngine);

        vm.expectRevert(LiquidityReserve.InvalidAddress.selector);
        vm.prank(rewardsEngine);
        reserve.withdrawDistributionSkim(address(0), 1000e6);
    }

    // =========================================================================
    // Admin Delay Config Tests
    // =========================================================================

    /// @notice Test: only admin can set admin delay seconds
    function test_SetAdminDelay_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                USER,
                reserve.ADMIN_ROLE()
            )
        );
        vm.prank(USER);
        reserve.setAdminDelaySeconds(6 hours);

        vm.prank(TIMELOCK);
        reserve.setAdminDelaySeconds(6 hours);
        // Queue to verify it applies
        uint64 nowTs = uint64(block.timestamp);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 1_000e6);
        LiquidityReserve.WithdrawalRequest memory req = reserve.getWithdrawal(0);
        assertEq(req.releaseAt, nowTs + 6 hours);
    }

    // =========================================================================
    // Pause/Unpause Tests
    // =========================================================================

    /// @notice Test: pause() blocks withdrawals
    function test_Pause_BlocksWithdrawals() public {
        vm.prank(TIMELOCK);
        reserve.pause();

        vm.expectRevert();
        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, 1000e6);
    }

    /// @notice Test: unpause() restores functionality
    function test_Unpause_RestoresWithdrawals() public {
        // Pause
        vm.prank(TIMELOCK);
        reserve.pause();

        // Unpause
        vm.prank(TIMELOCK);
        reserve.unpause();

        // Should work now
        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, 1000e6);

        assertEq(usdc.balanceOf(USER), 1000e6, "Withdrawal should work after unpause");
    }

    /// @notice Test: pause() reverts for unauthorized caller
    function test_Pause_UnauthorizedCaller() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        reserve.pause();
    }

    // =========================================================================
    // Execute/Cancel Withdrawal Tests
    // =========================================================================

    /// @notice Test: cancelWithdrawal() prevents execution
    /// @dev Uses TIMELOCK (ADMIN) since TREASURER now gets instant withdrawals
    function test_CancelWithdrawal_PreventsExecution() public {
        // Queue withdrawal via ADMIN (TREASURER now instant, ADMIN still queued)
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 100_000e6);

        // Cancel it
        vm.prank(TIMELOCK);
        reserve.cancelWithdrawal(0);

        // Try to execute (now requires ADMIN_ROLE)
        vm.warp(block.timestamp + 37 hours);
        vm.expectRevert(LiquidityReserve.WithdrawalAlreadyProcessed.selector);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
    }

    /// @notice Test: executeWithdrawal() reverts if already executed
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_ExecuteWithdrawal_AlreadyExecuted() public {
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 100_000e6);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        vm.warp(request.releaseAt + 1);

        // Execute once
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);

        // Try again
        vm.expectRevert(LiquidityReserve.WithdrawalAlreadyProcessed.selector);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
    }

    /// @notice Test: executeWithdrawal() reverts if cancelled
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_ExecuteWithdrawal_Cancelled() public {
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 100_000e6);

        vm.prank(TIMELOCK);
        reserve.cancelWithdrawal(0);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        vm.warp(request.releaseAt + 1);

        vm.expectRevert(LiquidityReserve.WithdrawalAlreadyProcessed.selector);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    /// @notice Test: totalLiquidity() returns correct balance
    function test_TotalLiquidity_ReturnsBalance() public view {
        uint256 balance = reserve.totalLiquidity();
        assertEq(balance, 1_000_000e6, "Should return USDC balance");
    }

    /// @notice Test: withdrawalCount() increments correctly
    function test_WithdrawalCount_IncrementsCorrectly() public {
        assertEq(reserve.withdrawalCount(), 0, "Should start at 0");

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 100_000e6);

        assertEq(reserve.withdrawalCount(), 1, "Should increment to 1");

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 200_000e6);

        assertEq(reserve.withdrawalCount(), 2, "Should increment to 2");
    }

    // =========================================================================
    // Flat Admin Delay Tests (24h regardless of amount)
    // =========================================================================

    /// @notice Test: Small withdrawal uses flat 24h delay
    function test_FlatDelay_SmallAmount() public {
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 amount = (balance * 50) / 10_000; // 0.5%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24h delay");
    }

    /// @notice Test: Medium withdrawal uses flat 24h delay
    function test_FlatDelay_MediumAmount() public {
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 amount = (balance * 51) / 10_000; // 0.51%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24 hour delay");
    }

    /// @notice Test: 2% withdrawal uses flat 24h delay
    function test_FlatDelay_TwoPercent() public {
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 amount = (balance * 200) / 10_000; // Exactly 2%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24 hour delay");
    }

    /// @notice Test: Large withdrawal uses flat 24h delay
    function test_FlatDelay_LargeAmount() public {
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 amount = (balance * 201) / 10_000; // 2.01%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24 hour delay");
    }

    /// @notice Test: Full balance withdrawal uses flat 24h delay
    /// @dev Uses TIMELOCK (ADMIN) since TREASURER now gets instant withdrawals
    function test_FlatDelay_FullBalance() public {
        uint256 balance = usdc.balanceOf(address(reserve));

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, balance);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24 hour delay");
    }

    /// @notice Test: Tiny withdrawal uses flat 24h delay
    /// @dev Uses TIMELOCK (ADMIN) since TREASURER now gets instant withdrawals
    function test_FlatDelay_TinyAmount() public {
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 amount = (balance * 1) / 10_000; // 0.01% (1 bps)

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertEq(request.releaseAt, block.timestamp + 24 hours, "Should have 24h delay");
    }

    // =========================================================================
    // Multi-Day Withdrawal Queue Scenarios
    // =========================================================================

    /// @notice Test: Multiple withdrawals queued on different days
    function test_MultiDay_WithdrawalsQueuedAcrossDays() public {
        // Day 1: Queue first withdrawal (24h)
        vm.warp(1000);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 15_000e6);

        LiquidityReserve.WithdrawalRequest memory req1 = reserve.getWithdrawal(0);
        assertEq(req1.releaseAt, 1000 + 24 hours, "First withdrawal should release in 24h");

        // Day 2: Queue second withdrawal (24 hours later)
        vm.warp(1000 + 1 days);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 30_000e6);

        LiquidityReserve.WithdrawalRequest memory req2 = reserve.getWithdrawal(1);
        assertEq(req2.releaseAt, 1000 + 1 days + 24 hours, "Second withdrawal should release in 24h");

        // Day 3: Queue third withdrawal (48 hours after start)
        vm.warp(1000 + 2 days);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 5_000e6);

        LiquidityReserve.WithdrawalRequest memory req3 = reserve.getWithdrawal(2);
        assertEq(req3.releaseAt, 1000 + 2 days + 24 hours, "Third withdrawal should release in 24h");

        // Verify all three are in queue
        assertEq(reserve.withdrawalCount(), 3, "Should have 3 withdrawals");
    }

    /// @notice Test: Execute withdrawal exactly at release time
    function test_MultiDay_ExecuteExactlyAtReleaseTime() public {
        // Queue withdrawal with 12h delay
        vm.warp(1000);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 15_000e6);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        uint256 releaseTime = request.releaseAt;

        // Fast forward to exactly release time
        vm.warp(releaseTime);

        // Should be able to execute (requires ADMIN_ROLE)
        uint256 balanceBefore = usdc.balanceOf(TREASURER);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);

        uint256 balanceAfter = usdc.balanceOf(TREASURER);
        assertEq(balanceAfter - balanceBefore, 15_000e6, "Should receive withdrawal amount");
    }

    /// @notice Test: Cannot execute withdrawal 1 second before release time
    function test_MultiDay_CannotExecute1SecondBeforeRelease() public {
        // Queue withdrawal with 12h delay
        vm.warp(1000);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 15_000e6);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        uint256 releaseTime = request.releaseAt;

        // Fast forward to 1 second before release
        vm.warp(releaseTime - 1);

        // Should revert (requires ADMIN_ROLE)
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityReserve.WithdrawalNotReady.selector, releaseTime)
        );
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
    }

    /// @notice Test: Multiple withdrawals execute only after flat delay
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_MultiDay_DifferentDelaysExecuteInOrder() public {
        vm.warp(1000);

        // Queue 3 withdrawals via ADMIN (all share flat 24h delay)
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 5_000e6); // ID 0

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 15_000e6); // ID 1

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 30_000e6); // ID 2

        // Cannot execute before delay
        vm.expectRevert();
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);

        // Fast forward 24 hours - can execute all
        vm.warp(1000 + 24 hours);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(1);

        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(2);

        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
    }

    /// @notice Test: Advance time multiple days and execute old withdrawals
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_MultiDay_AdvanceMultipleDays() public {
        vm.warp(1000);

        // Queue withdrawal with 36h delay via ADMIN
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 30_000e6);

        // Fast forward 7 days (way past the 36h delay)
        vm.warp(1000 + 7 days);

        // Should still be able to execute (requires ADMIN_ROLE)
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertTrue(request.executed, "Should be marked as executed");
    }

    // =========================================================================
    // Concurrent Withdrawal Edge Cases
    // =========================================================================

    /// @notice Test: Multiple withdrawals queued in same block
    /// @dev Uses TIMELOCK (ADMIN) since TREASURER now gets instant withdrawals
    function test_Concurrent_MultipleWithdrawalsInSameBlock() public {
        vm.warp(1000);

        // Queue 3 withdrawals in the same block (same timestamp) via ADMIN
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 1_000e6); // 0.1%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 2_000e6); // 0.2%

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 3_000e6); // 0.3%

        // All should have same release time (flat delay)
        LiquidityReserve.WithdrawalRequest memory req0 = reserve.getWithdrawal(0);
        LiquidityReserve.WithdrawalRequest memory req1 = reserve.getWithdrawal(1);
        LiquidityReserve.WithdrawalRequest memory req2 = reserve.getWithdrawal(2);

        assertEq(req0.releaseAt, req1.releaseAt, "Should have same release time");
        assertEq(req1.releaseAt, req2.releaseAt, "Should have same release time");
        assertEq(reserve.withdrawalCount(), 3, "Should have 3 withdrawals");
    }

    /// @notice Test: Execute withdrawals in non-sequential order after delay
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_Concurrent_ExecuteNonSequentialOrder() public {
        vm.warp(1000);

        // Queue 3 withdrawals via ADMIN
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 1_000e6); // ID 0

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 2_000e6); // ID 1

        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 3_000e6); // ID 2

        // After flat delay, execute in reverse order: 2, 1, 0
        uint256 balanceBefore = usdc.balanceOf(TREASURER);
        vm.warp(1000 + 24 hours);

        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(2); // Execute ID 2 first

        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(1); // Execute ID 1 second

        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0); // Execute ID 0 last

        uint256 balanceAfter = usdc.balanceOf(TREASURER);
        assertEq(balanceAfter - balanceBefore, 6_000e6, "Should receive all withdrawals");

        // Verify all executed
        assertTrue(reserve.getWithdrawal(0).executed, "ID 0 should be executed");
        assertTrue(reserve.getWithdrawal(1).executed, "ID 1 should be executed");
        assertTrue(reserve.getWithdrawal(2).executed, "ID 2 should be executed");
    }

    /// @notice Test: Cancel one withdrawal while another is ready to execute (different enqueue times)
    /// @dev Uses TIMELOCK (ADMIN) since executeWithdrawal requires ADMIN_ROLE
    function test_Concurrent_CancelOneWhileAnotherReady() public {
        vm.warp(1000);

        // Queue 2 withdrawals via ADMIN at different times so releaseAt differs
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 1_000e6); // ID 0 (release 1000+24h)

        // Warp 12h and queue another (release 1000+12h+24h)
        vm.warp(1000 + 12 hours);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, 2_000e6); // ID 1

        // At t = 1000+24h → ID 0 ready, ID 1 not yet
        vm.warp(1000 + 24 hours);

        // Cancel ID 0 (ready)
        vm.prank(TIMELOCK);
        reserve.cancelWithdrawal(0);

        // Execute ID 1 (should work fine)
        // Not ready yet (release at 1000 + 12h + 24h), expect revert first
        vm.expectRevert();
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(1);

        // Advance to its release and execute
        vm.warp(1000 + 36 hours);
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(1);

        // Verify states
        assertTrue(reserve.getWithdrawal(0).cancelled, "ID 0 should be cancelled");
        assertFalse(reserve.getWithdrawal(0).executed, "ID 0 should not be executed");
        assertTrue(reserve.getWithdrawal(1).executed, "ID 1 should be executed");
        assertFalse(reserve.getWithdrawal(1).cancelled, "ID 1 should not be cancelled");
    }

    /// @notice Test: Multiple admin withdrawals in same block share same release time (flat delay)
    function test_Concurrent_MultipleSameTierWithdrawals() public {
        vm.warp(1000);

        // Queue 5 withdrawals (flat 24h delay)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(TIMELOCK);
            reserve.queueWithdrawal(TREASURER, 10_000e6);
        }

        // All should have same release time
        uint256 expectedRelease = 1000 + 24 hours;
        for (uint256 i = 0; i < 5; i++) {
            LiquidityReserve.WithdrawalRequest memory req = reserve.getWithdrawal(i);
            assertEq(req.releaseAt, expectedRelease, "All should release at same time");
        }

        // Fast forward and execute all (requires ADMIN_ROLE)
        vm.warp(expectedRelease);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(TIMELOCK);
            reserve.executeWithdrawal(i);
        }

        // Verify all executed
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(reserve.getWithdrawal(i).executed, "Should be executed");
        }
    }

    // =========================================================================
    // Skim Withdrawal Boundary Conditions
    // =========================================================================

    /// @notice Test: Skim withdrawal exactly equal to reserve balance
    function test_Skim_ExactlyEqualToBalance() public {
        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(REWARDS_ENGINE);

        uint256 balance = usdc.balanceOf(address(reserve));

        // Withdraw exactly the full balance
        vm.prank(REWARDS_ENGINE);
        reserve.withdrawDistributionSkim(TREASURER, balance);

        // Reserve should be empty
        assertEq(usdc.balanceOf(address(reserve)), 0, "Reserve should be empty");
        assertEq(usdc.balanceOf(TREASURER), balance, "Treasurer should have full balance");
    }

    /// @notice Test: Skim withdrawal greater than balance reverts
    function test_Skim_GreaterThanBalance() public {
        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(REWARDS_ENGINE);

        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 overAmount = balance + 1e6;

        vm.expectRevert(LiquidityReserve.InsufficientLiquidity.selector);
        vm.prank(REWARDS_ENGINE);
        reserve.withdrawDistributionSkim(TREASURER, overAmount);
    }

    /// @notice Test: Skim withdrawal respects pause
    function test_Skim_RespectsaPause() public {
        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(REWARDS_ENGINE);

        // Pause the reserve
        vm.prank(TIMELOCK);
        reserve.pause();

        // Skim withdrawal should revert
        vm.expectRevert();
        vm.prank(REWARDS_ENGINE);
        reserve.withdrawDistributionSkim(TREASURER, 1_000e6);
    }

    /// @notice Test: Skim withdrawal works after unpause
    function test_Skim_WorksAfterUnpause() public {
        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(REWARDS_ENGINE);

        // Pause then unpause
        vm.prank(TIMELOCK);
        reserve.pause();

        vm.prank(TIMELOCK);
        reserve.unpause();

        // Skim withdrawal should work
        vm.prank(REWARDS_ENGINE);
        reserve.withdrawDistributionSkim(TREASURER, 1_000e6);

        assertEq(usdc.balanceOf(TREASURER), 1_000e6, "Should receive skim");
    }

    /// @notice Test: Multiple consecutive skim withdrawals
    function test_Skim_MultipleConsecutiveWithdrawals() public {
        // Set rewards engine
        vm.prank(TIMELOCK);
        reserve.setRewardsEngine(REWARDS_ENGINE);

        uint256 initialBalance = usdc.balanceOf(address(reserve));

        // Perform 5 consecutive skims
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(REWARDS_ENGINE);
            reserve.withdrawDistributionSkim(TREASURER, 10_000e6);
        }

        // Verify total withdrawn
        uint256 finalBalance = usdc.balanceOf(address(reserve));
        assertEq(initialBalance - finalBalance, 50_000e6, "Should withdraw 50k USDC total");
        assertEq(usdc.balanceOf(TREASURER), 50_000e6, "Treasurer should have 50k USDC");
    }

    // =========================================================================
    // Admin flat delay tests
    // =========================================================================

    /// @notice Admin can set flat delay and queued withdrawals honor it
    function test_AdminDelay_ConfigAndEnqueue() public {
        // Set to 24h (default already 24h, but change to 12h then back to test setter)
        vm.prank(TIMELOCK);
        reserve.setAdminDelaySeconds(12 hours);
        vm.prank(TIMELOCK);
        reserve.setAdminDelaySeconds(24 hours);

        uint256 amount = 10_000e6;
        uint64 nowTs = uint64(block.timestamp);
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(USER, amount);
        LiquidityReserve.WithdrawalRequest memory req = reserve.getWithdrawal(0);
        assertEq(req.enqueuedAt, nowTs, "enqueuedAt should equal now");
        assertEq(req.releaseAt, nowTs + 24 hours, "releaseAt should equal now + delay");
    }
}
