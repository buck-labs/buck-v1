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

contract ExcludedAccounts_NoAccrualNoClaim is Test, BaseTest {
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

    function test_ExcludedAccounts_DoNotAccrueOrClaim() public {
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Exclude ALICE and then mint to her
        vm.prank(ADMIN);
        rewards.setAccountExcluded(ALICE, true);
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Verify eligible supply is zero
        (
            , uint256 eligibleSupply,, , ,
        ) = rewards.getGlobalState();
        assertEq(eligibleSupply, 0, "Excluded account should not contribute to eligible supply");

        // Warp to epoch end and distribute
        vm.warp(t0 + 30 days);
        vm.prank(DISTRIBUTOR);
        rewards.distribute(50_000e6);

        // Excluded account has no pending and cannot claim anything
        uint256 pending = rewards.pendingRewards(ALICE);
        assertEq(pending, 0, "Excluded account should have 0 pending");

        uint256 claimed = rewards.claim(ALICE);
        assertEq(claimed, 0, "Excluded account claim should be 0");
    }

    /// @notice SpearBit #5: Verify totalExcludedSupply stays in sync when excluded accounts transfer
    function test_TotalExcludedSupply_StaysInSync_OnTransfers() public {
        address BOB = address(0xB0B);
        uint64 t0 = uint64(block.timestamp);
        _configureEpoch(1, t0, t0 + 30 days);

        // Mint to ALICE (not excluded yet)
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(ALICE, 100_000e18);

        // Mint to BOB (will stay non-excluded)
        vm.prank(LIQUIDITY_WINDOW);
        token.mint(BOB, 50_000e18);

        // Exclude ALICE
        vm.prank(ADMIN);
        rewards.setAccountExcluded(ALICE, true);

        // Verify totalExcludedSupply matches ALICE's balance
        uint256 excludedSupply = rewards.totalExcludedSupply();
        assertEq(excludedSupply, 100_000e18, "totalExcludedSupply should equal ALICE balance after exclusion");

        // BOB transfers 10k to excluded ALICE
        vm.prank(BOB);
        token.transfer(ALICE, 10_000e18);

        // Verify totalExcludedSupply INCREASED (this was the bug - it didn't before the fix)
        excludedSupply = rewards.totalExcludedSupply();
        assertEq(excludedSupply, 110_000e18, "totalExcludedSupply should increase when excluded account receives");

        // ALICE (excluded) transfers 20k to BOB
        vm.prank(ALICE);
        token.transfer(BOB, 20_000e18);

        // Verify totalExcludedSupply DECREASED
        excludedSupply = rewards.totalExcludedSupply();
        assertEq(excludedSupply, 90_000e18, "totalExcludedSupply should decrease when excluded account sends");

        // Verify the invariant: eligibleSupply = totalSupply - totalExcludedSupply
        uint256 totalSupply = token.totalSupply();
        (, uint256 eligibleSupply,,,,) = rewards.getGlobalState();
        assertEq(
            eligibleSupply,
            totalSupply - excludedSupply,
            "Invariant: eligibleSupply == totalSupply - totalExcludedSupply"
        );
    }
}

