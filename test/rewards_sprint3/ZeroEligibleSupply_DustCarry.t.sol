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

contract ZeroEligibleSupply_DustCarry is Test, BaseTest {
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

    function test_DustCarry_WhenNoEligibleSupply() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Warp to epoch end
        vm.warp(t0 + 30 days);

        // No token holders: denominator == 0
        vm.prank(DISTRIBUTOR);
        (uint256 allocated1, uint256 dust1) = rewards.distribute(100_000e6);
        assertEq(allocated1, 0, "No eligible supply => no allocation");
        assertGt(dust1, 0, "All tokens carried as dust");

        // Epoch 2: add a holder, dust should be consumed into allocation
        _configureEpoch(2, t0 + 30 days, t0 + 60 days);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        vm.warp(t0 + 60 days);
        vm.prank(DISTRIBUTOR);
        (uint256 allocated2, uint256 dust2) = rewards.distribute(50_000e6);
        assertGt(allocated2, 0, "With supply, allocation should be > 0");
        // Dust should decrease after being partially allocated
        assertLt(dust2, dust1, "Dust should be consumed in next distribution");

        // Sanity: declared == sum of epoch allocations (use epoch reports)
        (uint64 time1, uint256 units1, uint256 idx1, uint256 tok1, uint256 dustCarry1) = rewards
            .getEpochReport(1);
        (uint64 time2, uint256 units2, uint256 idx2, uint256 tok2, uint256 dustCarry2) = rewards
            .getEpochReport(2);
        assertEq(units1, 0, "Epoch 1 denominator should be zero");
        assertEq(idx1, 0, "Epoch 1 deltaIndex should be zero");
        assertEq(tok1, 0, "Epoch 1 tokensAllocated should be zero");
        assertGt(units2, 0, "Epoch 2 denominator should be > 0");
        assertGt(idx2, 0, "Epoch 2 deltaIndex should be > 0");
        assertEq(rewards.totalRewardsDeclared(), tok1 + tok2, "Declared should match sum of allocations");
    }
}
