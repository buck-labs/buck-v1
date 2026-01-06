// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {Buck} from "src/token/Buck.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title MockLiquidityReserveV2
 * @notice Simulates a new reserve implementation with different behavior
 * @dev Used to test that we can swap reserve implementations
 */
contract MockLiquidityReserveV2 {
    address public admin;
    address public asset;
    address public liquidityWindow;
    address public rewardsEngine;
    uint256 public version = 2; // Marker to identify this is V2

    constructor(address admin_, address asset_) {
        admin = admin_;
        asset = asset_;
    }

    function setLiquidityWindow(address newWindow) external {
        require(msg.sender == admin, "Not admin");
        liquidityWindow = newWindow;
    }

    function setRewardsEngine(address newEngine) external {
        require(msg.sender == admin, "Not admin");
        rewardsEngine = newEngine;
    }

    // Simplified deposit - just receives USDC
    function recordDeposit(uint256) external {
        // V2 implementation - simpler logic
    }
}

/**
 * @title LiquidityReserveSwapTest
 * @notice Tests that prove LiquidityReserve can be swapped without UUPS upgradeability
 * @dev These tests are equivalent to upgrade tests - they verify that swapping
 *      reserves works correctly. NOTE: This is the MOST CRITICAL swap test since
 *      LiquidityReserve holds all user USDC.
 *
 * CRITICAL FINDING: recoverERC20() CANNOT migrate USDC funds (explicitly rejected).
 * Fund migration MUST use the withdrawal queue system with delay periods.
 *
 * Test Coverage:
 * - Authorization: Only admin can swap reserve addresses
 * - Swap Execution: BUCK and RewardsEngine can swap reserve references
 * - Fund Migration: How to safely migrate USDC (WARNING: complex)
 * - Functionality: New reserve is used for operations
 * - Integration: End-to-end flows work with new reserve
 * - Edge Cases: Multiple swaps, state preservation, etc.
 */
