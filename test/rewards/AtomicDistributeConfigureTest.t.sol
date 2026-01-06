// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice Mock PolicyManager for atomic distribution test
contract MockPolicyManager {
    function getCAPPrice() external pure returns (uint256) { return 1e18; }
    function getDistributionSkimBps() external pure returns (uint16) { return 0; }
    function refreshBand() external pure returns (uint8) { return 0; }
}

/**
 * @title AtomicDistributeConfigureTest
 * @notice Verifies that Admin wallet with both ADMIN_ROLE and DISTRIBUTOR_ROLE
 *         can execute atomic multicall: distribute() + configureEpoch()
 *
 * This test validates the mainnet deployment strategy where:
 * - Admin wallet gets DISTRIBUTOR_ROLE (in addition to ADMIN_ROLE)
 * - Both distribute() and configureEpoch() are called atomically via multicall
 * - This prevents race conditions between distribution and epoch configuration
 */
contract AtomicDistributeConfigureTest is Test, BaseTest {
    RewardsEngine internal rewards;
    Buck internal token;
    MockPolicyManager internal mockPolicy;
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;

    // In mainnet: ADMIN and DISTRIBUTOR are the SAME wallet
    address internal constant ADMIN = address(0x1000);
    address internal constant TREASURY = address(0x2000);
    address internal constant LIQUIDITY_WINDOW = address(0x3000);
    address internal constant HOLDER = address(0xA1);

    bytes32 public constant ADMIN_ROLE = 0x00;
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    function setUp() public {
        vm.startPrank(ADMIN);

        // Deploy core contracts
        token = deployBUCK(ADMIN);
        mockPolicy = new MockPolicyManager();
        usdc = new MockUSDC();

        // Deploy LiquidityReserve
        LiquidityReserve reserveImpl = new LiquidityReserve();
        reserve = LiquidityReserve(
            address(new ERC1967Proxy(
                address(reserveImpl),
                abi.encodeCall(LiquidityReserve.initialize, (ADMIN, address(usdc), address(0), TREASURY))
            ))
        );

        // KEY: Deploy RewardsEngine with ADMIN as BOTH admin AND distributor
        // This mimics what 1-3-transfer-permissions.s.sol now does
        rewards = deployRewardsEngine(ADMIN, ADMIN, 0, 0, false);

        // Wire up contracts
        token.configureModules(LIQUIDITY_WINDOW, address(reserve), TREASURY, address(mockPolicy), address(0), address(rewards));
        token.enableProductionMode();

        rewards.setToken(address(token));
        rewards.setPolicyManager(address(mockPolicy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);
        reserve.setRewardsEngine(address(rewards));

        vm.stopPrank();

        // Fund admin with USDC for distribution
        usdc.mint(ADMIN, 1_000_000e6);
        vm.prank(ADMIN);
        usdc.approve(address(rewards), type(uint256).max);

        // Create some eligible supply
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(HOLDER, 100_000e18);
    }

    /// @notice Core test: Admin with both roles can do atomic distribute + configureEpoch
    function test_AtomicMulticall_DistributeAndConfigure() public {
        // Verify admin has BOTH roles (this is the key!)
        assertTrue(rewards.hasRole(ADMIN_ROLE, ADMIN), "Admin should have ADMIN_ROLE");
        assertTrue(rewards.hasRole(DISTRIBUTOR_ROLE, ADMIN), "Admin should have DISTRIBUTOR_ROLE");

        // Configure epoch 1
        uint64 t0 = uint64(block.timestamp);
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 1 days, t0 + 12 hours, t0 + 13 hours);

        // Move past epoch end
        vm.warp(t0 + 1 days + 1);

        // Prepare the atomic multicall
        uint256 couponAmount = 1000e6;
        uint64 nextEpoch = 2;
        uint64 now_ = uint64(block.timestamp);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(RewardsEngine.distribute, (couponAmount));
        calls[1] = abi.encodeCall(RewardsEngine.configureEpoch, (nextEpoch, now_, now_ + 1 days, now_ + 11 hours, now_ + 12 hours));

        // Execute atomic multicall as ADMIN (who has both roles)
        vm.prank(ADMIN);
        rewards.multicall(calls);

        // Verify both operations succeeded
        assertEq(rewards.currentEpochId(), nextEpoch, "Epoch should be configured to next epoch");

        console.log("");
        console.log("=======================================================================");
        console.log("  SUCCESS: Atomic multicall distribute() + configureEpoch() works!");
        console.log("=======================================================================");
        console.log("");
        console.log("  Admin has both ADMIN_ROLE and DISTRIBUTOR_ROLE");
        console.log("  distribute() succeeded (requires DISTRIBUTOR_ROLE)");
        console.log("  configureEpoch() succeeded (requires ADMIN_ROLE)");
        console.log("  Both executed atomically in single transaction");
        console.log("");
    }

    /// @notice Negative test: multicall fails if caller lacks DISTRIBUTOR_ROLE
    function test_Multicall_FailsWithoutDistributorRole() public {
        address onlyAdmin = makeAddr("onlyAdmin");

        // Grant only ADMIN_ROLE
        vm.prank(ADMIN);
        rewards.grantRole(ADMIN_ROLE, onlyAdmin);

        assertTrue(rewards.hasRole(ADMIN_ROLE, onlyAdmin), "Should have ADMIN_ROLE");
        assertFalse(rewards.hasRole(DISTRIBUTOR_ROLE, onlyAdmin), "Should NOT have DISTRIBUTOR_ROLE");

        // Configure epoch
        uint64 t0 = uint64(block.timestamp);
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 1 days, t0 + 12 hours, t0 + 13 hours);
        vm.warp(t0 + 1 days + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(RewardsEngine.distribute, (1000e6));
        calls[1] = abi.encodeCall(RewardsEngine.configureEpoch, (2, uint64(block.timestamp), uint64(block.timestamp + 1 days), uint64(block.timestamp + 11 hours), uint64(block.timestamp + 12 hours)));

        // Should fail - no DISTRIBUTOR_ROLE
        vm.prank(onlyAdmin);
        vm.expectRevert();
        rewards.multicall(calls);
    }

    /// @notice Negative test: multicall fails if caller lacks ADMIN_ROLE
    function test_Multicall_FailsWithoutAdminRole() public {
        address onlyDistributor = makeAddr("onlyDistributor");

        // Grant only DISTRIBUTOR_ROLE
        vm.prank(ADMIN);
        rewards.grantRole(DISTRIBUTOR_ROLE, onlyDistributor);

        assertFalse(rewards.hasRole(ADMIN_ROLE, onlyDistributor), "Should NOT have ADMIN_ROLE");
        assertTrue(rewards.hasRole(DISTRIBUTOR_ROLE, onlyDistributor), "Should have DISTRIBUTOR_ROLE");

        // Configure epoch and move past end
        uint64 t0 = uint64(block.timestamp);
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 1 days, t0 + 12 hours, t0 + 13 hours);
        vm.warp(t0 + 1 days + 1);

        // Fund the distributor
        usdc.mint(onlyDistributor, 10_000e6);
        vm.prank(onlyDistributor);
        usdc.approve(address(rewards), type(uint256).max);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(RewardsEngine.distribute, (1000e6));
        calls[1] = abi.encodeCall(RewardsEngine.configureEpoch, (2, uint64(block.timestamp), uint64(block.timestamp + 1 days), uint64(block.timestamp + 11 hours), uint64(block.timestamp + 12 hours)));

        // Should fail - no ADMIN_ROLE for configureEpoch
        vm.prank(onlyDistributor);
        vm.expectRevert();
        rewards.multicall(calls);
    }
}
