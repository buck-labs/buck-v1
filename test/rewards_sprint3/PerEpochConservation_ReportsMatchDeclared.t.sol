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

contract PerEpochConservation_ReportsMatchDeclared is Test, BaseTest {
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
    address internal constant BOB = address(0xB0);

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

    function test_PerEpochConservation_UsingEpochReports() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        vm.startPrank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);
        token.mint(BOB, 100_000e18);
        vm.stopPrank();

        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(100_000e6);

        _configureEpoch(2, t0 + 30 days, t0 + 60 days);
        vm.warp(t0 + 60 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(50_000e6);

        // Sum tokensAllocated directly from reports and compare to declared
        (, , , uint256 tok1, ) = rewards.getEpochReport(1);
        (, , , uint256 tok2, ) = rewards.getEpochReport(2);

        assertEq(rewards.totalRewardsDeclared(), tok1 + tok2, "Declared should equal sum of epoch allocations");
    }
}

