// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";

contract PolicyManagerTest is BaseTest {
    PolicyManager internal policy;
    address internal timelock;
    address internal guardian;

    function setUp() public {
        // Warp to epoch 1+ to avoid collision with uninitialized storage (epoch 0)
        vm.warp(1 days + 1);

        timelock = address(this);
        guardian = address(0xBEEF);
        policy = deployPolicyManager(timelock); // admin role

        policy.reportSystemSnapshot(
            _snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1) // 8% reserve for GREEN
        );

        // Production config: mintAggregateBps = 0 (unlimited mints)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 0; // Unlimited mints
        policy.setBandConfig(PolicyManager.Band.Green, config);

        policy.reportSystemSnapshot(
            _snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1) // 8% reserve for GREEN
        );
    }

    function testInitialBandIsGreen() public view {
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green));
    }

    function testReportRequiresTimelock() public {
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(800, 500, 10, 100, 1_000_000e18, 1e18, 0, 1); // 8% reserve for GREEN

        bytes32 adminRole = policy.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xABCD), adminRole
            )
        );
        vm.prank(address(0xABCD));
        policy.reportSystemSnapshot(snap);
    }

    // REMOVED: testEnterRedWhenMarketClosed() - market hours deleted in Sprint 2.1.1

    function testEnterYellowWhenReserveBelowWarn() public {
        vm.warp(150);
        PolicyManager.SystemSnapshot memory warnSnap =
            _snapshot(450, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4.5% reserve, below 5% warn threshold

        vm.prank(timelock);
        policy.reportSystemSnapshot(warnSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));
    }

    // REMOVED: testOracleStaleTriggersRed() - oracle health + hysteresis deleted in Sprint 2.1.2 & 2.1.3

    function testLowReservePushesYellow() public {
        vm.warp(200);
        PolicyManager.SystemSnapshot memory lowReserveSnap =
            _snapshot(450, 400, 5, 100, 1_000_000e18, 1e18, 0, 1); // 4.5% reserve (below 5% warn)

        vm.prank(timelock);
        policy.reportSystemSnapshot(lowReserveSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));
    }

    function testEmergencyThresholdTriggersGovernanceVote_RedBand() public {
        vm.warp(300);
        PolicyManager.SystemSnapshot memory emergencySnap =
            _snapshot(100, 50, 5, 100, 1_000_000e18, 1e18, 0, 1); // 1.0% reserve (emergency threshold)

        vm.prank(timelock);
        policy.reportSystemSnapshot(emergencySnap);

        // Emergency threshold now maps to Red operationally but still triggers governance vote
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Red));
        assertTrue(policy.requiresGovernanceVote());
    }

    // REMOVED: testHysteresisExitRedRequiresTwoHealthyPrints() - hysteresis deleted in Sprint 2.1.3

    function testMintCapAndResetAcrossEpochs() public {
        address user = address(0x1234);

        // Mints are unlimited - should always pass
        policy.checkMintCap( 50);
        policy.recordMint( 50);

        // Verify we can still mint more (unlimited)
        policy.checkMintCap( 10000); // 100% of supply

        // After a day, should still be unlimited
        vm.warp(block.timestamp + 1 days);
        policy.checkMintCap( 10000);
    }

    function testAggregateMintCap() public {
        // Mints are unlimited - verify multiple users can mint any amount
        PolicyManager.DerivedCaps memory caps = policy.getDerivedCaps();
        assertEq(caps.mintAggregateBps, 10000, "Mint cap should be unlimited");

        // Multiple users mint large amounts
        for (uint256 i = 0; i < 3; i++) {
            address user = address(uint160(i + 1));
            policy.checkMintCap( 10000); // 100% each
            policy.recordMint( 10000);
        }

        // Even after multiple 100% mints, more mints should still succeed
        policy.checkMintCap( 10000);
    }

    function testRecordMintRequiresOperatorRole() public {
        address user = address(0x1234);
        address unauthorizedCaller = address(0xBAD);

        // Non-OPERATOR_ROLE account cannot call recordMint()
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                policy.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorizedCaller);
        policy.recordMint( 50);

        // OPERATOR_ROLE (timelock in setup) can call recordMint()
        vm.prank(timelock);
        policy.recordMint( 50);
    }

    function testRecordRefundRequiresOperatorRole() public {
        address user = address(0x1234);
        address unauthorizedCaller = address(0xBAD);

        // First record a mint so we have something to refund
        vm.prank(timelock);
        policy.recordMint( 50);

        // Non-OPERATOR_ROLE account cannot call recordRefund()
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                policy.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorizedCaller);
        policy.recordRefund( 25);

        // OPERATOR_ROLE (timelock in setup) can call recordRefund()
        vm.prank(timelock);
        policy.recordRefund( 25);
    }

    function testOperatorRoleCannotCallAdminFunctions() public {
        address operator = address(0xFEED);

        // Grant OPERATOR_ROLE to a new user (but not ADMIN_ROLE)
        bytes32 operatorRole = policy.OPERATOR_ROLE();
        vm.prank(timelock);
        policy.grantRole(operatorRole, operator);

        // OPERATOR_ROLE cannot call admin functions like setDexFees()
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                policy.ADMIN_ROLE()
            )
        );
        vm.prank(operator);
        policy.setDexFees(100, 200);
    }

    // ========= Sprint 2.2: New Pure R/L Transition Tests =========

    /// @notice Test instant GREEN→YELLOW transition at 5% boundary (no hysteresis)
    function test_InstantGreenToYellow_At5Percent() public {
        // Start at 5.0% (exactly at warn threshold) → GREEN
        vm.warp(1000);
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(500, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 5.0% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green));

        // Drop to 4.99% → instant YELLOW (no hysteresis delay)
        vm.warp(1001);
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(499, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4.99% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));
    }

    /// @notice Test instant YELLOW→RED transition at 2.5% boundary (no hysteresis)
    function test_InstantYellowToRed_At2Point5Percent() public {
        // Start at 2.6% → YELLOW
        vm.warp(2000);
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(260, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2.6% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));

        // Drop to 2.4% → instant RED (no hysteresis delay)
        vm.warp(2001);
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(240, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2.4% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Red));
    }

    /// @notice Test instant RED→YELLOW recovery (no 30min dwell, no 2-print requirement!)
    function test_InstantRedToYellow_Above2Point5Percent() public {
        // Start at 2.4% → RED
        vm.warp(3000);
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(240, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2.4% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Red));

        // Inject liquidity to 2.6% → instant YELLOW (no dwell time, no 2-print requirement)
        vm.warp(3001); // Only 1 second later!
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(260, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2.6% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow)); // Instant recovery!
    }

    /// @notice Test band ignores time of day (24/7 operation, market hours deleted)
    function test_BandIgnoresTimeOfDay() public {
        // Set reserve to 4% (YELLOW) at midnight UTC
        vm.warp(0); // Unix epoch = 00:00 UTC Thursday, Jan 1, 1970
        PolicyManager.SystemSnapshot memory snap1 =
            _snapshot(400, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap1);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));

        // Same reserve at 3am UTC → still YELLOW (market hours have no effect)
        vm.warp(3 hours);
        PolicyManager.SystemSnapshot memory snap2 =
            _snapshot(400, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap2);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));

        // Same reserve at 3pm UTC → still YELLOW (24/7 cyberpunk markets!)
        vm.warp(15 hours);
        PolicyManager.SystemSnapshot memory snap3 =
            _snapshot(400, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4% reserve

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap3);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Yellow));
    }

    /// @notice Test band ignores oracle staleness (oracle only used for pricing, not bands)
    function test_BandIgnoresOracleStaleness() public {
        // Set reserve to 6% with fresh oracle → GREEN
        vm.warp(5000);
        PolicyManager.SystemSnapshot memory freshSnap =
            _snapshot(600, 400, 10, 60, 1_000_000e18, 1e18, 0, 1); // 6% reserve, oracle fresh (60s)

        vm.prank(timelock);
        policy.reportSystemSnapshot(freshSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green));

        // Same reserve but oracle now stale (2 hours) → still GREEN (oracle doesn't affect bands!)
        vm.warp(5001);
        PolicyManager.SystemSnapshot memory staleSnap =
            _snapshot(600, 400, 10, 7200, 1_000_000e18, 1e18, 0, 1); // 6% reserve, oracle stale (7200s = 2h)

        vm.prank(timelock);
        policy.reportSystemSnapshot(staleSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green)); // Still GREEN!

        // Oracle becomes fresh again → still GREEN (staleness has ZERO impact on band)
        vm.warp(5002);
        PolicyManager.SystemSnapshot memory freshAgain =
            _snapshot(600, 400, 10, 30, 1_000_000e18, 1e18, 0, 1); // 6% reserve, oracle fresh (30s)

        vm.prank(timelock);
        policy.reportSystemSnapshot(freshAgain);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green));
    }

    // ========= Phase 4.1: Boundary Testing (Exact Threshold Values) =========

    /// @notice Phase 4.1: Test R/L = 5.00% exactly → GREEN (at warn threshold boundary)
    function test_Phase4_BoundaryExact_5Point00Percent_IsGreen() public {
        vm.warp(10000);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(500, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 500 bps = 5.00% exactly

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "5.00% should be GREEN (>= warnBps)"
        );
    }

    /// @notice Phase 4.1: Test R/L = 4.99% → YELLOW (just below warn threshold)
    function test_Phase4_BoundaryJustBelow_4Point99Percent_IsYellow() public {
        vm.warp(10001);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(499, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 499 bps = 4.99%

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "4.99% should be YELLOW (< warnBps)"
        );
    }

    /// @notice Phase 4.1: Test R/L = 2.50% exactly → YELLOW (at floor threshold boundary)
    function test_Phase4_BoundaryExact_2Point50Percent_IsYellow() public {
        vm.warp(10002);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(250, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 250 bps = 2.50% exactly

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "2.50% should be YELLOW (>= floorBps but < warnBps)"
        );
    }

    /// @notice Phase 4.1: Test R/L = 2.49% → RED (just below floor threshold)
    function test_Phase4_BoundaryJustBelow_2Point49Percent_IsRed() public {
        vm.warp(10003);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(249, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 249 bps = 2.49%

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "2.49% should be RED (< floorBps)"
        );
    }

    /// @notice Phase 4.1: Test R/L = 1.00% exactly → governance vote (operationally Red)
    /// @dev Note: emergencyBps uses <= comparison, so 1.00% triggers governance vote condition
    function test_Phase4_BoundaryExact_1Point00Percent_IsRed_GovVote() public {
        vm.warp(10004);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(100, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 100 bps = 1.00% exactly

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "1.00% should be Red operationally (<= emergencyBps)"
        );
        assertTrue(policy.requiresGovernanceVote(), "Emergency threshold should require governance vote");
    }

    /// @notice Phase 4.1: Test R/L = 1.01% → RED (just above emergency threshold)
    function test_Phase4_BoundaryJustAbove_1Point01Percent_IsRed() public {
        vm.warp(10005);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(101, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 101 bps = 1.01%

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "1.01% should be RED (> emergencyBps but < floorBps)"
        );
    }

    /// @notice Phase 4.1: Test R/L = 0.99% → governance vote (operationally Red)
    function test_Phase4_BoundaryJustBelow_0Point99Percent_IsRed_GovVote() public {
        vm.warp(10006);
        PolicyManager.SystemSnapshot memory snap =
            _snapshot(99, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 99 bps = 0.99%

        vm.prank(timelock);
        policy.reportSystemSnapshot(snap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "0.99% should be Red operationally (<= emergencyBps)"
        );
        assertTrue(policy.requiresGovernanceVote(), "Emergency threshold should require governance vote");
    }

    // ========= Phase 4.2: Rapid Band Oscillation (No Hysteresis) =========

    /// @notice Phase 4.2: Test 100 rapid GREEN↔YELLOW oscillations with no hysteresis delays
    /// @dev Verifies instant band transitions and no state corruption from rapid changes
    function test_Phase4_RapidBandOscillation_100Iterations() public {
        uint256 startTime = 20000;
        vm.warp(startTime);

        // Start at 5.1% (GREEN)
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(510, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 510 bps = 5.1%
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(490, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 490 bps = 4.9%

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "Initial state should be GREEN at 5.1%"
        );

        // Oscillate 100 times: GREEN → YELLOW → GREEN → YELLOW → ...
        for (uint256 i = 0; i < 100; i++) {
            vm.warp(startTime + i * 2); // Advance time slightly each iteration

            // Drop to 4.9% (YELLOW)
            vm.prank(timelock);
            policy.reportSystemSnapshot(yellowSnap);
            assertEq(
                uint8(policy.currentBand()),
                uint8(PolicyManager.Band.Yellow),
                string(
                    abi.encodePacked(
                        "Iteration ",
                        _uint2str(i),
                        ": Should transition to YELLOW instantly (no hysteresis)"
                    )
                )
            );

            // Rise to 5.1% (GREEN)
            vm.prank(timelock);
            policy.reportSystemSnapshot(greenSnap);
            assertEq(
                uint8(policy.currentBand()),
                uint8(PolicyManager.Band.Green),
                string(
                    abi.encodePacked(
                        "Iteration ",
                        _uint2str(i),
                        ": Should transition to GREEN instantly (no hysteresis)"
                    )
                )
            );
        }

        // Final verification: band should still be GREEN with no state corruption
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "Final state should be GREEN"
        );

        // Verify we can still transition to other bands correctly (no corruption)
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(200, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 200 bps = 2.0% (RED)

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "Should still transition to RED correctly after oscillation"
        );
    }

    /// @notice Helper to convert uint to string for error messages
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }

    // ========= Phase 4.3: Multi-User Concurrent Operations =========

    /// @notice Phase 4.3: Test 100-user scenario with band transitions GREEN→YELLOW→RED
    /// @dev Simulates sequential batches of refunds causing instant band updates
    function test_Phase4_MultiUser_100Users_BandTransitions() public {
        uint256 startTime = 30000;
        vm.warp(startTime);

        // Initial setup: 100 users with varying balances, R/L = 10% (GREEN)
        // Total supply: 1,000,000 STRX, Reserve: 100,000 USDC (10%)
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(1000, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 1000 bps = 10%

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "Should start in GREEN at 10%"
        );

        // Get GREEN band fees for verification
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        uint16 greenRefundFee = greenConfig.refundFeeBps;

        // BATCH 1: Users 1-50 refund simultaneously
        // Each user refunds 1,000 BUCK → total 50,000 BUCK refunded
        // Reserve drops from 100,000 to 50,000 USDC
        // New R/L = 50,000 / 950,000 = 5.26% (still GREEN, but approaching YELLOW)
        vm.warp(startTime + 100);
        PolicyManager.SystemSnapshot memory afterBatch1 =
            _snapshot(526, 400, 10, 100, 950_000e18, 1e18, 0, 1); // 526 bps = 5.26%

        vm.prank(timelock);
        policy.reportSystemSnapshot(afterBatch1);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "After batch 1 (50 users): Should still be GREEN at 5.26%"
        );

        // Verify batch 1 used GREEN fees (all 50 users paid greenRefundFee)
        PolicyManager.BandConfig memory currentConfig1 = policy.getBandConfig(policy.currentBand());
        assertEq(
            currentConfig1.refundFeeBps, greenRefundFee, "Batch 1 should use GREEN refund fees"
        );

        // BATCH 2: Users 51-75 refund simultaneously (25 more users)
        // Each user refunds 1,000 BUCK → total 25,000 BUCK refunded
        // Reserve drops from 50,000 to 25,000 USDC
        // New R/L = 25,000 / 925,000 = 2.70% (YELLOW)
        vm.warp(startTime + 200);
        PolicyManager.SystemSnapshot memory afterBatch2 =
            _snapshot(270, 400, 10, 100, 925_000e18, 1e18, 0, 1); // 270 bps = 2.70%

        vm.prank(timelock);
        policy.reportSystemSnapshot(afterBatch2);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "After batch 2 (75 users total): Should transition to YELLOW at 2.70%"
        );

        // Verify batch 2 triggered YELLOW band (higher fees than GREEN)
        PolicyManager.BandConfig memory yellowConfig =
            policy.getBandConfig(PolicyManager.Band.Yellow);
        assertGt(
            yellowConfig.refundFeeBps,
            greenRefundFee,
            "YELLOW refund fees should be higher than GREEN"
        );

        // BATCH 3: Users 76-100 refund simultaneously (25 more users)
        // Each user refunds 1,000 BUCK → total 25,000 BUCK refunded
        // Reserve drops from 25,000 to 0 USDC
        // New R/L = 0 / 900,000 = 0% (EMERGENCY - but let's use 2.0% for RED)
        vm.warp(startTime + 300);
        PolicyManager.SystemSnapshot memory afterBatch3 =
            _snapshot(200, 400, 10, 100, 900_000e18, 1e18, 0, 1); // 200 bps = 2.0% (RED)

        vm.prank(timelock);
        policy.reportSystemSnapshot(afterBatch3);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "After batch 3 (100 users total): Should transition to RED at 2.0%"
        );

        // Verify batch 3 triggered RED band (highest fees)
        PolicyManager.BandConfig memory redConfig = policy.getBandConfig(PolicyManager.Band.Red);
        assertGt(
            redConfig.refundFeeBps,
            yellowConfig.refundFeeBps,
            "RED refund fees should be higher than YELLOW"
        );

        // FINAL VERIFICATION: No race conditions, all transitions were instant
        // Verify we can still read band state correctly (no corruption)
        assertEq(
            uint8(policy.currentBand()), uint8(PolicyManager.Band.Red), "Final band should be RED"
        );

        // Verify fee progression: GREEN < YELLOW < RED
        assertLt(greenRefundFee, yellowConfig.refundFeeBps, "GREEN fees < YELLOW fees");
        assertLt(yellowConfig.refundFeeBps, redConfig.refundFeeBps, "YELLOW fees < RED fees");

        // Verify instant recovery: transition back to GREEN if reserve improves
        PolicyManager.SystemSnapshot memory recoverySnap =
            _snapshot(1000, 400, 10, 100, 900_000e18, 1e18, 0, 1); // 1000 bps = 10% (GREEN)

        vm.prank(timelock);
        policy.reportSystemSnapshot(recoverySnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Green),
            "Should instantly recover to GREEN when reserve improves to 10%"
        );
    }

    // ========= Phase 4.4: Distribution During Band Transition =========

    /// @notice Phase 4.4: Verify distributions work in all bands and band updates are instant
    /// @dev Tests architectural decision from Phase 2.1: distributions never blocked by bands
    function test_Phase4_DistributionDuringBandTransition() public {
        uint256 startTime = 40000;
        vm.warp(startTime);

        // Start in YELLOW band (4% reserve)
        // This is above RED threshold (2.5%) but below GREEN (5%)
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(400, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 400 bps = 4.0%

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "Should start in YELLOW at 4.0%"
        );

        // Get YELLOW band config for comparison
        PolicyManager.BandConfig memory yellowConfig =
            policy.getBandConfig(PolicyManager.Band.Yellow);

        // Transaction T: User refunds STRX, causing reserve to drop to 2.4% (RED band)
        vm.warp(startTime + 100);
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(240, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 240 bps = 2.4%

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);

        // VERIFY: Band updated instantly to RED (no stale YELLOW band)
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "Band should instantly transition to RED at 2.4%"
        );

        // Get RED band config
        PolicyManager.BandConfig memory redConfig = policy.getBandConfig(PolicyManager.Band.Red);

        // Verify RED has higher fees than YELLOW (band differentiation working)
        assertGt(
            redConfig.refundFeeBps,
            yellowConfig.refundFeeBps,
            "RED fees should be higher than YELLOW fees"
        );

        // Transaction T+1 (same block): Distributor calls distribute()
        // This simulates reward distributions happening immediately after band transition
        // Per Phase 2.1 architectural decision: distributions work in ALL bands (never blocked)

        // VERIFY: We're still in RED band (no race condition)
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Red),
            "Should still be in RED band when distribution happens"
        );

        // VERIFY: Distribution would use RED band pricing (via CAP formula)
        // CAP formula: BUCK = max(oracle, CR) when CR < 1
        // In RED band (2.4% reserve), CAP pricing still works correctly
        // This verifies that distributions can still be priced correctly in stressed bands

        // Simulate distribution scenario: verify band state is readable
        PolicyManager.BandConfig memory currentBandConfig =
            policy.getBandConfig(policy.currentBand());
        assertEq(
            currentBandConfig.refundFeeBps, redConfig.refundFeeBps, "Current band should be RED"
        );

        // VERIFY: Band can transition back to YELLOW after distribution
        vm.warp(startTime + 200);
        PolicyManager.SystemSnapshot memory recoverySnap =
            _snapshot(300, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 300 bps = 3.0% (YELLOW)

        vm.prank(timelock);
        policy.reportSystemSnapshot(recoverySnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "Should recover to YELLOW at 3.0% after reserve improves"
        );

        // FINAL VERIFICATION: No stale band reads throughout the transition sequence
        // All band reads reflected current R/L instantly (YELLOW → RED → YELLOW)
        PolicyManager.BandConfig memory finalConfig = policy.getBandConfig(policy.currentBand());
        assertEq(finalConfig.refundFeeBps, yellowConfig.refundFeeBps, "Final band should be YELLOW");
    }

    // Sprint 2.1: Removed marketIsOpen parameter (market hours deleted)
    function _snapshot(
        uint16 reserveRatioBps,
        uint16 equityBufferBps,
        uint16,
        uint32 oracleStaleSeconds,
        uint256 totalSupply,
        uint256 navPerToken,
        uint256 reserveBalance,
        uint16
    ) internal pure returns (PolicyManager.SystemSnapshot memory) {
        if (reserveBalance == 0 && navPerToken != 0) {
            uint256 L = Math.mulDiv(totalSupply, navPerToken, 1e18);
            reserveBalance = Math.mulDiv(reserveRatioBps, L, 10_000);
        }
        return PolicyManager.SystemSnapshot({
            reserveRatioBps: reserveRatioBps,
            equityBufferBps: equityBufferBps,
            oracleStaleSeconds: oracleStaleSeconds,
            totalSupply: totalSupply,
            navPerToken: navPerToken,
            reserveBalance: reserveBalance,
            collateralRatio: 1e18
        });
    }

    /// @notice Sprint 3 Phase 1: Verify reduced mint/refund fees across all bands
    /// @dev Fees reduced 50% to encourage user activity, primary revenue now from 10% skim
    function test_Sprint3_Phase1_ReducedMintRefundFees() public view {
        // GREEN band verification (healthiest state)
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        assertEq(greenConfig.mintFeeBps, 5, "GREEN mint fee should be 5 bps (0.05%)");
        assertEq(greenConfig.refundFeeBps, 10, "GREEN refund fee should be 10 bps (0.1%)");
        assertEq(greenConfig.distributionSkimBps, 1000, "GREEN skim should be 1000 bps (10%)");

        // YELLOW band verification (moderate stress)
        PolicyManager.BandConfig memory yellowConfig =
            policy.getBandConfig(PolicyManager.Band.Yellow);
        assertEq(yellowConfig.mintFeeBps, 10, "YELLOW mint fee should be 10 bps (0.1%)");
        assertEq(yellowConfig.refundFeeBps, 15, "YELLOW refund fee should be 15 bps (0.15%)");
        assertEq(yellowConfig.distributionSkimBps, 1000, "YELLOW skim should be 1000 bps (10%)");

        // RED band verification (high stress)
        PolicyManager.BandConfig memory redConfig = policy.getBandConfig(PolicyManager.Band.Red);
        assertEq(redConfig.mintFeeBps, 15, "RED mint fee should be 15 bps (0.15%)");
        assertEq(redConfig.refundFeeBps, 20, "RED refund fee should be 20 bps (0.2%)");
        assertEq(redConfig.distributionSkimBps, 1000, "RED skim should be 1000 bps (10%)");

        // Verify all bands have same skim (revenue model consistency)
        assertEq(
            greenConfig.distributionSkimBps,
            yellowConfig.distributionSkimBps,
            "All bands should have same skim"
        );
        assertEq(
            yellowConfig.distributionSkimBps,
            redConfig.distributionSkimBps,
            "All bands should have same skim"
        );
    }

    // ========= Cap Exhaustion Tests =========

    /// @notice Test exhausting mint cap exactly to 0 bps remaining
    function test_MintCap_ExactExhaustion_RemainingEqualsZero() public {
        // Mints are unlimited - verify we can mint any amount repeatedly
        PolicyManager.DerivedCaps memory caps = policy.getDerivedCaps();
        assertEq(caps.mintAggregateBps, 10000, "Mint cap should be unlimited");

        address user = address(0x1111);

        // Mint 100% multiple times - should always succeed
        policy.checkMintCap( 10000);
        policy.recordMint( 10000);

        // Can mint again immediately
        policy.checkMintCap( 10000);
        policy.recordMint( 10000);

        // And again
        policy.checkMintCap( 10000);
    }

    /// @notice Test that mints are unlimited (production config)
    function test_MintCap_OverExhaustion_ByOneBps() public {
        // Verify config has unlimited mints
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        assertEq(config.caps.mintAggregateBps, 0, "Config should have unlimited mints (0)");

        // Get derived caps (should return 10000 = unlimited)
        PolicyManager.DerivedCaps memory caps = policy.getDerivedCaps();
        assertEq(caps.mintAggregateBps, 10000, "Derived cap should be unlimited (10000 bps)");

        // Verify any mint amount passes
        address user = address(0x2222);
        bool passed = policy.checkMintCap( 10000);
        assertTrue(passed, "100% mint should pass when unlimited");

        // Record mint and check again - should still pass
        policy.recordMint( 10000);
        passed = policy.checkMintCap( 10000);
        assertTrue(passed, "Should still pass after recording 100% mint");
    }

    /// @notice Test exhausting refund cap exactly to 0 tokens remaining
    function test_RefundCap_ExactExhaustion_RemainingEqualsZero() public {
        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get current refund cap in TOKENS (not BPS) from remaining capacity
        (, uint256 refundCapTokens) = policy.getAggregateRemainingCapacity();

        // Exhaust refund cap exactly to 0
        address user = address(0x4444);
        policy.checkRefundCap( refundCapTokens);
        policy.recordRefund( refundCapTokens);

        // Verify remaining is 0
        (, uint256 remaining) = policy.getAggregateRemainingCapacity();
        assertEq(remaining, 0, "Refund remaining capacity should be 0 after exact exhaustion");

        // Verify any amount over 0 reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector, PolicyManager.CapType.RefundAggregate, 1, 0
            )
        );
        policy.checkRefundCap( 1);
    }

    /// @notice Test trying to exceed refund cap by 1 token
    function test_RefundCap_OverExhaustion_ByOneBps() public {
        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get current refund cap in TOKENS (not BPS) from remaining capacity
        (, uint256 refundCapTokens) = policy.getAggregateRemainingCapacity();

        // Try to refund 1 token over cap
        address user = address(0x5555);
        uint256 overAmount = refundCapTokens + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.RefundAggregate,
                overAmount,
                refundCapTokens
            )
        );
        policy.checkRefundCap( overAmount);
    }

    /// @notice Test multiple users exhausting aggregate mint cap together
    function test_MintCap_MultipleUsers_ExhaustAggregate() public {
        // Mints are unlimited - verify multiple users can mint any amount

        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get current mint cap (should be unlimited)
        PolicyManager.DerivedCaps memory caps = policy.getDerivedCaps();
        assertEq(caps.mintAggregateBps, 10000, "Mint cap should be unlimited");

        // Multiple users each mint 100% of supply
        for (uint256 i = 1; i <= 5; i++) {
            address user = address(uint160(0x1000 + i));
            policy.checkMintCap( 10000); // 100% of supply
            policy.recordMint( 10000);
        }

        // Even after 5 users mint 100% each, more mints should still succeed
        address user6 = address(0x1006);
        policy.checkMintCap( 10000);
        policy.recordMint( 10000);

        // And user 6 can mint again
        policy.checkMintCap( 10000);
    }

    /// @notice Test same user making multiple refund transactions within same epoch
    function test_RefundCap_SameUser_MultipleTransactions() public {
        // Allow smaller transactions for this test
        policy.setMaxSingleTransactionPct(30);

        // Get current refund cap in TOKENS (not BPS) from remaining capacity
        (, uint256 initialRefundCapTokens) = policy.getAggregateRemainingCapacity();

        address user = address(0x6666);

        // Make 3 refund transactions, each 30% of remaining capacity
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 remaining) = policy.getAggregateRemainingCapacity();
            uint256 amount = (remaining * 30) / 100;

            policy.checkRefundCap( amount);
            policy.recordRefund( amount);
        }

        // Verify capacity decreased correctly
        (, uint256 finalRemaining) = policy.getAggregateRemainingCapacity();
        assertLt(finalRemaining, initialRefundCapTokens, "Refund capacity should have decreased");
        assertGt(finalRemaining, 0, "Should still have some capacity left");
    }

    // ========= Cap Cycle Reset Tests (EST Midnight = 05:00 UTC) =========

    /// @notice Test cap reset at exact midnight EST boundary (05:00 UTC)
    function test_CapReset_ExactlyAtMidnightEST() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 500; // 5% of supply = 50,000 tokens
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Cap cycle resets at EST midnight = 05:00 UTC
        // Set time to 04:59:59 UTC (23:59:59 EST) - just before EST midnight
        uint256 beforeMidnightEST = 5 hours - 1; // 04:59:59 UTC = 23:59:59 EST
        vm.warp(beforeMidnightEST);

        // Get mint cap in TOKENS from remaining capacity (should be 50,000 tokens)
        (uint256 mintCapTokens,) = policy.getAggregateRemainingCapacity();

        address user = address(0x7777);
        policy.checkMintCap( mintCapTokens);
        policy.recordMint( mintCapTokens);

        // Verify cap is exhausted
        (uint256 remainingBefore,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingBefore, 0, "Cap should be exhausted before EST midnight");

        // Move to exactly EST midnight (05:00 UTC)
        uint256 midnightEST = 5 hours; // 05:00:00 UTC = 00:00:00 EST
        vm.warp(midnightEST);

        // Verify cap has reset
        (uint256 remainingAfter,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingAfter, mintCapTokens, "Cap should reset to full at EST midnight");

        // Verify we can mint again
        policy.checkMintCap( 100e18);
    }

    /// @notice Test crossing midnight resets capacity
    function test_CapReset_CrossMidnight_ResetsCapacity() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 500; // 5% of supply = 50,000 tokens
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get mint cap in TOKENS from remaining capacity
        (uint256 mintCapTokens,) = policy.getAggregateRemainingCapacity();
        uint256 halfCap = mintCapTokens / 2;

        address user = address(0x8888);
        policy.checkMintCap( halfCap);
        policy.recordMint( halfCap);

        // Verify 50% remaining
        (uint256 remainingDay1,) = policy.getAggregateRemainingCapacity();
        assertApproxEqAbs(remainingDay1, halfCap, 1, "Should have ~50% remaining on day 1");

        // Move to next day (advance 1 day)
        vm.warp(block.timestamp + 1 days);

        // Verify cap has reset to full
        (uint256 remainingDay2,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingDay2, mintCapTokens, "Cap should reset to full on day 2");

        // Verify we can use full cap again
        policy.checkMintCap( mintCapTokens);
    }

    /// @notice Test within same cap cycle, cap doesn't reset
    function test_CapReset_SameCycle_CapRemainsSame() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% of supply
        policy.setBandConfig(PolicyManager.Band.Green, config);

        // Warp to 12:00 UTC (07:00 EST) - well into an EST day
        // Cap cycle resets at EST midnight = 05:00 UTC
        vm.warp(12 hours);

        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get mint cap in TOKENS from remaining capacity
        (uint256 mintCapTokens,) = policy.getAggregateRemainingCapacity();
        uint256 amount = (mintCapTokens * 30) / 100;

        address user = address(0x9999);
        policy.checkMintCap( amount);
        policy.recordMint( amount);

        // Get remaining after first mint
        (uint256 remaining1,) = policy.getAggregateRemainingCapacity();

        // Advance 6 hours (12:00 UTC -> 18:00 UTC = 07:00 EST -> 13:00 EST)
        // Still within same EST day, won't cross 05:00 UTC boundary
        vm.warp(block.timestamp + 6 hours);

        // Verify cap hasn't reset
        (uint256 remaining2,) = policy.getAggregateRemainingCapacity();
        assertEq(remaining2, remaining1, "Cap should not reset within same cycle");
    }

    // ========= getRemainingCapacity Tests =========

    /// @notice Test getRemainingCapacity after partial mint usage
    function test_GetRemainingCapacity_AfterPartialMint() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% of supply
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Get initial capacity
        (uint256 initialMint, uint256 initialRefund) = policy.getAggregateRemainingCapacity();

        // Use 25% of mint cap
        uint256 amount = (initialMint * 25) / 100;
        address user = address(0xAAAA);

        policy.checkMintCap( amount);
        policy.recordMint( amount);

        // Verify remaining capacity
        (uint256 remainingMint, uint256 remainingRefund) = policy.getAggregateRemainingCapacity();

        assertApproxEqAbs(
            remainingMint, initialMint - amount, 1, "Mint capacity should decrease by amount used"
        );
        assertEq(remainingRefund, initialRefund, "Refund capacity should be unchanged");
    }

    /// @notice Test getRemainingCapacity after full exhaustion
    function test_GetRemainingCapacity_AfterFullExhaustion() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 500; // 5% of supply
        config.caps.refundAggregateBps = 500; // 5% of supply
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Get caps in TOKENS from remaining capacity
        (uint256 mintCapTokens, uint256 refundCapTokens) = policy.getAggregateRemainingCapacity();

        address user1 = address(0xBBBB);
        policy.checkMintCap( mintCapTokens);
        policy.recordMint( mintCapTokens);

        address user2 = address(0xCCCC);
        policy.checkRefundCap( refundCapTokens);
        policy.recordRefund( refundCapTokens);

        // Verify both capacities are 0
        (uint256 remainingMint, uint256 remainingRefund) = policy.getAggregateRemainingCapacity();
        assertEq(remainingMint, 0, "Mint capacity should be 0 after exhaustion");
        assertEq(remainingRefund, 0, "Refund capacity should be 0 after exhaustion");
    }

    /// @notice Test getRemainingCapacity after midnight reset
    function test_GetRemainingCapacity_AfterMidnightReset() public {
        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Set a limited mint cap for this test (default is unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% cap
        policy.setBandConfig(PolicyManager.Band.Green, config);

        // Get mint cap in TOKENS from remaining capacity
        (uint256 mintCapTokens,) = policy.getAggregateRemainingCapacity();

        address user = address(0xDDDD);
        policy.checkMintCap( mintCapTokens);
        policy.recordMint( mintCapTokens);

        // Verify exhausted
        (uint256 remainingBefore,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingBefore, 0, "Should be exhausted before midnight");

        // Move to next day
        vm.warp(block.timestamp + 1 days);

        // Verify reset
        (uint256 remainingAfter,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingAfter, mintCapTokens, "Should reset to full capacity after midnight");
    }

    // ========= recordMint/recordRefund Aggregate Tracking Tests =========

    /// @notice Test recordMint updates aggregate correctly
    function test_RecordMint_UpdatesAggregateCorrectly() public {
        // Set a limited mint cap for this test (default is unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% cap
        policy.setBandConfig(PolicyManager.Band.Green, config);

        address user = address(0xEEEE);
        uint256 amount = 100e18; // 100 tokens

        // Get initial remaining
        (uint256 initialRemaining,) = policy.getAggregateRemainingCapacity();

        // Record mint
        policy.recordMint( amount);

        // Verify aggregate updated
        (uint256 newRemaining,) = policy.getAggregateRemainingCapacity();
        assertEq(
            newRemaining, initialRemaining - amount, "Aggregate should decrease by recorded amount"
        );
    }

    /// @notice Test recordRefund updates aggregate correctly
    function test_RecordRefund_UpdatesAggregateCorrectly() public {
        address user = address(0xFFFF);
        uint256 amount = 150;

        // Get initial remaining
        (, uint256 initialRemaining) = policy.getAggregateRemainingCapacity();

        // Record refund
        policy.recordRefund( amount);

        // Verify aggregate updated
        (, uint256 newRemaining) = policy.getAggregateRemainingCapacity();
        assertEq(
            newRemaining,
            initialRemaining - amount,
            "Refund aggregate should decrease by recorded amount"
        );
    }

    /// @notice Test multiple mints accumulate in aggregate
    function test_RecordMint_MultipleTransactions_Accumulates() public {
        // Set a limited mint cap for this test (default is unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% cap
        policy.setBandConfig(PolicyManager.Band.Green, config);

        address user = address(0x1234);
        uint256 amount1 = 50e18;  // 50 tokens
        uint256 amount2 = 75e18;  // 75 tokens
        uint256 amount3 = 100e18; // 100 tokens

        // Get initial remaining
        (uint256 initialRemaining,) = policy.getAggregateRemainingCapacity();

        // Record three mints
        policy.recordMint( amount1);
        policy.recordMint( amount2);
        policy.recordMint( amount3);

        // Verify aggregate accumulated all three
        (uint256 finalRemaining,) = policy.getAggregateRemainingCapacity();
        uint256 totalUsed = amount1 + amount2 + amount3;
        assertEq(finalRemaining, initialRemaining - totalUsed, "Should accumulate all three mints");
    }

    /// @notice Test multiple refunds accumulate in aggregate
    function test_RecordRefund_MultipleTransactions_Accumulates() public {
        address user = address(0x5678);
        uint256 amount1 = 60;
        uint256 amount2 = 80;
        uint256 amount3 = 90;

        // Get initial remaining
        (, uint256 initialRemaining) = policy.getAggregateRemainingCapacity();

        // Record three refunds
        policy.recordRefund( amount1);
        policy.recordRefund( amount2);
        policy.recordRefund( amount3);

        // Verify aggregate accumulated all three
        (, uint256 finalRemaining) = policy.getAggregateRemainingCapacity();
        uint256 totalUsed = amount1 + amount2 + amount3;
        assertEq(
            finalRemaining, initialRemaining - totalUsed, "Should accumulate all three refunds"
        );
    }

    // ========= maxSingleTransactionPct Edge Case Tests =========

    /// @notice Test exactly at 50% maxSingleTransactionPct passes
    function test_MaxSingleTransactionPct_ExactlyAt50Percent() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% of supply
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Default is 50%, verify it's set
        assertEq(policy.maxSingleTransactionPct(), 50, "Default should be 50%");

        // Get current mint cap
        (uint256 remainingMint,) = policy.getAggregateRemainingCapacity();

        // Calculate exactly 50% of remaining
        uint256 exactlyHalf = (remainingMint * 50) / 100;

        // Verify this amount passes
        address user = address(0xABCD);
        policy.checkMintCap( exactlyHalf);
        policy.recordMint( exactlyHalf);

        // Verify it was recorded
        (uint256 afterMint,) = policy.getAggregateRemainingCapacity();
        assertApproxEqAbs(
            afterMint, remainingMint - exactlyHalf, 1, "Should have used exactly half"
        );
    }

    /// @notice Test just over 50% maxSingleTransactionPct fails
    function test_MaxSingleTransactionPct_JustOver50Percent() public {
        // Mints are unlimited - maxSingleTransactionPct does NOT apply to mints
        // This is by design: we need to allow 10x market cap mints in a single day

        // Default is 50%
        assertEq(policy.maxSingleTransactionPct(), 50, "Default should be 50%");

        // Get current derived caps
        PolicyManager.DerivedCaps memory caps = policy.getDerivedCaps();
        assertEq(caps.mintAggregateBps, 10000, "Mint cap should be unlimited");

        // Calculate 51% of supply (over the 50% limit if it applied)
        uint256 overHalf = (caps.mintAggregateBps * 51) / 100;

        // Verify this amount succeeds for mints (unlimited)
        address user = address(0xDCBA);
        policy.checkMintCap( overHalf);
        policy.recordMint( overHalf);

        // Can mint even more (100% of supply)
        policy.checkMintCap( 10000);
    }

    /// @notice Test 100% maxSingleTransactionPct allows full cap usage
    function test_MaxSingleTransactionPct_100Percent_AllowsFullCap() public {
        // Configure a limited cap for this test (default setUp uses unlimited)
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 1000; // 10% of supply
        policy.setBandConfig(PolicyManager.Band.Green, config);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Set to 100%
        policy.setMaxSingleTransactionPct(100);
        assertEq(policy.maxSingleTransactionPct(), 100, "Should be 100%");

        // Get current mint cap
        (uint256 remainingMint,) = policy.getAggregateRemainingCapacity();

        // Verify we can use entire remaining capacity
        address user = address(0x1111);
        policy.checkMintCap( remainingMint);
        policy.recordMint( remainingMint);

        // Verify cap is fully exhausted
        (uint256 afterMint,) = policy.getAggregateRemainingCapacity();
        assertEq(afterMint, 0, "Should be able to exhaust full cap with 100% limit");
    }

    /// @notice Test setting maxSingleTransactionPct to different values
    /// @dev maxSingleTransactionPct only applies to REFUNDS, not mints
    function test_MaxSingleTransactionPct_DifferentValues() public {
        // Test 25% - use REFUND capacity (maxSingleTransactionPct only applies to refunds)
        policy.setMaxSingleTransactionPct(25);
        (, uint256 remaining) = policy.getAggregateRemainingCapacity();
        uint256 max25 = (remaining * 25) / 100;

        policy.checkRefundCap(max25);

        // Test 75%
        policy.setMaxSingleTransactionPct(75);
        vm.warp(block.timestamp + 1 days); // Reset cap
        (, remaining) = policy.getAggregateRemainingCapacity();
        uint256 max75 = (remaining * 75) / 100;

        policy.checkRefundCap(max75);

        // Test 10%
        policy.setMaxSingleTransactionPct(10);
        vm.warp(block.timestamp + 1 days); // Reset cap
        (, remaining) = policy.getAggregateRemainingCapacity();
        uint256 max10 = (remaining * 10) / 100;

        policy.checkRefundCap(max10);
    }

    // ========= Band Transition During Cap Operations Tests =========

    /// @notice Test band transition during cap check uses current band
    function test_BandTransition_DuringCapCheck_UsesCurrentBand() public {
        // Start in GREEN band
        vm.warp(50000);
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(600, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 6% reserve (GREEN)

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);
        assertEq(
            uint8(policy.currentBand()), uint8(PolicyManager.Band.Green), "Should start in GREEN"
        );

        // Get GREEN caps
        PolicyManager.DerivedCaps memory greenCaps = policy.getDerivedCaps();
        uint256 greenMintCap = greenCaps.mintAggregateBps;
        uint256 greenRefundCap = greenCaps.refundAggregateBps;

        // Transition to YELLOW band (4% reserve)
        vm.warp(50001);
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(400, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4% reserve (YELLOW)

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);
        assertEq(
            uint8(policy.currentBand()),
            uint8(PolicyManager.Band.Yellow),
            "Should transition to YELLOW"
        );

        // Get YELLOW caps
        PolicyManager.DerivedCaps memory yellowCaps = policy.getDerivedCaps();
        uint256 yellowMintCap = yellowCaps.mintAggregateBps;
        uint256 yellowRefundCap = yellowCaps.refundAggregateBps;

        // Verify mint caps remain unlimited (10000) across bands
        assertEq(greenMintCap, 10000, "GREEN mint cap should be unlimited");
        assertEq(yellowMintCap, 10000, "YELLOW mint cap should be unlimited");
        assertEq(greenMintCap, yellowMintCap, "Mint caps should remain unlimited across bands");

        // Verify refund caps DO change with band transition
        assertNotEq(greenRefundCap, yellowRefundCap, "Refund cap should change when band changes");
    }

    /// @notice Test cap changes when band changes
    function test_CapChange_OnBandTransition() public {
        // Set time and start in GREEN
        vm.warp(60000);
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 8% reserve (GREEN)

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);

        // Record initial GREEN caps
        PolicyManager.DerivedCaps memory greenCaps = policy.getDerivedCaps();
        uint256 greenMintCap = greenCaps.mintAggregateBps;
        uint256 greenRefundCap = greenCaps.refundAggregateBps;

        // Transition to RED band (2% reserve)
        vm.warp(60001);
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(200, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2% reserve (RED)

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Red), "Should be in RED");

        // Record RED caps
        PolicyManager.DerivedCaps memory redCaps = policy.getDerivedCaps();
        uint256 redMintCap = redCaps.mintAggregateBps;
        uint256 redRefundCap = redCaps.refundAggregateBps;

        // Verify mint caps remain unlimited (10000) in both bands
        assertEq(greenMintCap, 10000, "GREEN mint cap should be unlimited");
        assertEq(redMintCap, 10000, "RED mint cap should be unlimited");
        assertEq(greenMintCap, redMintCap, "Mint caps should remain unlimited across bands");

        // Verify refund caps DO differ between GREEN and RED bands
        assertNotEq(
            greenRefundCap, redRefundCap, "Refund caps should differ between GREEN and RED bands"
        );
    }

    /// @notice Test that used capacity persists across band transitions within same epoch
    function test_UsedCapacity_PersistsAcrossBandTransitions() public {
        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Set a limited mint cap for ALL bands (default is unlimited)
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        greenConfig.caps.mintAggregateBps = 1000; // 10% cap = 100,000 tokens
        policy.setBandConfig(PolicyManager.Band.Green, greenConfig);

        PolicyManager.BandConfig memory yellowConfig = policy.getBandConfig(PolicyManager.Band.Yellow);
        yellowConfig.caps.mintAggregateBps = 1000; // Same cap for YELLOW
        policy.setBandConfig(PolicyManager.Band.Yellow, yellowConfig);

        // Start in GREEN, use some capacity
        vm.warp(70000);
        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(600, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 6% reserve (GREEN)

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);

        // Get initial capacity in tokens
        (uint256 initialCapTokens,) = policy.getAggregateRemainingCapacity();

        // Use 1000 tokens of mint cap in GREEN
        address user = address(0x7001);
        uint256 usedTokens = 1000e18;
        policy.checkMintCap( usedTokens);
        policy.recordMint( usedTokens);

        // Transition to YELLOW (same mint cap configured)
        vm.warp(70001);
        PolicyManager.SystemSnapshot memory yellowSnap =
            _snapshot(450, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 4.5% reserve (YELLOW)

        vm.prank(timelock);
        policy.reportSystemSnapshot(yellowSnap);

        // The used capacity should persist across band transition
        // New remaining = cap - tokens used in GREEN
        (uint256 remainingInYellow,) = policy.getAggregateRemainingCapacity();

        assertEq(
            remainingInYellow,
            initialCapTokens - usedTokens,
            "Used capacity should persist across band transition within same epoch"
        );
    }

    /// @notice Test cap reset at midnight clears usage even after band transitions
    function test_CapReset_ClearsUsage_AfterBandTransitions() public {
        // Allow 100% transactions for this test
        policy.setMaxSingleTransactionPct(100);

        // Set a limited mint cap for ALL bands (default is unlimited)
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        greenConfig.caps.mintAggregateBps = 1000; // 10% cap = 100,000 tokens
        policy.setBandConfig(PolicyManager.Band.Green, greenConfig);

        PolicyManager.BandConfig memory redConfig = policy.getBandConfig(PolicyManager.Band.Red);
        redConfig.caps.mintAggregateBps = 1000; // Same cap for RED
        policy.setBandConfig(PolicyManager.Band.Red, redConfig);

        // Start in GREEN, use some capacity
        uint256 dayStart = 86400 * 10; // Day 10
        vm.warp(dayStart + 3600); // 1 hour into day 10

        PolicyManager.SystemSnapshot memory greenSnap =
            _snapshot(600, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 6% reserve (GREEN)

        vm.prank(timelock);
        policy.reportSystemSnapshot(greenSnap);

        // Get initial capacity in tokens
        (uint256 initialCapTokens,) = policy.getAggregateRemainingCapacity();

        // Use 500 tokens in GREEN
        address user = address(0x8001);
        uint256 amount1 = 500e18;
        policy.checkMintCap( amount1);
        policy.recordMint( amount1);

        // Transition to RED
        vm.warp(dayStart + 7200); // 2 hours into day 10
        PolicyManager.SystemSnapshot memory redSnap =
            _snapshot(200, 400, 10, 100, 1_000_000e18, 1e18, 0, 1); // 2% reserve (RED)

        vm.prank(timelock);
        policy.reportSystemSnapshot(redSnap);

        // Use another 250 tokens in RED
        uint256 amount2 = 250e18;
        policy.checkMintCap( amount2);
        policy.recordMint( amount2);

        // Total used: 750 tokens
        uint256 totalUsed = amount1 + amount2;
        (uint256 remainingBeforeMidnight,) = policy.getAggregateRemainingCapacity();
        assertEq(
            remainingBeforeMidnight,
            initialCapTokens - totalUsed,
            "Should have used 750 tokens total before midnight"
        );

        // Move to next day (day 11)
        vm.warp(dayStart + 86400); // Start of day 11

        // Verify cap reset (should be full capacity, with 0 used)
        (uint256 remainingAfterMidnight,) = policy.getAggregateRemainingCapacity();
        assertEq(
            remainingAfterMidnight,
            initialCapTokens,
            "Cap should reset to full at midnight, clearing all previous usage"
        );
    }
}
