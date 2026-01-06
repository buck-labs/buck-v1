// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "../../src/token/Buck.sol";

// Mock KYC Registry
contract MockAccessRegistry is IAccessRegistry {
    mapping(address => bool) public isAllowed;
    mapping(address => bool) public isDenylisted;

    function setAllowed(address account, bool allowed) external {
        isAllowed[account] = allowed;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

// Mock Rewards Hook for tracking balance changes
contract MockRewardsHook is IRewardsHook {
    mapping(address => uint256) public balances;

    function onBalanceChange(address from, address to, uint256 amount) external {
        if (from != address(0)) {
            balances[from] -= amount;
        }
        if (to != address(0)) {
            balances[to] += amount;
        }
    }

    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }
}

/**
 * @title DexFeePhantomBalanceTest
 * @notice Security tests to prevent DEX fee phantom balance attacks
 *
 * CRITICAL BUG FIXED:
 * - When fee-on-transfer occurs, BUCK only sends NET amount to buyer
 * - But previously notified RewardsEngine with GROSS amount
 * - This created "phantom balance" = fee amount in RewardsEngine ledger
 * - Attacker could loop buy/sell to stack unlimited phantom balances
 * - Claim monthly BUCK emissions without holding any tokens
 *
 * FIX:
 * - Changed Buck.sol:531 to pass netAmount instead of value
 * - RewardsEngine now receives accurate balance notifications
 *
 * These tests prove:
 * 1. No phantom balance created after fee-on-transfer
 * 2. RewardsEngine balance matches actual token balance
 * 3. Attack loop (buy/sell repeatedly) doesn't create phantom units
 */
contract DexFeePhantomBalanceTest is BaseTest {
    Buck public buck;
    MockRewardsHook public rewardsHook;
    MockAccessRegistry public kyc;

    address internal constant OWNER = address(0xA11CE);
    address internal constant LIQUIDITY_WINDOW = address(0xBEEF);
    address internal constant LIQUIDITY_RESERVE = address(0xCAFE);
    address internal constant TREASURY = address(0xFEE1);
    address internal constant DEX_POOL = address(0xDEAD);
    address internal constant ATTACKER = address(0x1337);
    address internal constant WHALE = address(0x4444);

    uint256 constant INITIAL_SUPPLY = 100_000_000e18; // 100M STRX

    function setUp() public {
        // Deploy BUCK using BaseTest helper
        buck = deployBUCK(OWNER);

        // Deploy mocks
        kyc = new MockAccessRegistry();
        rewardsHook = new MockRewardsHook();

        // Configure modules
        vm.prank(OWNER);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(0), // no policyManager needed for these tests
            address(kyc),
            address(rewardsHook)
        );

        // Configure DEX pair
        vm.prank(OWNER);
        buck.addDexPair(DEX_POOL);

        // KYC whitelist everyone
        kyc.setAllowed(OWNER, true);
        kyc.setAllowed(DEX_POOL, true);
        kyc.setAllowed(ATTACKER, true);
        kyc.setAllowed(TREASURY, true);
        kyc.setAllowed(WHALE, true);
        kyc.setAllowed(LIQUIDITY_WINDOW, true);

        // Mint initial supply
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(OWNER, INITIAL_SUPPLY);

        // Give DEX pool some tokens
        vm.prank(OWNER);
        buck.transfer(DEX_POOL, 10_000_000e18); // 10M to pool
    }

    /// @notice Test that RewardsEngine balance matches actual balance after fee-on-transfer
    function test_NoPhantomBalance_AfterDexFee() public {
        uint256 buyAmount = 1000e18; // Buy 1000 STRX

        // Simulate DEX buy: pool sends to attacker (1% fee)
        vm.prank(DEX_POOL);
        buck.transfer(ATTACKER, buyAmount);

        // Check actual token balance
        uint256 actualBalance = buck.balanceOf(ATTACKER);

        // Check RewardsHook ledger balance (acts like RewardsEngine)
        uint256 hookBalance = rewardsHook.getBalance(ATTACKER);

        // CRITICAL CHECK: Hook balance must match actual balance (no phantom)
        assertEq(
            hookBalance, actualBalance, "Hook balance must match actual token balance (no phantom)"
        );
    }

    /// @notice Test that buy/sell loop doesn't create phantom balances
    function test_NoPhantomBalance_BuySellLoop() public {
        uint256 buyAmount = 1000e18;

        // Run the attack loop 10 times
        for (uint256 i = 0; i < 10; i++) {
            // BUY: Pool sends to attacker (1% fee)
            vm.prank(DEX_POOL);
            buck.transfer(ATTACKER, buyAmount);

            // Check balances after buy
            uint256 attackerBalance = buck.balanceOf(ATTACKER);
            uint256 hookBalance = rewardsHook.getBalance(ATTACKER);
            assertEq(hookBalance, attackerBalance, "Hook balance must match after buy");

            // SELL: Attacker sends back to pool (1% fee)
            uint256 sellAmount = attackerBalance;

            vm.prank(ATTACKER);
            buck.transfer(DEX_POOL, sellAmount);

            // Check balances after sell (should be 0)
            attackerBalance = buck.balanceOf(ATTACKER);
            hookBalance = rewardsHook.getBalance(ATTACKER);

            assertEq(attackerBalance, 0, "Attacker balance should be 0 after sell");
            assertEq(hookBalance, 0, "Hook balance should be 0 after sell (no phantom)");
        }
    }

    /// @notice Test that phantom balances don't accumulate with repeated trading
    function test_NoPhantomBalance_RepeatedTrading() public {
        uint256 buyAmount = 1000e18;

        // Run 100 buy/sell loops
        for (uint256 i = 0; i < 100; i++) {
            // BUY
            vm.prank(DEX_POOL);
            buck.transfer(ATTACKER, buyAmount);

            // SELL immediately
            uint256 balance = buck.balanceOf(ATTACKER);
            vm.prank(ATTACKER);
            buck.transfer(DEX_POOL, balance);
        }

        // After 100 loops, attacker should have 0 balance
        assertEq(buck.balanceOf(ATTACKER), 0, "Attacker should have 0 balance");
        assertEq(rewardsHook.getBalance(ATTACKER), 0, "Hook should show 0 balance (no phantom)");
    }

    /// @notice Fuzz test: various buy amounts should never create phantom balance
    function testFuzz_NoPhantomBalance_VariousAmounts(uint256 buyAmount) public {
        // Bound to reasonable amounts (1 to 1M STRX)
        buyAmount = bound(buyAmount, 1e18, 1_000_000e18);

        // Ensure pool has enough
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_POOL, buyAmount);

        // DEX buy
        vm.prank(DEX_POOL);
        buck.transfer(ATTACKER, buyAmount);

        // Check balances match
        uint256 actualBalance = buck.balanceOf(ATTACKER);
        uint256 hookBalance = rewardsHook.getBalance(ATTACKER);

        assertEq(hookBalance, actualBalance, "Fuzz: Hook balance must always match actual balance");
    }

    /// @notice Test that non-DEX transfers still work correctly (no fee)
    function test_NoPhantomBalance_RegularTransfer() public {
        uint256 transferAmount = 1000e18;

        // Regular transfer (no fee)
        vm.prank(OWNER);
        buck.transfer(ATTACKER, transferAmount);

        // Both balances should match exactly (no fee deducted)
        uint256 actualBalance = buck.balanceOf(ATTACKER);
        uint256 hookBalance = rewardsHook.getBalance(ATTACKER);

        assertEq(actualBalance, transferAmount, "Should receive full amount (no fee)");
        assertEq(hookBalance, transferAmount, "Hook should record full amount");
        assertEq(hookBalance, actualBalance, "Balances must match exactly");
    }

    /// @notice Test the previous BUG to document what we fixed
    /// @dev This test would FAIL with the old buggy code
    function test_ProveOldBugFixed_PhantomBalanceWouldHaveExisted() public {
        uint256 buyAmount = 1000e18;

        // With OLD buggy code:
        // - Actual balance would be: 990 STRX
        // - Hook balance would be: 1000 STRX
        // - Phantom balance would be: 10 STRX

        // With NEW fixed code:
        vm.prank(DEX_POOL);
        buck.transfer(ATTACKER, buyAmount);

        uint256 actualBalance = buck.balanceOf(ATTACKER);
        uint256 hookBalance = rewardsHook.getBalance(ATTACKER);

        // Prove the bug is fixed: no 10 BUCK phantom balance
        uint256 phantomBalance = hookBalance > actualBalance ? hookBalance - actualBalance : 0;

        assertEq(phantomBalance, 0, "CRITICAL: Phantom balance must be 0 (bug fixed)");
    }
}
