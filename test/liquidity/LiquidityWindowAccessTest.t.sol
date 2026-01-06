// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {AccessRegistry} from "src/access/AccessRegistry.sol";
import {Buck} from "src/token/Buck.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";

/**
 * @title LiquidityWindowAccessTest
 * @notice Sprint 30: KYC Enforcement & Fee Exemption Tests
 * @dev Tests production KYC path that was previously untested
 *      All existing tests use testnetMode=true which bypasses KYC checks
 */
contract LiquidityWindowAccessTest is BaseTest {
    LiquidityWindow internal window;
    AccessRegistry internal accessRegistry;
    Buck internal token;
    PolicyManager internal policy;
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;
    OracleAdapter internal oracle;

    address internal constant OWNER = address(0x1000);
    address internal constant ATTESTOR = address(0x2000);
    address internal constant TREASURY = address(0x3000);
    address internal constant ALICE = address(0x4000);
    address internal constant BOB = address(0x5000);
    address internal constant CHARLIE = address(0x6000);
    address internal constant STEWARD = address(0x7000);

    uint256 internal constant INITIAL_PRICE = 1e18; // $1 per STRC
    uint16 internal constant MINT_FEE_BPS = 100; // 1%
    uint16 internal constant REFUND_FEE_BPS = 100; // 1%

    function setUp() public {
        vm.startPrank(OWNER);

        // Deploy contracts
        usdc = new MockUSDC();
        token = deployBUCK(OWNER);
        policy = deployPolicyManager(OWNER);
        reserve = deployLiquidityReserve(OWNER, address(usdc), address(0), TREASURY);
        oracle = new OracleAdapter(OWNER);

        // Deploy AccessRegistry
        accessRegistry = new AccessRegistry(OWNER, ATTESTOR);

        // Deploy LiquidityWindow
        window = deployLiquidityWindow(OWNER, address(token), address(reserve), address(policy));

        // Configure token
        token.configureModules(
            address(window), // liquidity window
            address(reserve), // liquidity reserve
            TREASURY, // treasury
            address(policy), // policy manager
            address(accessRegistry), // KYC registry - IMPORTANT: token also uses KYC
            address(0) // no rewards
        );

        // Configure oracle
        oracle.setInternalPrice(INITIAL_PRICE);

        // Configure window
        window.setUSDC(address(usdc));
        window.configureFeeSplit(0, TREASURY); // 0% to reserve = 100% to treasury
        window.setAccessRegistry(address(accessRegistry)); // Set KYC registry

        // Grant operator role to window
        bytes32 operatorRole = policy.OPERATOR_ROLE();
        policy.grantRole(operatorRole, address(window));

        // Configure reserve to allow window
        reserve.setLiquidityWindow(address(window));

        // Move past block-fresh window after oracle price update
        vm.roll(block.number + 2);

        // Configure band caps and fees
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        // Unlimited mints for these KYC path tests (avoid cap noise)
        greenConfig.caps.mintAggregateBps = 0; // 0 = unlimited
        greenConfig.caps.refundAggregateBps = 10_000; // 100% daily refund cap for testing
        greenConfig.alphaBps = 2_000; // 20% aggregate headroom
        greenConfig.mintFeeBps = MINT_FEE_BPS; // 1% mint fee
        greenConfig.refundFeeBps = REFUND_FEE_BPS; // 1% refund fee
        policy.setBandConfig(PolicyManager.Band.Green, greenConfig);

        // Allow 100% transactions for tests (bypass 50% security limit)
        policy.setMaxSingleTransactionPct(100);

        // Report system snapshot to set GREEN band
        // Note: reserveBalance must be in 18 decimals (USDC balance * 1e12) to match
        // what _computeCurrentSnapshot() would return
        policy.reportSystemSnapshot(
            PolicyManager.SystemSnapshot({
                reserveRatioBps: 1000, // 10% for GREEN
                equityBufferBps: 500,
                oracleStaleSeconds: 0,
                totalSupply: 100_000e18,
                navPerToken: INITIAL_PRICE,
                reserveBalance: 1_000_000e18, // 1M USDC in 18 decimals
                collateralRatio: 1e18
            })
        );

        vm.stopPrank();

        // Fund users with USDC for minting
        usdc.mint(ALICE, 10_000e6);
        usdc.mint(BOB, 10_000e6);
        usdc.mint(CHARLIE, 10_000e6);
        usdc.mint(STEWARD, 10_000e6);

        // Fund reserve for refunds
        usdc.mint(address(reserve), 100_000e6);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _allowUserInKYC(address user) internal {
        vm.prank(OWNER);
        accessRegistry.forceAllow(user);
    }

    function _revokeUserFromKYC(address user) internal {
        vm.prank(ATTESTOR);
        accessRegistry.revoke(user);
    }

    // =========================================================================
    // KYC Enforcement Tests - Mint
    // =========================================================================

    /// @notice Test: Non-KYC caller cannot mint (msg.sender check)
    function test_NonKYCCaller_MintReverts() public {
        // Alice is NOT in KYC registry
        assertFalse(accessRegistry.isAllowed(ALICE));

        // Approve USDC
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);

        // Try to mint → should revert with AccessCheckFailed
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
    }

    /// @notice Test: Non-KYC recipient cannot receive mint (recipient check)
    function test_NonKYCRecipient_MintReverts() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);

        // BOB is NOT in KYC registry
        assertFalse(accessRegistry.isAllowed(BOB));

        // Approve USDC
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);

        // Try to mint to BOB → should revert with AccessCheckFailed for BOB
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, BOB));
        window.requestMint(BOB, 1000e6, 0, type(uint256).max);
    }

    /// @notice Test: KYC user can mint successfully
    function test_KYCUser_MintSucceeds() public {
        // Allow both ALICE and BOB in KYC
        _allowUserInKYC(ALICE);
        _allowUserInKYC(BOB);

        // Approve USDC
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);

        // Mint should succeed
        vm.prank(ALICE);
        (uint256 strcMinted,) = window.requestMint(BOB, 1000e6, 0, type(uint256).max);

        assertGt(strcMinted, 0, "Should mint STRC");
        assertGt(token.balanceOf(BOB), 0, "BOB should receive STRC");
    }

    /// @notice Test: Revoked user gets blocked from minting
    function test_RevokedUser_MintBlocked() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);
        assertTrue(accessRegistry.isAllowed(ALICE));

        // Verify ALICE can mint initially
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);

        vm.prank(ALICE);
        window.requestMint(ALICE, 500e6, 0, type(uint256).max);

        // Revoke ALICE
        _revokeUserFromKYC(ALICE);
        assertFalse(accessRegistry.isAllowed(ALICE));

        // Try to mint again → should revert
        vm.prank(ALICE);
        usdc.approve(address(window), 500e6);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestMint(ALICE, 500e6, 0, type(uint256).max);
    }

    // =========================================================================
    // KYC Enforcement Tests - Refund
    // =========================================================================

    /// @notice Test: Non-KYC caller cannot refund (msg.sender check)
    function test_NonKYCCaller_RefundReverts() public {
        // First mint some STRC to ALICE (bypass KYC for setup)
        _allowUserInKYC(ALICE);
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Revoke ALICE from KYC
        _revokeUserFromKYC(ALICE);

        // Approve STRC for refund
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);

        // Try to refund → should revert with AccessCheckFailed
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestRefund(ALICE, strcAmount, 0, 0);
    }

    /// @notice Test: Non-KYC recipient cannot receive refund (recipient check)
    function test_NonKYCRecipient_RefundReverts() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);

        // Mint STRC to ALICE
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // BOB is NOT in KYC registry
        assertFalse(accessRegistry.isAllowed(BOB));

        // Approve STRC for refund
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);

        // Try to refund to BOB → should revert with AccessCheckFailed for BOB
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, BOB));
        window.requestRefund(BOB, strcAmount, 0, 0);
    }

    /// @notice Test: KYC user can refund successfully
    function test_KYCUser_RefundSucceeds() public {
        // Allow both ALICE and BOB in KYC
        _allowUserInKYC(ALICE);
        _allowUserInKYC(BOB);

        // Mint STRC to ALICE
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Approve STRC for refund
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);

        uint256 bobUsdcBefore = usdc.balanceOf(BOB);

        // Refund should succeed
        vm.prank(ALICE);
        (uint256 usdcRefunded,) = window.requestRefund(BOB, strcAmount, 0, 0);

        assertGt(usdcRefunded, 0, "Should refund USDC");
        assertGt(usdc.balanceOf(BOB), bobUsdcBefore, "BOB should receive USDC");
    }

    /// @notice Test: Revoked user gets blocked from refunding
    function test_RevokedUser_RefundBlocked() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);

        // Mint STRC to ALICE
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Revoke ALICE
        _revokeUserFromKYC(ALICE);

        // Approve STRC for refund
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);

        // Try to refund → should revert
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestRefund(ALICE, strcAmount, 0, 0);
    }

    // =========================================================================
    // Steward Fee Exemption Tests
    // =========================================================================

    /// @notice Test: Steward mints without fee
    function test_Steward_MintWithoutFee() public {
        // Allow STEWARD in KYC
        _allowUserInKYC(STEWARD);

        // Set STEWARD as liquidity steward
        vm.prank(OWNER);
        window.setLiquiditySteward(STEWARD, true);

        // Mint as steward
        vm.prank(STEWARD);
        usdc.approve(address(window), 1000e6);

        uint256 reserveBefore = usdc.balanceOf(address(reserve));
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(STEWARD);
        (uint256 strcMinted,) = window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        uint256 reserveAfter = usdc.balanceOf(address(reserve));
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // All USDC should go to reserve (no fee to treasury)
        assertEq(reserveAfter - reserveBefore, 1000e6, "All USDC to reserve");
        assertEq(treasuryAfter, treasuryBefore, "No fee to treasury");
        assertGt(strcMinted, 0, "Should mint STRC");
    }

    /// @notice Test: Regular user pays mint fee
    function test_RegularUser_PaysMintFee() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);

        // Mint as regular user
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);

        uint256 reserveBefore = usdc.balanceOf(address(reserve));
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(ALICE);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        uint256 reserveAfter = usdc.balanceOf(address(reserve));
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // Fee should be deducted (1% of 1000 USDC = 10 USDC, 100% to treasury = 10 USDC)
        uint256 actualFee = treasuryAfter - treasuryBefore;

        assertGt(actualFee, 0, "Fee should be charged");
        // With 1% fee and 100% to treasury (feeToReservePct = 10000), expect ~10 USDC fee
        assertApproxEqAbs(actualFee, 10e6, 1e6, "Fee should be ~10 USDC");
    }

    /// @notice Test: Steward refunds without fee
    function test_Steward_RefundWithoutFee() public {
        // Allow STEWARD in KYC
        _allowUserInKYC(STEWARD);

        // Set STEWARD as liquidity steward
        vm.prank(OWNER);
        window.setLiquiditySteward(STEWARD, true);

        // Mint STRC to STEWARD first
        vm.prank(STEWARD);
        usdc.approve(address(window), 1000e6);
        vm.prank(STEWARD);
        (uint256 strcAmount,) = window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        // Refund as steward
        vm.prank(STEWARD);
        token.approve(address(window), strcAmount);

        uint256 reserveBefore = usdc.balanceOf(address(reserve));
        uint256 stewardBefore = usdc.balanceOf(STEWARD);
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(STEWARD);
        (uint256 usdcRefunded,) = window.requestRefund(STEWARD, strcAmount, 0, 0);

        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // No fee should be charged
        assertGt(usdcRefunded, 0, "Should refund USDC");
        assertEq(treasuryAfter, treasuryBefore, "No refund fee to treasury");
    }

    /// @notice Test: Regular user pays refund fee
    function test_RegularUser_PaysRefundFee() public {
        // Allow ALICE in KYC
        _allowUserInKYC(ALICE);

        // Mint STRC to ALICE first
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Refund as regular user
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(ALICE);
        (uint256 usdcRefunded,) = window.requestRefund(ALICE, strcAmount, 0, 0);

        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // Fee should be deducted
        uint256 feeCharged = treasuryAfter - treasuryBefore;
        assertGt(feeCharged, 0, "Refund fee should be charged");
    }

    /// @notice Test: Removed steward pays fees again
    function test_RemovedSteward_PaysFees() public {
        // Allow STEWARD in KYC
        _allowUserInKYC(STEWARD);

        // Set STEWARD as liquidity steward
        vm.prank(OWNER);
        window.setLiquiditySteward(STEWARD, true);

        // Mint STRC to STEWARD (no fee)
        vm.prank(STEWARD);
        usdc.approve(address(window), 1000e6);
        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        // Remove steward status
        vm.prank(OWNER);
        window.setLiquiditySteward(STEWARD, false);

        // Try to mint again - should now pay fee
        vm.prank(STEWARD);
        usdc.approve(address(window), 1000e6);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // Fee should be charged now
        assertGt(treasuryAfter, treasuryBefore, "Should charge fee after steward removed");
    }

    // =========================================================================
    // Integration Tests
    // =========================================================================

    /// @notice Test: End-to-end flow with KYC enforcement
    function test_Integration_KYCEnforcement_EndToEnd() public {
        // 1. Regular user (ALICE) - starts without KYC
        assertFalse(accessRegistry.isAllowed(ALICE));

        // 2. Try to mint → blocked
        vm.prank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // 3. Admin approves ALICE for KYC
        _allowUserInKYC(ALICE);
        assertTrue(accessRegistry.isAllowed(ALICE));

        // 4. Mint succeeds
        vm.prank(ALICE);
        (uint256 strcAmount,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        assertGt(strcAmount, 0);

        // 5. Compliance revokes ALICE
        _revokeUserFromKYC(ALICE);

        // 6. Try to refund → blocked
        vm.prank(ALICE);
        token.approve(address(window), strcAmount);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestRefund(ALICE, strcAmount, 0, 0);

        // 7. Admin reinstates ALICE (must removeDeny + forceAllow)
        vm.prank(OWNER);
        accessRegistry.removeDeny(ALICE);
        _allowUserInKYC(ALICE);

        // 8. Refund succeeds
        vm.prank(ALICE);
        (uint256 usdcRefunded,) = window.requestRefund(ALICE, strcAmount, 0, 0);
        assertGt(usdcRefunded, 0);
    }

    /// @notice Test: FIND-007 - Denylisted user cannot re-register and mint
    /// @dev This verifies the denylist prevents the immediate re-registration attack
    function test_DenylistedUser_CannotReRegisterAndMint() public {
        // Setup: Allow ALICE and let her mint
        _allowUserInKYC(ALICE);
        vm.prank(ALICE);
        usdc.approve(address(window), 2000e6);
        vm.prank(ALICE);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Compliance revokes ALICE - this now also denylists her
        _revokeUserFromKYC(ALICE);
        assertFalse(accessRegistry.isAllowed(ALICE));
        assertTrue(accessRegistry.isDenylisted(ALICE));

        // ALICE tries to mint - should fail because denylisted
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Attestor cannot clear denylist - only owner can via removeDeny()
        // Verify that re-registration via Merkle proof fails for denylisted users:

        // Publish new Merkle root that still includes ALICE
        bytes32 leaf1 = keccak256(abi.encodePacked(ALICE));
        bytes32 leaf2 = keccak256(abi.encodePacked(BOB));
        bytes32 root = leaf1 < leaf2
            ? keccak256(abi.encodePacked(leaf1, leaf2))
            : keccak256(abi.encodePacked(leaf2, leaf1));

        vm.prank(OWNER);
        accessRegistry.setRoot(root, 1);

        // ALICE tries to re-register with valid proof - should FAIL because denylisted
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(ALICE);
        vm.expectRevert(bytes("AccessRegistry: denylisted"));
        accessRegistry.registerWithProof(proof);

        // ALICE still can't mint
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, ALICE));
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Only owner can reinstate ALICE: removeDeny + forceAllow (separate operations)
        vm.prank(OWNER);
        accessRegistry.removeDeny(ALICE);
        vm.prank(OWNER);
        accessRegistry.forceAllow(ALICE);

        assertFalse(accessRegistry.isDenylisted(ALICE));
        assertTrue(accessRegistry.isAllowed(ALICE));

        // Now ALICE can mint again
        vm.prank(ALICE);
        (uint256 strcMinted,) = window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        assertGt(strcMinted, 0, "ALICE should be able to mint after owner reinstates");
    }

    /// @notice Test: Steward + KYC combined enforcement
    function test_Integration_StewardAndKYC() public {
        // Steward without KYC should fail
        vm.prank(OWNER);
        window.setLiquiditySteward(STEWARD, true);

        vm.prank(STEWARD);
        usdc.approve(address(window), 1000e6);

        vm.prank(STEWARD);
        vm.expectRevert(abi.encodeWithSelector(LiquidityWindow.AccessCheckFailed.selector, STEWARD));
        window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        // Add KYC → should succeed with no fee
        _allowUserInKYC(STEWARD);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, type(uint256).max);

        assertEq(usdc.balanceOf(TREASURY), treasuryBefore, "Steward pays no fee");
    }
}
