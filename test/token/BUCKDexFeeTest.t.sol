// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "src/token/Buck.sol";

contract MockAccessRegistryDex is IAccessRegistry {
    mapping(address => bool) public isAllowed;
    mapping(address => bool) public isDenylisted;

    function setAllowed(address account, bool allowed) external {
        isAllowed[account] = allowed;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

contract MockRewardsHookDex is IRewardsHook {
    function onBalanceChange(address, address, uint256) external {}
}

contract MockPolicyManagerDex {
    uint16 public buyFeeBps = 100; // 1%
    uint16 public sellFeeBps = 150; // 1.5%

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }
}

contract BUCKDexFeeTest is BaseTest {
    Buck internal buck;
    MockAccessRegistryDex internal accessRegistry;
    MockRewardsHookDex internal rewardsHook;
    MockPolicyManagerDex internal policyManager;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant LIQUIDITY_WINDOW = address(0xBEEF);
    address internal constant LIQUIDITY_RESERVE = address(0xCAFE);
    address internal constant TREASURY = address(0xFEE1);
    address internal constant DEX_PAIR = address(0xDEAD);
    address internal constant DEX_PAIR_2 = address(0xDEAD2);

    address internal constant ALICE = address(0x1111);
    address internal constant BOB = address(0x2222);
    address internal constant LIQUIDITY_STEWARD = address(0x3333);
    address internal constant WHALE = address(0x4444);

    uint16 internal constant MAX_FEE = 200; // 2%
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
        accessRegistry = new MockAccessRegistryDex();
        rewardsHook = new MockRewardsHookDex();
        policyManager = new MockPolicyManagerDex();

        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);

        // Set up KYC for test accounts
        accessRegistry.setAllowed(ALICE, true);
        accessRegistry.setAllowed(BOB, true);
        accessRegistry.setAllowed(LIQUIDITY_STEWARD, true);
        accessRegistry.setAllowed(WHALE, true);
    }

    // =========================================================================
    // BOTH FEES ACTIVE TESTS
    // =========================================================================

    function testBothFeesActiveSimultaneously() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 150); // 1% buy, 1.5% sell
        buck.setFeeSplit(5000); // 50/50 split
        vm.stopPrank();

        // Mint tokens to DEX pair and user
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 1000 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // Test buy (DEX -> ALICE)
        uint256 buyAmount = 100 ether;
        uint256 expectedBuyFee = (buyAmount * 100) / BPS_DENOMINATOR; // 1 ether

        vm.prank(DEX_PAIR);
        buck.transfer(ALICE, buyAmount);

        assertEq(buck.balanceOf(ALICE), 1000 ether + buyAmount - expectedBuyFee);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), expectedBuyFee / 2);
        assertEq(buck.balanceOf(TREASURY), expectedBuyFee / 2);

        // Test sell (ALICE -> DEX)
        uint256 sellAmount = 100 ether;
        uint256 expectedSellFee = (sellAmount * 150) / BPS_DENOMINATOR; // 1.5 ether

        uint256 reserveBefore = buck.balanceOf(LIQUIDITY_RESERVE);
        uint256 treasuryBefore = buck.balanceOf(TREASURY);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, sellAmount);

        assertEq(buck.balanceOf(DEX_PAIR), 900 ether + sellAmount - expectedSellFee);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE) - reserveBefore, expectedSellFee / 2);
        assertEq(buck.balanceOf(TREASURY) - treasuryBefore, expectedSellFee / 2);
    }

    // =========================================================================
    // FEE SPLIT EDGE CASES
    // =========================================================================

    function test100PercentToReserve() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100); // 1% both ways
        buck.setFeeSplit(10000); // 100% to reserve, 0% to treasury
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        accessRegistry.setAllowed(DEX_PAIR, true);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 expectedFee = 1 ether;
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), expectedFee);
        assertEq(buck.balanceOf(TREASURY), 0);
    }

    function test100PercentToTreasury() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100); // 1% both ways
        buck.setFeeSplit(0); // 0% to reserve, 100% to treasury
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);
        accessRegistry.setAllowed(DEX_PAIR, true);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 expectedFee = 1 ether;
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), 0);
        assertEq(buck.balanceOf(TREASURY), expectedFee);
    }

    // =========================================================================
    // MAXIMUM FEE SCENARIOS
    // =========================================================================

    function testMaximumFeeBoundary() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(MAX_FEE, MAX_FEE); // 2% both ways (maximum)
        buck.setFeeSplit(5000); // 50/50
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 10000 ether);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 1000 ether);

        uint256 expectedFee = (1000 ether / BPS_DENOMINATOR) * MAX_FEE; // 20 ether
        assertEq(buck.balanceOf(DEX_PAIR), 1000 ether - expectedFee);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), expectedFee / 2);
        assertEq(buck.balanceOf(TREASURY), expectedFee / 2);
    }

    function testCumulativeFeeImpact() public {
        // Test impact of max fees on multiple trades
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(MAX_FEE, MAX_FEE); // 2% both ways
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 10000 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 10000 ether);

        uint256 startBalance = 1000 ether;
        uint256 currentBalance = startBalance;

        // Simulate 10 round trips (sell then buy back)
        for (uint256 i = 0; i < 10; i++) {
            // Sell to DEX
            vm.prank(ALICE);
            buck.transfer(DEX_PAIR, currentBalance);
            uint256 afterSellFee = currentBalance - (currentBalance * MAX_FEE / BPS_DENOMINATOR);

            // Buy back from DEX
            vm.prank(DEX_PAIR);
            buck.transfer(ALICE, afterSellFee);
            currentBalance = afterSellFee - (afterSellFee * MAX_FEE / BPS_DENOMINATOR);
        }

        // After 10 round trips with 2% fee each way, substantial value lost
        assertLt(currentBalance, startBalance * 70 / 100); // Lost more than 30%
    }

    // =========================================================================
    // MULTIPLE DEX PAIRS
    // =========================================================================

    function testMultipleDexPairs() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 150); // 1% buy, 1.5% sell
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // Mint to DEX pairs to allow them to transfer
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 100 ether);
        accessRegistry.setAllowed(DEX_PAIR_2, true);
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR_2, 100 ether);

        // Trade with first DEX pair (already registered in setUp)
        accessRegistry.setAllowed(DEX_PAIR, true);
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 expectedFee1 = (100 ether * 150) / BPS_DENOMINATOR;
        uint256 reserveAfterFirst = buck.balanceOf(LIQUIDITY_RESERVE);
        assertEq(reserveAfterFirst, expectedFee1 / 2);

        // Add second DEX pair (first is still active!)
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR_2);

        // Both DEX pairs now trigger fees - trade with first pair again
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);
        uint256 reserveAfterSecond = buck.balanceOf(LIQUIDITY_RESERVE);
        assertEq(reserveAfterSecond, reserveAfterFirst + expectedFee1 / 2); // Fees collected!

        // Second DEX pair should also trigger fees
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR_2, 100 ether);

        uint256 expectedFee2 = (100 ether * 150) / BPS_DENOMINATOR;
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), reserveAfterSecond + expectedFee2 / 2);
    }

    function testRemoveDexPairStopsFees() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 150); // 1% buy, 1.5% sell
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        accessRegistry.setAllowed(DEX_PAIR, true);

        // Trade triggers fees
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);
        uint256 reserveAfterFirst = buck.balanceOf(LIQUIDITY_RESERVE);
        assertGt(reserveAfterFirst, 0);

        // Remove DEX pair
        vm.prank(TIMELOCK);
        buck.removeDexPair(DEX_PAIR);

        // Trade no longer triggers fees
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), reserveAfterFirst); // No new fees
    }

    // =========================================================================
    // FEE CHANGES MID-BATCH
    // =========================================================================

    function testFeeChangeDuringTransactionBatch() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(50, 50); // 0.5% initially
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // First trade with low fees
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 lowFee = (100 ether * 50) / BPS_DENOMINATOR; // 0.5 ether
        uint256 reserveAfterFirst = buck.balanceOf(LIQUIDITY_RESERVE);
        assertEq(reserveAfterFirst, lowFee / 2);

        // Change fees mid-execution
        vm.prank(TIMELOCK);
        policyManager.setDexFees(200, 200); // Max fees

        // Second trade with high fees
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 highFee = (100 ether * 200) / BPS_DENOMINATOR; // 2 ether
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), reserveAfterFirst + highFee / 2);
    }

    // =========================================================================
    // LIQUIDITY PROVIDER SCENARIOS
    // =========================================================================

    function testLiquidityStewardFeeExemption() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100); // 1% both ways
        buck.setFeeSplit(5000);
        buck.setFeeExempt(LIQUIDITY_STEWARD, true);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(LIQUIDITY_STEWARD, 1000 ether);

        // Liquidity steward sells to DEX - no fees
        vm.prank(LIQUIDITY_STEWARD);
        buck.transfer(DEX_PAIR, 100 ether);

        assertEq(buck.balanceOf(DEX_PAIR), 100 ether); // Full amount, no fees
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), 0);
        assertEq(buck.balanceOf(TREASURY), 0);

        // Regular user sells - fees apply
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 100 ether);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 expectedFee = 1 ether;
        assertEq(buck.balanceOf(DEX_PAIR), 199 ether); // 100 + 100 - 1
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), expectedFee / 2);
    }

    // =========================================================================
    // SANDWICH ATTACK PATTERNS
    // =========================================================================

    function testSandwichAttackPattern() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(30, 30); // 0.3% both ways (realistic DEX fee)
        buck.setFeeSplit(5000);
        vm.stopPrank();

        // Setup: Attacker and victim have tokens
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether); // Victim

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(BOB, 10000 ether); // Attacker

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 50000 ether); // DEX liquidity

        uint256 attackerStartBalance = buck.balanceOf(BOB);
        uint256 totalFeesBefore = buck.balanceOf(LIQUIDITY_RESERVE) + buck.balanceOf(TREASURY);

        // 1. Attacker front-runs: Large buy from DEX
        vm.prank(DEX_PAIR);
        buck.transfer(BOB, 5000 ether);

        // 2. Victim's transaction: Normal sell to DEX
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 500 ether);

        // 3. Attacker back-runs: Sell back to DEX
        uint256 attackerBalance = buck.balanceOf(BOB);
        vm.prank(BOB);
        buck.transfer(DEX_PAIR, attackerBalance - attackerStartBalance);

        // Calculate fees paid
        uint256 totalFeesAfter = buck.balanceOf(LIQUIDITY_RESERVE) + buck.balanceOf(TREASURY);
        uint256 totalFeesPaid = totalFeesAfter - totalFeesBefore;

        // All three transactions should have generated fees
        assertGt(totalFeesPaid, 0);

        // Verify fee distribution
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), totalFeesAfter / 2);
        assertEq(buck.balanceOf(TREASURY), totalFeesAfter / 2);
    }

    // =========================================================================
    // ROUNDING AND EDGE CASES
    // =========================================================================

    function testSmallAmountFeeRounding() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(1, 1); // 0.01% - very small fee
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 100);

        // Transfer amount that would result in fractional wei fee
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100); // Fee would be 0.01 wei

        // Should round down to 0
        assertEq(buck.balanceOf(DEX_PAIR), 100);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), 0);
        assertEq(buck.balanceOf(TREASURY), 0);
    }

    function testOddFeeSplitRounding() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100); // 1%
        buck.setFeeSplit(3333); // 33.33% to reserve, 66.67% to treasury
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 10001); // Odd amount

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 10001);

        uint256 fee = 100; // 1% of 10001 = 100 (rounded down)
        uint256 toReserve = (fee * 3333) / 10000; // 33
        uint256 toTreasury = fee - toReserve; // 67

        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), toReserve);
        assertEq(buck.balanceOf(TREASURY), toTreasury);
        assertEq(toReserve + toTreasury, fee); // No dust lost
    }

    // =========================================================================
    // LARGE AMOUNT TESTS
    // =========================================================================

    function testLargeAmountNoOverflow() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(200, 200); // Max 2%
        buck.setFeeSplit(5000);
        vm.stopPrank();

        // Large but safe amount
        uint256 largeAmount = 1e30; // Large but won't overflow

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(WHALE, largeAmount);

        vm.prank(WHALE);
        buck.transfer(DEX_PAIR, largeAmount);

        uint256 expectedFee = (largeAmount * 200) / 10000;
        assertEq(buck.balanceOf(DEX_PAIR), largeAmount - expectedFee);

        // For very large numbers, there might be rounding in the split
        uint256 toReserve = (expectedFee * 5000) / 10000;
        uint256 toTreasury = expectedFee - toReserve;

        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), toReserve);
        assertEq(buck.balanceOf(TREASURY), toTreasury);
    }

    // =========================================================================
    // MISSING MODULE TESTS
    // =========================================================================

    function testFeesWithMissingTreasury() public {
        // Reconfigure with no treasury
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            address(0), // No treasury
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100);
        buck.setFeeSplit(5000); // 50/50 split
        // DEX_PAIR already added in setUp()
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // Should revert when trying to send fees to missing treasury
        vm.prank(ALICE);
        vm.expectRevert(Buck.InvalidAddress.selector);
        buck.transfer(DEX_PAIR, 100 ether);
    }

    function testFeesWithMissingReserve() public {
        // Reconfigure with no reserve
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            address(0), // No reserve
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(100, 100);
        buck.setFeeSplit(5000); // 50/50 split
        // DEX_PAIR already added in setUp()
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // Should revert when trying to send fees to missing reserve
        vm.prank(ALICE);
        vm.expectRevert(Buck.InvalidAddress.selector);
        buck.transfer(DEX_PAIR, 100 ether);
    }

    // =========================================================================
    // ZERO FEE SCENARIOS
    // =========================================================================

    function testZeroFeesConfiguration() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(0, 0); // No fees
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        // No fees should be collected
        assertEq(buck.balanceOf(DEX_PAIR), 100 ether);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), 0);
        assertEq(buck.balanceOf(TREASURY), 0);
    }

    function testAsymmetricFees() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(0, 200); // No buy fee, 2% sell fee
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 1000 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 1000 ether);

        // Buy from DEX - no fee
        vm.prank(DEX_PAIR);
        buck.transfer(ALICE, 100 ether);
        assertEq(buck.balanceOf(ALICE), 1100 ether); // Full amount

        // Sell to DEX - fee applies
        vm.prank(ALICE);
        buck.transfer(DEX_PAIR, 100 ether);

        uint256 expectedFee = 2 ether; // 2% of 100
        assertEq(buck.balanceOf(DEX_PAIR), 900 ether + 100 ether - expectedFee);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), expectedFee / 2);
    }

    // =========================================================================
    // COMPLEX TRADING PATTERNS
    // =========================================================================

    function testHighFrequencyTradingPattern() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(10, 10); // 0.1% - low fee for HFT
        buck.setFeeSplit(5000);
        vm.stopPrank();

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(ALICE, 10000 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 100000 ether);

        uint256 totalFees = 0;
        uint256 tradeSize = 100 ether;

        // Simulate 100 rapid trades
        for (uint256 i = 0; i < 100; i++) {
            if (i % 2 == 0) {
                // Buy
                vm.prank(DEX_PAIR);
                buck.transfer(ALICE, tradeSize);
            } else {
                // Sell
                vm.prank(ALICE);
                buck.transfer(DEX_PAIR, tradeSize);
            }
            totalFees += (tradeSize * 10) / 10000;
        }

        // Verify total fees collected
        uint256 actualFees = buck.balanceOf(LIQUIDITY_RESERVE) + buck.balanceOf(TREASURY);
        assertEq(actualFees, totalFees);
    }

    // =========================================================================
    // VIEW FUNCTION TESTS
    // =========================================================================

    function testCalculateSwapFeeView() public {
        vm.startPrank(TIMELOCK);
        policyManager.setDexFees(150, 200); // 1.5% buy, 2% sell
        vm.stopPrank();

        uint256 amount = 1000 ether;

        // Test buy fee calculation
        uint256 buyFee = buck.calculateSwapFee(amount, true);
        assertEq(buyFee, (amount * 150) / 10000);

        // Test sell fee calculation
        uint256 sellFee = buck.calculateSwapFee(amount, false);
        assertEq(sellFee, (amount * 200) / 10000);
    }
}
