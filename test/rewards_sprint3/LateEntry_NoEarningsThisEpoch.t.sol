// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract LateEntry_NoEarningsThisEpoch is Test, BaseTest {
    RewardsEngine internal rewards;
    Buck internal token;
    PolicyManager internal policy;
    OracleAdapter internal oracle;
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
        policy = deployPolicyManager(ADMIN);
        usdc = new MockUSDC();
        LiquidityReserve reserveImpl = new LiquidityReserve();
        reserve = LiquidityReserve(
            address(new ERC1967Proxy(address(reserveImpl), abi.encodeCall(LiquidityReserve.initialize, (ADMIN, address(usdc), address(0), TREASURY))))
        );
        rewards = deployRewardsEngine(ADMIN, DISTRIBUTOR, 0, 0, false);

        token.configureModules(LIQUIDITY_WINDOW, address(reserve), TREASURY, address(policy), address(0), address(rewards));
        token.enableProductionMode();

        rewards.setToken(address(token));
        rewards.setPolicyManager(address(policy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);
        reserve.setRewardsEngine(address(rewards));

        oracle = new OracleAdapter(ADMIN);
        oracle.setInternalPrice(1e18);
        vm.stopPrank();

        // Fund distributor
        usdc.mint(DISTRIBUTOR, 1_000_000e6);
        vm.prank(DISTRIBUTOR);
        usdc.approve(address(rewards), type(uint256).max);
    }

    function test_LateEntry_NoEarningsThisEpoch() public {
        uint64 t0 = uint64(block.timestamp);
        uint64 cs = t0 + 12 days;
        uint64 ce = t0 + 16 days;
        vm.prank(ADMIN);
        rewards.configureEpoch(1, t0, t0 + 30 days, cs, ce);

        // Mint AFTER checkpointStart (late entry)
        vm.warp(cs + 1);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Warp to epoch end and distribute
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(50_000e6);

        // Claim for ALICE should be zero for this epoch
        uint256 beforeDeclared = rewards.totalRewardsDeclared();
        vm.prank(ALICE);
        uint256 claimed = rewards.claim(ALICE);
        assertEq(claimed, 0, "Late entry should earn 0 this epoch");
        assertEq(rewards.totalRewardsDeclared(), beforeDeclared, "Declared should not change on claim");

        // Next epoch: ALICE should start earning
        uint64 e2 = t0 + 30 days;
        vm.prank(ADMIN);
        rewards.configureEpoch(2, e2, e2 + 30 days, e2 + 12 days, e2 + 16 days);
        vm.warp(e2 + 30 days); // Warp to epoch 2 end
        vm.prank(DISTRIBUTOR);
        rewards.distribute(10_000e6);

        // Credit epoch 2 rewards on rollover to epoch 3, then claim
        uint64 e3 = e2 + 30 days;
        vm.prank(ADMIN);
        rewards.configureEpoch(3, e3, e3 + 30 days, e3 + 12 days, e3 + 16 days);
        vm.prank(ALICE);
        uint256 claimed2 = rewards.claim(ALICE);
        assertGt(claimed2, 0, "Should earn next epoch after rollover");
    }
}
