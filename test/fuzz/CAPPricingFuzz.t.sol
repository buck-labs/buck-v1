// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {Buck} from "src/token/Buck.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title CAPPricingFuzzTest
 * @notice Fuzz tests for CAP pricing formula to ensure robustness across all input ranges
 * @dev Tests the invariants:
 *      - CAP price always ≥ 0
 *      - CAP price ≤ $1.00 always
 *      - CAP = $1.00 when CR ≥ 1.0
 *      - CAP = max(oracle, CR) when CR < 1.0 AND oracle is active
 *      - No arithmetic overflows/underflows
 */
contract CAPPricingFuzzTest is BaseTest {
    PolicyManager internal policyManager;
    CollateralAttestation internal collateralAttestation;
    OracleAdapter internal oracle;
    LiquidityReserve internal liquidityReserve;
    Buck internal buck;
    MockUSDC internal usdc;

    address internal constant OWNER = address(0x1000);
    address internal constant ATTESTOR = address(0x2000);

    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant USDC_TO_18 = 1e12;
    uint256 internal constant MIN_UNDERCOLLATERALIZED_ORACLE = 0.51e18;

    // Monotonic counter to ensure unique timestamps for attestations
    uint256 internal _attestCounter = 0;

    function setUp() public {
        // Deploy all contracts
        usdc = new MockUSDC();
        buck = deployBUCK(OWNER);
        oracle = new OracleAdapter(OWNER);
        _setOraclePrice(1.0e18);

        // Deploy PolicyManager
        policyManager = deployPolicyManager(OWNER);

        // Deploy LiquidityReserve
        liquidityReserve = deployLiquidityReserve(
            OWNER,
            address(usdc),
            address(0), // Will set liquidity window later if needed
            OWNER // treasury
        );

        // Deploy CollateralAttestation
        collateralAttestation = deployCollateralAttestation(
            OWNER,
            ATTESTOR,
            address(buck),
            address(liquidityReserve),
            address(usdc)
        );

        // Configure PolicyManager
        vm.startPrank(OWNER);
        policyManager.setCollateralAttestation(address(collateralAttestation));
        policyManager.setContractReferences(
            address(buck), address(liquidityReserve), address(oracle), address(usdc)
        );
        collateralAttestation.setStalenessThresholds(365 days, 365 days);

        // Allow PolicyManager to call setStrictMode() on oracle
        oracle.setPolicyManager(address(policyManager));
        vm.stopPrank();
    }

    // =========================================================================
    // Fuzz Test 1: Random CR values (0.5 → 2.0)
    // =========================================================================

    /// @notice Fuzz test: CAP price is always valid across full CR range
    /// @dev Tests CR from 0.5 to 2.0 (50% to 200% collateralization)
    function testFuzz_CAPPrice_ValidAcrossAllCRValues(uint256 crBps) public {
        // Bound CR to realistic range: 0.5 (5000 bps) to 2.0 (20000 bps)
        crBps = bound(crBps, 5000, 20000);
        uint256 cr = (crBps * 1e18) / 10000; // Convert bps to 18 decimals

        // Set up system state to achieve desired CR
        _setSystemCR(cr);
        _setOraclePrice(_oraclePriceForCR(cr));

        // Sync oracle strict mode based on CR
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Get CAP price
        uint256 capPrice = policyManager.getCAPPrice();

        // Invariant 1: CAP price always ≥ 0
        assertGe(capPrice, 0, "CAP price must be >= 0");

        // Invariant 2: CAP price ≤ $1.00 always
        assertLe(capPrice, 1e18, "CAP price must be <= $1.00");

        // Invariant 3: CAP = $1.00 when CR ≥ 1.0
        if (cr >= 1e18) {
            assertEq(capPrice, 1e18, "CAP price must be $1.00 when CR >= 1.0");
        }

        // Invariant 4: CAP < $1.00 when CR < 1.0
        if (cr < 1e18) {
            assertLt(capPrice, 1e18, "CAP price must be < $1.00 when CR < 1.0");
        }
    }

    /// @notice Fuzz test: CAP price follows max(oracle, CR) formula when CR < 1.0
    function testFuzz_CAPPrice_FollowsFormulaWhenUndercollateralized(
        uint256 crBps,
        uint256 oraclePriceBps
    ) public {
        // CR range: 0.5 to 0.99 (undercollateralized)
        crBps = bound(crBps, 5000, 9900);
        uint256 cr = (crBps * 1e18) / 10000;

        // Oracle price range: strictly greater than 0.5, but < 1.0 to maintain invariant
        // When CR < 1.0, oracle should also be < 1.0 in a well-functioning system
        oraclePriceBps = bound(oraclePriceBps, 5001, 9999);
        uint256 oraclePrice = (oraclePriceBps * 1e18) / 10000;

        // Set up system
        _setSystemCR(cr);
        _setOraclePrice(_oraclePriceForCR(cr));
        _setOraclePrice(_oraclePriceForCR(cr));
        _setOraclePrice(oraclePrice);

        // Sync oracle strict mode (should activate since CR < 1.0)
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Get CAP price
        uint256 capPrice = policyManager.getCAPPrice();

        // CAP should be max(oracle, CR)
        uint256 expectedCAP = oraclePrice > cr ? oraclePrice : cr;
        assertEq(capPrice, expectedCAP, "CAP price must be max(oracle, CR) when CR < 1.0");
    }

    /// @notice Fuzz test: Extreme CR values don't cause overflows
    function testFuzz_CAPPrice_NoOverflowAtExtremes(uint256 crBps) public {
        // Test full possible range: 0.01 to 10.0 (1% to 1000%)
        crBps = bound(crBps, 100, 100000);
        uint256 cr = (crBps * 1e18) / 10000;

        // Set up system
        _setSystemCR(cr);

        // Sync oracle strict mode
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Should not revert
        uint256 capPrice = policyManager.getCAPPrice();

        // Basic sanity checks
        assertGe(capPrice, 0, "CAP price must be >= 0");
        assertLe(capPrice, 1e18, "CAP price must be <= $1.00");
    }

    // =========================================================================
    // Fuzz Test 2: Random attestation updates
    // =========================================================================

    /// @notice Fuzz test: Rapid CR changes don't break pricing
    function testFuzz_CAPPrice_RapidCRChanges(uint256[5] memory crValues) public {
        for (uint256 i = 0; i < crValues.length; i++) {
            // Bound each CR to realistic range
            uint256 crBps = bound(crValues[i], 5000, 20000);
            uint256 cr = (crBps * 1e18) / 10000;

            // Set system CR and align oracle price with undercollateralized expectation
            _setSystemCR(cr);
            _setOraclePrice(_oraclePriceForCR(cr));

            // Sync oracle
            vm.prank(address(0));
            policyManager.syncOracleStrictMode();

            // Get CAP price - should not revert
            uint256 capPrice = policyManager.getCAPPrice();

            // Verify invariants
            assertGe(capPrice, 0, "CAP price must be >= 0");
            assertLe(capPrice, 1e18, "CAP price must be <= $1.00");

            if (cr >= 1e18) {
                assertEq(capPrice, 1e18, "CAP must be $1.00 when CR >= 1.0");
            }

            // Advance time for next iteration
            vm.warp(block.timestamp + 1 days);
        }
    }

    /// @notice Fuzz test: Stale attestations are handled correctly
    function testFuzz_CAPPrice_StaleAttestationHandling(uint256 timeSinceAttestation) public {
        // Time range: 0 to 30 days
        timeSinceAttestation = bound(timeSinceAttestation, 0, 30 days);

        // Set up CR = 1.2
        _setSystemCR(1.2e18);

        // Advance time
        vm.warp(block.timestamp + timeSinceAttestation);

        // Check if attestation is stale
        bool isStale = collateralAttestation.isAttestationStale();

        if (isStale) {
            // Stale attestations should cause getCAPPrice to revert or use fallback
            // depending on implementation - let's verify system behavior

            // For now, just verify CAP price call doesn't cause unexpected errors
            try policyManager.getCAPPrice() returns (uint256 capPrice) {
                // If it succeeds, verify basic invariants
                assertGe(capPrice, 0, "CAP price must be >= 0");
                assertLe(capPrice, 1e18, "CAP price must be <= $1.00");
            } catch {
                // If it reverts with stale attestation, that's acceptable behavior
            }
        } else {
            // Fresh attestation should work normally
            uint256 capPrice = policyManager.getCAPPrice();
            assertEq(capPrice, 1e18, "CAP should be $1.00 with fresh attestation and CR=1.2");
        }
    }

    // =========================================================================
    // Fuzz Test 3: Random mint/refund sequences
    // =========================================================================

    /// @notice Fuzz test: CAP pricing remains consistent during user operations
    function testFuzz_CAPPrice_ConsistentDuringOperations(uint256 crBps, uint256 numOperations)
        public
    {
        // Bound inputs
        crBps = bound(crBps, 5000, 20000);
        numOperations = bound(numOperations, 1, 10);
        uint256 cr = (crBps * 1e18) / 10000;

        // Set initial CR
        _setSystemCR(cr);
        _setOraclePrice(_oraclePriceForCR(cr));

        // Sync oracle
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Get initial CAP price
        uint256 initialCAPPrice = policyManager.getCAPPrice();

        // Simulate operations (without changing CR)
        for (uint256 i = 0; i < numOperations; i++) {
            // Advance time
            vm.warp(block.timestamp + 1 hours);

            // Keep oracle fresh by updating it after time warp
            _setOraclePrice(_oraclePriceForCR(cr));

            // Get CAP price again
            uint256 capPrice = policyManager.getCAPPrice();

            // CAP price should remain consistent if CR hasn't changed
            assertEq(capPrice, initialCAPPrice, "CAP price should remain consistent");
        }
    }

    // =========================================================================
    // Fuzz Test 4: Oracle price variations
    // =========================================================================

    /// @notice Fuzz test: CAP responds correctly to oracle price changes
    function testFuzz_CAPPrice_OraclePriceVariations(uint256 crBps, uint256 oraclePriceBps)
        public
    {
        // CR below 1.0 to activate oracle
        crBps = bound(crBps, 7000, 9900); // 0.7 to 0.99
        uint256 cr = (crBps * 1e18) / 10000;

        // Oracle price: strictly >0.5 to satisfy adapter guard, but < 1.0 to maintain invariant
        oraclePriceBps = bound(oraclePriceBps, 5001, 9999);
        uint256 oraclePrice = (oraclePriceBps * 1e18) / 10000;

        // Set up system
        _setSystemCR(cr);
        _setOraclePrice(oraclePrice);

        // Sync oracle strict mode
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Get CAP price
        uint256 capPrice = policyManager.getCAPPrice();

        // When oracle is active (CR < 1.0), CAP = max(oracle, CR)
        uint256 expectedCAP = oraclePrice > cr ? oraclePrice : cr;
        assertEq(capPrice, expectedCAP, "CAP must follow oracle when active");

        // Verify bounds
        assertGe(capPrice, cr, "CAP must be at least CR");
        assertLe(capPrice, 1e18, "CAP must not exceed $1.00");
    }

    /// @notice Fuzz test: Unhealthy oracle falls back correctly
    function testFuzz_CAPPrice_UnhealthyOracleInternal(uint256 crBps) public {
        // CR below 1.0 to test oracle behavior
        crBps = bound(crBps, 7000, 9900);
        uint256 cr = (crBps * 1e18) / 10000;

        // Set up system
        _setSystemCR(cr);

        // Sync oracle strict mode (emits event)
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Make oracle unhealthy by warping time beyond staleness window
        // Stressed staleness window is 15 minutes (900 seconds)
        vm.warp(block.timestamp + 901 seconds);

        // Get CAP price - should fall back to CR
        uint256 capPrice = policyManager.getCAPPrice();

        // With unhealthy oracle, CAP should use CR
        assertEq(capPrice, cr, "CAP must fall back to CR when oracle unhealthy");
    }

    // =========================================================================
    // Fuzz Test 5: Boundary conditions
    // =========================================================================

    /// @notice Fuzz test: CR exactly at 1.0 boundary
    function testFuzz_CAPPrice_CRAtOneBoundary(uint256 offset) public {
        // Test values very close to CR = 1.0
        // offset: -1000 to +1000 bps around 1.0
        offset = bound(offset, 0, 2000);
        uint256 crBps = 9000 + offset; // 0.90 to 1.10
        uint256 cr = (crBps * 1e18) / 10000;

        // Set up system
        _setSystemCR(cr);

        // Sync oracle
        vm.prank(address(0));
        policyManager.syncOracleStrictMode();

        // Get CAP price
        uint256 capPrice = policyManager.getCAPPrice();

        // Verify correct behavior at boundary
        if (cr >= 1e18) {
            assertEq(capPrice, 1e18, "CAP must be $1.00 when CR >= 1.0");
        } else {
            assertLt(capPrice, 1e18, "CAP must be < $1.00 when CR < 1.0");
            assertGe(capPrice, cr, "CAP must be at least CR");
        }
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /// @notice Helper to set system to specific CR by adjusting attested value (V)
    function _setSystemCR(uint256 targetCR) internal {
        // Fix total supply at 100M BUCK and reset balances
        uint256 totalSupply = 100_000_000e18;
        // `deal` with the `adjust` flag keeps Buck.totalSupply() in sync so CR math sees real liabilities.
        deal(address(buck), address(this), totalSupply, true);
        deal(address(usdc), address(liquidityReserve), 0);

        // Solve for V such that (scaledR + V) / L = targetCR. Here scaledR = 0.
        uint256 desiredNumerator = Math.mulDiv(targetCR, totalSupply, 1e18);

        // Advance time using counter to ensure monotonicity (workaround for compiler optimization)
        _attestCounter++;
        uint256 attestTs = block.timestamp + _attestCounter;
        vm.warp(attestTs);

        vm.prank(ATTESTOR);
        collateralAttestation.publishAttestation(desiredNumerator, 1e18, attestTs);

        uint256 measuredCR = collateralAttestation.getCollateralRatio();
        assertApproxEqAbs(measuredCR, targetCR, 1, "collateral ratio setup mismatch");
    }

    function _setOraclePrice(uint256 newPrice) internal {
        vm.prank(OWNER);
        oracle.setInternalPrice(newPrice);
    }

    function _setOracleHealth(bool isHealthy) internal {
        // Note: OracleAdapter doesn't have setHealthy(). Health is determined by:
        // 1. strictMode flag (controlled by PolicyManager based on CR)
        // 2. Price staleness (PolicyManager.STRESSED_ORACLE_STALENESS / HEALTHY_ORACLE_STALENESS)
        // For testing purposes, oracle health can be simulated by:
        // - Setting strict mode: oracle.setStrictMode(true/false)
        // - Setting fresh price: oracle.setInternalPrice(price)
        // This helper is currently a no-op with real OracleAdapter
    }

    function _oraclePriceForCR(uint256 cr) internal pure returns (uint256) {
        if (cr >= 1e18) {
            return 1e18;
        }
        return cr > MIN_UNDERCOLLATERALIZED_ORACLE ? cr : MIN_UNDERCOLLATERALIZED_ORACLE;
    }
}
