// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";

/// @title CapBypassFixTest
/// @notice Tests for Cyfrin Issue #57: Mint/Refund Caps Bypass via Zero-Rounded BPS Accounting
/// @dev Verifies that absolute token tracking prevents cap bypass attacks
contract CapBypassFixTest is BaseTest {
    PolicyManager internal policy;
    address internal timelock;

    // Use 1M tokens with 18 decimals as standard supply
    uint256 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        // Warp to epoch 1+ to avoid collision with uninitialized storage (epoch 0)
        vm.warp(1 days + 1);

        timelock = address(this);
        policy = deployPolicyManager(timelock);

        // Report snapshot with 1M token supply
        policy.reportSystemSnapshot(
            _snapshot(800, 400, 10, 100, TOTAL_SUPPLY, 1e18, 0, 1) // 8% reserve for GREEN
        );

        // Set a limited mint cap for testing (500 bps = 5%)
        // Production uses 0 (unlimited), but we need a cap for testing
        PolicyManager.BandConfig memory config = policy.getBandConfig(PolicyManager.Band.Green);
        config.caps.mintAggregateBps = 500; // 5% of supply = 50,000 tokens
        config.caps.refundAggregateBps = 500; // 5% of supply = 50,000 tokens
        policy.setBandConfig(PolicyManager.Band.Green, config);

        // Re-report snapshot to apply new config
        policy.reportSystemSnapshot(
            _snapshot(800, 400, 10, 100, TOTAL_SUPPLY, 1e18, 0, 1)
        );

        // Allow 100% transactions for clearer testing
        policy.setMaxSingleTransactionPct(100);
    }

    // ========= Core Fix Verification: Small Amounts Are Now Tracked =========

    /// @notice Test that very small refunds correctly consume proportional cap (no rounding to 0)
    /// @dev This is the core fix for Cyfrin Issue #57
    function test_SmallRefund_CorrectlyConsumesCapacity() public {
        address user = address(0x1234);

        // With 1M supply and 500 bps cap: capTokens = 1M * 500 / 10000 = 50,000 tokens
        uint256 expectedCapTokens = (TOTAL_SUPPLY * 500) / BPS_DENOMINATOR;
        assertEq(expectedCapTokens, 50_000e18, "Cap should be 50,000 tokens");

        // Get initial capacity
        (, uint256 initialRemaining) = policy.getAggregateRemainingCapacity();
        assertEq(initialRemaining, expectedCapTokens, "Initial capacity should equal cap");

        // Refund a small amount: 1 token (1e18 wei)
        // OLD BUG: 1e18 / 1_000_000e18 * 10000 = 0 BPS (rounded to 0, cap bypass!)
        // NEW FIX: Records 1e18 tokens directly (no rounding)
        uint256 smallAmount = 1e18; // 1 token

        policy.checkRefundCap( smallAmount);
        policy.recordRefund( smallAmount);

        // Verify capacity decreased by EXACTLY the amount used
        (, uint256 afterSmallRefund) = policy.getAggregateRemainingCapacity();
        assertEq(afterSmallRefund, initialRemaining - smallAmount, "Capacity should decrease by exact token amount");
        assertEq(afterSmallRefund, 50_000e18 - 1e18, "Remaining should be 49,999 tokens");
    }

    /// @notice Test that tiny amounts (sub-token) are tracked correctly
    /// @dev Even fractional token amounts must be tracked precisely
    function test_SubTokenAmount_CorrectlyTracked() public {
        address user = address(0x2345);

        // Get initial capacity
        (, uint256 initialRemaining) = policy.getAggregateRemainingCapacity();

        // Refund 0.001 tokens (1e15 wei) - would definitely round to 0 in old BPS system
        uint256 tinyAmount = 1e15; // 0.001 tokens

        policy.checkRefundCap( tinyAmount);
        policy.recordRefund( tinyAmount);

        // Verify capacity decreased by exact amount
        (, uint256 afterTinyRefund) = policy.getAggregateRemainingCapacity();
        assertEq(afterTinyRefund, initialRemaining - tinyAmount, "Even sub-token amounts must be tracked");
    }

    /// @notice Test multiple small refunds accumulate correctly
    function test_MultipleSmallRefunds_AccumulateCorrectly() public {
        address user = address(0x3456);

        uint256 smallAmount = 1e18; // 1 token each
        uint256 iterations = 100;

        // Get initial capacity
        (, uint256 initialRemaining) = policy.getAggregateRemainingCapacity();

        // Make 100 small refunds
        for (uint256 i = 0; i < iterations; i++) {
            policy.checkRefundCap( smallAmount);
            policy.recordRefund( smallAmount);
        }

        // Verify total consumed equals sum of all refunds
        (, uint256 afterRefunds) = policy.getAggregateRemainingCapacity();
        uint256 totalConsumed = initialRemaining - afterRefunds;

        assertEq(totalConsumed, smallAmount * iterations, "Total consumed should equal sum of all refunds");
        assertEq(totalConsumed, 100e18, "Should have consumed exactly 100 tokens");
    }

    // ========= Cap Bypass Attack Prevention =========

    /// @notice Test that cap bypass via splitting is no longer possible
    /// @dev OLD ATTACK: Many small tx each rounding to 0 BPS, allowing unlimited refunds
    /// @dev NEW BEHAVIOR: Each small tx tracked precisely, eventually hitting cap
    function test_CapBypass_ViaSplitting_NowBlocked() public {
        address attacker = address(0x4567);

        // Cap is 50,000 tokens (5% of 1M supply)
        uint256 capTokens = (TOTAL_SUPPLY * 500) / BPS_DENOMINATOR;

        // Use larger chunks (100 tokens) to reduce iterations while still proving the point
        // The fix works the same whether we use 1-token or 100-token chunks
        uint256 chunkAmount = 100e18; // 100 tokens per refund
        uint256 successfulRefunds = 0;
        uint256 totalRefunded = 0;

        // Keep refunding until cap is hit (should take 500 iterations, not 50k)
        for (uint256 i = 0; i < 1_000; i++) {
            (, uint256 remaining) = policy.getAggregateRemainingCapacity();

            if (remaining < chunkAmount) {
                // Cap reached - attack blocked!
                break;
            }

            policy.checkRefundCap(chunkAmount);
            policy.recordRefund(chunkAmount);
            successfulRefunds++;
            totalRefunded += chunkAmount;
        }

        // Verify we hit the cap at exactly the right number of refunds
        assertEq(successfulRefunds, capTokens / chunkAmount, "Should hit cap after exactly capTokens/chunkAmount refunds");
        assertEq(successfulRefunds, 500, "Should hit cap after 500 100-token refunds");
        assertEq(totalRefunded, capTokens, "Total refunded should equal cap");

        // Verify cap is now exhausted
        (, uint256 finalRemaining) = policy.getAggregateRemainingCapacity();
        assertEq(finalRemaining, 0, "Cap should be fully exhausted");

        // Verify next refund fails
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.RefundAggregate,
                chunkAmount,
                0
            )
        );
        policy.checkRefundCap(chunkAmount);
    }

    /// @notice Test that very small amounts cannot bypass cap via extreme splitting
    /// @dev Tests with dust amounts that would have been 0 BPS
    function test_DustAttack_NowBlocked() public {
        address attacker = address(0x5678);

        // Attacker uses tiny amounts (0.001 tokens) that would DEFINITELY round to 0 in BPS
        uint256 dustAmount = 1e15; // 0.001 tokens

        // Cap is 50,000 tokens = 50,000e18 wei
        uint256 capWei = 50_000e18;

        // Attacker would need 50,000,000 tx to bypass cap with dust amounts
        // This is impractical, but the math must still work correctly

        // Do 1000 dust refunds
        for (uint256 i = 0; i < 1000; i++) {
            policy.checkRefundCap( dustAmount);
            policy.recordRefund( dustAmount);
        }

        // Verify capacity decreased by exactly 1000 * 0.001 = 1 token
        (, uint256 remaining) = policy.getAggregateRemainingCapacity();
        uint256 consumed = capWei - remaining;
        assertEq(consumed, 1000 * dustAmount, "Consumed should be exactly sum of dust amounts");
        assertEq(consumed, 1e18, "1000 * 0.001 tokens = 1 token consumed");
    }

    // ========= Mint Cap Tests (Same Fix Applied) =========

    /// @notice Test that small mints are also tracked correctly
    function test_SmallMint_CorrectlyConsumesCapacity() public {
        address user = address(0x6789);

        // Get initial capacity
        (uint256 initialRemaining,) = policy.getAggregateRemainingCapacity();

        // Mint a small amount: 1 token
        uint256 smallAmount = 1e18;

        policy.checkMintCap( smallAmount);
        policy.recordMint( smallAmount);

        // Verify capacity decreased by exact amount
        (uint256 afterSmallMint,) = policy.getAggregateRemainingCapacity();
        assertEq(afterSmallMint, initialRemaining - smallAmount, "Mint capacity should decrease by exact token amount");
    }

    // ========= Epoch Reset Tests =========

    /// @notice Test that cap resets at midnight UTC
    function test_CapReset_AtMidnight_WithTokenAmounts() public {
        address user = address(0x789A);

        // Use some capacity
        uint256 amount = 10_000e18; // 10,000 tokens
        policy.checkRefundCap( amount);
        policy.recordRefund( amount);

        // Verify capacity consumed
        (, uint256 afterRefund) = policy.getAggregateRemainingCapacity();
        assertEq(afterRefund, 50_000e18 - amount, "Should have consumed 10,000 tokens");

        // Advance to next day
        vm.warp(block.timestamp + 1 days);

        // Verify cap reset
        (, uint256 afterReset) = policy.getAggregateRemainingCapacity();
        assertEq(afterReset, 50_000e18, "Cap should reset to full at midnight");
    }

    // ========= Frozen Cap Behavior =========

    /// @notice Frozen mint cap should not grow within the same epoch as supply increases
    function test_FrozenMintCap_DoesNotGrowWithinEpoch() public {
        address user = address(0xBEEF);

        // Configure a 10% mint cap and snapshot 10,000 tokens
        PolicyManager.BandConfig memory cfg = policy.getBandConfig(PolicyManager.Band.Green);
        cfg.caps.mintAggregateBps = 1000; // 10%
        policy.setBandConfig(PolicyManager.Band.Green, cfg);
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 10_000e18, 1e18, 0, 1));

        // Freeze cap by recording a mint (simulate 1000 token mint) and consume entire cap
        // Freeze happens on first record in epoch using the snapshot's totalSupply (10k)
        uint256 capTokens = Math.mulDiv(10_000e18, 1000, BPS_DENOMINATOR); // 1,000e18
        policy.checkMintCap( capTokens);
        policy.recordMint( capTokens);

        // Now increase totalSupply in the snapshot to 11,000 (would raise dynamic cap to 1,100 tokens)
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 11_000e18, 1e18, 0, 1));

        // Remaining should still be zero (frozen cap honored)
        (uint256 remainingMint,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingMint, 0, "Frozen mint cap should be exhausted");

        // Any positive amount should fail the check (reverts with CapExceeded)
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.MintAggregate,
                1e18,
                0
            )
        );
        policy.checkMintCap( 1e18);
    }

    /// @notice Zero mint cap should be enforced strictly when frozen (no capacity)
    function test_ZeroMintCap_Enforced() public {
        address user = address(0xC0FFEE);

        // Set mint cap to smallest non-zero bps
        PolicyManager.BandConfig memory cfg = policy.getBandConfig(PolicyManager.Band.Green);
        cfg.caps.mintAggregateBps = 1; // 0.01%
        policy.setBandConfig(PolicyManager.Band.Green, cfg);

        // Use a tiny supply so capTokens floors to zero: supply * 1 / 10000 = 0
        // For floor to 0, supply must be < 10000 wei
        policy.reportSystemSnapshot(_snapshot(800, 400, 10, 100, 9999, 1e18, 0, 1)); // 9999 wei

        // Freeze the cap by recording a zero-sized mint (freezing logic runs on epoch change)
        policy.recordMint( 0);

        // Remaining capacity should be zero (9999 * 1 / 10000 = 0 due to integer division)
        (uint256 remainingMint,) = policy.getAggregateRemainingCapacity();
        assertEq(remainingMint, 0, "Zero frozen cap should leave no remaining capacity");

        // Any positive amount should fail check (reverts with CapExceeded)
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.MintAggregate,
                1,
                0
            )
        );
        policy.checkMintCap( 1);
    }
    // ========= Edge Cases =========

    /// @notice Test exact cap exhaustion works correctly with token amounts
    function test_ExactCapExhaustion_WithTokens() public {
        address user = address(0x89AB);

        // Get cap in tokens
        (, uint256 capTokens) = policy.getAggregateRemainingCapacity();

        // Exhaust exactly to 0
        policy.checkRefundCap( capTokens);
        policy.recordRefund( capTokens);

        // Verify exactly 0 remaining
        (, uint256 remaining) = policy.getAggregateRemainingCapacity();
        assertEq(remaining, 0, "Should be exactly 0 remaining");

        // Verify 1 wei fails
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.RefundAggregate,
                1,
                0
            )
        );
        policy.checkRefundCap( 1);
    }

    /// @notice Test that 1 wei over cap fails
    function test_OneWeiOverCap_Fails() public {
        address user = address(0x9ABC);

        // Get cap in tokens
        (, uint256 capTokens) = policy.getAggregateRemainingCapacity();

        // Try to refund 1 wei more than cap
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.CapExceeded.selector,
                PolicyManager.CapType.RefundAggregate,
                capTokens + 1,
                capTokens
            )
        );
        policy.checkRefundCap( capTokens + 1);
    }

    // ========= Helper Functions =========

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
