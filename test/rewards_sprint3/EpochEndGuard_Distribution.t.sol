// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice Mock PolicyManager for testing
contract MockPolicyManagerForEpochGuard {
    uint256 public mockCAPPrice = 1e18;
    uint16 public mockSkimBps = 0;

    function getCAPPrice() external view returns (uint256) {
        return mockCAPPrice;
    }

    function getDistributionSkimBps() external view returns (uint16) {
        return mockSkimBps;
    }

    function refreshBand() external returns (uint8) {
        return 0; // GREEN
    }
}

/// @title EpochEndGuard_Distribution
/// @notice Regression test for SpearBit Finding #2 mitigation
/// @dev Tests that distribution is blocked before epoch end to prevent mid-epoch overpays
contract EpochEndGuard_Distribution is Test, BaseTest {
    RewardsEngine internal rewards;
    Buck internal token;
    MockPolicyManagerForEpochGuard internal mockPolicy;
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;

    address internal constant ADMIN = address(0x1000);
    address internal constant TREASURY = address(0x2000);
    address internal constant LIQUIDITY_WINDOW = address(0x3000);
    address internal constant DISTRIBUTOR = address(0x4000);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        vm.startPrank(ADMIN);
        token = deployBUCK(ADMIN);
        mockPolicy = new MockPolicyManagerForEpochGuard();
        usdc = new MockUSDC();

        LiquidityReserve reserveImpl = new LiquidityReserve();
        reserve = LiquidityReserve(
            address(new ERC1967Proxy(address(reserveImpl), abi.encodeCall(LiquidityReserve.initialize, (ADMIN, address(usdc), address(0), TREASURY))))
        );

        rewards = deployRewardsEngine(ADMIN, DISTRIBUTOR, 0, 0, false);

        token.configureModules(LIQUIDITY_WINDOW, address(reserve), TREASURY, address(mockPolicy), address(0), address(rewards));
        token.enableProductionMode();

        rewards.setToken(address(token));
        rewards.setPolicyManager(address(mockPolicy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);
        reserve.setRewardsEngine(address(rewards));
        vm.stopPrank();

        // Fund distributor
        usdc.mint(DISTRIBUTOR, 1_000_000e6);
        vm.prank(DISTRIBUTOR);
        usdc.approve(address(rewards), type(uint256).max);
    }

    function _configureEpoch(uint64 id, uint64 startTs, uint64 endTs) internal {
        vm.prank(ADMIN);
        rewards.configureEpoch(id, startTs, endTs, startTs + 12 days, startTs + 16 days);
    }

    /// @notice REGRESSION TEST: Distribution before epoch end should revert
    /// @dev This is the core fix for SpearBit Finding #2 - prevents mid-epoch distribution
    function test_Revert_DistributeBeforeEpochEnd() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint tokens to create eligible supply
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Try to distribute at various points BEFORE epoch end
        // All should revert with DistributionTooEarly

        // Day 1 - right at epoch start
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Day 10 - well before checkpoint
        vm.warp(t0 + 10 days);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Day 15 - during checkpoint window
        vm.warp(t0 + 15 days);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Day 29 - one day before epoch end
        vm.warp(t0 + 29 days);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Day 30 - one second before epoch end
        vm.warp(t0 + 30 days - 1);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);
    }

    /// @notice Distribution at exactly epoch end should succeed
    function test_DistributeAtExactEpochEnd_Succeeds() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint tokens
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Warp to exactly epoch end
        vm.warp(t0 + 30 days);

        // Distribution should succeed
        vm.prank(DISTRIBUTOR);
        (uint256 allocated,) = rewards.distribute(10_000e6);

        assertGt(allocated, 0, "Distribution should succeed at epochEnd");
    }

    /// @notice Distribution after epoch end should succeed (late distribution is fine)
    function test_DistributeAfterEpochEnd_Succeeds() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint tokens
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Warp past epoch end
        vm.warp(t0 + 35 days);

        // Distribution should succeed
        vm.prank(DISTRIBUTOR);
        (uint256 allocated,) = rewards.distribute(10_000e6);

        assertGt(allocated, 0, "Distribution should succeed after epochEnd");
    }

    /// @notice Verify that units are capped at epochEnd for late distributions
    /// @dev This ensures _cappedTimestamp() works correctly with the guard
    ///      Uses reward ratio between two users to prove capping:
    ///      - ALICE mints at t0, holds entire epoch (30 days capped)
    ///      - BOB mints at day 5 (before checkpoint), holds until distribution (25 days capped)
    ///      - If capped correctly: ratio = 30:25 = 1.2:1
    ///      - If broken (counted to dist time): ratio = 45:40 = 1.125:1
    function test_LateDistribution_UnitsCappedAtEpochEnd() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // ALICE mints at epoch start
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // BOB mints at day 5 (BEFORE checkpoint window starts at day 12)
        vm.warp(t0 + 5 days);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(BOB, 100_000e18);

        // Warp 15 days past epoch end (day 45) to amplify any capping error
        vm.warp(t0 + 45 days);

        // Distribute
        vm.prank(DISTRIBUTOR);
        rewards.distribute(100_000e6);

        // Get pending rewards for both users
        uint256 alicePending = rewards.pendingRewards(ALICE);
        uint256 bobPending = rewards.pendingRewards(BOB);

        assertGt(alicePending, 0, "ALICE should have rewards");
        assertGt(bobPending, 0, "BOB should have rewards");

        // ALICE held for 30 days (capped at epochEnd), BOB held for 25 days (day 5 to day 30, capped)
        // Expected ratio: 30/25 = 1.2:1 = 120%
        // If capping were broken: 45/40 = 1.125:1 = 112.5%
        uint256 actualRatio = (alicePending * 1000) / bobPending; // Scale by 1000 for precision
        uint256 expectedRatio = 1200; // 1.2:1 = 120% = 1200 in thousandths

        // Allow 1% tolerance for rounding
        assertApproxEqRel(actualRatio, expectedRatio, 0.01e18, "Reward ratio should be 1.2:1 (units capped at epochEnd)");

        // Verify the ratio is NOT ~1.125:1 (which would indicate broken capping)
        // If broken, ratio would be 1125 in thousandths
        assertTrue(actualRatio > 1150, "Ratio proves units are capped at epochEnd, not distribution time");
    }

    /// @notice Guard applies even in multi-epoch scenarios
    function test_MultiEpoch_GuardAppliesEachEpoch() public {
        uint64 t0 = uint64(block.timestamp);

        // Epoch 1
        _configureEpoch(1, t0, t0 + 30 days);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Try mid-epoch distribution - should fail
        vm.warp(t0 + 15 days);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Warp to epoch end and distribute successfully
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Epoch 2
        _configureEpoch(2, t0 + 30 days, t0 + 60 days);

        // Try mid-epoch 2 distribution - should fail
        vm.warp(t0 + 45 days);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Warp to epoch 2 end and distribute successfully
        vm.warp(t0 + 60 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Verify both epochs distributed correctly
        assertTrue(rewards.distributedThisEpoch(), "Epoch 2 should be distributed");
    }

    /// @notice Edge case: epoch with very short duration
    function test_ShortEpoch_GuardStillApplies() public {
        uint64 t0 = uint64(block.timestamp);

        // Configure a 1-hour epoch
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 1 hours, t0 + 20 minutes, t0 + 40 minutes);

        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Try distribution at t0 + 30 minutes (before epoch end)
        vm.warp(t0 + 30 minutes);
        vm.expectRevert(RewardsEngine.DistributionTooEarly.selector);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Warp to epoch end - should succeed
        vm.warp(t0 + 1 hours);
        vm.prank(DISTRIBUTOR);
        (uint256 allocated,) = rewards.distribute(10_000e6);

        assertGt(allocated, 0, "Short epoch distribution should succeed at epochEnd");
    }

    // =========================================================================
    // CONFIGURE EPOCH GUARD TESTS (MustDistributeBeforeNewEpoch)
    // =========================================================================

    /// @notice Cannot configure epoch 2 before distributing epoch 1
    function test_Revert_ConfigureBeforeDistribute() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Warp to epoch end
        vm.warp(t0 + 30 days);

        // Try to configure epoch 2 WITHOUT distributing first - should fail
        vm.expectRevert(RewardsEngine.MustDistributeBeforeNewEpoch.selector);
        vm.prank(ADMIN);
        rewards.configureEpoch(2, t0 + 30 days, t0 + 60 days, t0 + 42 days, t0 + 46 days);
    }

    /// @notice Can configure epoch 2 after distributing epoch 1
    function test_ConfigureAfterDistribute_Succeeds() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Warp to epoch end and distribute
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Now configure epoch 2 - should succeed
        vm.prank(ADMIN);
        rewards.configureEpoch(2, t0 + 30 days, t0 + 60 days, t0 + 42 days, t0 + 46 days);

        assertEq(rewards.currentEpochId(), 2, "Should be on epoch 2");
    }

    /// @notice First epoch can be configured without prior distribution
    function test_FirstEpoch_NoPriorDistributionNeeded() public {
        // This is tested implicitly by setUp, but let's be explicit
        uint64 t0 = uint64(block.timestamp);

        // Should succeed - currentEpochId == 0, no prior epoch to distribute
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 30 days, t0 + 12 days, t0 + 16 days);

        assertEq(rewards.currentEpochId(), 1, "Should be on epoch 1");
    }

    /// @notice Epoch gaps work: config(1) -> dist -> config(3)
    function test_EpochGap_WorksWithGuard() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Distribute epoch 1
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Skip epoch 2, configure epoch 3 directly - should succeed
        vm.prank(ADMIN);
        rewards.configureEpoch(3, t0 + 60 days, t0 + 90 days, t0 + 72 days, t0 + 76 days);

        assertEq(rewards.currentEpochId(), 3, "Should be on epoch 3");
    }
}
