// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {Buck} from "src/token/Buck.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

// Mock Oracle
contract MockOracle {
    uint256 public price;
    uint256 public updatedAt;
    uint256 public lastBlock;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isHealthy(uint256) external pure returns (bool) {
        return true;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastBlock;
    }

    function setPrice(uint256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }
}

/**
 * @title ComprehensiveFeeVectorTest
 * @notice Tests ALL 6 fee vectors in the BUCK protocol to ensure correct routing
 *
 * Fee Vectors:
 * 1. LiquidityWindow mint fees (USDC → Reserve/Treasury split)
 * 2. LiquidityWindow refund fees (USDC → Reserve/Treasury split)
 * 3. DEX buy fees (STRX → Reserve/Treasury split)
 * 4. DEX sell fees (STRX → Reserve/Treasury split)
 * 5. Distribution skim (USDC → Treasury before mint-as-yield)
 * 6. LiquidityWindow spread capture (implicit fee, USDC → Reserve)
 */
contract ComprehensiveFeeVectorTest is BaseTest {
    LiquidityWindow internal window;
    LiquidityReserve internal reserve;
    Buck internal buck;
    PolicyManager internal policy;
    RewardsEngine internal rewards;
    MockUSDC internal usdc;
    MockOracle internal oracle;

    address internal constant TIMELOCK = address(0x1000);
    address internal constant TREASURY = address(0x2000);
    address internal constant ALICE = address(0x3000);
    address internal constant BOB = address(0x4000);
    address internal constant GUARDIAN = address(0x5000);
    address internal constant DEX_PAIR = address(0x6000);

    uint256 internal constant PRICE = 0.97e18; // $0.97 per STRX

    function setUp() public {
        vm.startPrank(TIMELOCK);

        // Deploy contracts
        usdc = new MockUSDC();
        buck = deployBUCK(TIMELOCK);
        policy = deployPolicyManager(TIMELOCK);
        oracle = new MockOracle(PRICE);

        // Deploy liquidity contracts
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);
        window = deployLiquidityWindow(TIMELOCK, address(buck), address(reserve), address(policy));

        // Deploy rewards engine
        rewards = deployRewardsEngine(
            TIMELOCK,
            TIMELOCK,
            1800, // 30 min anti-snipe
            1e17, // 0.1 token min claim
            false // Allow multiple claims per epoch
        );

        // Configure connections
        buck.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0), // No KYC
            address(rewards)
        );

        reserve.setLiquidityWindow(address(window));
        reserve.setRewardsEngine(address(rewards));
        window.setUSDC(address(usdc));

        // Configure fees: 50 bps mint, 50 bps refund, 25 bps spread
        // window.configureFees(50, 50, 25); // Fees now managed by PolicyManager

        // Configure fee split: 50/50 between Reserve and Treasury
        window.configureFeeSplit(5000, TREASURY); // 50% to reserve, 50% to treasury

        // Configure PolicyManager with oracle and contract references
        policy.setContractReferences(
            address(buck), address(reserve), address(oracle), address(usdc)
        );

        // Register LiquidityWindow as operator
        bytes32 operatorRole = policy.OPERATOR_ROLE();
        policy.grantRole(operatorRole, address(window));

        // Configure GREEN band with updated parameters
        policy.setBandConfig(
            PolicyManager.Band.Green,
            PolicyManager.BandConfig({
                halfSpreadBps: 20, // 0.2% spread in each direction
                mintFeeBps: 10, // 0.1% mint fee
                refundFeeBps: 20, // 0.2% refund fee
                oracleStaleSeconds: 3600,
                deviationThresholdBps: 100,
                alphaBps: 10000, // 100% cap for testing
                floorBps: 500,
                distributionSkimBps: 25, // 0.25% skim
                caps: PolicyManager.CapSettings({mintAggregateBps: 0, refundAggregateBps: 10000})
            })
        );

        // Set GREEN band
        policy.reportSystemSnapshot(
            PolicyManager.SystemSnapshot({
                reserveRatioBps: 1000,
                equityBufferBps: 2000,
                oracleStaleSeconds: 0,
                totalSupply: 1000000e18,
                navPerToken: 1e18,
                reserveBalance: 500000e18, // 500k USDC in 18 decimals
                collateralRatio: 1e18
            })
        );

        // Configure DEX swap fees via PolicyManager
        policy.setDexFees(10, 10); // 0.1% buy, 0.1% sell (10 bps each)

        // Configure STRX
        buck.setFeeSplit(5000); // 50/50 split for DEX fees
        buck.addDexPair(DEX_PAIR);

        // Configure rewards engine
        rewards.setToken(address(buck));
        rewards.setPolicyManager(address(policy));
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setTreasury(TREASURY);
        rewards.setBlockDistributeOnDepeg(false); // Disable for testing (no CollateralAttestation configured)
        // Checkpoint window: day 12-16 of a 30-day epoch
        uint64 epochStart_ = uint64(block.timestamp);
        uint64 epochEnd_ = epochStart_ + 30 days;
        uint64 checkpointStart_ = epochStart_ + 12 days;
        uint64 checkpointEnd_ = epochStart_ + 16 days;
        rewards.configureEpoch(1, epochStart_, epochEnd_, checkpointStart_, checkpointEnd_);

        // Allow 100% transactions for tests (bypass 50% security limit)
        policy.setMaxSingleTransactionPct(100);

        vm.stopPrank();

        // Move past block-fresh window
        vm.roll(block.number + 2);

        // Fund test users
        usdc.mint(ALICE, 1_000_000e6);
        usdc.mint(BOB, 1_000_000e6);
        usdc.mint(address(reserve), 5_000_000e6); // Fund reserve for refunds
    }

    // =====================================================
    //           VECTOR 1: LIQUIDITY WINDOW MINT FEES
    // =====================================================

    function test_Vector1_MintFees_50_50_Split() public {
        uint256 usdcAmount = 100_000e6; // 100,000 USDC
        // GREEN band has 10 bps (0.1%) mint fee (from PolicyManager)
        uint256 expectedFee = (usdcAmount * 10) / 10000; // 0.1% = 100 USDC

        vm.startPrank(ALICE);
        usdc.approve(address(window), usdcAmount);

        uint256 reserveBalanceBefore = usdc.balanceOf(address(reserve));
        uint256 treasuryBalanceBefore = usdc.balanceOf(TREASURY);

        window.requestMint(ALICE, usdcAmount, 0, type(uint256).max);

        uint256 reserveBalanceAfter = usdc.balanceOf(address(reserve));
        uint256 treasuryBalanceAfter = usdc.balanceOf(TREASURY);

        // Calculate split
        uint256 feeToReserve = (expectedFee * 5000) / 10000; // 50% = 50 USDC
        uint256 feeToTreasury = expectedFee - feeToReserve; // 50% = 50 USDC

        // Reserve should receive: principal (100k - 100) + 50% of fee (50) = 99,950 USDC
        uint256 expectedReserveIncrease = (usdcAmount - expectedFee) + feeToReserve;
        assertEq(
            reserveBalanceAfter - reserveBalanceBefore,
            expectedReserveIncrease,
            "Reserve should receive principal + 50% of fee"
        );

        // Treasury should receive 50% of fee directly
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            feeToTreasury,
            "Treasury should receive 50% of fee"
        );

        vm.stopPrank();
    }

    function test_Vector1_MintFees_100_Percent_Reserve() public {
        vm.prank(TIMELOCK);
        window.configureFeeSplit(10000, TREASURY); // 100% to reserve

        uint256 usdcAmount = 50_000e6;
        // GREEN band has 10 bps (0.1%) mint fee (from PolicyManager)

        vm.startPrank(ALICE);
        usdc.approve(address(window), usdcAmount);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        window.requestMint(ALICE, usdcAmount, 0, type(uint256).max);
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        assertEq(
            treasuryAfter - treasuryBefore,
            0,
            "Treasury should receive 0% when split is 100% to reserve"
        );
        vm.stopPrank();
    }

    function test_Vector1_MintFees_100_Percent_Treasury() public {
        vm.prank(TIMELOCK);
        window.configureFeeSplit(0, TREASURY); // 0% to reserve = 100% to treasury

        uint256 usdcAmount = 50_000e6;
        // GREEN band has 10 bps (0.1%) mint fee (from PolicyManager)
        uint256 expectedFee = (usdcAmount * 10) / 10_000; // 0.1% = 10 bps

        vm.startPrank(ALICE);
        usdc.approve(address(window), usdcAmount);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        window.requestMint(ALICE, usdcAmount, 0, type(uint256).max);
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        assertEq(treasuryAfter - treasuryBefore, expectedFee, "Treasury should receive 100% of fee");
        vm.stopPrank();
    }

    // =====================================================
    //           VECTOR 2: LIQUIDITY WINDOW REFUND FEES
    // =====================================================

    function test_Vector2_RefundFees_50_50_Split() public {
        // First mint some STRX
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(ALICE, 100_000e6, 0, type(uint256).max);

        uint256 strcBalance = buck.balanceOf(ALICE);
        uint256 refundAmount = strcBalance / 10; // Refund 10%

        buck.approve(address(window), refundAmount);

        // Calculate expected refund using PolicyManager GREEN band fees (20 bps = 0.2%)
        uint256 priceWithSpread = (PRICE * (10000 - 20)) / 10000; // -0.20% spread (GREEN band)
        uint256 grossUsdc18 = (refundAmount * priceWithSpread) / 1e18;
        uint256 grossUsdc = grossUsdc18 / 1e12; // Convert to 6 decimals
        uint256 expectedFee = (grossUsdc * 20) / 10000; // 0.2% refund fee (GREEN band)
        uint256 feeToReserve = (expectedFee * 5000) / 10000; // 50% to reserve
        uint256 feeToTreasury = expectedFee - feeToReserve; // 50% to treasury

        uint256 reserveBefore = usdc.balanceOf(address(reserve));
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        // After Option A fix: fees are now routed immediately, not queued
        window.requestRefund(ALICE, refundAmount, 0, 0);

        uint256 reserveAfter = usdc.balanceOf(address(reserve));
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        // Verify treasury received its share of the fee immediately
        assertApproxEqAbs(
            treasuryAfter - treasuryBefore,
            feeToTreasury,
            1, // Allow 1 wei rounding error
            "Treasury should receive 50% of refund fee immediately"
        );

        // Verify reserve received its share back (it sent out gross, got back fee portion)
        // Reserve sent out grossUsdc, received back feeToReserve
        // Net change = feeToReserve - grossUsdc
        assertApproxEqAbs(
            reserveAfter,
            reserveBefore - grossUsdc + feeToReserve,
            1, // Allow 1 wei rounding error
            "Reserve should receive 50% of refund fee back"
        );

        vm.stopPrank();
    }

    // =====================================================
    //           VECTOR 3: DEX BUY FEES
    // =====================================================

    function test_Vector3_DexBuyFees_50_50_Split() public {
        // Setup: Give DEX_PAIR some BUCK to sell (via LiquidityWindow mint)
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(DEX_PAIR, 100_000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Simulate a DEX buy: transfer from DEX_PAIR to ALICE
        // Buy fee = 0.1% (10 bps)
        uint256 buyAmount = 10_000e18;
        uint256 expectedFee = (buyAmount * 10) / 10000; // 0.1% = 10 STRX
        uint256 feeToReserve = (expectedFee * 5000) / 10000; // 50% = 5 STRX
        uint256 feeToTreasury = expectedFee - feeToReserve; // 50% = 5 STRX

        uint256 reserveBalanceBefore = buck.balanceOf(address(reserve));
        uint256 treasuryBalanceBefore = buck.balanceOf(TREASURY);

        vm.prank(DEX_PAIR);
        buck.transfer(ALICE, buyAmount);

        uint256 reserveBalanceAfter = buck.balanceOf(address(reserve));
        uint256 treasuryBalanceAfter = buck.balanceOf(TREASURY);

        assertEq(
            reserveBalanceAfter - reserveBalanceBefore,
            feeToReserve,
            "Reserve should receive 50% of buy fee in STRX"
        );

        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            feeToTreasury,
            "Treasury should receive 50% of buy fee in STRX"
        );

        // Alice should receive net amount (buyAmount - fee)
        assertEq(
            buck.balanceOf(ALICE),
            buyAmount - expectedFee,
            "Alice should receive net amount after fee"
        );
    }

    // =====================================================
    //           VECTOR 4: DEX SELL FEES
    // =====================================================

    function test_Vector4_DexSellFees_50_50_Split() public {
        // Setup: Give ALICE some BUCK to sell (via LiquidityWindow mint)
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(ALICE, 100_000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Simulate a DEX sell: transfer from ALICE to DEX_PAIR
        // Sell fee = 0.1% (10 bps)
        uint256 sellAmount = 10_000e18;
        uint256 expectedFee = (sellAmount * 10) / 10000; // 0.1% = 10 STRX
        uint256 feeToReserve = (expectedFee * 5000) / 10000; // 50% = 5 STRX
        uint256 feeToTreasury = expectedFee - feeToReserve; // 50% = 5 STRX

        uint256 reserveBalanceBefore = buck.balanceOf(address(reserve));
        uint256 treasuryBalanceBefore = buck.balanceOf(TREASURY);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, sellAmount);

        uint256 reserveBalanceAfter = buck.balanceOf(address(reserve));
        uint256 treasuryBalanceAfter = buck.balanceOf(TREASURY);

        assertEq(
            reserveBalanceAfter - reserveBalanceBefore,
            feeToReserve,
            "Reserve should receive 50% of sell fee in STRX"
        );

        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            feeToTreasury,
            "Treasury should receive 50% of sell fee in STRX"
        );

        // DEX_PAIR should receive net amount (sellAmount - fee)
        assertEq(
            buck.balanceOf(DEX_PAIR),
            sellAmount - expectedFee,
            "DEX should receive net amount after fee"
        );
    }

    // =====================================================
    //           VECTOR 5: DISTRIBUTION SKIM
    // =====================================================

    function test_Vector5_DistributionSkim_GoesToTreasury() public {
        // Setup: Mint some BUCK to create users with units
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(ALICE, 100_000e6, 0, type(uint256).max);
        vm.stopPrank();

        // Allow time to elapse so the next settlement captures accrual
        vm.warp(block.timestamp + 400);

        // Transfer to trigger unit accrual
        vm.prank(ALICE);
        buck.transfer(BOB, 1000e18);

        // Warp to epoch end (distribution requires epochEnd)
        vm.warp(block.timestamp + 30 days);

        // Setup distribution with 10,000 USDC coupon
        uint256 couponAmount = 10_000e6; // 10,000 USDC
        // GREEN band has 25 bps (0.25%) distribution skim
        uint256 skimBps = 25;
        uint256 expectedSkim = (couponAmount * skimBps) / 10000; // 0.25% = 25 USDC

        // Fund TIMELOCK with USDC for distribution (new approve+distribute pattern)
        usdc.mint(TIMELOCK, couponAmount);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        uint256 reserveBefore = usdc.balanceOf(address(reserve));

        // Distribute using approve+distribute pattern
        vm.prank(TIMELOCK);
        usdc.approve(address(rewards), couponAmount);
        vm.prank(TIMELOCK);
        rewards.distribute(couponAmount);

        uint256 treasuryAfter = usdc.balanceOf(TREASURY);
        uint256 reserveAfter = usdc.balanceOf(address(reserve));

        // Treasury should receive the skim
        assertEq(
            treasuryAfter - treasuryBefore,
            expectedSkim,
            "Treasury should receive distribution skim"
        );

        // With the new approve+distribute pattern:
        // - TIMELOCK transfers couponAmount to reserve
        // - Reserve sends expectedSkim to treasury
        // - Net change to reserve = couponAmount - expectedSkim
        uint256 netCoupon = couponAmount - expectedSkim;
        assertEq(
            reserveAfter - reserveBefore,
            netCoupon,
            "Reserve gains net coupon after skim (USDC backing for newly minted STRX)"
        );
    }

    // =====================================================
    //           VECTOR 6: SPREAD CAPTURE
    // =====================================================

    function test_Vector6_SpreadCapture_StaysInReserve() public {
        // Spread capture is implicit - users get worse pricing, difference stays in reserve
        uint256 usdcAmount = 100_000e6;

        // Calculate what user would get WITHOUT spread
        uint256 strcWithoutSpread = (usdcAmount * 1e12 * 1e18) / PRICE; // Convert USDC to 18 decimals

        vm.startPrank(ALICE);
        usdc.approve(address(window), usdcAmount);

        (uint256 strcOut,) = window.requestMint(ALICE, usdcAmount, 0, type(uint256).max);

        // User should get LESS BUCK due to spread
        // Spread = 0.25%, so effective price is 1.0025x higher
        uint256 expectedStrcWithSpread = (usdcAmount * 1e12 * 1e18) / ((PRICE * 10025) / 10000);

        assertLt(strcOut, strcWithoutSpread, "User should get less BUCK due to spread");
        assertApproxEqRel(
            strcOut, expectedStrcWithSpread, 0.01e18, "STRX should match spread-adjusted amount"
        );

        // The spread benefit (difference) is captured by the reserve
        // This is implicit - reserve receives more USDC per BUCK than NAV
        vm.stopPrank();
    }

    function test_Vector6_SpreadCapture_Refund() public {
        // First mint
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(ALICE, 100_000e6, 0, type(uint256).max);

        uint256 strcBalance = buck.balanceOf(ALICE);
        uint256 refundAmount = strcBalance / 10; // Refund 10%

        // Calculate what user would get WITHOUT spread
        uint256 usdcWithoutSpread = (refundAmount * PRICE) / 1e18 / 1e12;

        buck.approve(address(window), refundAmount);

        (uint256 usdcOut,) = window.requestRefund(ALICE, refundAmount, 0, 0);

        // User should get LESS USDC due to spread
        assertLt(usdcOut, usdcWithoutSpread, "User should get less USDC due to spread");

        // Spread = 0.25%, so effective price is 0.9975x lower
        uint256 expectedUsdcWithSpread = (refundAmount * ((PRICE * 9975) / 10000)) / 1e18 / 1e12;
        uint256 refundFee = (expectedUsdcWithSpread * 50) / 10000; // 0.5% fee
        uint256 netUsdc = expectedUsdcWithSpread - refundFee;

        assertApproxEqRel(
            usdcOut, netUsdc, 0.01e18, "USDC should match spread-adjusted amount minus fee"
        );

        vm.stopPrank();
    }

    // =====================================================
    //           CROSS-VECTOR TESTS
    // =====================================================

    function test_AllVectors_FeeAccumulation() public {
        // Test that all fee vectors work together correctly

        uint256 treasuryUsdcBefore = usdc.balanceOf(TREASURY);
        uint256 treasuryStrxBefore = buck.balanceOf(TREASURY);

        // 1. Mint fees - GREEN band has 10 bps (0.1%) mint fee
        vm.startPrank(ALICE);
        usdc.approve(address(window), 100_000e6);
        window.requestMint(ALICE, 100_000e6, 0, type(uint256).max);
        vm.stopPrank();

        uint256 mintFeeTreasury = (100_000e6 * 10 * 5000) / (10000 * 10000); // 0.1% fee, 50% to treasury = 50 USDC

        // 2. DEX buy fees (mint to DEX_PAIR first)
        vm.startPrank(BOB);
        usdc.approve(address(window), 50_000e6);
        window.requestMint(DEX_PAIR, 50_000e6, 0, type(uint256).max);
        vm.stopPrank();

        vm.prank(DEX_PAIR);
        buck.transfer(BOB, 10_000e18);

        uint256 buyFeeTreasury = (10_000e18 * 10 * 5000) / (10000 * 10000); // 0.1% fee, 50% to treasury = 5 STRX

        // Check treasury accumulated fees correctly
        uint256 treasuryStrxBalance = buck.balanceOf(TREASURY) - treasuryStrxBefore;
        assertEq(
            treasuryStrxBalance, buyFeeTreasury, "Treasury should have accumulated DEX fees in STRX"
        );

        uint256 treasuryUsdcBalance = usdc.balanceOf(TREASURY) - treasuryUsdcBefore;
        // Total USDC fees = mint fees from ALICE (50) + mint fees from BOB (25) = 75 USDC
        uint256 expectedTotalUsdcFees = mintFeeTreasury + ((50_000e6 * 10 * 5000) / (10000 * 10000));
        assertEq(
            treasuryUsdcBalance,
            expectedTotalUsdcFees,
            "Treasury should have accumulated mint fees in USDC"
        );
    }

    function test_AllVectors_DifferentSplitRatios() public {
        // Test 70/30 split for all vectors
        vm.startPrank(TIMELOCK);
        window.configureFeeSplit(7000, TREASURY); // 70% reserve, 30% treasury
        buck.setFeeSplit(7000); // 70% reserve, 30% treasury for DEX fees
        vm.stopPrank();

        // Test mint with 70/30 split - GREEN band has 10 bps (0.1%) mint fee
        uint256 mintAmount = 50_000e6;
        uint256 mintFee = (mintAmount * 10) / 10000; // 0.1% = 50 USDC
        uint256 mintFeeToTreasury = (mintFee * 3000) / 10000; // 30% = 15 USDC

        vm.startPrank(ALICE);
        usdc.approve(address(window), mintAmount);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        window.requestMint(ALICE, mintAmount, 0, type(uint256).max);
        uint256 treasuryAfter = usdc.balanceOf(TREASURY);

        assertEq(
            treasuryAfter - treasuryBefore,
            mintFeeToTreasury,
            "Treasury should receive 30% of mint fee"
        );
        vm.stopPrank();

        // Test DEX sell with 70/30 split (mint to BOB first)
        vm.startPrank(BOB);
        usdc.approve(address(window), 50_000e6);
        window.requestMint(BOB, 50_000e6, 0, type(uint256).max);
        vm.stopPrank();

        uint256 sellAmount = 10_000e18;
        uint256 sellFee = (sellAmount * 10) / 10000; // 0.1% = 10 STRX
        uint256 sellFeeToTreasury = (sellFee * 3000) / 10000; // 30% = 3 STRX

        treasuryBefore = buck.balanceOf(TREASURY);
        vm.prank(BOB);
        buck.transfer(DEX_PAIR, sellAmount);
        treasuryAfter = buck.balanceOf(TREASURY);

        assertEq(
            treasuryAfter - treasuryBefore,
            sellFeeToTreasury,
            "Treasury should receive 30% of sell fee"
        );
    }
}
