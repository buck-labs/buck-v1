// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice Mock PolicyManager that returns configurable CAP price
contract MockPolicyManagerForDepeg {
    uint256 public mockCAPPrice = 1e18; // Default: $1.00
    uint16 public mockSkimBps = 1000;   // 10%

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

contract DepegGuard_BlockDistribute is Test, BaseTest {
    RewardsEngine internal rewards;
    Buck internal token;
    MockPolicyManagerForDepeg internal mockPolicy;
    LiquidityReserve internal reserve;
    MockUSDC internal usdc;

    address internal constant ADMIN = address(0x1000);
    address internal constant TREASURY = address(0x2000);
    address internal constant LIQUIDITY_WINDOW = address(0x3000);
    address internal constant DISTRIBUTOR = address(0x4000);
    address internal constant ALICE = address(0xA1);

    function setUp() public {
        vm.startPrank(ADMIN);
        token = deployBUCK(ADMIN);
        mockPolicy = new MockPolicyManagerForDepeg();
        usdc = new MockUSDC();

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
        usdc.mint(DISTRIBUTOR, 1_000_000e6);
        vm.prank(DISTRIBUTOR);
        usdc.approve(address(rewards), type(uint256).max);
    }

    function _configureEpoch(uint64 id, uint64 startTs, uint64 endTs) internal {
        vm.prank(ADMIN);
        rewards.configureEpoch(id, startTs, endTs, startTs + 12 days, startTs + 16 days);
    }

    /// @notice Test: Distribution blocked when CAP < $1 and guard is ON (default)
    function test_Revert_DistributeBlockedDuringDepeg() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Add one eligible holder
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 1000e18);

        // Set CAP price to $0.50 (depeg scenario)
        mockPolicy.setCAPPrice(0.5e18);

        // Warp to epoch end (distribution requires epochEnd)
        vm.warp(t0 + 30 days);

        // Expect revert with DistributionBlockedDuringDepeg
        vm.expectRevert(abi.encodeWithSelector(RewardsEngine.DistributionBlockedDuringDepeg.selector, 0.5e18));
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);
    }

    /// @notice Test: Distribution succeeds when CAP < $1 but guard is OFF
    function test_Success_DistributeWhenGuardDisabled() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Add one eligible holder
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 1000e18);

        // Set CAP price to $0.50 (depeg scenario)
        mockPolicy.setCAPPrice(0.5e18);

        // Disable the depeg guard
        vm.prank(ADMIN);
        rewards.setBlockDistributeOnDepeg(false);

        // Warp to epoch end (distribution requires epochEnd)
        vm.warp(t0 + 30 days);

        // Distribution should succeed now
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Verify distribution happened
        assertTrue(rewards.distributedThisEpoch(), "Distribution should have succeeded");
    }

    /// @notice Test: Distribution succeeds when CAP >= $1 regardless of guard
    function test_Success_DistributeWhenHealthy() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Add one eligible holder
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 1000e18);

        // CAP price at $1.00 (healthy)
        mockPolicy.setCAPPrice(1e18);

        // Warp to epoch end (distribution requires epochEnd)
        vm.warp(t0 + 30 days);

        // Guard is ON by default, but CAP >= $1 so should succeed
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        assertTrue(rewards.distributedThisEpoch(), "Distribution should have succeeded");
    }

    /// @notice Test: Admin can toggle the depeg guard
    function test_AdminCanToggleDepegGuard() public {
        // Default should be true (guard ON)
        assertTrue(rewards.blockDistributeOnDepeg(), "Guard should be ON by default");

        // Admin turns it off
        vm.prank(ADMIN);
        rewards.setBlockDistributeOnDepeg(false);
        assertFalse(rewards.blockDistributeOnDepeg(), "Guard should be OFF after toggle");

        // Admin turns it back on
        vm.prank(ADMIN);
        rewards.setBlockDistributeOnDepeg(true);
        assertTrue(rewards.blockDistributeOnDepeg(), "Guard should be ON after toggle");
    }

    /// @notice Test: Non-admin cannot toggle the depeg guard
    function test_Revert_NonAdminCannotToggleGuard() public {
        vm.expectRevert();
        vm.prank(ALICE);
        rewards.setBlockDistributeOnDepeg(false);
    }
}
