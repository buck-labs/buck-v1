// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

// Minimal oracle adapter compatible with LiquidityWindow + PolicyManager
contract RBOracle {
    uint256 public price;
    uint256 public updatedAt;
    uint256 public lastBlock;
    constructor(uint256 p) { price = p; updatedAt = block.timestamp; lastBlock = block.number; }
    function latestPrice() external view returns (uint256, uint256) { return (price, updatedAt); }
    function isHealthy(uint256) external pure returns (bool) { return true; }
    function getLastPriceUpdateBlock() external view returns (uint256) { return lastBlock; }
    function setStrictMode(bool) external {}
}

contract UserHappyPathRedBand is Test, BaseTest {
    Buck token;
    LiquidityWindow window;
    LiquidityReserve reserve;
    PolicyManager policy;
    RewardsEngine rewards;
    RBOracle oracle;
    MockUSDC usdc;

    address constant TIMELOCK = address(0x1000);
    address constant TREASURY = address(0x2000);
    address constant ALICE = address(0x5000);
    address constant BOB   = address(0x5001);

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(TIMELOCK);
        token = deployBUCK(TIMELOCK);
        policy = deployPolicyManager(TIMELOCK);
        oracle = new RBOracle(1e18);
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);
        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));
        rewards = deployRewardsEngine(TIMELOCK, TIMELOCK, 0, 0, false);

        token.configureModules(address(window), address(reserve), TREASURY, address(policy), address(0), address(rewards));
        reserve.setLiquidityWindow(address(window));
        reserve.setRewardsEngine(address(rewards));

        window.setUSDC(address(usdc));
        window.configureFeeSplit(7000, TREASURY);

        policy.setContractReferences(address(token), address(reserve), address(oracle), address(usdc));
        policy.grantRole(policy.OPERATOR_ROLE(), address(window));

        // Set conservative "red-like" parameters on GREEN so we don't depend on autonomous band
        PolicyManager.BandConfig memory green = policy.getBandConfig(PolicyManager.Band.Green);
        green.halfSpreadBps = 40;      // 0.40%
        green.mintFeeBps    = 15;      // 0.15%
        green.refundFeeBps  = 20;      // 0.20%
        green.floorBps      = 500;     // 5% reserve floor
        // Disable aggregate caps for this test to focus on floor/availability behavior
        // Note: Use 0 (unlimited) instead of 10000 (100%) because percentage caps fail when totalSupply=0
        green.caps.mintAggregateBps   = 0; // Unlimited
        green.caps.refundAggregateBps = 0; // Unlimited
        policy.setBandConfig(PolicyManager.Band.Green, green);
        // Allow large single transactions (100% of remaining capacity)
        policy.setMaxSingleTransactionPct(100);

        // Rewards engine wiring
        rewards.setToken(address(token));
        rewards.setPolicyManager(address(policy));
        rewards.setTreasury(TREASURY);
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setBreakageSink(TREASURY);

        // Epoch for completeness
        uint64 s = uint64(block.timestamp); uint64 e = s + 30 days;
        rewards.configureEpoch(1, s, e, s + 12 days, s + 16 days);
        vm.stopPrank();

        // Fund users
        usdc.mint(ALICE, 50_000e6);
        usdc.mint(BOB,   50_000e6);
    }

    // Simulates RED-like stress: high floor + limited reserve means refunds revert, then succeed after top-up
    function test_RedLike_Refunds_RevertThenSucceed() public {
        // Mint initial supply to establish liabilities
        _mint(ALICE, 20_000e6);
        _mint(BOB,   20_000e6);

        // Reserve currently holds deposits from mints; drain to a minimal balance to simulate stress
        // In unit tests, simply transfer USDC out as the timelock via reserve queueWithdrawal fast path is not exposed.
        // We send a portion directly by impersonating the reserve for test purposes (mock USDC has no auth)
        uint256 resBal = usdc.balanceOf(address(reserve));
        if (resBal > 25_000e6) {
            // Reduce reserve so available liquidity < 0 given 5% floor
            uint256 drain = resBal - 25_000e6;
            vm.prank(address(reserve));
            usdc.transfer(address(0xdead), drain);
        }

        // Refund should revert due to floor-protected liquidity
        vm.startPrank(ALICE);
        uint256 amount = token.balanceOf(ALICE) / 2;
        token.approve(address(window), amount);
        vm.expectRevert();
        window.requestRefund(ALICE, amount, 0, 0);
        vm.stopPrank();

        // Top up reserve so available liquidity becomes positive
        usdc.mint(address(reserve), 1_000_000e6);

        // Refund now succeeds within caps: pick 1 bps of supply (always <= remaining capacity if any)
        uint256 totalSupply = token.totalSupply();
        uint256 amountOk = totalSupply / 10_000; // 1 bps of supply
        if (amountOk > token.balanceOf(ALICE)) amountOk = token.balanceOf(ALICE);
        require(amountOk > 0, "no refundable amount within caps");

        vm.startPrank(ALICE);
        token.approve(address(window), amountOk);
        (uint256 usdcOut, uint256 fee) = window.requestRefund(ALICE, amountOk, 0, 0);
        vm.stopPrank();
        assertGt(usdcOut, 0, "refund should succeed after top-up");
        // Sanity: check policy fees/spread reflect configured values
        (uint16 mintFee, uint16 refundFee) = policy.getFees();
        assertEq(mintFee, 15);
        assertEq(refundFee, 20);
        assertEq(policy.getHalfSpread(), 40);
    }

    function _mint(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(window), usdcAmount);
        window.requestMint(user, usdcAmount, 0, type(uint256).max);
        vm.stopPrank();
    }
}
