// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

// Oracle adapter compatible with LiquidityWindow and PolicyManager
contract RCIMockOracle {
    uint256 public price;
    uint256 public updatedAt;
    uint256 public lastBlock;
    bool public healthy = true;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isHealthy(uint256) external view returns (bool) {
        return healthy;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastBlock;
    }

    function setStrictMode(bool) external {}

    // helpers
    function setPrice(uint256 p) external {
        price = p;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }

    function setHealthy(bool ok) external {
        healthy = ok;
    }
}

contract RewardsCAPPricingIntegration is Test, BaseTest {
    // Contracts
    Buck public token;
    LiquidityWindow public window;
    LiquidityReserve public reserve;
    RewardsEngine public rewards;
    PolicyManager public policy;
    CollateralAttestation public attest;
    RCIMockOracle public oracle;
    MockUSDC public usdc;

    // Actors
    address public constant TIMELOCK = address(0x1000);
    address public constant TREASURY = address(0x2000);
    address public constant ATTESTOR = address(0x3000);
    address public constant ALICE = address(0x4001);
    address public constant BOB   = address(0x4002);

    uint256 constant PRICE_SCALE = 1e18;
    uint256 constant USDC_TO_18 = 1e12;
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint16  constant SKIM_BPS = 1000; // 10%

    function setUp() public {
        // Deploy mocks
        usdc = new MockUSDC();

        vm.startPrank(TIMELOCK);

        token = deployBUCK(TIMELOCK);
        policy = deployPolicyManager(TIMELOCK);
        oracle = new RCIMockOracle(0.97e18);
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);
        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));
        rewards = deployRewardsEngine(TIMELOCK, TIMELOCK, 0, 0, false);
        attest = deployCollateralAttestation(
            TIMELOCK, ATTESTOR, address(token), address(reserve), address(usdc)
        );

        // Wire modules
        token.configureModules(
            address(window), address(reserve), TREASURY, address(policy), address(0), address(rewards)
        );

        reserve.setLiquidityWindow(address(window));
        reserve.setRewardsEngine(address(rewards));

        window.setUSDC(address(usdc));
        window.configureFeeSplit(7000, TREASURY);

        policy.setContractReferences(address(token), address(reserve), address(oracle), address(usdc));
        policy.setCollateralAttestation(address(attest));

        // Operator role for window
        policy.grantRole(policy.OPERATOR_ROLE(), address(window));

        // Configure band skim
        PolicyManager.BandConfig memory green = policy.getBandConfig(PolicyManager.Band.Green);
        green.distributionSkimBps = SKIM_BPS;
        // Use 0 (unlimited) instead of 10000 because percentage caps fail when totalSupply=0
        green.caps.mintAggregateBps = 0; // Unlimited
        green.caps.refundAggregateBps = 0; // Unlimited
        policy.setBandConfig(PolicyManager.Band.Green, green);

        // Rewards wiring
        rewards.setToken(address(token));
        rewards.setPolicyManager(address(policy));
        rewards.setTreasury(TREASURY);
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);
        rewards.setBreakageSink(TREASURY);

        // Epoch with checkpoint window
        uint64 start = uint64(block.timestamp);
        uint64 end = start + 30 days;
        rewards.configureEpoch(1, start, end, start + 12 days, start + 16 days);

        vm.stopPrank();

        // Fund users
        usdc.mint(ALICE, 200_000e6);
        usdc.mint(BOB,   200_000e6);
    }

    // ---------------------- Tests ----------------------

    function test_FullLifecycle_HealthyCR_CAPPricing() public {
        // Alice mints 50k; Bob mints 30k
        _mint(ALICE, 50_000e6);
        _mint(BOB,   30_000e6);

        // Publish CR = 1.5 (derived V)
        _publishCR(1.5e18);

        // Distribute at epoch end
        uint64 end = rewards.epochEnd();
        vm.warp(end - 1);
        // Refresh attestation after time warp to avoid staleness
        _publishCR(1.5e18);

        uint256 coupon = 100_000e6;
        uint256 skimExpected = (coupon * SKIM_BPS) / BPS_DENOMINATOR;
        uint256 treBefore = usdc.balanceOf(TREASURY);

        // Distributor funds and calls distribute
        usdc.mint(TIMELOCK, coupon);
        vm.startPrank(TIMELOCK);
        usdc.approve(address(rewards), coupon);
        (uint256 allocated,) = rewards.distribute(coupon);
        vm.stopPrank();

        // Verify skim routed
        uint256 treAfter = usdc.balanceOf(TREASURY);
        assertApproxEqAbs(treAfter - treBefore, skimExpected, 1, "skim mismatch");

        // CAP = $1.00 when CR >= 1.0
        uint256 cap = policy.getCAPPrice();
        assertEq(cap, 1e18, "CAP should be $1.00 at healthy CR");

        // Allocation ≈ (coupon - skim) / $1
        uint256 expectedAllocated = (coupon - skimExpected) * USDC_TO_18; // 18-dec tokens at $1
        assertApproxEqRel(allocated, expectedAllocated, 0.000001e18, "allocated mismatch");

        // Configure next epoch and claim
        _rollToNextEpoch();

        // Claims should succeed and not exceed declared
        vm.prank(ALICE); rewards.claim(ALICE);
        vm.prank(BOB);   rewards.claim(BOB);
        assertLe(rewards.totalRewardsClaimed(), rewards.totalRewardsDeclared());
    }

    function test_SkimAndCAPPricing_TwoDistributions() public {
        _mint(ALICE, 50_000e6);
        _publishCR(1.2e18);

        // D1
        _distributeAtEnd(80_000e6);
        uint256 cap1 = policy.getCAPPrice();
        assertEq(cap1, 1e18, "CAP $1.00 when healthy");

        // Next epoch; D2
        _rollToNextEpoch();
        _distributeAtEnd(120_000e6);
        uint256 cap2 = policy.getCAPPrice();
        assertEq(cap2, 1e18, "CAP $1.00 when healthy");
    }

    // ---------------------- Helpers ----------------------

    function _mint(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(window), usdcAmount);
        window.requestMint(user, usdcAmount, 0, type(uint256).max);
        vm.stopPrank();
    }

    // Compute V required to reach desired CR, then publish via attestor
    function _publishCR(uint256 desiredCR) internal {
        uint256 L = token.totalSupply();
        uint256 R6 = usdc.balanceOf(address(reserve));
        uint256 R = R6 * USDC_TO_18; // 18-dec
        uint256 HC = 0.98e18; // default haircut in CollateralAttestation

        uint256 targetValue = (desiredCR * L) / PRICE_SCALE;
        uint256 V = (targetValue <= R) ? 0 : ((targetValue - R) * PRICE_SCALE) / HC;

        // Advance time to satisfy monotonic timestamp requirement
        vm.warp(block.timestamp + 1);

        vm.prank(ATTESTOR);
        attest.publishAttestation(V, HC, block.timestamp);
    }

    function _distributeAtEnd(uint256 coupon) internal {
        uint64 end = rewards.epochEnd();
        vm.warp(end - 1);
        // Refresh attestation after time warp to avoid staleness
        _publishCR(1.2e18);
        uint256 treBefore = usdc.balanceOf(TREASURY);
        uint256 skimExpected = (coupon * SKIM_BPS) / BPS_DENOMINATOR;

        usdc.mint(TIMELOCK, coupon);
        vm.startPrank(TIMELOCK);
        usdc.approve(address(rewards), coupon);
        (uint256 allocated,) = rewards.distribute(coupon);
        vm.stopPrank();

        // skim
        uint256 treAfter = usdc.balanceOf(TREASURY);
        assertApproxEqAbs(treAfter - treBefore, skimExpected, 1, "skim mismatch");

        // sanity (allow small precision tolerance)
        assertLe(allocated, (coupon - skimExpected) * USDC_TO_18 + 1e18);
    }

    function _rollToNextEpoch() internal {
        uint64 newStart = uint64(block.timestamp + 1);
        uint64 newEnd = newStart + 30 days;
        uint64 nextEpochId = rewards.currentEpochId() + 1; // Cache before prank
        vm.prank(TIMELOCK);
        rewards.configureEpoch(nextEpochId, newStart, newEnd, newStart + 12 days, newStart + 16 days);
        // Refresh attestation after epoch roll
        _publishCR(1.2e18);
    }
}
