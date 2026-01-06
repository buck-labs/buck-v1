// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract LiquidityReserveTest is BaseTest {
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant WINDOW = address(0xBEEF);
    address internal constant TREASURER = address(0xCAFE);
    address internal constant USER = address(0xD00D);

    function setUp() public {
        usdc = new MockUSDC();
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), WINDOW, TREASURER); // admin role

        // Pre-fund vault for instant withdrawals.
        usdc.mint(address(reserve), 1_000_000e6);
    }

    function testRecordDepositByTreasurerTransfers() public {
        uint256 amount = 50_000e6;

        usdc.mint(TREASURER, amount);

        vm.startPrank(TREASURER);
        usdc.approve(address(reserve), amount);
        reserve.recordDeposit(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(reserve)), 1_050_000e6);
    }

    function testRecordDepositUnauthorizedReverts() public {
        vm.expectRevert(LiquidityReserve.NotAuthorized.selector);
        reserve.recordDeposit(1);
    }

    function testInstantWithdrawalForLiquidityWindow() public {
        uint256 amount = 10_000e6;
        vm.prank(WINDOW);
        reserve.queueWithdrawal(USER, amount);

        assertEq(usdc.balanceOf(USER), amount);
        assertEq(usdc.balanceOf(address(reserve)), 1_000_000e6 - amount);
        assertEq(reserve.withdrawalCount(), 0);
    }

    function testTreasuryWithdrawalInstantForTreasurer() public {
        uint256 amount = 200_000e6;
        uint256 beforeBal = usdc.balanceOf(TREASURER);
        vm.prank(TREASURER);
        reserve.queueWithdrawal(TREASURER, amount);
        // Instant path: no queue entry, funds transferred immediately
        assertEq(reserve.withdrawalCount(), 0);
        assertEq(usdc.balanceOf(TREASURER), beforeBal + amount);
    }

    // Removed: treasurer withdrawals are instant; no queued delay remains

    function testExecuteWithdrawalRequiresAdminRole() public {
        uint256 amount = 100_000e6;
        // Queue by admin so it is not instant
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        vm.warp(request.releaseAt + 1);

        // Non-ADMIN_ROLE account cannot call executeWithdrawal()
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                USER,
                reserve.ADMIN_ROLE()
            )
        );
        vm.prank(USER);
        reserve.executeWithdrawal(0);

        // ADMIN_ROLE (TIMELOCK in setup) can call executeWithdrawal()
        vm.prank(TIMELOCK);
        reserve.executeWithdrawal(0);
        assertTrue(reserve.getWithdrawal(0).executed);
    }

    function testTreasurerRoleCannotCallAdminFunctions() public {
        address treasurer2 = address(0xCAFE2);

        // Grant TREASURER_ROLE to a new user (but not ADMIN_ROLE)
        bytes32 treasurerRole = reserve.TREASURER_ROLE();
        vm.prank(TIMELOCK);
        reserve.grantRole(treasurerRole, treasurer2);

        // TREASURER_ROLE cannot call admin functions like setAdminDelaySeconds()
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                treasurer2,
                reserve.ADMIN_ROLE()
            )
        );
        vm.prank(treasurer2);
        reserve.setAdminDelaySeconds(6 hours);
    }

    function testTreasurerBypassesWithdrawalTiersNowInstant() public {
        uint256 largeAmount = 200_000e6;
        uint256 beforeBal = usdc.balanceOf(TREASURER);
        vm.prank(TREASURER);
        reserve.queueWithdrawal(TREASURER, largeAmount);
        assertEq(reserve.withdrawalCount(), 0, "No queue for treasurer");
        assertEq(usdc.balanceOf(TREASURER), beforeBal + largeAmount, "Instant withdrawal");
    }

    function testCancelByTimelock() public {
        uint256 amount = 50_000e6;
        vm.prank(TIMELOCK);
        reserve.queueWithdrawal(TREASURER, amount);

        vm.prank(TIMELOCK);
        reserve.cancelWithdrawal(0);

        LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(0);
        assertTrue(request.cancelled);
    }

    // -------------------------------------------------------------------------
    // Recovery admin
    // -------------------------------------------------------------------------

    function testRecoverERC20HappyPath() public {
        MockAltToken extra = new MockAltToken();
        extra.mint(address(reserve), 1_000e18);

        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(extra), TREASURER, 750e18);

        assertEq(extra.balanceOf(TREASURER), 750e18);
        assertEq(extra.balanceOf(address(reserve)), 250e18);
    }

    function testRecoverERC20BlockedAsset() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityReserve.UnsupportedRecoveryAsset.selector, address(usdc)
            )
        );
        vm.prank(TIMELOCK);
        reserve.recoverERC20(address(usdc), TREASURER, 1);
    }

    function testRecoverERC20UnauthorizedCaller() public {
        MockAltToken extra = new MockAltToken();
        extra.mint(address(reserve), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, USER, reserve.ADMIN_ROLE()
            )
        );
        vm.prank(USER);
        reserve.recoverERC20(address(extra), TREASURER, 10e18);
    }
}
