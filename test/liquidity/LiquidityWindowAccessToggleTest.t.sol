// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {Buck} from "src/token/Buck.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {AccessRegistry} from "src/access/AccessRegistry.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";

/**
 * @title LiquidityWindowAccessToggleTest
 * @notice Tests for toggling KYC enforcement on/off via address(0)
 * @dev Verifies owner can disable/re-enable KYC for entire protocol
 */
contract LiquidityWindowAccessToggleTest is BaseTest {
    LiquidityWindow internal window;
    Buck internal token;
    MockUSDC internal usdc;
    AccessRegistry internal accessRegistry;
    PolicyManager internal policy;
    LiquidityReserve internal reserve;
    OracleAdapter internal oracle;

    address internal constant TIMELOCK = address(0x1000);
    address internal constant TREASURY = address(0x2000);
    address internal constant ATTESTOR = address(0x3000);
    address internal constant ALICE = address(0x4000);
    address internal constant BOB = address(0x5000);

    uint256 internal constant INITIAL_PRICE = 1e18; // $1 per STRC

    function setUp() public {
        vm.startPrank(TIMELOCK);

        // Deploy contracts
        usdc = new MockUSDC();
        token = deployBUCK(TIMELOCK);
        policy = deployPolicyManager(TIMELOCK);
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);
        oracle = new OracleAdapter(TIMELOCK);
        accessRegistry = new AccessRegistry(TIMELOCK, ATTESTOR);

        // Deploy LiquidityWindow
        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));

        // Configure token with KYC
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(accessRegistry), // KYC enabled
            address(0) // rewards
        );

        // Configure oracle
        oracle.setInternalPrice(INITIAL_PRICE);

        // Configure window
        window.setUSDC(address(usdc));
        window.configureFeeSplit(0, TREASURY);
        window.setAccessRegistry(address(accessRegistry));
        // Note: Leave testnetMode enabled by default - individual tests will disable/enable as needed

        // Grant operator role to window
        bytes32 operatorRole = policy.OPERATOR_ROLE();
        policy.grantRole(operatorRole, address(window));

        // Configure reserve
        reserve.setLiquidityWindow(address(window));

        // Move past block-fresh window
        vm.roll(block.number + 2);

        // Configure band caps
        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        // Unlimited mints in these toggle tests to avoid cap interactions
        greenConfig.caps.mintAggregateBps = 0;
        greenConfig.caps.refundAggregateBps = 10_000;
        greenConfig.alphaBps = 2_000;
        policy.setBandConfig(PolicyManager.Band.Green, greenConfig);

        // Report system snapshot for GREEN band
        // Note: reserveBalance must be in 18 decimals (USDC balance * 1e12)
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

        // Allow 100% transactions for tests (bypass 50% security limit)
        policy.setMaxSingleTransactionPct(100);

        vm.stopPrank();

        // Fund Alice and Bob with USDC
        usdc.mint(ALICE, 100_000e6);
        usdc.mint(BOB, 100_000e6);

        // Fund reserve for refunds
        usdc.mint(address(reserve), 100_000e6);
    }

    // ============================================================================
    // TEST 1: Disable KYC on LiquidityWindow
    // ============================================================================

    function test_CanSetAccessRegistryToAddressZero() public {
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));

        assertEq(window.accessRegistry(), address(0), "KYC registry should be zero");
    }

    function test_MintWorksWithoutKYC_WhenDisabled() public {
        // Disable KYC on both LiquidityWindow and STRX
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(0));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // Disable KYC on STRX
            address(0)
        );
        vm.stopPrank();

        // Alice (not KYC'd) can mint
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        assertGt(token.balanceOf(ALICE), 0, "Alice should have minted tokens");
    }

    function test_RedeemWorksWithoutKYC_WhenDisabled() public {
        // Setup: Give Alice tokens first (with KYC disabled)
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(0));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // Disable KYC on STRX
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        uint256 tokenBalance = token.balanceOf(ALICE);

        // Redeem without KYC
        token.approve(address(window), tokenBalance);
        window.requestRefund(ALICE, tokenBalance, 0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(ALICE), 0, "Alice should have redeemed all tokens");
    }

    // ============================================================================
    // TEST 2: Re-enable KYC after disabling
    // ============================================================================

    function test_CanReEnableKYCAfterDisabling() public {
        // Disable
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));
        assertEq(window.accessRegistry(), address(0));

        // Re-enable
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(accessRegistry));
        assertEq(window.accessRegistry(), address(accessRegistry), "KYC should be re-enabled");
    }

    function test_MintRequiresKYC_AfterReEnabling() public {
        // Disable KYC
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));

        // Re-enable KYC
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(accessRegistry));

        // Alice (not KYC'd) cannot mint now
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.expectRevert(); // KYC check should fail
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();
    }

    // ============================================================================
    // TEST 3: Multiple toggle cycles
    // ============================================================================

    function test_MultipleToggleCycles() public {
        // Cycle 1: Disable → Mint works
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(0));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // Disable KYC on STRX
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        uint256 balance1 = token.balanceOf(ALICE);
        assertGt(balance1, 0, "First mint should work");

        // Cycle 2: Re-enable → Mint fails
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(accessRegistry));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(accessRegistry), // Re-enable KYC on STRX
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.expectRevert();
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Cycle 3: Disable again → Mint works again
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(0));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // Disable KYC on BUCK again
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        assertGt(token.balanceOf(ALICE), balance1, "Third mint should work");
    }

    // ============================================================================
    // TEST 4: Integration - Disable KYC for entire protocol
    // ============================================================================

    function test_DisableKYCForEntireProtocol() public {
        // Disable on both BUCK and LiquidityWindow
        vm.startPrank(TIMELOCK);

        token.configureModules(
            address(window),
            address(0),
            TREASURY,
            address(0),
            address(0), // Disable KYC on STRX
            address(0)
        );

        window.setAccessRegistry(address(0)); // Disable KYC on LiquidityWindow

        vm.stopPrank();

        // Alice can mint (LiquidityWindow check bypassed)
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);

        // Alice can transfer (STRX check bypassed)
        token.transfer(BOB, 100e18);
        vm.stopPrank();

        assertGt(token.balanceOf(BOB), 0, "Transfer should work without KYC");
    }

    function test_ReEnableKYCForEntireProtocol() public {
        // Start with KYC disabled
        vm.startPrank(TIMELOCK);
        token.configureModules(
            address(window), address(0), TREASURY, address(0), address(0), address(0)
        );
        window.setAccessRegistry(address(0));
        vm.stopPrank();

        // Give Alice tokens while KYC is off
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Re-enable KYC on both
        vm.startPrank(TIMELOCK);
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(accessRegistry), // Re-enable on STRX
            address(0)
        );
        window.setAccessRegistry(address(accessRegistry)); // Re-enable on LiquidityWindow
        vm.stopPrank();

        // Alice cannot mint more (LiquidityWindow enforces KYC)
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.expectRevert(abi.encodeWithSignature("AccessCheckFailed(address)", ALICE));
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Note: BUCK token transfers are permissionless by design - KYC is only enforced at mint/refund
        // So Alice CAN transfer to Bob even without KYC
    }

    // ============================================================================
    // TEST 5: Event emission
    // ============================================================================

    function test_EmitsEventWhenSettingToZero() public {
        vm.expectEmit(true, false, false, false);
        emit LiquidityWindow.AccessRegistrySet(address(0));

        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));
    }

    function test_EmitsEventWhenReEnabling() public {
        // Disable first
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));

        // Re-enable
        vm.expectEmit(true, false, false, false);
        emit LiquidityWindow.AccessRegistrySet(address(accessRegistry));

        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(accessRegistry));
    }

    // ============================================================================
    // TEST 6: Access control
    // ============================================================================

    function test_OnlyOwnerCanDisableKYC() public {
        vm.prank(ALICE);
        vm.expectRevert();
        window.setAccessRegistry(address(0));
    }

    function test_OnlyOwnerCanReEnableKYC() public {
        // Disable as owner
        vm.prank(TIMELOCK);
        window.setAccessRegistry(address(0));

        // Try to re-enable as non-owner
        vm.prank(ALICE);
        vm.expectRevert();
        window.setAccessRegistry(address(accessRegistry));
    }

    // ============================================================================
    // TEST 7: State consistency
    // ============================================================================

    function test_KYCStateConsistentAcrossOperations() public {
        // Initial: KYC enabled
        assertEq(window.accessRegistry(), address(accessRegistry));

        // Disable
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(0));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // Disable KYC on STRX
            address(0)
        );
        vm.stopPrank();
        assertEq(window.accessRegistry(), address(0));

        // Operations work
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        // KYC still disabled
        assertEq(window.accessRegistry(), address(0));

        // Re-enable
        vm.startPrank(TIMELOCK);
        window.setAccessRegistry(address(accessRegistry));
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(accessRegistry), // Re-enable KYC on STRX
            address(0)
        );
        vm.stopPrank();
        assertEq(window.accessRegistry(), address(accessRegistry));

        // Operations now fail
        vm.startPrank(ALICE);
        usdc.approve(address(window), 1000e6);
        vm.expectRevert();
        window.requestMint(ALICE, 1000e6, 0, type(uint256).max);
        vm.stopPrank();

        // KYC still enabled
        assertEq(window.accessRegistry(), address(accessRegistry));
    }
}
