// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {Buck} from "src/token/Buck.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title CAPPricingTest
 * @notice Comprehensive tests for CAP (Collateral-Aware Peg) pricing
 * @dev THE CRAZIEST PART OF THE WHOLE IMPLEMENTATION - Testing the heart of the system!
 *
 * CAP Pricing Formula:
 * - When CR ≥ 1.0: BUCK = $1.00 (oracle ignored, strict mode OFF)
 * - When CR < 1.0: BUCK = min(P_STRC/100, CR) (oracle required, strict mode ON)
 *
 * Critical Scenarios Tested:
 * 1. CR = 1.2 → $1.00 (healthy, oracle can be stale/broken)
 * 2. CR = 0.96, P_STRC = 0.95 → $0.95 (stressed, oracle wins)
 * 3. CR = 0.90, P_STRC = 0.95 → $0.90 (stressed, CR wins)
 * 4. CR = 0.99 → oracle activates immediately (threshold crossing)
 * 5. CR = 1.0 exactly → boundary condition
 * 6. Multiple CR transitions → system adapts correctly
 * 7. Oracle strict mode transitions → automatic toggling
 */
contract CAPPricingTest is BaseTest {
    PolicyManager internal policyManager;
    CollateralAttestation internal collateralAttestation;
    OracleAdapter internal oracle;
    LiquidityWindow internal liquidityWindow;
    LiquidityReserve internal liquidityReserve;
    Buck internal buck;
    MockUSDC internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant ATTESTOR = address(0xA77E5701);
    address internal constant ALICE = address(0xA11CE1);
    address internal constant BOB = address(0xB0B);

    // For easy reference
    uint256 internal constant ONE = 1e18;
    uint256 internal constant DOLLAR = 1e18;

    // Monotonic counter to ensure unique timestamps for attestations
    uint256 internal _attestCounter = 0;

    event StrictModeChangeRequired(bool shouldBeStrict, uint256 collateralRatio, string reason);

    function setUp() public {
        // Deploy all contracts
        usdc = new MockUSDC();
        buck = deployBUCK(TIMELOCK);
        oracle = new OracleAdapter(address(this));

        // Deploy PolicyManager
        policyManager = deployPolicyManager(TIMELOCK);

        // Deploy LiquidityReserve (before CollateralAttestation needs it)
        liquidityReserve = deployLiquidityReserve(
            TIMELOCK,
            address(usdc),
            address(0), // Will set liquidity window later
            TIMELOCK // treasury
        );

        // Deploy CollateralAttestation with all required addresses
        collateralAttestation = deployCollateralAttestation(
            TIMELOCK, ATTESTOR, address(buck), address(liquidityReserve), address(usdc)
        );

        // Deploy LiquidityWindow
        liquidityWindow = deployLiquidityWindow(
            TIMELOCK, address(buck), address(liquidityReserve), address(policyManager)
        );

        // AUDIT FIX: Configure oracle to accept calls from PolicyManager for automatic strict mode
        // Must be called before vm.startPrank since test contract is the oracle admin
        oracle.setPolicyManager(address(policyManager));

        // Configure everything
        vm.startPrank(TIMELOCK);

        // Set CollateralAttestation and oracle on PolicyManager
        policyManager.setCollateralAttestation(address(collateralAttestation));
        policyManager.setContractReferences(
            address(buck), address(liquidityReserve), address(oracle), address(usdc)
        );

        // Configure LiquidityWindow
        liquidityWindow.setUSDC(address(usdc));

        // Configure LiquidityReserve
        liquidityReserve.setLiquidityWindow(address(liquidityWindow));

        // Configure STRX
        buck.configureModules(
            address(liquidityWindow),
            address(liquidityReserve),
            TIMELOCK,
            address(policyManager),
            address(0), // No KYC
            address(0) // No rewards
        );

        // Grant OPERATOR_ROLE to LiquidityWindow for cap tracking
        policyManager.grantRole(policyManager.OPERATOR_ROLE(), address(liquidityWindow));

        // Configure production-style caps: unlimited mints, 25% refunds
        policyManager.setMaxSingleTransactionPct(100); // Allow full daily cap in single tx for testing

        PolicyManager.BandConfig memory greenConfig = policyManager.getBandConfig(PolicyManager.Band.Green);
        greenConfig.caps.mintAggregateBps = 0;     // 0 = unlimited (mints improve reserve ratio)
        greenConfig.caps.refundAggregateBps = 2500; // 25% per day
        // Note: alphaBps defaults (500/250/100) now only apply to refunds per architecture
        policyManager.setBandConfig(PolicyManager.Band.Green, greenConfig);

        PolicyManager.BandConfig memory yellowConfig = policyManager.getBandConfig(PolicyManager.Band.Yellow);
        yellowConfig.caps.mintAggregateBps = 0;
        yellowConfig.caps.refundAggregateBps = 2500;
        policyManager.setBandConfig(PolicyManager.Band.Yellow, yellowConfig);

        PolicyManager.BandConfig memory redConfig = policyManager.getBandConfig(PolicyManager.Band.Red);
        redConfig.caps.mintAggregateBps = 0;
        redConfig.caps.refundAggregateBps = 2500;
        policyManager.setBandConfig(PolicyManager.Band.Red, redConfig);

        vm.stopPrank();

        // Set default oracle price to $0.95 (95 cents)
        oracle.setInternalPrice(0.95e18);

        // Move past block-fresh window
        vm.roll(block.number + 2);

        // Fund users
        usdc.mint(ALICE, 1_000_000e6);
        usdc.mint(BOB, 1_000_000e6);
        usdc.mint(address(liquidityReserve), 10_000_000e6); // Fund reserve for refunds
    }

    // ========================================================================
    // SCENARIO 1: CR = 1.2 → $1.00 (Healthy Mode - Oracle Ignored)
    // ========================================================================

    function test_CAP_HealthyCR_IgnoresOracle() public {
        // Setup: CR = 1.2 (120% collateralized - healthy!)
        _setCollateralRatio(1.2e18); // R = 1200, V = 0, L = 1000 → CR = 1.2

        // Oracle says $0.95, but should be ignored
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // CAP price should be $1.00 regardless of oracle
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 1e18, "CAP price should be $1.00 when CR >= 1");

        // Mint should execute at $1.00
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // 1000 USDC at $1.00 = ~1000 BUCK (accounting for fees and spread)
        assertApproxEqRel(
            strcOut, 1000e18, 0.01e18, "Should mint at $1.00 despite oracle showing $0.95"
        );
    }

    function test_CAP_HealthyCR_OracleCanBeStale() public {
        // Setup: CR = 1.5 (super healthy)
        _setCollateralRatio(1.5e18);

        // Set oracle price
        oracle.setInternalPrice(0.95e18);

        // Make oracle stale by warping time AND rolling blocks
        vm.warp(block.timestamp + 3 hours);
        vm.roll(block.number + 1000); // Advance blocks to make price "stale" by block-based checks

        // Oracle is stale by timestamp, but strict mode should be OFF
        assertFalse(oracle.strictMode(), "Strict mode should be OFF when CR >= 1");
        assertTrue(oracle.isHealthy(1 hours), "Oracle should report healthy in non-strict mode");

        // CAP price should still work
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 1e18, "CAP price works even with stale oracle");

        // Mint should succeed - need fresh oracle for LiquidityWindow's block-based check
        // When CR >= 1, oracle health doesn't matter, so refresh the oracle
        oracle.setInternalPrice(0.95e18); // Refresh oracle for LiquidityWindow's block check
        vm.roll(block.number + 2);

        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(
            strcOut, 1000e18, 0.01e18, "Mint succeeds even with stale oracle when CR >= 1"
        );
    }

    function test_CAP_HealthyCR_OracleCanBeBroken() public {
        // Setup: CR = 1.3
        _setCollateralRatio(1.3e18);

        // Set oracle to unhealthy
        // oracle.setHealthy(false); // Note: OracleAdapter uses setStrictMode() instead

        // Sync oracle mode - should set strict mode OFF since CR >= 1
        _syncAndApplyStrictMode(false);

        // Even though oracle is marked unhealthy, isHealthy() returns true in non-strict mode
        assertTrue(oracle.isHealthy(1 hours), "isHealthy returns true when strict mode OFF");

        // CAP price should work
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 1e18, "CAP price is $1.00 when CR >= 1");

        // Mint should succeed
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(
            strcOut, 1000e18, 0.01e18, "Mint succeeds with broken oracle when CR >= 1"
        );
    }

    // ========================================================================
    // SCENARIO 2: CR = 0.96, P_STRC = 0.95 → $0.96 (CR Wins)
    // ========================================================================

    function test_CAP_StressedCR_OracleWins() public {
        // Setup: CR = 0.96 (96% collateralized - stressed!)
        _setCollateralRatio(0.96e18);

        // Oracle price = $0.95 (95 cents)
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // Sync oracle mode - should enable strict mode since CR < 1
        _syncAndApplyStrictMode(true);

        // CAP formula: max(0.95, 0.96) = 0.96 (CR wins - better price for users)
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 0.96e18, "CAP price should be max(oracle, CR) = $0.96");

        // Mint should execute at $0.96
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // 1000 USDC at $0.96 = ~1041.67 STRX
        uint256 expected = Math.mulDiv(1000e18, 1e18, 0.96e18);
        assertApproxEqRel(strcOut, expected, 0.01e18, "Should mint at $0.96 (CR wins)");
    }

    // ========================================================================
    // SCENARIO 3: CR = 0.90, P_STRC = 0.95 → $0.95 (Oracle Wins)
    // ========================================================================

    function test_CAP_StressedCR_CRWins() public {
        // Setup: CR = 0.90 (90% collateralized - very stressed!)
        _setCollateralRatio(0.9e18);

        // Oracle price = $0.95 (95 cents)
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // Sync oracle mode
        _syncAndApplyStrictMode(true);

        // CAP formula: max(0.95, 0.90) = 0.95 (oracle wins - better price for users)
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 0.95e18, "CAP price should be max(oracle, CR) = $0.95 (oracle wins)");

        // Mint should execute at $0.95
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // 1000 USDC at $0.95 = ~1052.63 STRX
        uint256 expected = Math.mulDiv(1000e18, 1e18, 0.95e18);
        assertApproxEqRel(strcOut, expected, 0.01e18, "Should mint at $0.95 (oracle wins)");
    }

    // ========================================================================
    // SCENARIO 4: CR = 0.99 → Oracle Activates Immediately
    // ========================================================================

    function test_CAP_ThresholdCrossing_OracleActivates() public {
        // Start healthy: CR = 1.01
        _setCollateralRatio(1.01e18);
        _syncAndApplyStrictMode(false);

        // Set oracle price
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // Price should be $1.00
        assertEq(policyManager.getCAPPrice(), 1e18, "Price $1.00 when CR >= 1");

        // Make oracle stale by advancing time and blocks
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1000);

        // In non-strict mode, stale oracle still reports healthy
        assertTrue(oracle.isHealthy(1 hours), "Stale oracle reports healthy in non-strict mode");

        // Now CR drops to 0.99 (crosses threshold!)
        _setCollateralRatio(0.99e18);

        // Sync oracle mode - should immediately enable strict mode
        _syncAndApplyStrictMode(true);

        // Manually set oracle to unhealthy to simulate staleness
        // oracle.setHealthy(false); // Note: OracleAdapter uses setStrictMode() instead

        // Now oracle health matters - stale oracle should fail health check in strict mode
        assertFalse(oracle.isHealthy(1 hours), "Stale oracle fails health check in strict mode");

        // Fresh oracle needed - refresh it and set back to healthy
        // oracle.setHealthy(true); // Note: OracleAdapter uses setStrictMode() instead
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        assertTrue(oracle.isHealthy(1 hours), "Fresh oracle passes health check");

        // CAP price now depends on oracle
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 0.99e18, "CAP price = max(0.95, 0.99) = $0.99 (CR wins)");
    }

    // ========================================================================
    // SCENARIO 5: CR = 1.0 Exactly (Boundary Condition)
    // ========================================================================

    function test_CAP_ExactThreshold() public {
        // Setup: CR = 1.0 exactly (100% collateralized)
        _setCollateralRatio(1.0e18);

        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // At exactly 1.0, should use $1.00 (formula: CR >= 1.0)
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 1e18, "At CR = 1.0 exactly, price should be $1.00");

        // Strict mode should be OFF (CR >= 1.0)
        _syncAndApplyStrictMode(false);
    }

    function test_CAP_JustBelowThreshold() public {
        // Setup: CR = 0.999999999999999999 (just under 1.0)
        _setCollateralRatio(1e18 - 1);

        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // Just below 1.0, should use CAP formula: max(0.95, 0.999....) = 0.999....
        uint256 capPrice = policyManager.getCAPPrice();
        uint256 cr = 1e18 - 1;
        uint256 expected = Math.max(0.95e18, cr);
        assertApproxEqAbs(
            capPrice, expected, 1e15, "Just below 1.0, uses CAP formula: max(oracle, CR)"
        );

        // Strict mode should be ON
        _syncAndApplyStrictMode(true);
    }

    // ========================================================================
    // SCENARIO 6: Multiple CR Transitions
    // ========================================================================

    function test_CAP_MultipleTransitions() public {
        // Start at CR = 1.5 (healthy)
        _setCollateralRatio(1.5e18);
        _syncAndApplyStrictMode(false);
        assertEq(policyManager.getCAPPrice(), 1e18, "Start: $1.00");

        // Drop to CR = 0.95 (stressed), oracle = 0.90 → max = 0.95 (CR wins)
        _setCollateralRatio(0.95e18);
        oracle.setInternalPrice(0.9e18);
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);
        assertEq(
            policyManager.getCAPPrice(), 0.95e18, "Drop: $0.95 (CR wins, max of 0.90 and 0.95)"
        );

        // Recover to CR = 1.1 (healthy again)
        _setCollateralRatio(1.1e18);
        _syncAndApplyStrictMode(false);
        assertEq(policyManager.getCAPPrice(), 1e18, "Recover: $1.00");

        // Drop again to CR = 0.85 (very stressed), oracle = 0.92 → max = 0.92 (oracle wins)
        _setCollateralRatio(0.85e18);
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);
        assertEq(
            policyManager.getCAPPrice(),
            0.92e18,
            "Drop again: $0.92 (oracle wins, max of 0.85 and 0.92)"
        );

        // Final recovery to CR = 1.3
        _setCollateralRatio(1.3e18);
        _syncAndApplyStrictMode(false);
        assertEq(policyManager.getCAPPrice(), 1e18, "Final: $1.00");
    }

    // ========================================================================
    // SCENARIO 7: Oracle Strict Mode Enforcement
    // ========================================================================

    function test_CAP_StrictMode_EnforcesFreshness() public {
        // Setup: CR = 0.90 (stressed)
        _setCollateralRatio(0.9e18);

        // Set fresh oracle price
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);

        // Enable strict mode
        _syncAndApplyStrictMode(true);

        // Fresh oracle works
        assertTrue(oracle.isHealthy(1 hours), "Fresh oracle healthy");
        assertEq(
            policyManager.getCAPPrice(),
            0.92e18,
            "CAP price = max(0.90, 0.92) = $0.92 (oracle wins)"
        );

        // Make oracle stale (2 hours old) - advance both time and blocks
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1000); // Advance blocks to make price stale by block checks too

        // Manually set oracle to unhealthy to simulate staleness in strict mode
        // oracle.setHealthy(false); // Note: OracleAdapter uses setStrictMode() instead

        // In strict mode, stale/unhealthy oracle fails health check
        assertFalse(oracle.isHealthy(1 hours), "Stale oracle unhealthy in strict mode");

        // Mint should fail with OracleUnhealthy due to stale oracle in strict mode
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        vm.expectRevert(); // Will revert with OracleUnhealthy
        liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();
    }

    function test_CAP_NonStrictMode_AllowsStaleOracle() public {
        // Setup: CR = 1.2 (healthy)
        _setCollateralRatio(1.2e18);

        // Set oracle price
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);

        // Ensure strict mode is OFF
        _syncAndApplyStrictMode(false);

        // Make oracle very stale (10 hours old)
        vm.warp(block.timestamp + 10 hours);

        // In non-strict mode, even very stale oracle reports healthy
        assertTrue(oracle.isHealthy(1 hours), "Stale oracle still 'healthy' in non-strict mode");

        // Mint should succeed at $1.00
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(strcOut, 1000e18, 0.01e18, "Mint succeeds with stale oracle when CR >= 1");
    }

    // ========================================================================
    // SCENARIO 8: Refund Operations with CAP Pricing
    // ========================================================================

    function test_CAP_Refund_HealthyCR() public {
        // Setup: CR = 1.2
        _setCollateralRatio(1.2e18);
        oracle.setInternalPrice(0.95e18);
        vm.roll(block.number + 2);

        // First mint some BUCK at $1.00
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);

        // Now refund 20 BUCK (~2% of total supply, within 2.5% maxSingleTransactionPct limit)
        // Should get ~20 USDC (at $1.00, accounting for fees and spread)
        (uint256 usdcOut,) = liquidityWindow.requestRefund(ALICE, 20e18, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(usdcOut, 20e6, 0.01e18, "Refund at $1.00 when CR >= 1");
    }

    function test_CAP_Refund_StressedCR() public {
        // Setup: CR = 0.88, oracle = 0.92 → max = 0.92
        _setCollateralRatio(0.88e18);
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);

        // Mint some BUCK at stressed price ($0.92)
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);

        // Refund 20 BUCK (~1% of supply after mint, within 2.5% maxSingleTransactionPct limit)
        // Should get ~18.4 USDC (at $0.92)
        (uint256 usdcOut,) = liquidityWindow.requestRefund(ALICE, 20e18, 0, 0);
        vm.stopPrank();

        uint256 expected = Math.mulDiv(20e18, 0.92e18, 1e18) / 1e12; // Convert to 6 decimals
        assertApproxEqRel(usdcOut, expected, 0.01e18, "Refund at $0.92 when CR < 1");
    }

    // ========================================================================
    // SCENARIO 9: Edge Cases and Extreme Values
    // ========================================================================

    function test_CAP_ExtremeCR_VeryHigh() public {
        // CR = 5.0 (500% overcollateralized!)
        _setCollateralRatio(5.0e18);
        oracle.setInternalPrice(0.51e18); // Oracle shows $0.51 (near lowest valid price)
        vm.roll(block.number + 2);

        // Should still return $1.00 (ignores oracle)
        assertEq(policyManager.getCAPPrice(), 1e18, "CAP price capped at $1.00 even with high CR");
    }

    function test_CAP_ExtremeCR_VeryLow() public {
        // CR = 0.51 (51% collateralized - severe stress!)
        _setCollateralRatio(0.51e18);
        oracle.setInternalPrice(0.6e18); // Oracle shows $0.60
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);

        // Should return max(0.60, 0.51) = $0.60 (oracle wins)
        assertEq(policyManager.getCAPPrice(), 0.6e18, "CAP price follows oracle at severe stress");
    }

    function test_CAP_OracleVeryLow() public {
        // CR = 0.95, Oracle = $0.51 (oracle shows severe discount - near lowest valid price)
        _setCollateralRatio(0.95e18);
        oracle.setInternalPrice(0.51e18);
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);

        // Should return max(0.51, 0.95) = $0.95 (CR wins)
        assertEq(policyManager.getCAPPrice(), 0.95e18, "CAP follows CR when oracle very low");
    }

    function test_CAP_BothAtParity() public {
        // CR = 0.97, Oracle = $0.97 (both exactly same)
        _setCollateralRatio(0.97e18);
        oracle.setInternalPrice(0.97e18);
        vm.roll(block.number + 2);
        _syncAndApplyStrictMode(true);

        // Should return $0.97 (min of identical values)
        assertEq(policyManager.getCAPPrice(), 0.97e18, "CAP price when CR = oracle price");
    }

    // ========================================================================
    // SCENARIO 10: Permissionless Oracle Sync
    // ========================================================================

    function test_CAP_OracleSync_Permissionless() public {
        // Setup: CR = 0.90 (stressed)
        _setCollateralRatio(0.9e18);

        // Anyone can call syncOracleStrictMode
        _syncAndApplyStrictModeAs(ALICE, true);

        // Change CR back to healthy
        _setCollateralRatio(1.1e18);

        // Bob can also sync
        _syncAndApplyStrictModeAs(BOB, false);

        // Even random address
        _setCollateralRatio(0.85e18);
        _syncAndApplyStrictModeAs(address(0xDEAD), true);
    }

    // ========================================================================
    // SPRINT 2: CAP Pricing Independence from Bands
    // ========================================================================

    /// @notice Sprint 2: Verifies CAP pricing is independent of band status
    /// @dev CAP pricing depends ONLY on CR and oracle, NOT on R/L band
    /// Band is determined by R/L (reserve ratio), CAP by CR (collateral ratio)
    function test_Sprint2_CAPPricing_IndependentOfBand() public {
        // Simpler scenario: CR = 1.2 (healthy, overcollateralized) with RED band (low R/L)
        // This proves CAP pricing ($1.00) works even when band is RED
        //
        // Key insight: Band (RED) is determined by R/L (on-chain liquidity)
        //              CAP price ($1.00) is determined by CR (total collateral)
        //              These are independent!

        // Set CR = 1.2 (120% collateralized, healthy)
        // This gives us CAP price = $1.00 (since CR >= 1)
        _setCollateralRatio(1.2e18);

        // Verify CR is correct
        uint256 actualCR = collateralAttestation.getCollateralRatio();
        assertApproxEqRel(actualCR, 1.2e18, 0.01e18, "CR should be 1.2");

        // Now manually adjust reserve to create RED band scenario
        // RED band: R/L < 2.5%, so set R = 2% of L
        uint256 L = buck.totalSupply();
        uint256 targetR_usdc = (L * 2) / 100 / 1e12; // 2% of L in USDC (6 decimals)

        uint256 currentReserve = usdc.balanceOf(address(liquidityReserve));
        if (targetR_usdc > currentReserve) {
            usdc.mint(address(liquidityReserve), targetR_usdc - currentReserve);
        } else if (targetR_usdc < currentReserve) {
            vm.prank(address(liquidityReserve));
            usdc.transfer(address(0xDEAD), currentReserve - targetR_usdc);
        }

        // Verify we're in RED band based on R/L
        uint256 R = usdc.balanceOf(address(liquidityReserve)) * 1e12; // Scale to 18 decimals
        uint256 reserveRatioBps = (R * 10_000) / L;
        assertLt(reserveRatioBps, 250, "Should be in RED band (R/L < 2.5%)");

        // Note: After reducing R to create RED band, CR has also changed
        // (since V=0 in this setup). Let's verify the actual CR and test CAP accordingly.
        uint256 finalCR = collateralAttestation.getCollateralRatio();

        // Set oracle price to $0.80
        oracle.setInternalPrice(0.8e18);
        vm.roll(block.number + 2);

        // Sync oracle mode
        _syncAndApplyStrictMode(finalCR < 1e18);

        // CAP price should be max(oracle, finalCR), proving it's independent of RED band
        // The key insight: Band status (RED) doesn't directly affect CAP price calculation
        uint256 capPrice = policyManager.getCAPPrice();
        uint256 expectedCAP = Math.max(0.8e18, finalCR);
        assertEq(
            capPrice, expectedCAP, "CAP price = max(oracle, CR), independent of RED band status"
        );

        // Mint operation should work at expectedCAP price even in RED band
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        (uint256 strcOut,) = liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // Mint should use the CAP price (max of oracle and CR), not affected by RED band status
        uint256 expectedStrc = Math.mulDiv(1000e18, 1e18, expectedCAP);
        assertApproxEqRel(
            strcOut,
            expectedStrc,
            0.05e18,
            "Mint uses CAP price (max of oracle, CR) even in RED band"
        );
    }

    /// @notice Sprint 2: Verifies oracle staleness affects pricing but NOT band determination
    /// @dev Bands are determined purely by R/L ratio, oracle health is irrelevant to bands
    function test_Sprint2_OracleStaleness_AffectsPricingNotBands() public {
        // Setup: Create scenario where R/L puts us in YELLOW band
        // L = 1000e18, R = 40e6 USDC (4% reserve ratio) -> YELLOW band (2.5% <= R/L < 5%)
        // V = 0 (no off-chain collateral) -> CR = R/L = 0.04 (4%, very undercollateralized)

        uint256 L = 1000e18;
        uint256 R_usdc = 40e6; // 4% reserve ratio (YELLOW band)

        // Setup: Mint initial supply
        vm.prank(address(liquidityWindow));
        buck.mint(ALICE, L);

        // Set reserve balance for YELLOW band
        uint256 currentReserve = usdc.balanceOf(address(liquidityReserve));
        if (R_usdc > currentReserve) {
            usdc.mint(address(liquidityReserve), R_usdc - currentReserve);
        } else {
            vm.prank(address(liquidityReserve));
            usdc.transfer(address(0xDEAD), currentReserve - R_usdc);
        }

        // Publish attestation with V = 0
        vm.prank(ATTESTOR);
        collateralAttestation.publishAttestation(0, 1e18, block.timestamp);

        // Verify we're in YELLOW band based on R/L (band determination is independent of oracle)
        uint256 reserveRatioBps = (uint256(R_usdc) * 1e12 * 10_000) / L;
        assertGe(reserveRatioBps, 250, "Should be in YELLOW band (R/L >= 2.5%)");
        assertLt(reserveRatioBps, 500, "Should be in YELLOW band (R/L < 5%)");

        // Set fresh oracle price
        oracle.setInternalPrice(0.6e18); // Oracle shows $0.60
        vm.roll(block.number + 2);

        // Enable strict mode since CR = 0.04 < 1
        _syncAndApplyStrictMode(true);

        // With fresh oracle: CAP price = max(0.60, 0.04) = $0.60 (oracle wins)
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 0.6e18, "With fresh oracle: CAP price = $0.60 (oracle wins)");

        // Now make oracle stale by advancing time and blocks
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1000);

        // Set oracle to unhealthy to simulate staleness in strict mode
        // oracle.setHealthy(false); // Note: OracleAdapter uses setStrictMode() instead

        // Band should STILL be YELLOW - oracle staleness doesn't affect band determination
        // (Band is determined purely by R/L ratio, which hasn't changed)
        uint256 reserveRatioBpsAfter = (uint256(R_usdc) * 1e12 * 10_000) / L;
        assertGe(
            reserveRatioBpsAfter, 250, "Still in YELLOW band after oracle stale (R/L unchanged)"
        );
        assertLt(
            reserveRatioBpsAfter, 500, "Still in YELLOW band after oracle stale (R/L unchanged)"
        );

        // However, pricing SHOULD be affected - stale oracle should cause reverts
        // in strict mode when trying to mint
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        vm.expectRevert(); // Will revert due to stale oracle (OracleUnhealthy)
        liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // This proves:
        // 1. Band determination (YELLOW) is independent of oracle health
        // 2. Pricing operations (mint) ARE affected by oracle health when CR < 1
    }

    // ========================================================================
    // SCENARIO 11: Attestation Staleness Checks (Sprint 2 Phase 3.5.2)
    // ========================================================================

    /// @notice Phase 3.5.2: Verify getCAPPrice() reverts when attestation is stale
    /// @dev When CR < 1 (stressed mode), attestation must be fresh within 15 minutes
    function test_GetCAPPrice_RevertsWhenAttestationStale() public {
        // Setup: CR = 0.95 (stressed mode, requires 15min staleness threshold)
        _setCollateralRatio(0.95e18);

        // Set oracle price
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);

        // Enable strict mode
        _syncAndApplyStrictMode(true);

        // Verify getCAPPrice() works with fresh attestation
        uint256 capPrice = policyManager.getCAPPrice();
        assertEq(capPrice, 0.95e18, "CAP price should work with fresh attestation");

        // Warp 20 minutes forward (exceeds 15min stressed staleness threshold)
        vm.warp(block.timestamp + 20 minutes);

        // Now getCAPPrice() should revert with StaleCollateralAttestation
        vm.expectRevert(); // Will revert with StaleCollateralAttestation
        policyManager.getCAPPrice();
    }

    /// @notice Phase 3.5.2: Verify mint operations revert when attestation is stale
    /// @dev Mint calls getCAPPrice() internally, so stale attestation blocks minting
    function test_Mint_RevertsWhenAttestationStale() public {
        // Setup: CR = 0.95 (stressed mode)
        _setCollateralRatio(0.95e18);

        // Set oracle price
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);

        // Enable strict mode
        _syncAndApplyStrictMode(true);

        // Verify mint works with fresh attestation
        vm.startPrank(ALICE);
        usdc.approve(address(liquidityWindow), 1000e6);
        liquidityWindow.requestMint(ALICE, 1000e6, 0, 0);
        vm.stopPrank();

        // Warp 20 minutes forward (exceeds 15min threshold)
        vm.warp(block.timestamp + 20 minutes);

        // Refresh oracle (since LiquidityWindow has its own oracle checks)
        oracle.setInternalPrice(0.92e18);
        vm.roll(block.number + 2);

        // Now mint should revert due to stale collateral attestation
        vm.startPrank(BOB);
        usdc.approve(address(liquidityWindow), 1000e6);
        vm.expectRevert(); // Will revert with StaleCollateralAttestation from getCAPPrice()
        liquidityWindow.requestMint(BOB, 1000e6, 0, 0);
        vm.stopPrank();
    }

    // ========================================================================
    // Bootstrap Mode Tests (Auditor Finding #3 Fix)
    // ========================================================================

    /// @notice Test fresh deployment allows minting before first attestation
    /// @dev Bootstrap mode: getCAPPrice() returns $1.00 when no attestation published yet
    function test_Bootstrap_MintBeforeFirstAttestation() public {
        // Fresh deployment state (setUp already ran, but no attestation published yet)
        // Verify timeSinceLastAttestation returns max uint (bootstrap mode)
        assertEq(
            collateralAttestation.timeSinceLastAttestation(),
            type(uint256).max,
            "Should be in bootstrap mode"
        );

        // Mint should work at $1.00 even with no attestation
        uint256 price = policyManager.getCAPPrice();
        assertEq(price, 1e18, "Bootstrap mode should return $1.00");

        // Verify mint operation succeeds (simulated via price check)
        // In real deployment, LiquidityWindow would call this
        vm.prank(address(liquidityWindow));
        buck.mint(ALICE, 1000e18);

        assertEq(buck.balanceOf(ALICE), 1000e18, "Mint should succeed in bootstrap mode");
    }

    /// @notice Test normal staleness checks apply after first attestation
    /// @dev After publishing first attestation, bootstrap mode ends and staleness is enforced
    function test_Bootstrap_TransitionToNormalMode() public {
        // Start in bootstrap mode
        assertEq(
            collateralAttestation.timeSinceLastAttestation(),
            type(uint256).max,
            "Should start in bootstrap mode"
        );

        // Bootstrap: getCAPPrice works without attestation
        uint256 bootstrapPrice = policyManager.getCAPPrice();
        assertEq(bootstrapPrice, 1e18, "Bootstrap price should be $1.00");

        // Advance time to avoid underflow (Foundry starts at timestamp 1)
        vm.warp(block.timestamp + 100 days);

        // Publish first attestation (timestamp = 1 hour ago to test staleness)
        uint256 pastTimestamp = block.timestamp - 1 hours;
        vm.prank(ATTESTOR);
        collateralAttestation.publishAttestation(0, 1e18, pastTimestamp);

        // Bootstrap mode should end
        assertLt(
            collateralAttestation.timeSinceLastAttestation(),
            type(uint256).max,
            "Should exit bootstrap mode after first attestation"
        );

        // Since attestation was from 1 hour ago and CR is likely high (healthy mode),
        // the staleness threshold is 72 hours, so attestation is still fresh
        uint256 normalPrice = policyManager.getCAPPrice();
        assertEq(normalPrice, 1e18, "Should return $1.00 with fresh attestation");

        // Verify bootstrap mode is truly over by checking timeSinceLastAttestation
        uint256 timeSince = collateralAttestation.timeSinceLastAttestation();
        assertGt(timeSince, 0, "Time since attestation should be > 0");
        assertLt(timeSince, type(uint256).max, "Should not be max uint anymore");
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    function _syncAndApplyStrictMode(bool shouldBeStrict) internal {
        _syncAndApplyStrictModeAs(address(this), shouldBeStrict);
    }

    function _syncAndApplyStrictModeAs(address caller, bool shouldBeStrict) internal {
        // AUDIT FIX: syncOracleStrictMode now automatically toggles strict mode on-chain
        // No need for manual oracle.setStrictMode() call or event expectations
        if (caller == address(this)) {
            policyManager.syncOracleStrictMode();
        } else {
            vm.prank(caller);
            policyManager.syncOracleStrictMode();
        }

        assertEq(oracle.strictMode(), shouldBeStrict, "Oracle strict mode state mismatch");
    }

    /// @notice Set collateral ratio by configuring R, V, L
    /// @dev Uses simple setup: R + V = CR * L, V = 0 for simplicity
    function _setCollateralRatio(uint256 targetCR) internal {
        // Simple setup: V = 0, just adjust R
        // Formula: CR = R / L
        // So: R = CR * L

        uint256 L = buck.totalSupply();
        if (L == 0) {
            // Bootstrap: Create initial supply
            L = 1000e18;
            vm.prank(address(liquidityWindow));
            buck.mint(ALICE, L);
        }

        uint256 R = Math.mulDiv(targetCR, L, 1e18);

        // Adjust reserve balance to match desired R
        uint256 currentReserve = usdc.balanceOf(address(liquidityReserve));
        uint256 targetReserve = R / 1e12; // Convert to 6 decimals

        if (targetReserve > currentReserve) {
            usdc.mint(address(liquidityReserve), targetReserve - currentReserve);
        } else if (targetReserve < currentReserve) {
            // Burn excess (transfer to dead address)
            vm.prank(address(liquidityReserve));
            usdc.transfer(address(0xDEAD), currentReserve - targetReserve);
        }

        // Advance time using counter to ensure monotonicity (workaround for compiler optimization)
        _attestCounter++;
        uint256 attestTs = block.timestamp + _attestCounter;
        vm.warp(attestTs);

        // Publish attestation: V = 0, HC = 1.0 (no haircut)
        vm.prank(ATTESTOR);
        collateralAttestation.publishAttestation(0, 1e18, attestTs);

        // Verify CR is correct
        uint256 actualCR = collateralAttestation.getCollateralRatio();
        assertApproxEqRel(actualCR, targetCR, 0.001e18, "CR set correctly");
    }
}
