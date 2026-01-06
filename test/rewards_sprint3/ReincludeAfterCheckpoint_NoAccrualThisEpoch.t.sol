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

contract ReincludeAfterCheckpoint_NoAccrualThisEpoch is Test, BaseTest {
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

    function _configureEpoch(uint64 id, uint64 startTs, uint64 endTs) internal {
        vm.prank(ADMIN);
        rewards.configureEpoch(id, startTs, endTs, startTs + 12 days, startTs + 16 days);
    }

    function test_ReincludeAfterCheckpoint_NoAccrualThisEpoch() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // ALICE eligible at start
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Exclude ALICE before checkpoint
        vm.warp(t0 + 10 days);
        vm.prank(ADMIN);
        rewards.setAccountExcluded(ALICE, true);

        // Re-include AFTER checkpointStart → must remain ineligible for the rest of this epoch
        vm.warp(t0 + 13 days); // after checkpointStart (t0 + 12 days)
        vm.prank(ADMIN);
        rewards.setAccountExcluded(ALICE, false);

        // Verify eligible supply remains zero after re-inclusion this epoch
        (
            , uint256 eligibleSupply,, , , 
        ) = rewards.getGlobalState();
        assertEq(eligibleSupply, 0, "Re-inclusion after checkpoint should not add to eligible supply");

        // Distribute
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(100_000e6);

        // ALICE was excluded at distribution time → no rewards for this epoch
        uint256 pending1 = rewards.pendingRewards(ALICE);
        assertEq(pending1, 0, "Excluded at distribution -> 0 for this epoch");

        // Next epoch: ALICE should start earning again
        _configureEpoch(2, t0 + 30 days, t0 + 60 days);
        vm.warp(t0 + 60 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(50_000e6);

        uint256 pending2 = rewards.pendingRewards(ALICE);
        assertGt(pending2, 0, "Should accrue again next epoch after rollover");
    }
}
