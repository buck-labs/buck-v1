// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract CollateralAttestationTest is Test {
    CollateralAttestation internal attestation;
    MockERC20 internal buckToken;
    MockERC20 internal usdc;

    address internal liquidityReserve;
    address internal admin;
    address internal attestor;
    address internal alice;

    // Events
    event AttestationPublished(
        uint256 indexed V,
        uint256 indexed HC,
        uint256 measurementTime,
        uint256 submissionTime,
        uint256 collateralRatio
    );
    event ContractReferencesUpdated(
        address indexed buckToken, address indexed liquidityReserve, address indexed usdc
    );
    event StalenessThresholdsUpdated(uint256 healthyStaleness, uint256 stressedStaleness);
    event HaircutUpdated(uint256 HC);

    function setUp() public {
        admin = address(this);
        attestor = address(0xA77E5707);
        alice = address(0xA11CE);
        liquidityReserve = address(0x1190101D);

        // Deploy mock tokens
        buckToken = new MockERC20("BUCK", "BUCK", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy CollateralAttestation with proxy
        CollateralAttestation implementation = new CollateralAttestation();
        bytes memory initData = abi.encodeCall(
            implementation.initialize,
            (
                admin,
                attestor,
                address(buckToken),
                liquidityReserve,
                address(usdc),
                6, // reserveAssetDecimals (USDC has 6 decimals)
                72 hours, // healthyStaleness
                15 minutes // stressedStaleness
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        attestation = CollateralAttestation(address(proxy));
    }

    // ========= Initialization Tests =========

    function test_Initialize_SetsCorrectDefaults() public view {
        assertEq(attestation.HC(), 0.98e18, "Default haircut should be 2%");
        assertEq(attestation.V(), 0, "Initial V should be 0");
        assertEq(attestation.lastAttestationTime(), 0, "Initial attestation time should be 0");
        assertEq(attestation.healthyStaleness(), 72 hours, "Healthy staleness should be 72 hours");
        assertEq(
            attestation.stressedStaleness(), 15 minutes, "Stressed staleness should be 15 minutes"
        );
    }

    function test_Initialize_SetsCorrectRoles() public view {
        bytes32 adminRole = attestation.ADMIN_ROLE();
        bytes32 attestorRole = attestation.ATTESTOR_ROLE();

        assertTrue(attestation.hasRole(adminRole, admin), "Admin should have ADMIN_ROLE");
        assertTrue(
            attestation.hasRole(attestorRole, attestor), "Attestor should have ATTESTOR_ROLE"
        );
    }

    function test_Initialize_SetsCorrectContractReferences() public view {
        assertEq(attestation.buckToken(), address(buckToken), "BUCK token address incorrect");
        assertEq(
            attestation.liquidityReserve(), liquidityReserve, "Liquidity reserve address incorrect"
        );
        assertEq(attestation.usdc(), address(usdc), "USDC address incorrect");
    }

    function test_Initialize_RevertsOnZeroAddress() public {
        CollateralAttestation implementation = new CollateralAttestation();

        // Test zero admin
        vm.expectRevert(CollateralAttestation.ZeroAddress.selector);
        bytes memory initData = abi.encodeCall(
            implementation.initialize,
            (
                address(0),
                attestor,
                address(buckToken),
                liquidityReserve,
                address(usdc),
                6,
                72 hours,
                15 minutes
            )
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsOnZeroThresholds() public {
        CollateralAttestation implementation = new CollateralAttestation();

        // Test zero healthy staleness
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        bytes memory initData = abi.encodeCall(
            implementation.initialize,
            (
                admin,
                attestor,
                address(buckToken),
                liquidityReserve,
                address(usdc),
                6,
                0,
                15 minutes
            )
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    // ========= Access Control Tests =========

    function test_PublishAttestation_OnlyAttestor() public {
        bytes32 attestorRole = attestation.ATTESTOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, attestorRole
            )
        );
        vm.prank(alice);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);
    }

    function test_SetContractReferences_OnlyAdmin() public {
        bytes32 adminRole = attestation.ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vm.prank(alice);
        attestation.setContractReferences(address(buckToken), liquidityReserve, address(usdc));
    }

    function test_SetStalenessThresholds_OnlyAdmin() public {
        bytes32 adminRole = attestation.ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vm.prank(alice);
        attestation.setStalenessThresholds(48 hours, 10 minutes);
    }

    function test_SetHaircut_OnlyAdmin() public {
        bytes32 adminRole = attestation.ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vm.prank(alice);
        attestation.setHaircut(0.95e18);
    }

    // ========= Attestation Publication Tests =========

    function test_PublishAttestation_UpdatesState() public {
        uint256 V = 1_000_000e18; // $1M
        uint256 HC = 0.98e18; // 2% haircut

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(V, HC, 1000);

        assertEq(attestation.V(), V, "V not updated");
        assertEq(attestation.HC(), HC, "HC not updated");
        assertEq(attestation.lastAttestationTime(), 1000, "Attestation time not updated");
        assertEq(attestation.attestationMeasurementTime(), 1000, "Measurement time not updated");
    }

    function test_PublishAttestation_EmitsEvent() public {
        uint256 V = 1_000_000e18;
        uint256 HC = 0.98e18;

        // Set up state for CR calculation
        buckToken.mint(alice, 1_000_000e18); // 1M BUCK supply
        usdc.mint(liquidityReserve, 500_000e6); // 500k USDC in reserve

        vm.warp(1000);

        // Expected CR = (R + HC×V) / L = (500k + 0.98×1M) / 1M = 1.48
        uint256 expectedCR = 1.48e18;

        vm.expectEmit(true, true, false, true);
        emit AttestationPublished(V, HC, 1000, 1000, expectedCR);

        vm.prank(attestor);
        attestation.publishAttestation(V, HC, 1000);
    }

    function test_PublishAttestation_RevertsOnInvalidHaircut_TooHigh() public {
        vm.prank(attestor);
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        attestation.publishAttestation(1_000_000e18, 1.01e18, block.timestamp); // >100%
    }

    function test_PublishAttestation_RevertsOnInvalidHaircut_Zero() public {
        vm.prank(attestor);
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        attestation.publishAttestation(1_000_000e18, 0, block.timestamp); // 0%
    }

    function test_PublishAttestation_AcceptsEdgeCaseHaircut() public {
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 1e18, block.timestamp); // Exactly 100%
        assertEq(attestation.HC(), 1e18, "Should accept 100% haircut");

        vm.warp(1001); // Advance time to satisfy monotonic timestamp requirement
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 1, block.timestamp); // Minimal haircut
        assertEq(attestation.HC(), 1, "Should accept minimal haircut");
    }

    // ========= Collateral Ratio Calculation Tests =========

    function test_GetCollateralRatio_Healthy() public {
        // Setup: L = 1M, R = 500k, V = 1M, HC = 0.98
        // CR = (500k + 0.98×1M) / 1M = 1.48
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertApproxEqRel(cr, 1.48e18, 0.001e18, "CR should be ~1.48"); // 0.1% tolerance
    }

    function test_GetCollateralRatio_Undercollateralized() public {
        // Setup: L = 1M, R = 200k, V = 500k, HC = 0.98
        // CR = (200k + 0.98×500k) / 1M = 0.69
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 200_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertApproxEqRel(cr, 0.69e18, 0.001e18, "CR should be ~0.69");
    }

    function test_GetCollateralRatio_ExactlyOne() public {
        // Setup: L = 1M, R = 200k, V = 816,326.53 (adjusted for 98% HC)
        // CR = (200k + 0.98×816,326.53) / 1M = 1.0
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 200_000e6);

        // Solve for V: 200k + 0.98V = 1M → V = 800k/0.98 = 816,326.53
        uint256 V = 816_326_530_612_244_897_959_184; // Precise value

        vm.prank(attestor);
        attestation.publishAttestation(V, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertApproxEqAbs(cr, 1e18, 1e15, "CR should be exactly 1.0"); // 0.001 tolerance
    }

    function test_GetCollateralRatio_ZeroSupply() public {
        // When L = 0, CR should be infinite (max uint256)
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertEq(cr, type(uint256).max, "CR should be infinite when supply is 0");
    }

    function test_GetCollateralRatio_ZeroReserveAndValue() public {
        // Setup: L = 1M, R = 0, V = 0, HC = 0.98
        // CR = (0 + 0.98×0) / 1M = 0
        buckToken.mint(alice, 1_000_000e18);

        vm.prank(attestor);
        attestation.publishAttestation(0, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertEq(cr, 0, "CR should be 0 when R and V are 0");
    }

    function test_GetCollateralRatio_LargeValues() public {
        // Test with large realistic values
        // L = 100M, R = 50M, V = 100M, HC = 0.98
        // CR = (50M + 0.98×100M) / 100M = 1.48
        buckToken.mint(alice, 100_000_000e18);
        usdc.mint(liquidityReserve, 50_000_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(100_000_000e18, 0.98e18, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();
        assertApproxEqRel(cr, 1.48e18, 0.001e18, "CR should be ~1.48");
    }

    function test_GetCollateralRatio_DifferentHaircuts() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        // 5% haircut (HC = 0.95)
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.95e18, block.timestamp);
        uint256 cr1 = attestation.getCollateralRatio();
        assertApproxEqRel(cr1, 1.45e18, 0.001e18, "CR with 5% haircut should be ~1.45");

        // 10% haircut (HC = 0.90)
        vm.warp(1001);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.9e18, block.timestamp);
        uint256 cr2 = attestation.getCollateralRatio();
        assertApproxEqRel(cr2, 1.4e18, 0.001e18, "CR with 10% haircut should be ~1.40");

        // No haircut (HC = 1.0)
        vm.warp(1002);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 1.0e18, block.timestamp);
        uint256 cr3 = attestation.getCollateralRatio();
        assertApproxEqRel(cr3, 1.5e18, 0.001e18, "CR with no haircut should be ~1.50");
    }

    // ========= Attestation Staleness Tests =========

    function test_IsAttestationStale_Never() public view {
        // Never attested
        assertTrue(attestation.isAttestationStale(), "Should be stale when never attested");
    }

    function test_IsAttestationStale_HealthyMode_Fresh() public {
        // Setup healthy CR (>= 1.0)
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp); // CR = 1.48

        // Move forward 71 hours (within 72 hour window)
        vm.warp(1000 + 71 hours);
        assertFalse(
            attestation.isAttestationStale(), "Should be fresh in healthy mode after 71 hours"
        );
    }

    function test_IsAttestationStale_HealthyMode_Stale() public {
        // Setup healthy CR (>= 1.0)
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp); // CR = 1.48

        // Move forward 73 hours (beyond 72 hour window)
        vm.warp(1000 + 73 hours);
        assertTrue(
            attestation.isAttestationStale(), "Should be stale in healthy mode after 73 hours"
        );
    }

    function test_IsAttestationStale_StressedMode_Fresh() public {
        // Setup stressed CR (< 1.0)
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.59

        // Move forward 14 minutes (within 15 minute window)
        vm.warp(1000 + 14 minutes);
        assertFalse(
            attestation.isAttestationStale(), "Should be fresh in stressed mode after 14 minutes"
        );
    }

    function test_IsAttestationStale_StressedMode_Stale() public {
        // Setup stressed CR (< 1.0)
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.59

        // Move forward 16 minutes (beyond 15 minute window)
        vm.warp(1000 + 16 minutes);
        assertTrue(
            attestation.isAttestationStale(), "Should be stale in stressed mode after 16 minutes"
        );
    }

    function test_IsAttestationStale_ModeSwitching_HealthyToStressed() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        // Start healthy (CR = 1.48)
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        // Move forward 1 hour (fresh in healthy mode)
        vm.warp(1000 + 1 hours);
        assertFalse(attestation.isAttestationStale(), "Should be fresh in healthy mode");

        // Now crash the CR by reducing V
        vm.prank(attestor);
        attestation.publishAttestation(200_000e18, 0.98e18, block.timestamp); // CR = 0.696 (stressed)

        // Move forward 20 minutes (stale in stressed mode, but fresh from last publish)
        vm.warp(1000 + 1 hours + 20 minutes);
        assertTrue(
            attestation.isAttestationStale(), "Should be stale after 20 min in stressed mode"
        );
    }

    function test_IsAttestationStale_ModeSwitching_StressedToHealthy() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        // Start stressed (CR = 0.59)
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp);

        // Move forward 10 minutes (fresh in stressed mode)
        vm.warp(1000 + 10 minutes);
        assertFalse(attestation.isAttestationStale(), "Should be fresh in stressed mode");

        // Now recover the CR by increasing V
        vm.prank(attestor);
        attestation.publishAttestation(2_000_000e18, 0.98e18, block.timestamp); // CR = 2.06 (healthy)

        // Move forward 50 hours (fresh in healthy mode)
        vm.warp(1000 + 10 minutes + 50 hours);
        assertFalse(
            attestation.isAttestationStale(), "Should be fresh after 50 hours in healthy mode"
        );
    }

    // ========= Time Since Last Attestation Tests =========

    function test_TimeSinceLastAttestation_NeverAttested() public view {
        assertEq(
            attestation.timeSinceLastAttestation(),
            type(uint256).max,
            "Should return max uint256 when never attested"
        );
    }

    function test_TimeSinceLastAttestation_JustAttested() public {
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        assertEq(
            attestation.timeSinceLastAttestation(), 0, "Should be 0 immediately after attestation"
        );
    }

    function test_TimeSinceLastAttestation_AfterDelay() public {
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        vm.warp(1000 + 3600);
        assertEq(attestation.timeSinceLastAttestation(), 3600, "Should be 3600 seconds");
    }

    // ========= Healthy Collateral Tests =========

    function test_IsHealthyCollateral_True() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp); // CR = 1.48

        assertTrue(attestation.isHealthyCollateral(), "Should be healthy when CR >= 1.0");
    }

    function test_IsHealthyCollateral_False() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.59

        assertFalse(attestation.isHealthyCollateral(), "Should not be healthy when CR < 1.0");
    }

    function test_IsHealthyCollateral_ExactlyOne() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 200_000e6);

        uint256 V = 816_326_530_612_244_897_959_184; // CR = exactly 1.0

        vm.prank(attestor);
        attestation.publishAttestation(V, 0.98e18, block.timestamp);

        assertTrue(attestation.isHealthyCollateral(), "Should be healthy when CR = exactly 1.0");
    }

    // ========= Collateral Components Tests =========

    function test_GetCollateralComponents() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp);

        (uint256 R, uint256 V_, uint256 L, uint256 haircutValue) =
            attestation.getCollateralComponents();

        assertEq(R, 500_000e18, "R should be 500k (scaled to 18 decimals)");
        assertEq(V_, 1_000_000e18, "V should be 1M");
        assertEq(L, 1_000_000e18, "L should be 1M");
        assertEq(haircutValue, 980_000e18, "Haircut value should be 0.98 * 1M = 980k");
    }

    // ========= Admin Functions Tests =========

    function test_SetContractReferences() public {
        address newStrx = address(0x123);
        address newReserve = address(0x456);
        address newUsdc = address(0x789);

        vm.expectEmit(true, true, true, false);
        emit ContractReferencesUpdated(newStrx, newReserve, newUsdc);

        attestation.setContractReferences(newStrx, newReserve, newUsdc);

        assertEq(attestation.buckToken(), newStrx, "BUCK token not updated");
        assertEq(attestation.liquidityReserve(), newReserve, "Liquidity reserve not updated");
        assertEq(attestation.usdc(), newUsdc, "USDC not updated");
    }

    function test_SetContractReferences_RevertsOnZeroAddress() public {
        vm.expectRevert(CollateralAttestation.ZeroAddress.selector);
        attestation.setContractReferences(address(0), liquidityReserve, address(usdc));

        vm.expectRevert(CollateralAttestation.ZeroAddress.selector);
        attestation.setContractReferences(address(buckToken), address(0), address(usdc));

        vm.expectRevert(CollateralAttestation.ZeroAddress.selector);
        attestation.setContractReferences(address(buckToken), liquidityReserve, address(0));
    }

    function test_SetStalenessThresholds() public {
        uint256 newHealthy = 48 hours;
        uint256 newStressed = 10 minutes;

        vm.expectEmit(false, false, false, true);
        emit StalenessThresholdsUpdated(newHealthy, newStressed);

        attestation.setStalenessThresholds(newHealthy, newStressed);

        assertEq(attestation.healthyStaleness(), newHealthy, "Healthy staleness not updated");
        assertEq(attestation.stressedStaleness(), newStressed, "Stressed staleness not updated");
    }

    function test_SetStalenessThresholds_RevertsOnZero() public {
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        attestation.setStalenessThresholds(0, 10 minutes);

        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        attestation.setStalenessThresholds(48 hours, 0);
    }

    function test_SetHaircut() public {
        uint256 newHC = 0.95e18; // 5% haircut

        vm.expectEmit(false, false, false, true);
        emit HaircutUpdated(newHC);

        attestation.setHaircut(newHC);

        assertEq(attestation.HC(), newHC, "Haircut not updated");
    }

    function test_SetHaircut_RevertsOnInvalid() public {
        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        attestation.setHaircut(1.01e18); // >100%

        vm.expectRevert(CollateralAttestation.InvalidHaircut.selector);
        attestation.setHaircut(0); // 0%
    }

    // ========= CR Threshold Crossing Tests =========

    function test_CRCrossing_OneToBelow_StalenessChanges() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        // Start healthy
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp); // CR = 1.48

        // After 50 hours, still fresh (healthy mode)
        vm.warp(1000 + 50 hours);
        assertFalse(attestation.isAttestationStale());

        // Drop CR below 1.0
        vm.prank(attestor);
        attestation.publishAttestation(200_000e18, 0.98e18, block.timestamp); // CR = 0.696

        // Same time interval, but now uses stressed mode threshold
        vm.warp(1000 + 50 hours + 20 minutes);
        assertTrue(attestation.isAttestationStale(), "Should be stale with stressed threshold");
    }

    function test_CRCrossing_BelowToOne_StalenessChanges() public {
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        // Start stressed
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.59

        // After 20 minutes, stale (stressed mode)
        vm.warp(1000 + 20 minutes);
        assertTrue(attestation.isAttestationStale());

        // Recover CR above 1.0
        vm.warp(1000 + 20 minutes);
        vm.prank(attestor);
        attestation.publishAttestation(2_000_000e18, 0.98e18, block.timestamp); // CR = 2.06

        // Same time interval from last attestation, but now uses healthy threshold
        vm.warp(1000 + 20 minutes + 50 hours);
        assertFalse(attestation.isAttestationStale(), "Should be fresh with healthy threshold");
    }

    // ========= TOCTOU Fix Verification Tests (Phase 3.5.1) =========

    function test_PublishAttestation_RejectsStaleWhenCRDropsBelowOne() public {
        // This test verifies the TOCTOU fix: submission with timestamp that drops CR below 1.0
        // should be rejected if older than 15 minutes, even if CURRENT CR is healthy.

        // Setup: L = 1M, R = 200k
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 200_000e6);

        // Start with healthy CR = 1.2
        // CR = (200k + 0.98*V) / 1M = 1.2 → V = 1,020,408
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_020_408e18, 0.98e18, block.timestamp); // CR = 1.2 (healthy)

        // Move forward 60 minutes
        vm.warp(1000 + 60 minutes);

        // Now try to submit an attestation that's 59 minutes old (just 1 second after previous)
        // Must be > previous timestamp (1000), but still old enough to be stale (> 15 min)
        uint256 staleMeasurementTime = 1001; // Just after previous, but ~59 min old

        // This should FAIL because:
        // - NEW CR = 0.95 (< 1.0) requires stressed staleness (15 min)
        // - Measurement is ~59 min old (> 15 min)
        // Before the TOCTOU fix, this would have passed because OLD CR=1.2 allowed 72hr staleness
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralAttestation.StaleAttestationSubmission.selector,
                staleMeasurementTime,
                block.timestamp,
                15 minutes
            )
        );
        vm.prank(attestor);
        attestation.publishAttestation(765_306e18, 0.98e18, staleMeasurementTime);
    }

    function test_PublishAttestation_AcceptsOldWhenCRStaysAboveOne() public {
        // This test verifies that attestations with CR >= 1.0 can still be ~59 minutes old
        // because they use the healthy staleness threshold (72 hours).

        // Setup: L = 1M, R = 200k
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 200_000e6);

        // Start with healthy CR = 1.2
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_020_408e18, 0.98e18, block.timestamp); // CR = 1.2

        // Move forward 60 minutes
        vm.warp(1000 + 60 minutes);

        // Submit an attestation that's ~59 minutes old (just 1 second after previous)
        // Must be > previous timestamp (1000) to satisfy monotonic requirement
        uint256 measurementTime = 1001; // Just after previous, but ~59 min old

        // This should SUCCEED because:
        // - NEW CR = 1.15 (>= 1.0) uses healthy staleness (72 hours)
        // - Measurement is ~59 min old (< 72 hours)
        vm.prank(attestor);
        attestation.publishAttestation(969_388e18, 0.98e18, measurementTime);

        // Verify it was accepted
        assertEq(attestation.V(), 969_388e18, "V should be updated");
        assertEq(
            attestation.attestationMeasurementTime(),
            measurementTime,
            "Measurement time should be set"
        );
        assertApproxEqRel(attestation.getCollateralRatio(), 1.15e18, 0.001e18, "CR should be ~1.15");
    }

    // ========= Fuzz Tests =========

    function testFuzz_GetCollateralRatio(uint256 supply, uint256 reserve, uint256 V, uint256 HC)
        public
    {
        // Bound inputs to reasonable ranges
        supply = bound(supply, 1e18, 1_000_000_000e18); // 1 to 1B tokens
        reserve = bound(reserve, 0, 1_000_000_000e6); // 0 to 1B USDC
        V = bound(V, 0, 10_000_000_000e18); // 0 to 10B USD
        HC = bound(HC, 0.01e18, 1e18); // 1% to 100% haircut

        buckToken.mint(alice, supply);
        usdc.mint(liquidityReserve, reserve);

        vm.prank(attestor);
        attestation.publishAttestation(V, HC, block.timestamp);

        uint256 cr = attestation.getCollateralRatio();

        // CR should never be negative (covered by uint256)
        // CR calculation: (R + HC×V) / L
        uint256 expectedR = uint256(reserve) * 1e12; // Scale USDC to 18 decimals
        uint256 expectedHaircutValue = (HC * V) / 1e18;
        uint256 expectedNumerator = expectedR + expectedHaircutValue;
        uint256 expectedCR = (expectedNumerator * 1e18) / supply;

        assertApproxEqRel(cr, expectedCR, 0.0001e18, "CR calculation incorrect");
    }

    function testFuzz_IsAttestationStale_HealthyMode(uint256 timeElapsed) public {
        timeElapsed = bound(timeElapsed, 0, 200 hours);

        // Setup healthy CR
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 500_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(1_000_000e18, 0.98e18, block.timestamp); // CR = 1.48

        vm.warp(1000 + timeElapsed);

        bool expectedStale = timeElapsed > 72 hours;
        assertEq(
            attestation.isAttestationStale(),
            expectedStale,
            "Staleness check incorrect in healthy mode"
        );
    }

    function testFuzz_IsAttestationStale_StressedMode(uint256 timeElapsed) public {
        timeElapsed = bound(timeElapsed, 0, 2 hours);

        // Setup stressed CR
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 100_000e6);

        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.59

        vm.warp(1000 + timeElapsed);

        bool expectedStale = timeElapsed > 15 minutes;
        assertEq(
            attestation.isAttestationStale(),
            expectedStale,
            "Staleness check incorrect in stressed mode"
        );
    }

    // ========================================================================
    // Phase 3.5.4: Test Coverage for TOCTOU Fix (StaleAttestationSubmission)
    // ========================================================================

    /// @notice Phase 3.5.4: Test that attestations are rejected when submitted too late in stressed mode
    function test_PublishAttestation_RevertsOnStaleSubmission() public {
        // Setup stressed CR (< 1.0) which requires 15min freshness
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 400_000e6);

        // Initial attestation to establish CR = 0.89 (stressed mode)
        vm.warp(10000); // Start at time 10000 to avoid underflow
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.89

        // Move forward 30 minutes
        vm.warp(block.timestamp + 30 minutes);

        // Attempt to submit attestation with timestamp 20 minutes ago
        // In stressed mode (CR < 1), max staleness = 15 minutes
        uint256 staleTimestamp = block.timestamp - 20 minutes;

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralAttestation.StaleAttestationSubmission.selector,
                staleTimestamp,
                block.timestamp,
                15 minutes
            )
        );

        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, staleTimestamp);
    }

    /// @notice Phase 3.5.4: Test CR transition from healthy to stressed enforces tighter staleness
    function test_PublishAttestation_HealthyToStressedTransition() public {
        // Start with healthy CR by having V = 0 and good reserve
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 1_050_000e6); // R/L = 1.05 → CR = 1.05

        // Initial attestation to establish healthy CR
        vm.warp(10000);
        vm.prank(attestor);
        attestation.publishAttestation(0, 0.98e18, block.timestamp); // V=0, CR = 1.05

        // 60 minutes later, try to submit attestation with measurement from ~59min ago
        // Provide V that would drop CR below 1.0 (stressed), requiring 15min freshness
        // The ~59min-old measurement should be rejected
        vm.warp(10000 + 60 minutes);
        uint256 oldMeasurementTime = 10001; // Just after previous, but ~59 min old

        // Now reduce reserve to create stressed scenario
        // Burn most of the reserve to make room for off-chain value to dominate
        vm.prank(liquidityReserve);
        usdc.transfer(address(0xdead), 1_000_000e6); // Leave only 50k

        // Now submit V that makes CR = 0.95
        // CR = (50_000e6 * 1e12 + 0.98 * V) / 1_000_000e18 = 0.95
        // 0.95 * 1_000_000e18 = 50_000e18 + 0.98 * V
        // 950_000e18 = 50_000e18 + 0.98 * V
        // 900_000e18 = 0.98 * V
        // V ≈ 918_367e18
        uint256 newV = 918_367_346_938_775_510_204_081; // CR ≈ 0.95

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralAttestation.StaleAttestationSubmission.selector,
                oldMeasurementTime,
                block.timestamp,
                15 minutes
            )
        );

        vm.prank(attestor);
        attestation.publishAttestation(newV, 0.98e18, oldMeasurementTime);
    }

    /// @notice Phase 3.5.4: Test CR transition from stressed to healthy allows older measurements
    function test_PublishAttestation_StressedToHealthyTransition() public {
        // Start with stressed CR = 0.95
        buckToken.mint(alice, 1_000_000e18);
        usdc.mint(liquidityReserve, 460_000e6);

        // Initial attestation to establish stressed CR
        vm.warp(1000);
        vm.prank(attestor);
        attestation.publishAttestation(500_000e18, 0.98e18, block.timestamp); // CR = 0.95

        // 60 minutes later, submit attestation with measurement from ~59min ago
        // This would raise CR to 1.05 (healthy), which allows 72hr staleness
        // The ~59min-old measurement should be accepted
        vm.warp(1000 + 60 minutes);
        uint256 oldMeasurementTime = 1001; // Just after previous, but ~59 min old

        // Calculate V that would make CR = 1.05 with current R and L
        // CR = (R + HC×V) / L = 1.05
        // 1.05 = (460_000e6 * 1e12 + 0.98 * V) / 1_000_000e18
        // Solving: V ≈ 603_000e18
        uint256 newV = 602_040_816e18; // Carefully calculated to give CR ≈ 1.05

        // This should succeed because NEW CR ≥ 1, so 72hr threshold applies
        vm.prank(attestor);
        attestation.publishAttestation(newV, 0.98e18, oldMeasurementTime);

        // Verify the attestation was accepted
        assertEq(attestation.V(), newV, "V should be updated");
        assertEq(
            attestation.attestationMeasurementTime(),
            oldMeasurementTime,
            "Measurement time should be stored"
        );
    }

    // =========================================================================
    // Staleness Threshold Validation Tests (FIND-006)
    // =========================================================================

    /// @notice Test that setStalenessThresholds reverts when stressed > healthy
    function test_SetStalenessThresholds_RevertsWhenStressedGreaterThanHealthy() public {
        vm.prank(admin);
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        // 1 day healthy, 2 days stressed - INVALID (stressed should be shorter)
        attestation.setStalenessThresholds(1 days, 2 days);
    }

    /// @notice Test that setStalenessThresholds accepts valid configuration (stressed < healthy)
    function test_SetStalenessThresholds_AcceptsStressedLessThanHealthy() public {
        vm.prank(admin);
        // 72 hours healthy, 15 minutes stressed - VALID
        attestation.setStalenessThresholds(72 hours, 15 minutes);

        assertEq(attestation.healthyStaleness(), 72 hours);
        assertEq(attestation.stressedStaleness(), 15 minutes);
    }

    /// @notice Test that setStalenessThresholds accepts equal thresholds
    function test_SetStalenessThresholds_AcceptsEqualThresholds() public {
        vm.prank(admin);
        // Same threshold for both - VALID (edge case)
        attestation.setStalenessThresholds(1 hours, 1 hours);

        assertEq(attestation.healthyStaleness(), 1 hours);
        assertEq(attestation.stressedStaleness(), 1 hours);
    }

    /// @notice Test that setStalenessThresholds still reverts on zero healthy
    function test_SetStalenessThresholds_RevertsOnZeroHealthy() public {
        vm.prank(admin);
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        attestation.setStalenessThresholds(0, 15 minutes);
    }

    /// @notice Test that setStalenessThresholds still reverts on zero stressed
    function test_SetStalenessThresholds_RevertsOnZeroStressed() public {
        vm.prank(admin);
        vm.expectRevert(CollateralAttestation.InvalidStalenessThreshold.selector);
        attestation.setStalenessThresholds(72 hours, 0);
    }
}
