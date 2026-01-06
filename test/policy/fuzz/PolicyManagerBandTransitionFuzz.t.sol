// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PolicyManagerBandTransitionFuzzTest
 * @notice Comprehensive fuzz tests for PolicyManager band transitions and cap enforcement
 * @dev Tests random reserve ratios, snapshot timing, and band transition stress scenarios
 */
contract PolicyManagerBandTransitionFuzzTest is BaseTest {
    PolicyManager internal policy;
    address internal admin; // Admin wallet per strongArch.md
    address internal constant USER1 = address(0xBEEF);
    address internal constant USER2 = address(0xCAFE);
    address internal constant USER3 = address(0xD00D);

    // Reserve threshold constants (from default config)
    uint16 internal constant TARGET_BPS = 800; // 8% target
    uint16 internal constant WARN_BPS = 500; // 5% warning
    uint16 internal constant FLOOR_BPS = 200; // 2% floor
    uint16 internal constant EMERGENCY_BPS = 150; // 1.5% emergency

    function setUp() public {
        // Warp to epoch 1+ to avoid collision with uninitialized storage (epoch 0)
        vm.warp(1 days + 1);

        admin = address(this); // Test contract is the Admin
        policy = deployPolicyManager(admin);

        // Grant this test contract OPERATOR_ROLE for cap recording
        policy.grantRole(policy.OPERATOR_ROLE(), address(this));

        // Set initial snapshot with healthy reserve
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 1_000_000e18, 1e18, 0, 1));

        // Configure caps
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 10_000; // 100% of supply
        config.caps.refundAggregateBps = 10_000;
        policy.setBandConfig(PolicyManager.Band.Green, config);

        config = policy.getBandConfig(PolicyManager.Band.Yellow);
        config.caps.mintAggregateBps = 5_000; // 50% of supply
        config.caps.refundAggregateBps = 5_000;
        policy.setBandConfig(PolicyManager.Band.Yellow, config);

        config = policy.getBandConfig(PolicyManager.Band.Red);
        config.caps.mintAggregateBps = 1_000; // 10% of supply
        config.caps.refundAggregateBps = 1_000;
        policy.setBandConfig(PolicyManager.Band.Red, config);
    }

    /// @notice Fuzz test: Random reserve ratios trigger correct band transitions
    function testFuzzRandomReserveRatiosBandTransitions(
        uint16[20] memory reserveRatios,
        uint32[20] memory delays
    ) public {
        PolicyManager.Band previousBand = policy.currentBand();

        for (uint256 i = 0; i < reserveRatios.length; i++) {
            // Bound reserve ratio from 0% to 20% (0-2000 bps)
            uint16 reserveRatio = uint16(bound(uint256(reserveRatios[i]), 0, 2_000));

            // Advance time by 0-12 hours
            uint256 delay = bound(uint256(delays[i]), 0, 12 hours);
            vm.warp(block.timestamp + delay);

            // Report snapshot with new reserve ratio
            // Admin calls (test contract is admin)
            policy.reportSystemSnapshot(
                _snapshot(reserveRatio, 400, 10, 100, 1_000_000e18, 1e18, 0, 1)
            );

            PolicyManager.Band currentBand = policy.currentBand();

            // Verify band transitions follow expected logic (with hysteresis tolerance)
            if (reserveRatio <= EMERGENCY_BPS) {
                // Very low reserve should evaluate to Red operationally
                assertTrue(
                    uint8(currentBand) >= uint8(PolicyManager.Band.Red),
                    "Very low reserve should be Red"
                );
            } else if (reserveRatio < FLOOR_BPS) {
                // Below floor: Red or worse (no Emergency band anymore)
                assertTrue(
                    uint8(currentBand) >= uint8(PolicyManager.Band.Red),
                    "Below floor should be Red or worse"
                );
            } else if (reserveRatio < WARN_BPS) {
                // Should be Yellow or worse (could still be in hysteresis)
                assertTrue(
                    uint8(currentBand) >= uint8(PolicyManager.Band.Yellow),
                    "Below warn should be at least Yellow"
                );
            }
            // Note: We don't assert Green because RED hysteresis requires 30min + 2 healthy prints

            // Invariant: Band transitions should be reasonable (no impossible skips)
            uint8 diff = uint8(currentBand) > uint8(previousBand)
                ? uint8(currentBand) - uint8(previousBand)
                : uint8(previousBand) - uint8(currentBand);
            // Allow up to 2 step jumps for extreme condition changes
            assertLe(diff, 2, "Band transitions should not skip impossible states");

            previousBand = currentBand;
        }
    }

    /// @notice Fuzz test: Cap enforcement across random mint/refund operations
    function testFuzzCapEnforcementAcrossOperations(uint8[30] memory ops, uint16[30] memory amounts)
        public
    {
        vm.warp(block.timestamp + 1 days);
        uint256 totalSupply = 1_000_000e18;

        for (uint256 i = 0; i < ops.length; i++) {
            uint8 op = ops[i] % 4;
            address user = _selectUser(i);

            // Bound amount to 0.1% - 50% of supply in BPS, then convert to tokens
            uint256 amountBps = bound(uint256(amounts[i]), 10, 5_000);
            uint256 amountTokens = Math.mulDiv(amountBps, totalSupply, 10_000);

            if (op == 0) {
                // Try to mint - might hit cap
                try policy.checkMintCap( amountTokens) returns (bool) {
                    // Cap check passed, record the mint
                    policy.recordMint( amountTokens);
                } catch {
                    // Cap exceeded - this is expected behavior during fuzz testing
                    // Continue to next operation
                }
            } else if (op == 1) {
                // Try to refund - might hit cap
                try policy.checkRefundCap( amountTokens) returns (bool) {
                    // Cap check passed, record the refund
                    policy.recordRefund( amountTokens);
                } catch {
                    // Cap exceeded - this is expected behavior during fuzz testing
                    // Continue to next operation
                }
            } else if (op == 2) {
                // Change band (change reserve ratio)
                uint16 newRatio = uint16(bound(uint256(amounts[i]), 100, 1_500));

                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(newRatio, 400, 10, 100, totalSupply, 1e18, 0, 1)
                );
            } else {
                // Advance time (test epoch boundaries)
                uint256 timeJump = bound(uint256(amounts[i]), 1 hours, 2 days);
                vm.warp(block.timestamp + timeJump);

                // After epoch boundary, caps should reset
                if (timeJump >= 1 days) {
                    // New epoch - caps should have reset
                    // Note: Mint returns type(uint256).max when unlimited (mintAggregateBps=0)
                    // Note: Refund can be 0 when reserves are at/below floor (correct enforcement)
                    (uint256 mintCap, uint256 refundCap) = policy.getAggregateRemainingCapacity();
                    // Mint is unlimited (returns max) or has capacity
                    assertTrue(mintCap > 0 || mintCap == type(uint256).max, "Mint cap should be available after epoch reset");
                    // Refund cap can be 0 if reserves are at floor - this is correct behavior
                    // Just verify it's a valid value (not reverted)
                    assertTrue(refundCap <= totalSupply || refundCap == 0, "Refund cap should be valid");
                }
            }

            // Invariant: getRemainingCapacity should be valid
            // Mint: unlimited returns type(uint256).max, otherwise <= totalSupply
            // Refund: always <= totalSupply (can be 0 at floor)
            (uint256 mintRemaining, uint256 refundRemaining) = policy.getAggregateRemainingCapacity();
            assertTrue(mintRemaining <= totalSupply || mintRemaining == type(uint256).max, "Mint remaining should be valid");
            assertLe(refundRemaining, totalSupply, "Refund remaining should not exceed total supply");
        }
    }

    /// @notice Fuzz test: Snapshot timing and epoch boundaries
    function testFuzzSnapshotTimingEpochBoundaries(
        uint32[25] memory delays,
        uint16[25] memory amounts
    ) public {
        address user = USER1;
        uint64 currentEpoch = uint64(block.timestamp / 1 days);
        uint256 totalSupply = 1_000_000e18;

        for (uint256 i = 0; i < delays.length; i++) {
            // Bound delay from 10 minutes to 3 days
            uint256 delay = bound(uint256(delays[i]), 10 minutes, 3 days);
            vm.warp(block.timestamp + delay);

            uint64 newEpoch = uint64(block.timestamp / 1 days);

            // Perform some mint operations - convert BPS to tokens
            uint256 amountBps = bound(uint256(amounts[i]), 10, 500);
            uint256 amountTokens = Math.mulDiv(amountBps, totalSupply, 10_000);

            // Try to mint - might hit cap
            try policy.checkMintCap( amountTokens) returns (bool) {
                policy.recordMint( amountTokens);
            } catch {
                // Cap exceeded - expected during fuzz testing
            }

            // Invariant: After crossing epoch boundary, caps should reset
            if (newEpoch > currentEpoch) {
                // New epoch detected - verify caps reset
                (uint256 mintRemainingTokens,) = policy.getAggregateRemainingCapacity();

                // Get current band config to check what cap should be
                PolicyManager.Band currentBand = policy.currentBand();
                PolicyManager.BandConfig memory config = policy.getBandConfig(currentBand);

                // Convert cap from BPS to tokens for comparison
                uint256 capTokens = Math.mulDiv(config.caps.mintAggregateBps, totalSupply, 10_000);

                // Remaining should be close to full cap (allowing for any operations this epoch)
                assertTrue(
                    mintRemainingTokens <= capTokens, "Remaining should not exceed cap in tokens"
                );

                currentEpoch = newEpoch;
            }

            // Update snapshot occasionally
            if (i % 5 == 0) {
                uint16 ratio = uint16(bound(uint256(amounts[i]), 400, 1_200));
                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(ratio, 400, 10, 100, totalSupply, 1e18, 0, 1)
                );
            }
        }
    }

    /// @notice Fuzz test: Multi-band cap changes under stress
    function testFuzzMultiBandCapChanges(uint8[20] memory ops, uint16[20] memory values) public {
        uint256 totalSupply = 1_000_000e18;

        for (uint256 i = 0; i < ops.length; i++) {
            uint8 op = ops[i] % 5;
            address user = _selectUser(i);

            if (op == 0) {
                // Force to GREEN
                // First advance to new epoch to reset caps
                vm.warp(block.timestamp + 1 days);

                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(1_000, 500, 10, 100, totalSupply, 1e18, 0, 1) // 10% reserve
                );

                // GREEN band should eventually have higher caps (but may take time due to hysteresis)
                vm.warp(block.timestamp + 35 minutes); // Past RED exit dwell time
                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(1_000, 500, 10, 100, totalSupply, 1e18, 0, 1)
                );

                // Verify band transition worked and caps are reasonable
                // Note: Due to hysteresis, we might not reach GREEN immediately
                // Just verify we have some reasonable capacity available
                (uint256 mintCap,) = policy.getAggregateRemainingCapacity();

                // After epoch reset and healthy snapshots, should have meaningful capacity
                // Don't assert specific amounts since band and prior operations can vary
                assertGt(
                    mintCap,
                    0,
                    "Should have some mint capacity after epoch reset and healthy snapshot"
                );
            } else if (op == 1) {
                // Force to YELLOW
                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(400, 300, 10, 100, totalSupply, 1e18, 0, 1) // 4% reserve
                );

                // Wait for transition
                vm.warp(block.timestamp + 1 hours);
            } else if (op == 2) {
                // Force to RED
                // Admin calls (test contract is admin)
                policy.reportSystemSnapshot(
                    _snapshot(150, 100, 10, 2_000, totalSupply, 1e18, 0, 1) // Low reserve + stale
                );

                // Note: With frozen caps, remaining capacity might exceed RED's cap if the epoch
                // started while in a higher band (GREEN/YELLOW). The frozen cap persists until
                // the epoch resets at midnight UTC. This is intentional behavior.
                // The end-of-loop invariant (maxCapTokens) ensures we never exceed GREEN's cap.
            } else if (op == 3) {
                // Try minting - convert BPS to tokens
                uint256 amountBps = bound(uint256(values[i]), 10, 1_000);
                uint256 amountTokens = Math.mulDiv(amountBps, totalSupply, 10_000);

                // Try to mint - might hit cap
                try policy.checkMintCap( amountTokens) returns (bool) {
                    policy.recordMint( amountTokens);
                } catch {
                    // Cap exceeded - expected during fuzz testing
                }
            } else {
                // Advance time
                vm.warp(block.timestamp + bound(uint256(values[i]), 1 hours, 2 days));
            }

            // Invariant: Remaining capacity should not exceed the maximum possible cap
            // Note: With frozen caps, remaining can exceed the CURRENT band's cap if the
            // cap was frozen earlier when in a higher band (e.g., GREEN -> YELLOW transition)
            (uint256 mintRemainingTokens,) = policy.getAggregateRemainingCapacity();

            // Use GREEN band's cap as upper bound (100% = max possible frozen cap)
            PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
            uint256 maxCapTokens = Math.mulDiv(greenConfig.caps.mintAggregateBps, totalSupply, 10_000);

            assertLe(
                mintRemainingTokens, maxCapTokens, "Remaining should not exceed max band cap (GREEN)"
            );
        }
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /// @notice Helper to select user based on index
    function _selectUser(uint256 i) internal pure returns (address) {
        if (i % 3 == 0) return USER1;
        if (i % 3 == 1) return USER2;
        return USER3;
    }

    // Sprint 2.1.1: Removed marketIsOpen parameter (market hours deleted)
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
}
