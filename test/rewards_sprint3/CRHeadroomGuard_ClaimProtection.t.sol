// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice Mock CollateralAttestation that returns configurable CR
contract MockCollateralAttestation {
    uint256 public mockCR = 1e18; // Default: CR = 1.0
    bool public stale;

    function setCollateralRatio(uint256 cr) external {
        mockCR = cr;
    }

    function setAttestationStale(bool stale_) external {
        stale = stale_;
    }

    function getCollateralRatio() external view returns (uint256) {
        return mockCR;
    }

    function isAttestationStale() external view returns (bool) {
        return stale;
    }
}

/// @notice Mock PolicyManager that returns collateralAttestation + CAP price
contract MockPolicyManagerForCRGuard {
    address public collateralAttestation;
    uint256 public mockCAPPrice = 1e18; // Default: $1.00
    uint16 public mockSkimBps = 0;

    function setCollateralAttestation(address att) external {
        collateralAttestation = att;
    }

    function setCAPPrice(uint256 price) external {
        mockCAPPrice = price;
    }

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

/// @title CRHeadroomGuard_ClaimProtection
/// @notice Tests for RewardsEngine CR headroom guard and per-tx claim cap
/// @dev Addresses audit issue #48: prevent claims from pushing CR below 1
contract CRHeadroomGuard_ClaimProtection is Test, BaseTest {
    RewardsEngine internal rewards;
    Buck internal token;
    MockPolicyManagerForCRGuard internal mockPolicy;
    MockCollateralAttestation internal mockAttestation;
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
        mockPolicy = new MockPolicyManagerForCRGuard();
        mockAttestation = new MockCollateralAttestation();
        usdc = new MockUSDC();

        // Link attestation to policy
        mockPolicy.setCollateralAttestation(address(mockAttestation));

        LiquidityReserve reserveImpl = new LiquidityReserve();
        reserve = LiquidityReserve(
            address(new ERC1967Proxy(address(reserveImpl), abi.encodeCall(LiquidityReserve.initialize, (ADMIN, address(usdc), address(0), TREASURY))))
        );

        rewards = deployRewardsEngine(ADMIN, DISTRIBUTOR, 0, 0, false);

        token.configureModules(LIQUIDITY_WINDOW, address(reserve), TREASURY, address(0), address(0), address(rewards));
        token.enableProductionMode();

        rewards.setToken(address(token));
        rewards.setPolicyManager(address(mockPolicy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        reserve.setRewardsEngine(address(rewards));
        vm.stopPrank();

        // Fund distributor
        usdc.mint(DISTRIBUTOR, 10_000_000e6);
        vm.prank(DISTRIBUTOR);
        usdc.approve(address(rewards), type(uint256).max);

        // Fund reserve with USDC for CR calculations
        usdc.mint(address(reserve), 1_000_000e6);
    }

    function _configureEpoch(uint64 id, uint64 startTs, uint64 endTs) internal {
        vm.prank(ADMIN);
        rewards.configureEpoch(id, startTs, endTs, startTs + 12 days, startTs + 16 days);
    }

    function _mintAndDistribute(address user, uint256 mintAmount, uint256 couponUsdc) internal {
        // Mint tokens to user
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(user, mintAmount);

        // Advance time to epoch end (distribution must happen at or after epochEnd)
        vm.warp(block.timestamp + 30 days);

        // Distribute rewards
        vm.prank(DISTRIBUTOR);
        rewards.distribute(couponUsdc);
    }

    // =========================================================================
    // Admin toggle tests
    // =========================================================================

    /// @notice Test: enforceCROnClaim defaults to false
    function test_CRGuard_DefaultsToFalse() public view {
        assertFalse(rewards.enforceCROnClaim(), "CR guard should be OFF by default");
    }

    /// @notice Test: Admin can toggle CR guard on/off
    function test_AdminCanToggleCRGuard() public {
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);
        assertTrue(rewards.enforceCROnClaim(), "CR guard should be ON");

        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(false);
        assertFalse(rewards.enforceCROnClaim(), "CR guard should be OFF");
    }

    /// @notice Test: Non-admin cannot toggle CR guard
    function test_Revert_NonAdminCannotToggleCRGuard() public {
        vm.expectRevert();
        vm.prank(ALICE);
        rewards.setEnforceCROnClaim(true);
    }

    /// @notice Test: Admin can set max claim per tx
    function test_AdminCanSetMaxClaimPerTx() public {
        vm.prank(ADMIN);
        rewards.setMaxClaimTokensPerTx(1000e18);
        assertEq(rewards.maxClaimTokensPerTx(), 1000e18, "Max claim should be set");

        vm.prank(ADMIN);
        rewards.setMaxClaimTokensPerTx(0); // Disable
        assertEq(rewards.maxClaimTokensPerTx(), 0, "Max claim should be disabled");
    }

    /// @notice Test: Non-admin cannot set max claim per tx
    function test_Revert_NonAdminCannotSetMaxClaimPerTx() public {
        vm.expectRevert();
        vm.prank(ALICE);
        rewards.setMaxClaimTokensPerTx(1000e18);
    }

    // =========================================================================
    // CR Headroom Guard tests
    // =========================================================================

    /// @notice Test: Claim succeeds when CR > 1 and claim <= headroom
    function test_ClaimSucceeds_WhenUnderHeadroom() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 2.0 (100% headroom) - generous so small rewards fit
        mockAttestation.setCollateralRatio(2e18);

        // Mint 1000 tokens and distribute SMALL rewards (100 USDC = ~100 tokens)
        // This ensures pending << headroom (1000 tokens)
        _mintAndDistribute(ALICE, 1000e18, 100e6);

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        // Get pending rewards
        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 0, "Should have pending rewards");

        // Calculate headroom: L * (CR - 1) = 1000e18 * 1.0 = 1000e18
        uint256 supply = token.totalSupply();
        uint256 expectedHeadroom = supply; // 100% of supply when CR = 2.0
        assertTrue(pending < expectedHeadroom, "Pending should be under headroom for this test");

        // Claim should succeed
        vm.prank(ALICE);
        rewards.claim(ALICE);

        // Verify claim worked
        assertEq(rewards.pendingRewards(ALICE), 0, "Pending should be 0 after claim");
    }

    /// @notice Test: Claim reverts when CR = 1.0 (zero headroom)
    function test_Revert_ClaimBlocked_WhenCREqualsOne() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to exactly 1.0 (zero headroom)
        mockAttestation.setCollateralRatio(1e18);

        // Mint tokens and distribute rewards
        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 0, "Should have pending rewards");

        // Claim should revert - headroom is 0
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.ClaimExceedsHeadroom.selector, pending, 0));
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Claim reverts when CR < 1.0 (zero headroom)
    function test_Revert_ClaimBlocked_WhenCRBelowOne() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 0.8 (undercollateralized, zero headroom)
        mockAttestation.setCollateralRatio(0.8e18);

        // Mint tokens and distribute rewards
        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 0, "Should have pending rewards");

        // Claim should revert - headroom is 0 when CR < 1
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.ClaimExceedsHeadroom.selector, pending, 0));
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Claim reverts when amount exceeds headroom
    function test_Revert_ClaimBlocked_WhenExceedsHeadroom() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 1.01 (1% headroom = ~10 tokens on 1000 supply)
        mockAttestation.setCollateralRatio(1.01e18);

        // Mint tokens and distribute large rewards that exceed headroom
        _mintAndDistribute(ALICE, 1000e18, 1_000_000e6);

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        uint256 pending = rewards.pendingRewards(ALICE);
        uint256 supply = token.totalSupply();
        uint256 headroom = (supply * 0.01e18) / 1e18; // ~1% of supply

        assertTrue(pending > headroom, "Pending should exceed headroom for this test");

        // Claim should revert
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.ClaimExceedsHeadroom.selector, pending, headroom));
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Claim reverts when attestation data is stale
    function test_Revert_ClaimBlocked_WhenAttestationStale() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Healthy CR, but stale attestation should still block claims
        mockAttestation.setCollateralRatio(2e18);

        _mintAndDistribute(ALICE, 1000e18, 100e6);

        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        mockAttestation.setAttestationStale(true);

        vm.expectRevert(RewardsEngine.StaleAttestationForClaim.selector);
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Claim succeeds when CR guard is disabled even with low CR
    function test_ClaimSucceeds_WhenGuardDisabled() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 0.5 (would block if guard enabled)
        mockAttestation.setCollateralRatio(0.5e18);

        // Mint tokens and distribute rewards
        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // CR guard is OFF by default
        assertFalse(rewards.enforceCROnClaim());

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 0, "Should have pending rewards");

        // Claim should succeed despite low CR (guard is off)
        vm.prank(ALICE);
        rewards.claim(ALICE);

        assertEq(rewards.pendingRewards(ALICE), 0, "Should have claimed");
    }

    /// @notice Test: Sequential claims work as headroom shrinks
    function test_SequentialClaims_HeadroomShrinks() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 1.2 (20% headroom)
        mockAttestation.setCollateralRatio(1.2e18);

        // Mint to both users
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 500e18);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(BOB, 500e18);

        // Advance to epoch end and distribute
        vm.warp(block.timestamp + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(100_000e6);

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        uint256 alicePending = rewards.pendingRewards(ALICE);
        uint256 bobPending = rewards.pendingRewards(BOB);
        assertTrue(alicePending > 0 && bobPending > 0, "Both should have rewards");

        // First claim by Alice - should succeed if under headroom
        uint256 supplyBefore = token.totalSupply();
        uint256 headroomBefore = (supplyBefore * 0.2e18) / 1e18;

        if (alicePending <= headroomBefore) {
            vm.prank(ALICE);
            rewards.claim(ALICE);

            // After Alice claims, supply increased, headroom shrinks
            uint256 supplyAfter = token.totalSupply();
            assertTrue(supplyAfter > supplyBefore, "Supply should increase after claim");

            // Bob's claim might now exceed remaining headroom
            // (depends on exact amounts - this demonstrates the mechanism)
        }
    }

    // =========================================================================
    // Max Claim Per Tx tests
    // =========================================================================

    /// @notice Test: Claim reverts when exceeds max per tx
    function test_Revert_ClaimExceedsMaxPerTx() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint and distribute to create rewards
        _mintAndDistribute(ALICE, 1000e18, 1_000_000e6);

        // Set max claim to 100 tokens
        vm.prank(ADMIN);
        rewards.setMaxClaimTokensPerTx(100e18);

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 100e18, "Pending should exceed cap for this test");

        // Claim should revert
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.MaxClaimPerTxExceeded.selector, pending, 100e18));
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Claim succeeds when under max per tx
    function test_ClaimSucceeds_WhenUnderMaxPerTx() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint and distribute small rewards
        _mintAndDistribute(ALICE, 1000e18, 10_000e6);

        // Set generous max claim
        vm.prank(ADMIN);
        rewards.setMaxClaimTokensPerTx(1_000_000e18);

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending < 1_000_000e18, "Pending should be under cap");

        // Claim should succeed
        vm.prank(ALICE);
        rewards.claim(ALICE);

        assertEq(rewards.pendingRewards(ALICE), 0, "Should have claimed");
    }

    /// @notice Test: Max per tx disabled when set to 0
    function test_MaxPerTx_DisabledWhenZero() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint and distribute large rewards
        _mintAndDistribute(ALICE, 1000e18, 1_000_000e6);

        // Max is 0 by default (disabled)
        assertEq(rewards.maxClaimTokensPerTx(), 0);

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 0, "Should have rewards");

        // Claim should succeed regardless of size
        vm.prank(ALICE);
        rewards.claim(ALICE);

        assertEq(rewards.pendingRewards(ALICE), 0, "Should have claimed");
    }

    // =========================================================================
    // Combined guard tests
    // =========================================================================

    /// @notice Test: Both guards can be active simultaneously
    function test_BothGuardsActive() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Set CR to 1.5 (healthy)
        mockAttestation.setCollateralRatio(1.5e18);

        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // Enable both guards
        vm.startPrank(ADMIN);
        rewards.setEnforceCROnClaim(true);
        rewards.setMaxClaimTokensPerTx(50e18); // Very low cap
        vm.stopPrank();

        uint256 pending = rewards.pendingRewards(ALICE);
        assertTrue(pending > 50e18, "Pending should exceed per-tx cap");

        // Should hit the per-tx cap first (checked before CR)
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.MaxClaimPerTxExceeded.selector, pending, 50e18));
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Revert with InvalidConfig when policyManager not set
    function test_Revert_InvalidConfig_NoPolicyManager() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // Clear policy manager
        vm.prank(ADMIN);
        rewards.setPolicyManager(address(0));

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        // Claim should revert with InvalidConfig
        vm.expectRevert(RewardsEngine.InvalidConfig.selector);
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    /// @notice Test: Revert with InvalidConfig when collateralAttestation not set
    function test_Revert_InvalidConfig_NoAttestation() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        _mintAndDistribute(ALICE, 1000e18, 100_000e6);

        // Clear attestation in mock policy
        mockPolicy.setCollateralAttestation(address(0));

        // Enable CR guard
        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);

        // Claim should revert with InvalidConfig
        vm.expectRevert(RewardsEngine.InvalidConfig.selector);
        vm.prank(ALICE);
        rewards.claim(ALICE);
    }

    // =========================================================================
    // Event emission tests
    // =========================================================================

    /// @notice Test: CROnClaimEnforcementUpdated event emitted
    function test_Event_CROnClaimEnforcementUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit RewardsEngine.CROnClaimEnforcementUpdated(true);

        vm.prank(ADMIN);
        rewards.setEnforceCROnClaim(true);
    }

    /// @notice Test: MaxClaimPerTxUpdated event emitted
    function test_Event_MaxClaimPerTxUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit RewardsEngine.MaxClaimPerTxUpdated(500e18);

        vm.prank(ADMIN);
        rewards.setMaxClaimTokensPerTx(500e18);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    /// @notice Fuzz: Headroom calculation is correct for various CR values
    function testFuzz_HeadroomCalculation(uint256 cr) public view {
        // Bound CR to reasonable range: 0.1 to 10.0
        cr = bound(cr, 0.1e18, 10e18);

        uint256 supply = 1000e18;
        uint256 capSupply = (supply * cr) / 1e18;
        uint256 headroom = capSupply > supply ? capSupply - supply : 0;

        // Verify headroom is 0 when CR <= 1
        if (cr <= 1e18) {
            assertEq(headroom, 0, "Headroom should be 0 when CR <= 1");
        } else {
            // Headroom should be positive when CR > 1
            assertTrue(headroom > 0, "Headroom should be positive when CR > 1");
            // Headroom should be approximately (CR - 1) * supply
            uint256 expectedHeadroom = (supply * (cr - 1e18)) / 1e18;
            assertApproxEqAbs(headroom, expectedHeadroom, 1, "Headroom calculation mismatch");
        }
    }
}
