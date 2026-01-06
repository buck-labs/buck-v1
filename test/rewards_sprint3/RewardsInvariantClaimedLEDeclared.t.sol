// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {OracleAdapter} from "src/oracle/OracleAdapter.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract RewardsInvariantClaimedLEDeclared is Test, BaseTest {
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

        // Deploy core contracts
        token = deployBUCK(ADMIN);
        policy = deployPolicyManager(ADMIN);
        usdc = new MockUSDC();
        LiquidityReserve reserveImpl = new LiquidityReserve();
        reserve = LiquidityReserve(
            address(new ERC1967Proxy(address(reserveImpl), abi.encodeCall(LiquidityReserve.initialize, (ADMIN, address(usdc), address(0), TREASURY))))
        );

        rewards = deployRewardsEngine(ADMIN, DISTRIBUTOR, 0, 0, false);

        // Wire BUCK modules (no KYC, no window contract in this test)
        token.configureModules(
            LIQUIDITY_WINDOW, address(reserve), TREASURY, address(policy), address(0), address(rewards)
        );
        token.enableProductionMode();

        // Wire RewardsEngine
        rewards.setToken(address(token));
        rewards.setPolicyManager(address(policy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);

        // LiquidityReserve permissions
        reserve.setRewardsEngine(address(rewards));

        // Oracle pricing for CAP = $1
        oracle = new OracleAdapter(ADMIN);
        oracle.setInternalPrice(1e18);

        vm.stopPrank();

        // Fund distributor
        usdc.mint(DISTRIBUTOR, 1_000_000e6);
        vm.prank(DISTRIBUTOR);
        usdc.approve(address(rewards), type(uint256).max);
    }

    function _configureEpoch(uint64 id, uint64 startTs, uint64 endTs) internal {
        uint64 cs = startTs + 12 days;
        uint64 ce = startTs + 16 days;
        vm.prank(ADMIN);
        rewards.configureEpoch(id, startTs, endTs, cs, ce);
    }

    function test_Invariant_Claimed_LE_Declared_across_epochs() public {
        uint64 t0 = uint64(block.timestamp);

        // Epoch 1
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint BUCK to ALICE/BOB via liquidity window (only minter)
        vm.startPrank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);
        token.mint(BOB, 100_000e18);
        vm.stopPrank();

        // Move to mid-epoch before checkpoint
        vm.warp(t0 + 10 days);

        // Create some pre-checkpoint breakage: ALICE sells 10% (forfeits proportional current-epoch units)
        vm.startPrank(ALICE);
        token.transfer(BOB, 10_000e18);
        vm.stopPrank();

        // Warp to epoch end and distribute $100k
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        (uint256 allocated1,) = rewards.distribute(100_000e6);

        // Invariant holds after distribution (sink auto-mint may have occurred)
        assertLe(rewards.totalRewardsClaimed(), rewards.totalRewardsDeclared());
        assertEq(rewards.totalRewardsDeclared(), allocated1);

        // Epoch 2
        uint64 e2Start = t0 + 30 days;
        _configureEpoch(2, e2Start, e2Start + 30 days);

        // Mid-epoch, Bob sells post-checkpoint to create future breakage
        vm.warp(e2Start + 20 days);
        vm.startPrank(BOB);
        token.transfer(ALICE, 1); // trivial outflow to trigger settlement+breakage path
        vm.stopPrank();

        // Warp to epoch 2 end and distribute another $50k
        vm.warp(e2Start + 30 days);
        vm.prank(DISTRIBUTOR);
        (uint256 allocated2,) = rewards.distribute(50_000e6);

        // Invariant must still hold
        assertLe(rewards.totalRewardsClaimed(), rewards.totalRewardsDeclared());
        assertEq(rewards.totalRewardsDeclared(), allocated1 + allocated2);

        // Optional: users claim (may be zero if current-epoch credits happen at rollover)
        vm.prank(ALICE);
        rewards.claim(ALICE);
        vm.prank(BOB);
        rewards.claim(BOB);

        // Invariant still holds after claims
        assertLe(rewards.totalRewardsClaimed(), rewards.totalRewardsDeclared());
    }
}

