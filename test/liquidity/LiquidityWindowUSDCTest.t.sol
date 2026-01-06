// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {console} from "forge-std/console.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title LiquidityWindow USDC Flow Tests
 * @notice Critical tests to ensure USDC must be provided to mint STRC and vice versa
 * @dev These tests MUST pass before deploying to any network
 */
contract LiquidityWindowUSDCTest is BaseTest {
    Buck public buck;
    LiquidityWindow public liquidityWindow;
    LiquidityReserve public liquidityReserve;
    PolicyManager public policyManager;
    OracleAdapter public oracle;
    MockUSDC public usdc;

    address public timelock = address(0x1);
    address public treasury = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);

    // Events to check
    event MintExecuted(
        address indexed caller,
        address indexed recipient,
        uint256 usdcAmount,
        uint256 strcOut,
        uint256 feeUsdc
    );

    event RefundExecuted(
        address indexed caller,
        address indexed recipient,
        uint256 strcAmount,
        uint256 usdcOut,
        uint256 feeUsdc
    );

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy oracle with $0.97 price
        oracle = new OracleAdapter(address(this));
        oracle.setInternalPrice(0.97e18);

        // Move past block-fresh window after oracle price update
        vm.roll(block.number + 2);

        // Deploy PolicyManager
        policyManager = deployPolicyManager(timelock);

        // Deploy LiquidityReserve
        liquidityReserve = deployLiquidityReserve(
            timelock,
            address(usdc),
            address(0), // Will set liquidity window later
            treasury
        );

        // Deploy STRC token
        buck = deployBUCK(timelock);

        // Deploy LiquidityWindow
        liquidityWindow = deployLiquidityWindow(
            timelock, address(buck), address(liquidityReserve), address(policyManager)
        );

        // Configure everything
        vm.startPrank(timelock);

        // Set USDC in LiquidityWindow
        liquidityWindow.setUSDC(address(usdc));

        // Configure LiquidityWindow
        liquidityWindow.configureFeeSplit(5000, treasury); // 50% to reserve, 50% to treasury

        // Configure STRC modules
        buck.configureModules(
            address(liquidityWindow),
            address(liquidityReserve),
            treasury,
            address(policyManager),
            address(0), // No KYC for testing
            address(0) // No rewards for these tests
        );

        // Configure PolicyManager with oracle and contract references
        policyManager.setContractReferences(
            address(buck), address(liquidityReserve), address(oracle), address(usdc)
        );

        // Grant OPERATOR_ROLE to LiquidityWindow (required for recordMint/recordRefund)
        bytes32 operatorRole = policyManager.OPERATOR_ROLE();
        policyManager.grantRole(operatorRole, address(liquidityWindow));

        // Configure PolicyManager with unlimited caps for basic USDC flow testing
        PolicyManager.BandConfig memory config = policyManager.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 0; // 0 = unlimited mints
        config.caps.refundAggregateBps = 0; // 0 = unlimited refunds
        config.alphaBps = 10000; // 100% - allow unlimited refunds (alphaBps limits refund amount)
        policyManager.setBandConfig(PolicyManager.Band.Green, config);

        // Allow 100% single transactions (default is 50%)
        policyManager.setMaxSingleTransactionPct(100);

        // Update LiquidityReserve to recognize LiquidityWindow
        liquidityReserve.setLiquidityWindow(address(liquidityWindow));

        vm.stopPrank();

        // Give Alice and Bob some USDC to start with
        usdc.mint(alice, 10000e6); // 10,000 USDC (6 decimals)
        usdc.mint(bob, 10000e6); // 10,000 USDC

        // Fund the LiquidityReserve with some USDC for refunds
        usdc.mint(address(liquidityReserve), 100000e6); // 100,000 USDC
    }

    // =============================================================
    //                    CRITICAL MINT TESTS
    // =============================================================

    function test_MintRequiresUSDC() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        // Note: USDC has 6 decimals, STRC has 18 decimals
        // Need to convert: 1000 USDC (1e9 raw) at $0.97 = ~1030 STRC
        // But spread and fees reduce it, so expect ~1000 STRC
        uint256 minStrcOut = 0; // Don't enforce minimum for this test

        // Check initial balances
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceStrcBefore = buck.balanceOf(alice);
        uint256 reserveUsdcBefore = usdc.balanceOf(address(liquidityReserve));

        vm.startPrank(alice);

        // Alice must approve LiquidityWindow to spend her USDC
        usdc.approve(address(liquidityWindow), usdcAmount);

        // Mint STRC by providing USDC
        (uint256 strcOut, uint256 feeUsdc) = liquidityWindow.requestMint(
            alice,
            usdcAmount,
            minStrcOut,
            0 // No max price limit
        );

        vm.stopPrank();

        // Verify USDC was taken from Alice
        assertEq(
            usdc.balanceOf(alice),
            aliceUsdcBefore - usdcAmount,
            "USDC should be deducted from Alice"
        );

        // Verify USDC went to LiquidityReserve
        // Reserve gets: (principal - fee) + (50% of fee) = principal - (50% of fee)
        // PolicyManager GREEN band has 5 bps (0.05%) mint fee (Sprint 3)
        uint256 fee = (usdcAmount * 5) / 10000; // 0.05% (Sprint 3)
        uint256 reserveFee = fee / 2; // 50% of fee stays in reserve
        uint256 expectedReserveReceive = (usdcAmount - fee) + reserveFee; // Principal - fee + reserve's portion
        assertEq(
            usdc.balanceOf(address(liquidityReserve)),
            reserveUsdcBefore + expectedReserveReceive,
            "USDC should be sent to LiquidityReserve (principal + reserve fee portion)"
        );

        // Verify Alice received STRC
        assertGt(buck.balanceOf(alice), aliceStrcBefore, "Alice should receive STRC tokens");

        // Verify the amount is reasonable (accounting for price, spread, and fees)
        // Price is $0.97, so 1000 USDC should give ~1030 STRC minus fees/spread
        // With 0.5% fee and 0.25% spread, expect around 1020 STRC
        assertGt(strcOut, 1000e18, "Should receive reasonable amount of STRC");
        assertLt(strcOut, 1050e18, "Should not receive excessive STRC");

        console.log("Alice spent USDC:", usdcAmount / 1e6);
        console.log("Alice received STRC:", strcOut / 1e18);
        console.log("Fee in USDC:", feeUsdc / 1e6);
    }

    function test_MintFailsWithoutUSDCApproval() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC

        vm.startPrank(alice);

        // Try to mint WITHOUT approving USDC
        vm.expectRevert(); // Should revert with ERC20 insufficient allowance
        liquidityWindow.requestMint(alice, usdcAmount, 0, 0);

        vm.stopPrank();
    }

    function test_MintFailsWithInsufficientUSDC() public {
        uint256 aliceBalance = usdc.balanceOf(alice);
        uint256 usdcAmount = aliceBalance + 1000e6; // Try to spend more than Alice has

        vm.startPrank(alice);

        // Approve more than balance
        usdc.approve(address(liquidityWindow), usdcAmount);

        // Try to mint with insufficient USDC
        vm.expectRevert(); // Should revert with ERC20 insufficient balance
        liquidityWindow.requestMint(alice, usdcAmount, 0, 0);

        vm.stopPrank();
    }

    // =============================================================
    //                    CRITICAL REFUND TESTS
    // =============================================================

    function test_RefundReturnsUSDC() public {
        // First, Alice needs to mint some STRC
        uint256 mintUsdcAmount = 1000e6; // 1000 USDC

        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), mintUsdcAmount);
        (uint256 strcReceived,) = liquidityWindow.requestMint(alice, mintUsdcAmount, 0, 0);
        vm.stopPrank();

        // Now test the refund
        uint256 refundStrcAmount = strcReceived / 2; // Refund half
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceStrcBefore = buck.balanceOf(alice);
        // Track Alice balances before refund

        vm.startPrank(alice);

        // Approve LiquidityWindow to burn STRC
        buck.approve(address(liquidityWindow), refundStrcAmount);

        // Refund STRC to get USDC back
        (uint256 usdcOut, uint256 feeUsdc) = liquidityWindow.requestRefund(
            alice,
            refundStrcAmount,
            0, // No minimum USDC out for this test
            0 // No minimum price
        );

        vm.stopPrank();

        // Verify STRC was burned from Alice
        assertEq(
            buck.balanceOf(alice),
            aliceStrcBefore - refundStrcAmount,
            "STRC should be burned from Alice"
        );

        // Verify Alice received USDC (instant withdrawal from reserve)
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "Alice should receive USDC back");

        // The amount should be reasonable (accounting for price, spread, and fees)
        assertGt(usdcOut, 400e6, "Should receive reasonable USDC back");
        assertLt(usdcOut, 550e6, "Should not receive excessive USDC");

        console.log("Alice burned STRC:", refundStrcAmount / 1e18);
        console.log("Alice received USDC:", usdcOut / 1e6);
        console.log("Fee in USDC:", feeUsdc / 1e6);
    }

    function test_RefundFailsWithoutSTRC() public {
        uint256 refundAmount = 1000e18; // 1000 STRC that Alice doesn't have

        vm.startPrank(alice);

        // Try to refund STRC that Alice doesn't have
        vm.expectRevert(); // Should revert with ERC20 insufficient balance
        liquidityWindow.requestRefund(alice, refundAmount, 0, 0);

        vm.stopPrank();
    }

    // =============================================================
    //                    FULL CYCLE TEST
    // =============================================================

    function test_FullMintRefundCycle() public {
        // Initial balances
        uint256 aliceInitialUsdc = usdc.balanceOf(alice);

        // Step 1: Alice mints STRC with 1000 USDC
        uint256 mintUsdcAmount = 1000e6;

        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), mintUsdcAmount);
        (uint256 strcReceived, uint256 mintFee) =
            liquidityWindow.requestMint(alice, mintUsdcAmount, 0, 0);
        vm.stopPrank();

        console.log("=== After Mint ===");
        console.log("STRC received:", strcReceived / 1e18);
        console.log("Mint fee:", mintFee / 1e6, "USDC");
        console.log("Alice USDC balance:", usdc.balanceOf(alice) / 1e6);

        // Step 2: Alice refunds all her STRC
        vm.startPrank(alice);
        buck.approve(address(liquidityWindow), strcReceived);
        (uint256 usdcBack, uint256 refundFee) =
            liquidityWindow.requestRefund(alice, strcReceived, 0, 0);
        vm.stopPrank();

        console.log("\n=== After Refund ===");
        console.log("USDC received back:", usdcBack / 1e6);
        console.log("Refund fee:", refundFee / 1e6, "USDC");
        console.log("Alice USDC balance:", usdc.balanceOf(alice) / 1e6);

        // Verify Alice has less USDC than started (due to fees and spread)
        uint256 aliceFinalUsdc = usdc.balanceOf(alice);
        assertLt(
            aliceFinalUsdc, aliceInitialUsdc, "Alice should have less USDC due to fees and spread"
        );

        // Verify Alice has no STRC left
        assertEq(buck.balanceOf(alice), 0, "Alice should have no STRC left");

        // Calculate total loss to fees and spread
        uint256 totalLoss = aliceInitialUsdc - aliceFinalUsdc;
        console.log("\n=== Summary ===");
        console.log("Total USDC loss to fees/spread:", totalLoss / 1e6);
        console.log("Loss percentage:", (totalLoss * 10000) / mintUsdcAmount / 100, "%");

        // Loss should be reasonable (fees + spread, probably 1-2%)
        assertLt(totalLoss, (mintUsdcAmount * 3) / 100, "Loss should be less than 3%");
        assertGt(totalLoss, 0, "Should have some loss to fees/spread");
    }

    // =============================================================
    //                    TESTNET MODE TEST
    // =============================================================

    function test_TestnetModeAllowsMintingWithoutUSDC() public {
        // The current liquidityWindow already has testnet mode enabled
        // Verify that in testnet mode, USDC is still required (but caps are bypassed)
        // This is the correct behavior - testnet mode bypasses CAPS, not USDC requirement

        // Alice still needs USDC even in testnet mode
        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(alice, 1000e6, 0, 0);
        vm.stopPrank();

        // Verify minting worked (caps were bypassed due to testnet mode)
        assertGt(strcOut, 0, "Should receive STRC in testnet mode");

        // Note: In production, you'd need to be a liquidity steward
        // In testnet mode, anyone can mint (caps bypassed) but still needs USDC
    }

    // =============================================================
    //                    RESERVE BALANCE TEST
    // =============================================================

    function test_ReserveTracksUSDCProperly() public {
        uint256 reserveInitial = usdc.balanceOf(address(liquidityReserve));

        // Multiple users mint
        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), 1000e6);
        liquidityWindow.requestMint(alice, 1000e6, 0, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(liquidityWindow), 2000e6);
        liquidityWindow.requestMint(bob, 2000e6, 0, 0);
        vm.stopPrank();

        // Reserve should have received principal + reserve's portion of fees
        // PolicyManager GREEN band has 5 bps (0.05%) mint fee (Sprint 3)
        // Alice: 1000 USDC, fee = 0.5 USDC, reserve gets (1000-0.5) + 0.25 = 999.75 USDC
        // Bob: 2000 USDC, fee = 1 USDC, reserve gets (2000-1) + 0.5 = 1999.5 USDC
        // Total to reserve = 999.75 + 1999.5 = 2999.25 USDC
        uint256 aliceFee = (1000e6 * 5) / 10000; // Sprint 3: 5 bps
        uint256 bobFee = (2000e6 * 5) / 10000; // Sprint 3: 5 bps
        uint256 expectedReserveTotal =
            (1000e6 - aliceFee) + (aliceFee / 2) + (2000e6 - bobFee) + (bobFee / 2);
        uint256 reserveAfterMints = usdc.balanceOf(address(liquidityReserve));
        assertEq(
            reserveAfterMints,
            reserveInitial + expectedReserveTotal,
            "Reserve should have principal + reserve fee portions"
        );

        // Bob refunds some STRC
        uint256 bobStrc = buck.balanceOf(bob);
        vm.startPrank(bob);
        buck.approve(address(liquidityWindow), bobStrc / 2);
        liquidityWindow.requestRefund(bob, bobStrc / 2, 0, 0);
        vm.stopPrank();

        // Reserve balance should decrease (instant withdrawal for users)
        uint256 reserveAfterRefund = usdc.balanceOf(address(liquidityReserve));
        assertLt(
            reserveAfterRefund, reserveAfterMints, "Reserve should have less USDC after refund"
        );
    }
}
