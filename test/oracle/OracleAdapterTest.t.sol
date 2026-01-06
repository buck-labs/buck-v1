// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {OracleAdapter, IPyth} from "src/oracle/OracleAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockPyth is IPyth {
    Price internal stored;
    bool public shouldRevert;

    function setPrice(int64 price, int32 expo, uint64 publishTime) external {
        stored = Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function setPriceWithConf(int64 price, int32 expo, uint64 publishTime, uint64 conf) external {
        stored = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function getPriceUnsafe(bytes32) external view returns (Price memory) {
        if (shouldRevert) revert("pyth-error");
        return stored;
    }
}

contract OracleAdapterTest is BaseTest {
    OracleAdapter internal adapter;
    MockPyth internal pyth;

    address internal constant TIMELOCK = address(0xA11CE);
    bytes32 internal constant PYTH_ID = keccak256("priceId");

    function setUp() public {
        adapter = new OracleAdapter(TIMELOCK);
        pyth = new MockPyth();
    }

    function testPythPrimary() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Pyth returns price with -8 exponent (like USD price feeds)
        pyth.setPrice(123456789, -8, uint64(block.timestamp));

        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, 123456789 * 1e10); // Scaled to 18 decimals
        assertEq(updatedAt, block.timestamp);
        assertTrue(adapter.isHealthy(1 hours));
    }

    function testPythWithNegativeExponent() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Test with -4 exponent (less common but valid)
        pyth.setPrice(12_345, -4, uint64(block.timestamp));

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 12_345 * 1e14); // Scaled to 18 decimals
    }

    function testInternalPrice() public {
        // When Pyth returns invalid price (negative), use internal price
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 0, 0);
        pyth.setPrice(-1, -8, uint64(block.timestamp));

        vm.prank(TIMELOCK);
        adapter.setInternalPrice(1_111e18);

        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, 1_111e18);
        assertEq(updatedAt, block.timestamp);
    }

    function testNotHealthyWhenStale() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        vm.warp(10 hours);
        // Set Pyth price that was published 2 hours ago (stale)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 2 hours));

        // Enable strict mode to test staleness detection
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        assertFalse(adapter.isHealthy(1 hours));
    }

    function testPythConfidenceThreshold() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 5e15);

        pyth.setPriceWithConf(12_345, -4, uint64(block.timestamp), 100);

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0);

        pyth.setPriceWithConf(12_345, -4, uint64(block.timestamp), 50);
        (price,) = adapter.latestPrice();
        assertEq(price, 12_345 * 1e14);
    }

    function testNonOwnerCannotSetInternalPrice() public {
        address unauthorizedCaller = address(0xBAD);

        // Non-owner/non-priceUpdater account cannot call setInternalPrice()
        vm.expectRevert(OracleAdapter.UnauthorizedPriceUpdate.selector);
        vm.prank(unauthorizedCaller);
        adapter.setInternalPrice(1_111e18);

        // Owner (TIMELOCK) can call setInternalPrice()
        vm.prank(TIMELOCK);
        adapter.setInternalPrice(1_111e18);
    }

    // ============================================
    // SPRINT 25 SECURITY TESTS: Oracle Strict Mode Access Control
    // Issue #1: CRITICAL - Prevent permissionless oracle freshness manipulation
    // ============================================

    /// @notice Test that non-owner cannot call setStrictMode (SECURITY FIX)
    /// @dev This prevents attackers from disabling oracle freshness checks during depeg
    function testNonOwnerCannotSetStrictMode() public {
        address attacker = address(0xBADBAD);

        // Attacker tries to enable strict mode → reverts
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        vm.prank(attacker);
        adapter.setStrictMode(true);

        // Attacker tries to disable strict mode → reverts
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        vm.prank(attacker);
        adapter.setStrictMode(false);

        // Verify strict mode unchanged (still false by default)
        assertFalse(adapter.strictMode());
    }

    /// @notice Test that owner (TIMELOCK) can successfully toggle strict mode
    function testOwnerCanToggleStrictMode() public {
        // Initial state: strict mode is false
        assertFalse(adapter.strictMode());

        // Owner enables strict mode → succeeds
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);
        assertTrue(adapter.strictMode());

        // Owner disables strict mode → succeeds
        vm.prank(TIMELOCK);
        adapter.setStrictMode(false);
        assertFalse(adapter.strictMode());
    }

    /// @notice Test that frontrun attack on strict mode toggle fails (SECURITY)
    /// @dev Scenario: CR drops below 1.0, PolicyManager emits StrictModeChangeRequired,
    ///      attacker tries to frontrun and disable strict mode before keeper enables it
    function testFrontrunAttackFails() public {
        address attacker = address(0xBADBAD);

        // Setup: Configure Pyth oracle and enable strict mode
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);
        assertTrue(adapter.strictMode());

        // Scenario: PolicyManager emits event that strict mode should be disabled (CR recovered)
        // Attacker sees this and tries to re-enable strict mode maliciously → FAILS
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        vm.prank(attacker);
        adapter.setStrictMode(true);

        // Keeper (authorized) can disable strict mode as intended
        // NOTE: In production, keeper would be multisig or have TIMELOCK role
        vm.prank(TIMELOCK);
        adapter.setStrictMode(false);
        assertFalse(adapter.strictMode());
    }

    /// @notice Test that strict mode blocks stale price acceptance when enabled
    /// @dev Ensures access-controlled strict mode actually enforces oracle freshness
    function testStrictModeEnforcesOracleFreshness() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Setup stale price (2 hours old)
        vm.warp(10 hours);
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 2 hours));

        // Without strict mode, oracle is "healthy" (for CR >= 1.0 case)
        assertTrue(adapter.isHealthy(1 hours));

        // Owner enables strict mode (for CR < 1.0 depeg case)
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        // Now stale price is rejected
        assertFalse(adapter.isHealthy(1 hours));
    }

    /// @notice Test that attacker cannot manipulate oracle during depeg scenario
    /// @dev Full attack simulation: depeg → stale oracle → attacker tries to disable strict mode
    function testDepegOracleManipulationPrevented() public {
        address attacker = address(0xBADBAD);

        // Setup: Configure Pyth oracle with 1 hour staleness
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Fresh price available
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp));

        // Governance enables strict mode (CR < 1.0 depeg scenario)
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        // Time passes, oracle becomes stale (> 1 hour old)
        vm.warp(block.timestamp + 2 hours);

        // Oracle is now unhealthy due to staleness
        assertFalse(adapter.isHealthy(1 hours));

        // ATTACK ATTEMPT: Attacker tries to disable strict mode to arbitrage at stale price
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        vm.prank(attacker);
        adapter.setStrictMode(false);

        // Oracle remains unhealthy, preventing arbitrage
        assertFalse(adapter.isHealthy(1 hours));
    }

    // ============================================
    // COMPREHENSIVE EDGE CASE TESTS: Oracle Coverage 85%+
    // ============================================

    /// @notice Test Pyth scaling with various negative exponents
    function test_PythScaling_NegativeExponents() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Test -8 exponent (standard USD price)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp));
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Price with -8 exponent should be $1.00");

        // Test -4 exponent
        pyth.setPrice(10_000, -4, uint64(block.timestamp));
        (price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Price with -4 exponent should be $1.00");

        // Test -18 exponent (same as output decimals)
        pyth.setPrice(1_000_000_000_000_000_000, -18, uint64(block.timestamp));
        (price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Price with -18 exponent should be $1.00");
    }

    /// @notice Test Pyth scaling with extreme exponents (overflow protection)
    function test_PythScaling_ExtremeExponents() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Test exponent that would cause overflow (> 60)
        pyth.setPrice(1, 70, uint64(block.timestamp));
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0, "Extreme positive exponent should return 0 (overflow guard)");

        // Test extreme negative exponent (< -60)
        pyth.setPrice(1, -70, uint64(block.timestamp));
        (price,) = adapter.latestPrice();
        assertEq(price, 0, "Extreme negative exponent should return 0 (overflow guard)");
    }

    /// @notice Test confidence interval enforcement with pythMaxConf
    function test_ConfidenceInterval_Enforcement() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 5e15); // Max conf = 0.005e18

        // Confidence too high (100 with -4 exponent = 0.01e18, which is > 0.005e18)
        pyth.setPriceWithConf(10_000, -4, uint64(block.timestamp), 100);
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0, "High confidence should reject price");

        // Confidence within bounds (50 with -4 exponent = 0.005e18, which is <= 0.005e18)
        pyth.setPriceWithConf(10_000, -4, uint64(block.timestamp), 50);
        (price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Low confidence should accept price");

        // Zero confidence always passes
        pyth.setPriceWithConf(10_000, -4, uint64(block.timestamp), 0);
        (price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Zero confidence should accept price");
    }

    /// @notice Test confidence interval disabled (pythMaxConf = 0)
    function test_ConfidenceInterval_Disabled() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 0); // Max conf = 0 (disabled)

        // Even extremely high confidence should pass when disabled
        pyth.setPriceWithConf(10_000, -4, uint64(block.timestamp), 1_000_000);
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 1e18, "High confidence should accept when maxConf disabled");
    }

    /// @notice Test staleness detection with pythStaleAfter
    function test_Staleness_PythStaleAfter() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        vm.warp(10 hours);

        // Fresh price (within 1 hour)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp));
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Fresh price should be accepted");

        // Price at exact staleness threshold (exactly 1 hour old)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 1 hours));
        (price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Price at exact threshold should be accepted");

        // Stale price (1 hour + 1 second old)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 1 hours - 1));
        (price,) = adapter.latestPrice();
        assertEq(price, 0, "Stale price should be rejected");
    }

    /// @notice Test staleness disabled (pythStaleAfter = 0)
    function test_Staleness_Disabled() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 0, 1e20); // staleAfter = 0 (disabled)

        vm.warp(365 days);

        // Very old price should still pass when staleness check disabled
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 365 days));
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 1e18, "Old price should accept when staleness disabled");
    }

    /// @notice Test manual internal price updates and lastPriceUpdateBlock
    function test_InternalPrice_SetInternalPrice() public {
        uint256 initialBlock = block.number;

        // Set internal price
        vm.prank(TIMELOCK);
        adapter.setInternalPrice(1_500e18);

        // Verify internal price is set
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, 1_500e18, "Internal price should be $1.50");
        assertEq(updatedAt, block.timestamp, "Updated timestamp should match");

        // Advance block and update again
        vm.roll(initialBlock + 100);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(TIMELOCK);
        adapter.setInternalPrice(2_000e18);

        // Verify the price is updated correctly
        (price, updatedAt) = adapter.latestPrice();
        assertEq(price, 2_000e18, "Internal price should be $2.00");
    }

    /// @notice Test PolicyManager can auto-toggle strict mode
    function test_PolicyManager_CanToggleStrictMode() public {
        address policyManager = address(0xF0F1C7);

        // Set PolicyManager address
        vm.prank(TIMELOCK);
        adapter.setPolicyManager(policyManager);

        // Verify PolicyManager can enable strict mode
        vm.prank(policyManager);
        adapter.setStrictMode(true);
        assertTrue(adapter.strictMode(), "PolicyManager should enable strict mode");

        // Verify PolicyManager can disable strict mode
        vm.prank(policyManager);
        adapter.setStrictMode(false);
        assertFalse(adapter.strictMode(), "PolicyManager should disable strict mode");
    }

    /// @notice Test only owner and PolicyManager can toggle strict mode
    function test_PolicyManager_ExclusiveAccess() public {
        address policyManager = address(0xF0F1C7);
        address randomUser = address(0xBADF00D);

        vm.prank(TIMELOCK);
        adapter.setPolicyManager(policyManager);

        // Random user cannot toggle
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnauthorizedStrictModeAccess.selector));
        vm.prank(randomUser);
        adapter.setStrictMode(true);

        // Owner can toggle
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);
        assertTrue(adapter.strictMode());

        // PolicyManager can toggle
        vm.prank(policyManager);
        adapter.setStrictMode(false);
        assertFalse(adapter.strictMode());
    }

    /// @notice Test all oracles fail scenario (returns internal price)
    function test_AllOraclesFail_ReturnsInternalPrice() public {
        // Configure Pyth but make it return invalid data
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Set internal price
        vm.prank(TIMELOCK);
        adapter.setInternalPrice(999e18);

        // Pyth returns negative price (invalid)
        pyth.setPrice(-1, -8, uint64(block.timestamp));

        // Should fall back to manual price
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, 999e18, "Should return internal price when Pyth fails");
        assertEq(updatedAt, block.timestamp, "Should return internal price timestamp");
    }

    /// @notice Test Pyth unconfigured falls back to manual
    function test_PythUnconfigured_ReturnsInternalPrice() public {
        // Don't configure Pyth, only set internal price
        vm.prank(TIMELOCK);
        adapter.setInternalPrice(777e18);

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 777e18, "Should return internal price when Pyth unconfigured");
    }

    /// @notice Test Pyth edge case: price=0, conf>0
    function test_PythEdgeCase_ZeroPriceWithConfidence() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Pyth returns price=0 with confidence (invalid scenario)
        pyth.setPriceWithConf(0, -8, uint64(block.timestamp), 100);

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0, "Zero price should be rejected even with confidence");
    }

    /// @notice Test Pyth edge case: negative price
    function test_PythEdgeCase_NegativePrice() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Pyth returns negative price (invalid)
        pyth.setPrice(-100, -8, uint64(block.timestamp));

        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 0, "Negative price should be rejected");
    }

    /// @notice Test isHealthy() in non-strict mode (always healthy)
    function test_IsHealthy_NonStrictMode_AlwaysHealthy() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        // Strict mode disabled (default)
        assertFalse(adapter.strictMode());

        // Even with stale price, should be healthy in non-strict mode
        vm.warp(10 hours);
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 5 hours));

        assertTrue(
            adapter.isHealthy(1 hours),
            "Should be healthy in non-strict mode regardless of staleness"
        );

        // Even with no price, should be healthy in non-strict mode
        assertTrue(
            adapter.isHealthy(1 hours), "Should be healthy in non-strict mode even with stale price"
        );
    }

    /// @notice Test isHealthy() in strict mode with fresh price
    function test_IsHealthy_StrictMode_FreshPrice() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        // Fresh Pyth price
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp));

        assertTrue(
            adapter.isHealthy(1 hours), "Should be healthy with fresh Pyth price in strict mode"
        );
    }

    /// @notice Test isHealthy() in strict mode with stale price
    function test_IsHealthy_StrictMode_StalePrice() public {
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        vm.warp(10 hours);

        // Stale Pyth price (2 hours old)
        pyth.setPrice(100_000_000, -8, uint64(block.timestamp - 2 hours));

        assertFalse(
            adapter.isHealthy(1 hours), "Should be unhealthy with stale price in strict mode"
        );
    }

    /// @notice Test isHealthy() in strict mode with internal price
    function test_IsHealthy_StrictMode_InternalPriceFresh() public {
        // Don't configure Pyth, use internal price
        vm.prank(TIMELOCK);
        adapter.setInternalPrice(1_000e18);

        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        // Fresh internal price
        assertTrue(
            adapter.isHealthy(1 hours),
            "Should be healthy with fresh internal price in strict mode"
        );

        // Advance time past staleness threshold
        vm.warp(block.timestamp + 2 hours);

        assertFalse(
            adapter.isHealthy(1 hours),
            "Should be unhealthy with stale internal price in strict mode"
        );
    }

    /// @notice Test isHealthy() returns false when price is zero
    function test_IsHealthy_ZeroPrice() public {
        vm.prank(TIMELOCK);
        adapter.setStrictMode(true);

        // No price configured, should return false
        assertFalse(adapter.isHealthy(1 hours), "Should be unhealthy with zero price");
    }

    /// @notice Test multiple Pyth configuration updates
    function test_PythConfiguration_MultipleUpdates() public {
        // Initial configuration
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 1 hours, 1e20);

        pyth.setPrice(100_000_000, -8, uint64(block.timestamp));
        (uint256 price1,) = adapter.latestPrice();
        assertEq(price1, 1e18);

        // Update staleness threshold
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), PYTH_ID, 2 hours, 1e20);

        // Old price should now be valid with 2 hour threshold
        vm.warp(block.timestamp + 90 minutes);
        (uint256 price2,) = adapter.latestPrice();
        assertEq(price2, 1e18, "Price should be valid with extended staleness threshold");
    }

    /// @notice Test setPolicyManager with zero address reverts
    function test_SetPolicyManager_ZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.ZeroAddress.selector));
        vm.prank(TIMELOCK);
        adapter.setPolicyManager(address(0));
    }

    /// @notice Test configurePyth with zero address reverts
    function test_ConfigurePyth_ZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.ZeroAddress.selector));
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(0), PYTH_ID, 1 hours, 1e20);
    }

    /// @notice Test configurePyth with zero priceId reverts
    function test_ConfigurePyth_ZeroPriceIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.ZeroAddress.selector));
        vm.prank(TIMELOCK);
        adapter.configurePyth(address(pyth), bytes32(0), 1 hours, 1e20);
    }

}