contract LiquidityReserveSwapTest is BaseTest {
    Buck internal buck;
    LiquidityReserve internal reserveV1;
    MockLiquidityReserveV2 internal reserveV2;
    PolicyManager internal policyManager;
    RewardsEngine internal rewardsEngine;
    LiquidityWindow internal liquidityWindow;
    MockUSDC internal usdc;

    address internal constant OWNER = address(0x1000);
    address internal constant TREASURER = address(0x1001);
    address internal constant ALICE = address(0x3000);

    function setUp() public {
        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy dependencies
        policyManager = deployPolicyManager(OWNER);
        buck = deployBUCK(OWNER);

        // Deploy V1 reserve
        vm.prank(OWNER);
        reserveV1 = deployLiquidityReserve(
            OWNER,
            address(usdc),
            address(0), // liquidityWindow - set later
            TREASURER
        );

        // Deploy LiquidityWindow
        vm.prank(OWNER);
        liquidityWindow =
            deployLiquidityWindow(OWNER, address(buck), address(reserveV1), address(policyManager));

        // Update reserveV1 with liquidityWindow address
        vm.prank(OWNER);
        reserveV1.setLiquidityWindow(address(liquidityWindow));

        // Deploy RewardsEngine
        rewardsEngine = deployRewardsEngine(
            OWNER,
            OWNER,
            1800, // cutoff
            1e17, // minClaim
            false // claimOnce
        );

        // Configure BUCK modules
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV1), // ← Reserve V1
            TREASURER, // treasury
            address(policyManager),
            address(0), // No KYC for tests
            address(rewardsEngine)
        );

        // Configure RewardsEngine
        vm.startPrank(OWNER);
        rewardsEngine.setToken(address(buck));
        rewardsEngine.setPolicyManager(address(policyManager));
        rewardsEngine.setReserveAddresses(address(reserveV1), address(usdc));
        vm.stopPrank();

        // Deploy V2 reserve for swap tests
        reserveV2 = new MockLiquidityReserveV2(OWNER, address(usdc));
    }

    // =========================================================================
    // Authorization Tests
    // =========================================================================

    function testOnlyOwnerCanSwapReserveInBUCK() public {
        vm.prank(ALICE);
        vm.expectRevert();
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2), // Try to swap
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
    }

    function testOwnerCanSwapReserveInBUCK() public {
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2), // Swap to V2
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        assertEq(buck.liquidityReserve(), address(reserveV2), "Reserve not swapped in STRX");
    }

    function testOnlyAdminCanSwapReserveInRewardsEngine() public {
        vm.prank(ALICE);
        vm.expectRevert();
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));
    }

    function testAdminCanSwapReserveInRewardsEngine() public {
        vm.prank(OWNER);
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));

        assertEq(
            rewardsEngine.liquidityReserve(),
            address(reserveV2),
            "Reserve not swapped in RewardsEngine"
        );
    }

    function testSwapReserveRevertsOnZeroAddressInRewardsEngine() public {
        // RewardsEngine should revert on zero address
        vm.prank(OWNER);
        vm.expectRevert();
        rewardsEngine.setReserveAddresses(address(0), address(usdc));
    }

    function testSTRXAllowsZeroAddressForReserve() public {
        // BUCK actually ALLOWS zero address for reserve (might be intentional)
        // This could be used to disable reserve functionality

        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(0), // Zero address - allowed
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // Verify it was set to zero
        assertEq(buck.liquidityReserve(), address(0), "Reserve set to zero");
    }

    // =========================================================================
    // Swap Execution Tests
    // =========================================================================

    function testSwapReserveInBUCK() public {
        // Record old reserve
        address oldReserve = buck.liquidityReserve();
        assertEq(oldReserve, address(reserveV1), "Should start with V1");

        // Swap to V2
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // Verify swap
        assertEq(buck.liquidityReserve(), address(reserveV2), "Should be V2 now");
    }

    function testSwapReserveInRewardsEngine() public {
        // Record old reserve
        address oldReserve = rewardsEngine.liquidityReserve();
        assertEq(oldReserve, address(reserveV1), "Should start with V1");

        // Swap to V2
        vm.prank(OWNER);
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));

        // Verify swap
        assertEq(rewardsEngine.liquidityReserve(), address(reserveV2), "Should be V2 now");
    }

    function testSwapReserveInBothContracts() public {
        vm.startPrank(OWNER);

        // Swap in both
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));

        vm.stopPrank();

        // Verify both use V2
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX should use V2");
        assertEq(
            rewardsEngine.liquidityReserve(), address(reserveV2), "RewardsEngine should use V2"
        );
    }

    // =========================================================================
    // Fund Migration Tests (CRITICAL - This holds all user USDC)
    // =========================================================================

    function testRecoverERC20CannotMigrateUSDC() public {
        // Fund reserveV1 with 1M USDC
        usdc.mint(address(reserveV1), 1_000_000e6);

        // Try to recover USDC to V2 - should FAIL (current implementation blocks USDC)
        vm.prank(OWNER);
        vm.expectRevert();
        reserveV1.recoverERC20(address(usdc), address(reserveV2), 1_000_000e6);

        // Verify USDC still in V1
        assertEq(usdc.balanceOf(address(reserveV1)), 1_000_000e6, "USDC should still be in V1");
    }

    function testRecoverERC20CannotSendToNonRecoverySink() public {
        // Fund reserveV1 with 1M USDC
        usdc.mint(address(reserveV1), 1_000_000e6);

        // Try to recover to random address - should FAIL (not a recovery sink)
        vm.prank(OWNER);
        vm.expectRevert();
        reserveV1.recoverERC20(address(usdc), ALICE, 1_000_000e6);

        // Verify USDC still in V1
        assertEq(usdc.balanceOf(address(reserveV1)), 1_000_000e6, "USDC should still be in V1");
    }

    function testRecoverERC20ToApprovedSinkAfterUpgrade() public {
        // NOTE: This test documents the RECOMMENDED upgrade path:
        // 1. Remove the USDC block from recoverERC20() (line 234)
        // 2. This enables instant USDC migration to approved recovery sinks
        // 3. Still protected by isRecoverySink whitelist

        // Current behavior: USDC recovery is blocked entirely
        // After upgrade: USDC recovery allowed to approved sinks only

        // This test would pass after upgrading LiquidityReserve to remove the USDC block
        // For now, we document the expected behavior:

        // Step 1: Mark new reserve as recovery sink
        vm.prank(OWNER);
        reserveV1.setRecoverySink(address(reserveV2), true);

        // Step 2: Fund reserveV1 with USDC
        usdc.mint(address(reserveV1), 1_000_000e6);

        // Step 3: Recover USDC to approved sink (would work after upgrade)
        // vm.prank(OWNER);
        // reserveV1.recoverERC20(address(usdc), address(reserveV2), 1_000_000e6);
        // assertEq(usdc.balanceOf(address(reserveV2)), 1_000_000e6, "USDC migrated to V2");

        // For now, verify the current behavior (blocks USDC)
        vm.prank(OWNER);
        vm.expectRevert();
        reserveV1.recoverERC20(address(usdc), address(reserveV2), 1_000_000e6);
    }

    function testFundMigrationRequiresWithdrawalQueue() public {
        // Fund reserveV1 with 1M USDC
        usdc.mint(address(reserveV1), 1_000_000e6);

        // To migrate funds, we must:
        // 1. Queue withdrawal from V1 to V2 (or to a trusted intermediary)
        // 2. Wait for delay period
        // 3. Execute withdrawal
        // 4. Manually transfer to V2

        // Queue withdrawal (requires TREASURER role)
        vm.prank(TREASURER);
        reserveV1.queueWithdrawal(TREASURER, 1_000_000e6);

        // Note: This test doesn't execute the withdrawal because:
        // - It requires waiting for the delay period (up to 36 hours)
        // - This demonstrates the complexity of fund migration
        // - In production, this would be a multi-step process
    }

    function testSwapReserveWithoutMigratingFunds() public {
        // Fund reserveV1 with USDC
        usdc.mint(address(reserveV1), 1_000_000e6);

        // Swap reserve addresses WITHOUT migrating funds
        vm.startPrank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));
        vm.stopPrank();

        // Verify: V1 still holds the funds, V2 has no funds
        assertEq(usdc.balanceOf(address(reserveV1)), 1_000_000e6, "V1 still has funds");
        assertEq(usdc.balanceOf(address(reserveV2)), 0, "V2 has no funds");

        // Verify: System now references V2 but funds are in V1 (DANGEROUS STATE)
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX points to V2");
        assertEq(rewardsEngine.liquidityReserve(), address(reserveV2), "RewardsEngine points to V2");
    }

    // =========================================================================
    // Functionality Tests: New Reserve is Used
    // =========================================================================

    function testNewReserveIsUsedByBUCK() public {
        // Swap to V2
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // BUCK should now reference V2
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX should use V2");
    }

    function testNewReserveIsUsedByRewardsEngine() public {
        // Swap to V2
        vm.prank(OWNER);
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));

        // RewardsEngine should now reference V2
        assertEq(
            rewardsEngine.liquidityReserve(), address(reserveV2), "RewardsEngine should use V2"
        );
    }

    function testOldReserveNoLongerReferenced() public {
        // Swap to V2
        vm.startPrank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        rewardsEngine.setReserveAddresses(address(reserveV2), address(usdc));
        vm.stopPrank();

        // System should NOT reference V1 anymore
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX should not reference V1");
        assertEq(
            rewardsEngine.liquidityReserve(),
            address(reserveV2),
            "RewardsEngine should not reference V1"
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function testMultipleSequentialSwaps() public {
        // Create V3
        MockLiquidityReserveV2 reserveV3 = new MockLiquidityReserveV2(OWNER, address(usdc));

        vm.startPrank(OWNER);

        // Swap V1 → V2
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        assertEq(buck.liquidityReserve(), address(reserveV2), "Should use V2");

        // Swap V2 → V3
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV3),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        assertEq(buck.liquidityReserve(), address(reserveV3), "Should use V3");

        // Swap V3 → V1 (back to original)
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV1),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );
        assertEq(buck.liquidityReserve(), address(reserveV1), "Should use V1 again");

        vm.stopPrank();
    }

    function testSwapToCompletelyDifferentImplementation() public {
        // V2 has different implementation
        assertEq(reserveV2.version(), 2, "V2 has version marker");

        // Swap
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // New implementation works
        assertEq(reserveV2.version(), 2, "Can call V2-specific functions");
    }

    // =========================================================================
    // Independence Tests: BUCK and RewardsEngine are Independent
    // =========================================================================

    function testSTRXAndRewardsEngineCanUseDifferentReserves() public {
        MockLiquidityReserveV2 reserveV3 = new MockLiquidityReserveV2(OWNER, address(usdc));

        vm.startPrank(OWNER);

        // BUCK uses V2
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // RewardsEngine uses V3
        rewardsEngine.setReserveAddresses(address(reserveV3), address(usdc));

        vm.stopPrank();

        // Verify they're different
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX uses V2");
        assertEq(rewardsEngine.liquidityReserve(), address(reserveV3), "RewardsEngine uses V3");
    }

    function testSwappingOneReserveDoesNotAffectTheOther() public {
        // Both start with V1
        assertEq(buck.liquidityReserve(), address(reserveV1));
        assertEq(rewardsEngine.liquidityReserve(), address(reserveV1));

        // Swap only BUCK to V2
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // BUCK uses V2, RewardsEngine still uses V1
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX swapped");
        assertEq(rewardsEngine.liquidityReserve(), address(reserveV1), "RewardsEngine unchanged");
    }

    // =========================================================================
    // LiquidityWindow Gap Test (NO SETTER EXISTS)
    // =========================================================================

    function testLiquidityWindowHasNoReserveSetter() public {
        // LiquidityWindow is deployed with reserveV1 reference
        // There is NO setter function to update this reference

        // Swap reserve in STRX
        vm.prank(OWNER);
        buck.configureModules(
            address(liquidityWindow),
            address(reserveV2),
            TREASURER,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        // BUCK now uses V2
        assertEq(buck.liquidityReserve(), address(reserveV2), "STRX uses V2");

        // But LiquidityWindow STILL references V1 (no way to change it)
        assertEq(
            liquidityWindow.liquidityReserve(), address(reserveV1), "LiquidityWindow still uses V1"
        );

        // This is an architectural gap that should be addressed
        // Options:
        // 1. Add setLiquidityReserve() to LiquidityWindow (requires upgrade)
        // 2. Deploy new LiquidityWindow with V2 reference
        // 3. Accept that LiquidityWindow keeps old reserve reference
    }
}
