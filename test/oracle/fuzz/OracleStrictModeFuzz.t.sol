// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OracleStrictModeFuzz
 * @notice FUZZ TESTS: Oracle strict mode access control with random actors
 * @dev Sprint 30 - Fuzz Testing for Audit Fixes
 *      Tests that ONLY owner can toggle strict mode, no matter what random address tries
 */
contract OracleStrictModeFuzz is BaseTest {
    OracleAdapter internal oracle;

    address internal constant TIMELOCK = address(0xA11CE);

    function setUp() public {
        oracle = new OracleAdapter(TIMELOCK);
    }

    // ============================================================================
    // FUZZ TEST 1: Random actors cannot enable strict mode
    // ============================================================================

    /// @notice Fuzz: Random unauthorized actors cannot enable strict mode
    /// @dev Tests that access control blocks all non-owner addresses
    function testFuzz_RandomActorCannotEnableStrictMode(address attacker) public {
        // Exclude legitimate owner from fuzz inputs
        vm.assume(attacker != TIMELOCK);
        vm.assume(attacker != address(0)); // OpenZeppelin checks for zero address

        // Verify strict mode is off initially
        assertFalse(oracle.strictMode(), "Strict mode should start disabled");

        // Random attacker tries to enable strict mode
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        oracle.setStrictMode(true);

        // Verify strict mode still disabled
        assertFalse(oracle.strictMode(), "Strict mode should remain disabled after attack");
    }

    /// @notice Fuzz: Random unauthorized actors cannot disable strict mode
    /// @dev Tests that attackers cannot disable strict mode during depeg scenarios
    function testFuzz_RandomActorCannotDisableStrictMode(address attacker) public {
        // Exclude legitimate owner from fuzz inputs
        vm.assume(attacker != TIMELOCK);
        vm.assume(attacker != address(0));

        // Setup: Owner enables strict mode (depeg scenario)
        vm.prank(TIMELOCK);
        oracle.setStrictMode(true);
        assertTrue(oracle.strictMode(), "Strict mode should be enabled");

        // Random attacker tries to disable strict mode
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        oracle.setStrictMode(false);

        // Verify strict mode still enabled
        assertTrue(oracle.strictMode(), "Strict mode should remain enabled after attack");
    }

    // ============================================================================
    // FUZZ TEST 2: Random actors with random bool states
    // ============================================================================

    /// @notice Fuzz: Random actors cannot toggle strict mode to any state
    /// @dev Fuzzes both the actor address AND the desired state
    function testFuzz_RandomActorCannotToggleToAnyState(address attacker, bool desiredState)
        public
    {
        // Exclude legitimate owner
        vm.assume(attacker != TIMELOCK);
        vm.assume(attacker != address(0));

        // Record initial state
        bool initialState = oracle.strictMode();

        // Random attacker tries to set strict mode to random state
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        oracle.setStrictMode(desiredState);

        // Verify state unchanged
        assertEq(oracle.strictMode(), initialState, "State should be unchanged after attack");
    }

    // ============================================================================
    // FUZZ TEST 3: Multiple sequential attack attempts
    // ============================================================================

    /// @notice Fuzz: Multiple random actors in sequence cannot bypass access control
    /// @dev Tests that repeated attacks from different addresses all fail
    function testFuzz_MultipleRandomActorsCannotBypassAccessControl(address[5] memory attackers)
        public
    {
        // Setup: Owner enables strict mode
        vm.prank(TIMELOCK);
        oracle.setStrictMode(true);

        // Try multiple attacks from different random addresses
        for (uint256 i = 0; i < attackers.length; i++) {
            address attacker = attackers[i];

            // Skip if attacker is owner or zero address
            if (attacker == TIMELOCK || attacker == address(0)) continue;

            // Each attacker tries to disable strict mode
            vm.prank(attacker);
            vm.expectRevert(
                abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector)
            );
            oracle.setStrictMode(false);

            // Verify strict mode still enabled after each attack
            assertTrue(oracle.strictMode(), "Strict mode should remain enabled");
        }
    }

    // ============================================================================
    // FUZZ TEST 4: Owner can always toggle (sanity check)
    // ============================================================================

    /// @notice Fuzz: Owner can toggle strict mode to any state (sanity check)
    /// @dev Ensures access control allows legitimate owner to operate
    function testFuzz_OwnerCanToggleToAnyState(bool desiredState) public {
        // Owner sets strict mode to random state
        vm.prank(TIMELOCK);
        oracle.setStrictMode(desiredState);

        // Verify state matches desired
        assertEq(oracle.strictMode(), desiredState, "Owner should be able to set any state");
    }

    // ============================================================================
    // FUZZ TEST 5: Contract addresses cannot toggle strict mode
    // ============================================================================

    /// @notice Fuzz: Random contract addresses cannot toggle strict mode
    /// @dev Tests that even contracts cannot bypass access control
    function testFuzz_RandomContractsCannotToggleStrictMode(uint256 contractSeed) public {
        // Generate deterministic contract address from seed
        address attackerContract =
            address(uint160(uint256(keccak256(abi.encodePacked(contractSeed)))));

        // Ensure it's not the owner
        vm.assume(attackerContract != TIMELOCK);
        vm.assume(attackerContract != address(0));

        // Try to enable strict mode from contract address
        vm.prank(attackerContract);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        oracle.setStrictMode(true);

        // Verify still disabled
        assertFalse(oracle.strictMode(), "Contract should not be able to enable strict mode");
    }

    // ============================================================================
    // FUZZ TEST 6: Frontrun attack scenario with random timing
    // ============================================================================

    /// @notice Fuzz: Attacker cannot frontrun keeper's strict mode toggle
    /// @dev Simulates depeg scenario with random block/timestamp advances
    function testFuzz_CannotFrontrunStrictModeToggle(
        address attacker,
        uint256 blockAdvance,
        uint256 timeAdvance
    ) public {
        // Bound inputs to reasonable ranges
        vm.assume(attacker != TIMELOCK && attacker != address(0));
        blockAdvance = bound(blockAdvance, 1, 1000);
        timeAdvance = bound(timeAdvance, 1 hours, 30 days);

        // Setup: Strict mode is enabled (depeg scenario)
        vm.prank(TIMELOCK);
        oracle.setStrictMode(true);

        // Time passes (simulating depeg recovery period)
        vm.warp(block.timestamp + timeAdvance);
        vm.roll(block.number + blockAdvance);

        // Attacker sees keeper transaction to disable strict mode and tries to frontrun
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        oracle.setStrictMode(true); // Try to re-enable before keeper disables

        // Keeper's legitimate transaction succeeds
        vm.prank(TIMELOCK);
        oracle.setStrictMode(false);

        // Verify strict mode is now disabled (keeper succeeded)
        assertFalse(oracle.strictMode(), "Keeper should successfully disable strict mode");
    }

    // ============================================================================
    // FUZZ TEST 7: Random actor cannot configure oracle settings
    // ============================================================================

    /// @notice Fuzz: Random actors cannot configure Pyth feed
    function testFuzz_RandomActorCannotConfigurePyth(
        address attacker,
        address randomPyth,
        bytes32 randomPriceId,
        uint256 randomStaleThreshold,
        uint256 randomMaxConf
    ) public {
        vm.assume(attacker != TIMELOCK && attacker != address(0));
        randomStaleThreshold = bound(randomStaleThreshold, 0, 365 days);
        randomMaxConf = bound(randomMaxConf, 0, 1e20);

        // Attacker tries to configure Pyth feed
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        oracle.configurePyth(randomPyth, randomPriceId, randomStaleThreshold, randomMaxConf);
    }

    /// @notice Fuzz: Random actors cannot set internal price
    function testFuzz_RandomActorCannotSetInternalPrice(address attacker, uint256 randomPrice)
        public
    {
        vm.assume(attacker != TIMELOCK && attacker != address(0));
        vm.assume(attacker != oracle.priceUpdater()); // Also exclude priceUpdater
        randomPrice = bound(randomPrice, 0.01e18, 100e18); // $0.01 to $100

        // Attacker tries to set internal price
        vm.prank(attacker);
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        oracle.setInternalPrice(randomPrice);
    }

    // ============================================================================
    // FUZZ TEST 8: High-frequency attack attempts
    // ============================================================================

    /// @notice Fuzz: Rapid repeated attempts from same attacker all fail
    /// @dev Tests that access control doesn't have race conditions
    function testFuzz_RapidAttackAttemptsFail(address attacker, uint8 numAttempts) public {
        vm.assume(attacker != TIMELOCK && attacker != address(0));
        numAttempts = uint8(bound(numAttempts, 1, 100));

        // Enable strict mode
        vm.prank(TIMELOCK);
        oracle.setStrictMode(true);

        // Rapid-fire attack attempts
        for (uint256 i = 0; i < numAttempts; i++) {
            vm.prank(attacker);
            vm.expectRevert(
                abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector)
            );
            oracle.setStrictMode(false);

            // Fast-forward minimal time
            vm.warp(block.timestamp + 1);
        }

        // Verify strict mode still enabled after all attempts
        assertTrue(oracle.strictMode(), "Strict mode should survive rapid attacks");
    }
}
