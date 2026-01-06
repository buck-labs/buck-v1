// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title STRCConfigurationTest
/// @notice Tests for enhanced configuration functions with validation and old→new events
contract BUCKConfigurationTest is BaseTest {
    Buck public buck;

    address constant TIMELOCK = address(0x1000);
    address constant LIQUIDITY_WINDOW = address(0x2000);
    address constant LIQUIDITY_RESERVE = address(0x3000);
    address constant TREASURY = address(0x4000);
    address constant POLICY_MANAGER = address(0x5000);
    address constant KYC_REGISTRY = address(0x6000);
    address constant REWARDS_HOOK = address(0x7000);
    address constant DEX_PAIR = address(0x8000);
    address constant NEW_DEX_PAIR = address(0x8001);

    address constant ZERO_ADDRESS = address(0);

    event ModulesUpdated(
        address indexed oldLiquidityWindow,
        address indexed newLiquidityWindow,
        address oldLiquidityReserve,
        address newLiquidityReserve,
        address oldTreasury,
        address newTreasury,
        address oldPolicyManager,
        address newPolicyManager,
        address oldKycRegistry,
        address newKycRegistry,
        address oldRewardsHook,
        address newRewardsHook
    );

    event DexPairAdded(address indexed pair);
    event DexPairRemoved(address indexed pair);
    event SwapFeesUpdated(
        uint16 oldBuyFeeBps, uint16 newBuyFeeBps, uint16 oldSellFeeBps, uint16 newSellFeeBps
    );
    event FeeSplitUpdated(uint16 oldFeeToReservePct, uint16 newFeeToReservePct);
    event ProductionModeEnabled(uint256 timestamp);

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
    }

    // -------------------------------------------------------------------------
    // configureModules Tests
    // -------------------------------------------------------------------------

    function testConfigureModulesEmitsOldAndNewValues() public {
        // First configuration
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        // Second configuration - should emit old values
        address newLiquidityWindow = address(0x2001);
        address newLiquidityReserve = address(0x3001);
        address newTreasury = address(0x4001);
        address newPolicyManager = address(0x5001);
        address newKycRegistry = address(0x6001);
        address newRewardsHook = address(0x7001);

        vm.expectEmit(true, true, false, true);
        emit ModulesUpdated(
            LIQUIDITY_WINDOW, // old
            newLiquidityWindow, // new
            LIQUIDITY_RESERVE,
            newLiquidityReserve,
            TREASURY,
            newTreasury,
            POLICY_MANAGER,
            newPolicyManager,
            KYC_REGISTRY,
            newKycRegistry,
            REWARDS_HOOK,
            newRewardsHook
        );

        vm.prank(TIMELOCK);
        buck.configureModules(
            newLiquidityWindow,
            newLiquidityReserve,
            newTreasury,
            newPolicyManager,
            newKycRegistry,
            newRewardsHook
        );

        // Verify storage updated
        assertEq(buck.liquidityWindow(), newLiquidityWindow);
        assertEq(buck.liquidityReserve(), newLiquidityReserve);
        assertEq(buck.treasury(), newTreasury);
        assertEq(buck.policyManager(), newPolicyManager);
        assertEq(buck.accessRegistry(), newKycRegistry);
        assertEq(buck.rewardsHook(), newRewardsHook);
    }

    function testConfigureModulesAllowsZeroAddressesInDevMode() public {
        // Should work with zero addresses before production mode
        vm.prank(TIMELOCK);
        buck.configureModules(
            ZERO_ADDRESS, // liquidityWindow
            ZERO_ADDRESS, // liquidityReserve
            ZERO_ADDRESS, // treasury
            ZERO_ADDRESS, // policyManager
            ZERO_ADDRESS, // accessRegistry
            ZERO_ADDRESS // rewardsHook
        );

        assertEq(buck.liquidityWindow(), ZERO_ADDRESS);
        assertEq(buck.liquidityReserve(), ZERO_ADDRESS);
        assertEq(buck.treasury(), ZERO_ADDRESS);
    }

    function testConfigureModulesRejectsCriticalZeroAddressesInProductionMode() public {
        // Setup valid configuration
        vm.startPrank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        // Enable production mode
        buck.enableProductionMode();
        vm.stopPrank();

        // Try to set liquidityWindow to zero - should fail
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(Buck.CriticalAddressCannotBeZero.selector, "liquidityWindow")
        );
        buck.configureModules(
            ZERO_ADDRESS, // liquidityWindow
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        // Try to set liquidityReserve to zero - should fail
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(Buck.CriticalAddressCannotBeZero.selector, "liquidityReserve")
        );
        buck.configureModules(
            LIQUIDITY_WINDOW,
            ZERO_ADDRESS, // liquidityReserve
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        // Try to set treasury to zero - should fail
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(Buck.CriticalAddressCannotBeZero.selector, "treasury")
        );
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            ZERO_ADDRESS, // treasury
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );
    }

    function testConfigureModulesAllowsOptionalZeroAddressesInProductionMode() public {
        // Setup and enable production mode
        vm.startPrank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );
        buck.enableProductionMode();

        // Should allow zero for optional modules
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            ZERO_ADDRESS, // policyManager - optional
            ZERO_ADDRESS, // accessRegistry - optional
            ZERO_ADDRESS // rewardsHook - optional
        );
        vm.stopPrank();

        assertEq(buck.policyManager(), ZERO_ADDRESS);
        assertEq(buck.accessRegistry(), ZERO_ADDRESS);
        assertEq(buck.rewardsHook(), ZERO_ADDRESS);
    }

    // -------------------------------------------------------------------------
    // DEX Pair Tests (addDexPair / removeDexPair)
    // -------------------------------------------------------------------------

    function testAddDexPairEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit DexPairAdded(DEX_PAIR);

        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        assertTrue(buck.isDexPair(DEX_PAIR));
    }

    function testAddMultipleDexPairs() public {
        // Add first pair
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);
        assertTrue(buck.isDexPair(DEX_PAIR));

        // Add second pair - first is still active
        vm.prank(TIMELOCK);
        buck.addDexPair(NEW_DEX_PAIR);

        // Both should be active
        assertTrue(buck.isDexPair(DEX_PAIR));
        assertTrue(buck.isDexPair(NEW_DEX_PAIR));
    }

    function testAddDexPairSetsFeeExempt() public {
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        assertTrue(buck.isFeeExempt(DEX_PAIR));
    }

    function testRemoveDexPairEmitsEvent() public {
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        vm.expectEmit(true, false, false, true);
        emit DexPairRemoved(DEX_PAIR);

        vm.prank(TIMELOCK);
        buck.removeDexPair(DEX_PAIR);

        assertFalse(buck.isDexPair(DEX_PAIR));
    }

    function testRemoveDexPairRemovesFeeExempt() public {
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);
        assertTrue(buck.isFeeExempt(DEX_PAIR));

        vm.prank(TIMELOCK);
        buck.removeDexPair(DEX_PAIR);

        assertFalse(buck.isFeeExempt(DEX_PAIR));
    }

    function testCannotAddZeroAddressAsDexPair() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.ZeroAddress.selector);
        buck.addDexPair(ZERO_ADDRESS);
    }

    function testCannotAddDuplicateDexPair() public {
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.AlreadyDexPair.selector);
        buck.addDexPair(DEX_PAIR);
    }

    function testCannotRemoveNonExistentDexPair() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.NotDexPair.selector);
        buck.removeDexPair(DEX_PAIR);
    }

    // -------------------------------------------------------------------------
    // NOTE: setSwapFees Tests moved to PolicyManager
    // -------------------------------------------------------------------------
    // DEX swap fees (buyFeeBps, sellFeeBps) are now configured via PolicyManager.setDexFees()
    // These tests are now covered in PolicyManagerTest.t.sol

    // -------------------------------------------------------------------------
    // setFeeSplit Tests
    // -------------------------------------------------------------------------

    function testSetFeeSplitEmitsOldAndNewValues() public {
        // Set initial split
        vm.prank(TIMELOCK);
        buck.setFeeSplit(5000); // 50% to reserve

        // Update split - should emit old value
        vm.expectEmit(false, false, false, true);
        emit FeeSplitUpdated(5000, 7000);

        vm.prank(TIMELOCK);
        buck.setFeeSplit(7000); // 70% to reserve

        assertEq(buck.feeToReservePct(), 7000);
    }

    function testSetFeeSplitRejectsInvalidPercentage() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.InvalidFee.selector);
        buck.setFeeSplit(10001); // > 100%
    }

    // -------------------------------------------------------------------------
    // Production Mode Tests
    // -------------------------------------------------------------------------

    function testEnableProductionMode() public {
        // Setup valid configuration
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        assertFalse(buck.productionMode());

        // Enable production mode
        vm.expectEmit(false, false, false, true);
        emit ProductionModeEnabled(block.timestamp);

        vm.prank(TIMELOCK);
        buck.enableProductionMode();

        assertTrue(buck.productionMode());
    }

    function testEnableProductionModeRequiresCriticalAddresses() public {
        // Try to enable without setting critical addresses
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.ProductionModeRequiresCriticalAddresses.selector);
        buck.enableProductionMode();

        // Set only some critical addresses
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            ZERO_ADDRESS, // missing liquidityReserve
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.ProductionModeRequiresCriticalAddresses.selector);
        buck.enableProductionMode();
    }

    function testEnableProductionModeIsOneWaySwitch() public {
        // Setup and enable production mode
        vm.startPrank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );
        buck.enableProductionMode();

        // Try to enable again - should fail
        vm.expectRevert(Buck.ProductionModeAlreadyEnabled.selector);
        buck.enableProductionMode();
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Access Control Tests
    // -------------------------------------------------------------------------

    function testOnlyTimelockCanConfigure() public {
        address attacker = address(0x9999);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        buck.addDexPair(DEX_PAIR);

        // Note: setSwapFees now on PolicyManager, not STRX

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        buck.setFeeSplit(5000);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        buck.enableProductionMode();
    }

    // -------------------------------------------------------------------------
    // Integration Tests
    // -------------------------------------------------------------------------

    function testFullConfigurationFlow() public {
        vm.startPrank(TIMELOCK);

        // Initial configuration in dev mode
        buck.configureModules(
            ZERO_ADDRESS, // Start with zero addresses
            ZERO_ADDRESS,
            ZERO_ADDRESS,
            ZERO_ADDRESS,
            ZERO_ADDRESS,
            ZERO_ADDRESS
        );

        // Configure with real addresses
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            POLICY_MANAGER,
            KYC_REGISTRY,
            REWARDS_HOOK
        );

        // Set up DEX
        buck.addDexPair(DEX_PAIR);
        // Note: DEX fees now configured via PolicyManager.setDexFees()
        buck.setFeeSplit(7000);

        // Enable production mode
        buck.enableProductionMode();

        // Now critical addresses cannot be zero
        vm.expectRevert(
            abi.encodeWithSelector(Buck.CriticalAddressCannotBeZero.selector, "liquidityWindow")
        );
        buck.configureModules(
            ZERO_ADDRESS, LIQUIDITY_RESERVE, TREASURY, POLICY_MANAGER, KYC_REGISTRY, REWARDS_HOOK
        );

        vm.stopPrank();

        // Verify final state
        assertTrue(buck.productionMode());
        assertEq(buck.liquidityWindow(), LIQUIDITY_WINDOW);
        assertEq(buck.liquidityReserve(), LIQUIDITY_RESERVE);
        assertEq(buck.treasury(), TREASURY);
        assertTrue(buck.isDexPair(DEX_PAIR));
        // Note: buyFeeBps/sellFeeBps now on PolicyManager, not STRX
        assertEq(buck.feeToReservePct(), 7000);
    }
}
