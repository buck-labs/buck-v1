// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title CollateralAttestationUnitTest
 * @notice Comprehensive unit tests for CollateralAttestation to fill coverage gaps
 * @dev Fills missing coverage identified in Sprint 30 testing audit (56% → ~95%)
 */
contract CollateralAttestationUnitTest is BaseTest {
    CollateralAttestation internal attestation;
    Buck internal buck;
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;

    address internal constant OWNER = address(0x1000);
    address internal constant ATTESTOR = address(0x2000);
    address internal constant TREASURY = address(0x3000);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        usdc = new MockUSDC();
        buck = deployBUCK(OWNER);
        reserve = deployLiquidityReserve(OWNER, address(usdc), address(0), TREASURY);

        attestation = deployCollateralAttestation(
            OWNER, ATTESTOR, address(buck), address(reserve), address(usdc)
        );

        // Set staleness thresholds: 72h healthy, 15min stressed
        vm.prank(OWNER);
        attestation.setStalenessThresholds(72 hours, 15 minutes);

        // Configure BUCK so OWNER can mint (set OWNER as liquidity window)
        vm.prank(OWNER);
        buck.configureModules(
            OWNER, // liquidityWindow (allows OWNER to mint)
            address(reserve), // liquidityReserve
            TREASURY, // treasury
            address(0), // policyManager (not needed for these tests)
            address(0), // accessRegistry (not needed for these tests)
            address(0) // rewardsHook (not needed for these tests)
        );
    }

    // =========================================================================
    // publishAttestation() Staleness Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: publishAttestation() enforces stressed staleness when CR < 1.0
    /// @dev COVERAGE GAP: Tests stressed staleness threshold (line 202)
    function test_PublishAttestation_StalenessWhenCRBelowOne() public {
        // Setup: CR = 0.85 (undercollateralized)
        // Supply: 100M STRX, Reserve: 0 USDC, V: 85M USD, HC: 0.98
        // CR = (0 + 0.98 * 85M) / 100M = 83.3M / 100M = 0.833

        uint256 supply = 100_000_000e18;
        uint256 V = 85_000_000e18; // $85M off-chain value
        uint256 HC = 0.98e18; // 2% haircut

        // Mock totalSupply to return our desired supply
        vm.mockCall(
            address(buck),
            abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
            abi.encode(supply)
        );

        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 1 days);

        // Try to publish attestation that's 20 minutes old (exceeds 15min stressed threshold)
        uint256 measurementTime = block.timestamp - 20 minutes;

        vm.expectRevert();
        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, measurementTime);
    }

    /// @notice Test: publishAttestation() allows 14min old when CR < 1.0
    function test_PublishAttestation_StressedWithinThreshold() public {
        // Setup: CR < 1.0
        uint256 supply = 100_000_000e18;
        uint256 V = 85_000_000e18;
        uint256 HC = 0.98e18;

        vm.mockCall(
            address(buck),
            abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
            abi.encode(supply)
        );

        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 1 days);

        // 14 minutes old (within 15min threshold)
        uint256 measurementTime = block.timestamp - 14 minutes;

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, measurementTime);

        assertEq(attestation.V(), V, "Should accept 14min old when CR < 1.0");
    }

    /// @notice Test: publishAttestation() allows 48h old when CR >= 1.0
    /// @dev COVERAGE GAP: Tests healthy staleness threshold (line 202)
    function test_PublishAttestation_StalenessWhenCRAboveOne() public {
        // Setup: CR = 1.2 (healthy)
        // Supply: 100M STRX, Reserve: 20M USDC, V: 100M USD, HC: 0.98
        // CR = (20M + 0.98 * 100M) / 100M = 118M / 100M = 1.18

        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 20_000_000e6; // 20M USDC
        uint256 V = 100_000_000e18; // $100M off-chain value
        uint256 HC = 0.98e18;

        vm.mockCall(
            address(buck),
            abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
            abi.encode(supply)
        );
        usdc.mint(address(reserve), reserveBalance);

        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 100 days);

        // 48 hours old (within 72h healthy threshold)
        uint256 measurementTime = block.timestamp - 48 hours;

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, measurementTime);

        assertEq(attestation.V(), V, "Should accept 48h old when CR >= 1.0");
    }

    /// @notice Test: publishAttestation() rejects 73h old when CR >= 1.0
    function test_PublishAttestation_HealthyExceedsThreshold() public {
        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 20_000_000e6;
        uint256 V = 100_000_000e18;
        uint256 HC = 0.98e18;

        vm.mockCall(
            address(buck),
            abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
            abi.encode(supply)
        );
        usdc.mint(address(reserve), reserveBalance);

        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 100 days);

        // 73 hours old (exceeds 72h threshold)
        uint256 measurementTime = block.timestamp - 73 hours;

        vm.expectRevert();
        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, measurementTime);
    }

    // =========================================================================
    // isAttestationStale() Transition Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: isAttestationStale() detects healthy → stressed transition
    /// @dev COVERAGE GAP: Tests staleness threshold change on CR transition (line 279)
    function test_IsAttestationStale_HealthyToStressedTransition() public {
        // Phase 1: Publish attestation when CR is healthy
        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 20_000_000e6; // CR = 1.18
        uint256 V = 100_000_000e18;
        uint256 HC = 0.98e18;

        vm.mockCall(
            address(buck),
            abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
            abi.encode(supply)
        );
        usdc.mint(address(reserve), reserveBalance);

        // Publish attestation (current time)
        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        assertFalse(attestation.isAttestationStale(), "Should be fresh initially");

        // Phase 2: Wait 30 minutes (within 72h healthy threshold, exceeds 15min stressed)
        vm.warp(block.timestamp + 30 minutes);

        // Attestation should still be valid (CR >= 1.0)
        assertFalse(attestation.isAttestationStale(), "Should still be fresh when CR >= 1.0");

        // Phase 3: CR drops below 1.0 (simulated by removing reserve funds)
        // Remove 19M USDC from reserve → CR drops to 0.98
        vm.prank(address(reserve));
        usdc.transfer(address(0x999), 19_000_000e6);

        // Now attestation should be stale (30min > 15min stressed threshold)
        assertTrue(attestation.isAttestationStale(), "Should be stale when CR < 1.0");
    }

    /// @notice Test: isAttestationStale() returns true when never attested
    function test_IsAttestationStale_NeverAttested() public {
        // Fresh deployment, no attestations published
        assertTrue(attestation.isAttestationStale(), "Should be stale when never attested");
    }

    /// @notice Test: isAttestationStale() changes threshold based on CR
    function test_IsAttestationStale_ThresholdChangesByCR() public {
        // Setup: CR = 1.1 (healthy)
        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 12_000_000e6;
        uint256 V = 100_000_000e18;
        uint256 HC = 0.98e18;

        deal(address(buck), address(this), supply, true);
        usdc.mint(address(reserve), reserveBalance);

        // Publish fresh attestation
        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        // Wait 20 minutes
        vm.warp(block.timestamp + 20 minutes);

        // Should be fresh (20min < 72h)
        assertFalse(attestation.isAttestationStale(), "Should be fresh when CR >= 1.0");

        // Check CR
        uint256 cr = attestation.getCollateralRatio();
        assertGe(cr, 1e18, "CR should be >= 1.0");
    }

    // =========================================================================
    // getCollateralRatio() Overflow Protection Tests - Coverage Gaps
    // =========================================================================

    /// @notice Test: getCollateralRatio() handles max uint256 values without overflow
    /// @dev COVERAGE GAP: Tests overflow protection in Math.mulDiv (line 269)
    function test_GetCollateralRatio_OverflowProtection() public {
        // Setup extreme values that could cause overflow in naive implementation
        uint256 supply = 1e18; // 1 token
        uint256 reserveBalance = type(uint128).max / 1e12; // Max USDC that fits in uint128
        uint256 V = type(uint128).max; // Max off-chain value
        uint256 HC = 0.98e18;

        deal(address(buck), address(this), supply, true);
        usdc.mint(address(reserve), reserveBalance);

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        // Should not revert due to overflow
        uint256 cr = attestation.getCollateralRatio();

        // CR should be extremely high but not overflow
        assertGt(cr, 1e18, "CR should be calculated correctly");
    }

    /// @notice Test: getCollateralRatio() returns max uint when supply is zero
    function test_GetCollateralRatio_ZeroSupply() public {
        // No BUCK minted yet
        uint256 cr = attestation.getCollateralRatio();
        assertEq(cr, type(uint256).max, "Should return max uint when supply is zero");
    }

    /// @notice Test: getCollateralRatio() EXCLUDES treasury USDC (protocol profit, not user backing)
    function test_GetCollateralRatio_ExcludesTreasury() public {
        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 80_000_000e6;
        uint256 treasuryBalance = 10_000_000e6; // 10M in treasury (protocol profit)
        uint256 V = 10_000_000e18;
        uint256 HC = 0.98e18;

        deal(address(buck), address(this), supply, true);
        usdc.mint(address(reserve), reserveBalance);
        usdc.mint(TREASURY, treasuryBalance);

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        // CR = (80M + 0.98 * 10M) / 100M = (80M + 9.8M) / 100M = 0.898
        // Treasury is NOT included as it's protocol profit, not user backing
        uint256 cr = attestation.getCollateralRatio();

        // Should be close to 0.898e18
        assertApproxEqRel(cr, 0.898e18, 0.01e18, "Should exclude treasury from CR");
    }

    // =========================================================================
    // Haircut Validation Tests
    // =========================================================================

    /// @notice Test: publishAttestation() rejects haircut > 100%
    function test_PublishAttestation_HaircutTooHigh() public {
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        vm.prank(ATTESTOR);
        attestation.publishAttestation(100_000_000e18, 1.01e18, block.timestamp);
    }

    /// @notice Test: publishAttestation() rejects haircut = 0
    function test_PublishAttestation_HaircutZero() public {
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        vm.prank(ATTESTOR);
        attestation.publishAttestation(100_000_000e18, 0, block.timestamp);
    }

    /// @notice Test: setHaircut() validates bounds
    function test_SetHaircut_InvalidBounds() public {
        // Too high
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        vm.prank(OWNER);
        attestation.setHaircut(1.01e18);

        // Zero
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        vm.prank(OWNER);
        attestation.setHaircut(0);
    }

    // =========================================================================
    // Staleness Threshold Tests
    // =========================================================================

    /// @notice Test: setStalenessThresholds() rejects zero values
    function test_SetStalenessThresholds_ZeroHealthy() public {
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        vm.prank(OWNER);
        attestation.setStalenessThresholds(0, 15 minutes);
    }

    /// @notice Test: setStalenessThresholds() rejects zero stressed threshold
    function test_SetStalenessThresholds_ZeroStressed() public {
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        vm.prank(OWNER);
        attestation.setStalenessThresholds(72 hours, 0);
    }

    // =========================================================================
    // Access Control Tests
    // =========================================================================

    /// @notice Test: publishAttestation() reverts for non-attestor
    function test_PublishAttestation_UnauthorizedCaller() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        attestation.publishAttestation(100_000_000e18, 0.98e18, block.timestamp);
    }

    /// @notice Test: setStalenessThresholds() reverts for non-owner
    function test_SetStalenessThresholds_UnauthorizedCaller() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        attestation.setStalenessThresholds(24 hours, 10 minutes);
    }

    /// @notice Test: setHaircut() reverts for non-owner
    function test_SetHaircut_UnauthorizedCaller() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        attestation.setHaircut(0.95e18);
    }

    /// @notice Test: setContractReferences() reverts for non-owner
    function test_SetContractReferences_UnauthorizedCaller() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        attestation.setContractReferences(address(buck), address(reserve), address(usdc));
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    /// @notice Test: timeSinceLastAttestation() returns max when never attested
    function test_TimeSinceLastAttestation_NeverAttested() public {
        uint256 timeSince = attestation.timeSinceLastAttestation();
        assertEq(timeSince, type(uint256).max, "Should return max uint when never attested");
    }

    /// @notice Test: timeSinceLastAttestation() calculates correctly
    function test_TimeSinceLastAttestation_Calculates() public {
        vm.prank(ATTESTOR);
        attestation.publishAttestation(100_000_000e18, 0.98e18, block.timestamp);

        vm.warp(block.timestamp + 1000);

        uint256 timeSince = attestation.timeSinceLastAttestation();
        assertEq(timeSince, 1000, "Should calculate time since attestation");
    }

    /// @notice Test: isHealthyCollateral() returns correct status
    function test_IsHealthyCollateral_Status() public {
        // Setup: CR < 1.0
        uint256 supply = 100_000_000e18;
        uint256 V = 50_000_000e18;
        uint256 HC = 0.98e18;

        deal(address(buck), address(this), supply, true);

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        assertFalse(attestation.isHealthyCollateral(), "Should be unhealthy when CR < 1.0");

        // Increase reserve to make CR >= 1.0
        usdc.mint(address(reserve), 60_000_000e6);

        assertTrue(attestation.isHealthyCollateral(), "Should be healthy when CR >= 1.0");
    }

    /// @notice Test: getCollateralComponents() returns correct values
    function test_GetCollateralComponents_ReturnsValues() public {
        uint256 supply = 100_000_000e18;
        uint256 reserveBalance = 20_000_000e6;
        uint256 treasuryBalance = 5_000_000e6;
        uint256 V = 80_000_000e18;
        uint256 HC = 0.98e18;

        deal(address(buck), address(this), supply, true);
        usdc.mint(address(reserve), reserveBalance);
        usdc.mint(TREASURY, treasuryBalance);

        vm.prank(ATTESTOR);
        attestation.publishAttestation(V, HC, block.timestamp);

        (uint256 R, uint256 V_, uint256 L, uint256 haircutValue) =
            attestation.getCollateralComponents();

        // R should include ONLY reserve (treasury is protocol profit, not user backing)
        assertEq(R, reserveBalance * 1e12, "R should include only reserve");
        assertEq(V_, V, "V should match published value");
        assertEq(L, supply, "L should match supply");
        assertEq(haircutValue, (HC * V) / 1e18, "Haircut value should be HC * V");
    }

}
