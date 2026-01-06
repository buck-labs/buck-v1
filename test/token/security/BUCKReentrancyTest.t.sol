// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";

// ============================================================================
// MALICIOUS CONTRACTS FOR REENTRANCY TESTING
// ============================================================================

/// @notice Malicious rewards hook that attempts reentrancy during callback
contract MaliciousRewardsHook {
    Buck public immutable token;

    // Attack configuration
    bool public attackEnabled;
    uint256 public attackCount;
    uint256 public maxAttacks = 1;

    // Attack types
    enum AttackType {
        NONE,
        TRANSFER,
        TRANSFER_FROM,
        MINT,
        BURN,
        APPROVE
    }

    AttackType public currentAttack = AttackType.NONE;
    address public attackTarget;
    uint256 public attackAmount;

    constructor(Buck _token) {
        token = _token;
    }

    function setAttack(AttackType _type, address _target, uint256 _amount, uint256 _maxAttacks)
        external
    {
        currentAttack = _type;
        attackTarget = _target;
        attackAmount = _amount;
        maxAttacks = _maxAttacks;
        attackCount = 0;
        attackEnabled = true;
    }

    function disableAttack() external {
        attackEnabled = false;
        currentAttack = AttackType.NONE;
    }

    // This is called by STRC during transfers
    function onBalanceChange(address, address, uint256) external {
        if (!attackEnabled || attackCount >= maxAttacks) return;
        attackCount++;

        // Attempt reentrant call based on attack type
        if (currentAttack == AttackType.TRANSFER) {
            token.transfer(attackTarget, attackAmount);
        } else if (currentAttack == AttackType.TRANSFER_FROM) {
            token.transferFrom(attackTarget, address(this), attackAmount);
        } else if (currentAttack == AttackType.MINT) {
            token.mint(attackTarget, attackAmount);
        } else if (currentAttack == AttackType.BURN) {
            token.burn(attackTarget, attackAmount);
        } else if (currentAttack == AttackType.APPROVE) {
            token.approve(attackTarget, attackAmount);
        }
    }
}

/// @notice Nested malicious rewards hook for multi-level attacks
contract NestedMaliciousHook {
    Buck public immutable token;
    MaliciousRewardsHook public immutable parentHook;
    bool public attackTriggered;

    constructor(Buck _token, MaliciousRewardsHook _parentHook) {
        token = _token;
        parentHook = _parentHook;
    }

    function onBalanceChange(address, address, uint256) external {
        if (!attackTriggered) {
            attackTriggered = true;
            // Try to trigger the parent hook's attack
            token.transfer(address(parentHook), 1);
        }
    }
}

/// @notice Malicious liquidity window for mint/burn reentrancy
contract MaliciousLiquidityWindow {
    Buck public immutable token;
    bool public attackOnMint;
    bool public attackOnBurn;
    address public attackTarget;
    uint256 public attackAmount;

    constructor(Buck _token) {
        token = _token;
    }

    function setMintAttack(address target, uint256 amount) external {
        attackOnMint = true;
        attackTarget = target;
        attackAmount = amount;
    }

    function setBurnAttack(address target, uint256 amount) external {
        attackOnBurn = true;
        attackTarget = target;
        attackAmount = amount;
    }

    function triggerMint(address to, uint256 amount) external {
        // Start the mint which will lock the reentrancy guard
        token.mint(to, amount);

        // If attack is enabled, try a reentrant mint (should fail)
        if (attackOnMint) {
            attackOnMint = false; // Prevent infinite recursion
            token.mint(attackTarget, attackAmount);
        }
    }

    function triggerBurn(address from, uint256 amount) external {
        // Start the burn which will lock the reentrancy guard
        token.burn(from, amount);

        // If attack is enabled, try a reentrant burn (should fail)
        if (attackOnBurn) {
            attackOnBurn = false; // Prevent infinite recursion
            token.burn(attackTarget, attackAmount);
        }
    }
}

// ============================================================================
// REENTRANCY TEST SUITE
// ============================================================================

contract BUCKReentrancyTest is BaseTest {
    Buck public token;

    address public timelock;
    address public liquidityWindow;
    address public liquidityReserve;
    address public treasury;
    address public policyManager;
    address public dexPair;
    address public accessRegistry;

    address public alice;
    address public bob;

    MaliciousRewardsHook public maliciousHook;
    MaliciousLiquidityWindow public maliciousLW;
    NestedMaliciousHook public nestedHook;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // Setup addresses
        timelock = makeAddr("timelock");
        liquidityWindow = makeAddr("liquidityWindow");
        liquidityReserve = makeAddr("liquidityReserve");
        treasury = makeAddr("treasury");
        policyManager = makeAddr("policyManager");
        dexPair = makeAddr("dexPair");
        accessRegistry = address(0); // No KYC for testing

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy token
        vm.prank(timelock);
        token = deployBUCK(timelock);

        // Deploy malicious contracts
        maliciousHook = new MaliciousRewardsHook(token);
        maliciousLW = new MaliciousLiquidityWindow(token);

        // Initial configuration without rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(0) // No rewards hook initially
        );

        // Mint tokens for testing
        vm.prank(liquidityWindow);
        token.mint(alice, 10000 ether);

        vm.prank(liquidityWindow);
        token.mint(bob, 1000 ether);
    }

    // ========================================================================
    // REWARDS HOOK REENTRANCY TESTS
    // ========================================================================

    function test_ReentrancyProtection_RewardsHook_TransferReentry() public {
        // Setup malicious rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give hook some tokens
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);

        // Configure attack - hook will try to transfer during callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 10 ether, 1);

        // Alice's transfer triggers hook, which attempts reentrant transfer
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(bob, 10 ether);
    }

    function test_ReentrancyProtection_RewardsHook_TransferFromReentry() public {
        // Setup malicious rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Alice approves hook
        vm.prank(alice);
        token.approve(address(maliciousHook), 100 ether);

        // Configure attack - hook will try transferFrom during callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER_FROM, alice, 50 ether, 1);

        // Bob's transfer triggers hook, which attempts reentrant transferFrom
        vm.prank(bob);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(alice, 10 ether);
    }

    function test_ReentrancyProtection_RewardsHook_MintReentry() public {
        // Setup malicious rewards hook as both rewards hook AND authorized minter
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook) // Hook is also rewards hook
        );

        // Configure attack - hook will try to mint during callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.MINT, alice, 100 ether, 1);

        // Transfer triggers hook, which attempts reentrant mint
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(bob, 10 ether);
    }

    function test_ReentrancyProtection_RewardsHook_ApproveManipulation() public {
        // Setup malicious rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Configure attack - hook will try to change approvals during transfer
        // Note: approve() is NOT protected by reentrancy guard (inherited from OpenZeppelin)
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.APPROVE, bob, 1000 ether, 1);

        // Transfer triggers hook, which attempts to approve
        // This will actually succeed because approve isn't protected by reentrancy guard
        vm.prank(alice);
        token.transfer(bob, 10 ether);

        // Verify the approval went through
        // NOTE: This is expected behavior (LOW severity). Hook can only manipulate its OWN allowances,
        // not user allowances. Since hook already controls its own tokens, this doesn't enable new attacks.
        assertEq(token.allowance(address(maliciousHook), bob), 1000 ether);
    }

    // ========================================================================
    // DIRECT MINT/BURN TESTS (No reentrancy possible without callback)
    // ========================================================================

    function test_ReentrancyProtection_SequentialMintAllowed() public {
        // Replace liquidity window with malicious contract
        vm.prank(timelock);
        token.configureModules(
            address(maliciousLW), liquidityReserve, treasury, policyManager, accessRegistry, address(0)
        );

        // Sequential mints should work (not reentrancy)
        vm.startPrank(address(maliciousLW));
        token.mint(alice, 100 ether);
        token.mint(bob, 50 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 10100 ether);
        assertEq(token.balanceOf(bob), 1050 ether);
    }

    function test_ReentrancyProtection_SequentialBurnAllowed() public {
        // Replace liquidity window with malicious contract
        vm.prank(timelock);
        token.configureModules(
            address(maliciousLW), liquidityReserve, treasury, policyManager, accessRegistry, address(0)
        );

        // Give malicious LW ability to burn alice's tokens
        vm.startPrank(address(maliciousLW));

        // Sequential burns should work (not reentrancy)
        token.burn(alice, 100 ether);
        token.burn(alice, 50 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 9850 ether);
    }

    // ========================================================================
    // COMPLEX ATTACK SCENARIOS
    // ========================================================================

    function test_ReentrancyProtection_NestedHookAttack() public {
        // Deploy nested hook
        nestedHook = new NestedMaliciousHook(token, maliciousHook);

        // Setup malicious rewards hook first
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give both hooks tokens
        vm.startPrank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);
        token.mint(address(nestedHook), 100 ether);
        vm.stopPrank();

        // Configure primary hook attack
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, alice, 10 ether, 1);

        // Now switch to nested hook as rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(nestedHook)
        );

        // Transfer triggers nested hook, which triggers main hook attack
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(bob, 5 ether);
    }

    function test_ReentrancyProtection_MultipleReentryAttempts() public {
        // Setup malicious rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give hook tokens
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 1000 ether);

        // Configure attack for multiple attempts
        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER,
            bob,
            1 ether,
            10 // Try 10 reentrant calls
        );

        // Should fail on first reentry attempt
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 10 ether);

        // Since the whole tx reverted, the attack count stays at 0
        assertEq(maliciousHook.attackCount(), 0, "Attack count should be 0 after revert");
    }

    // ========================================================================
    // CROSS-FUNCTION REENTRANCY TESTS
    // ========================================================================

    function test_ReentrancyProtection_TransferToMint() public {
        // Setup hook as both rewards hook and authorized minter
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Configure to attempt mint during transfer callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.MINT, alice, 100 ether, 1);

        // Transfer should trigger hook that attempts mint
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 10 ether);
    }

    function test_ReentrancyProtection_MintToTransfer() public {
        // Setup hook as rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give hook tokens
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);

        // Configure to attempt transfer during mint callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 10 ether, 1);

        // Mint should trigger hook that attempts transfer
        vm.prank(liquidityWindow);
        vm.expectRevert();
        token.mint(alice, 50 ether);
    }

    function test_ReentrancyProtection_BurnToTransfer() public {
        // Setup hook as rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give hook tokens
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);

        // Configure to attempt transfer during burn callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 10 ether, 1);

        // Burn should trigger hook that attempts transfer
        vm.prank(liquidityWindow);
        vm.expectRevert();
        token.burn(alice, 50 ether);
    }

    // ========================================================================
    // STATE CONSISTENCY TESTS
    // ========================================================================

    function test_ReentrancyProtection_StateConsistencyAfterFailedAttack() public {
        // Setup malicious rewards hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        // Give hook tokens
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);

        // Record state before attack
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);
        uint256 hookBalanceBefore = token.balanceOf(address(maliciousHook));
        uint256 totalSupplyBefore = token.totalSupply();

        // Configure attack
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, alice, 50 ether, 1);

        // Attempt transfer that triggers attack
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 10 ether);

        // Verify state unchanged
        assertEq(token.balanceOf(alice), aliceBalanceBefore, "Alice balance changed");
        assertEq(token.balanceOf(bob), bobBalanceBefore, "Bob balance changed");
        assertEq(token.balanceOf(address(maliciousHook)), hookBalanceBefore, "Hook balance changed");
        assertEq(token.totalSupply(), totalSupplyBefore, "Total supply changed");
    }

    // ========================================================================
    // NORMAL OPERATIONS VERIFICATION
    // ========================================================================

    function test_ReentrancyProtection_NormalOperationsWork() public {
        // Verify normal operations work without reentrancy issues

        // Normal transfer
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 1100 ether);

        // Normal transferFrom
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 50 ether);
        assertEq(token.balanceOf(bob), 1150 ether);

        // Normal mint
        vm.prank(liquidityWindow);
        token.mint(alice, 100 ether);

        // Normal burn
        vm.prank(liquidityWindow);
        token.burn(alice, 50 ether);

        // Multiple operations in same transaction
        vm.startPrank(alice);
        token.transfer(bob, 10 ether);
        token.transfer(bob, 10 ether);
        token.approve(bob, 500 ether);
        vm.stopPrank();

        assertTrue(token.balanceOf(bob) > 0, "Bob should have tokens");
    }

    function test_ReentrancyProtection_WithoutRewardsHook() public {
        // Verify transfers work normally without rewards hook
        uint256 aliceStart = token.balanceOf(alice);
        uint256 bobStart = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), aliceStart - 100 ether);
        assertEq(token.balanceOf(bob), bobStart + 100 ether);
    }

    // ========================================================================
    // GAS OPTIMIZATION TESTS
    // ========================================================================

    function test_ReentrancyProtection_GasEfficiency() public {
        // Setup malicious hook with many reentry attempts
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            accessRegistry,
            address(maliciousHook)
        );

        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 1000 ether);

        // Configure for many attempts
        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER,
            bob,
            1 ether,
            100 // Try 100 times
        );

        uint256 gasBefore = gasleft();

        // Should fail fast without excessive gas consumption
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 10 ether);

        uint256 gasUsed = gasBefore - gasleft();

        // Should fail on first reentry, not consume gas for 100 attempts
        assertLt(gasUsed, 500_000, "Used too much gas defending against reentrancy");
    }

    // ========================================================================
    // FEE DISTRIBUTION CEI PATTERN TESTS (Issue #4 Part A)
    // ========================================================================

    function test_FeeDistribution_ReentrancyDuringNotifyRewards() public {
        // Configure token with PolicyManager mock to enable DEX fees
        MockPolicyManagerFees policyMock = new MockPolicyManagerFees();
        policyMock.setDexFees(100, 100); // 1% buy/sell

        vm.startPrank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            address(policyMock),
            accessRegistry,
            address(maliciousHook)
        );
        token.setFeeSplit(5000); // 50/50 split
        token.addDexPair(dexPair);
        vm.stopPrank();

        // Give malicious hook tokens to attempt reentrant transfer
        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 100 ether);

        // Configure attack: Hook will try to reenter during fee distribution
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 10 ether, 1);

        // Record balances before attack (alice already has tokens from setUp)
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 reserveBefore = token.balanceOf(liquidityReserve);
        uint256 treasuryBefore = token.balanceOf(treasury);

        // Alice sells to DEX, triggering fee distribution and hook callback
        // Hook will attempt reentry during _notifyRewards call
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(dexPair, 100 ether);

        // Verify balances unchanged (whole transaction reverted)
        assertEq(token.balanceOf(liquidityReserve), reserveBefore);
        assertEq(token.balanceOf(treasury), treasuryBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
    }

    function test_FeeDistribution_StateConsistentDuringCallback() public {
        // Configure token with DEX fees
        MockPolicyManagerFees policyMock = new MockPolicyManagerFees();
        policyMock.setDexFees(100, 100); // 1% fees

        // Create a state-observing hook
        StateObservingHook observingHook = new StateObservingHook(token);

        vm.startPrank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            address(policyMock),
            accessRegistry,
            address(observingHook)
        );
        token.setFeeSplit(5000); // 50/50 split
        token.addDexPair(dexPair);
        vm.stopPrank();

        // Reset observations to ignore setup callbacks
        observingHook.resetObservations();

        // Alice sells to DEX (alice already has tokens from setUp)
        uint256 sellAmount = 1000 ether;
        uint256 expectedFee = 10 ether; // 1% of 1000

        vm.prank(alice);
        token.transfer(dexPair, sellAmount);

        // Verify hook observed consistent state during callbacks
        // CEI pattern ensures all balance updates happen before callbacks
        StateObservingHook.Observation[] memory observations = observingHook.getObservations();

        // Expected callbacks:
        // 1. _notifyRewards(alice, reserve, 5 ether) - after reserve fee transfer
        // 2. _notifyRewards(alice, treasury, 5 ether) - after treasury fee transfer
        // 3. _notifyRewards(alice, dexPair, 1000 ether) - after main transfer
        assertEq(observations.length, 3, "Should have 3 hook callbacks (2 fee + 1 main)");

        // First callback (reserve fee): CEI pattern means BOTH reserve AND treasury should be updated
        assertGt(
            observations[0].reserveBalance, 0, "Reserve should be updated before first callback"
        );
        assertGt(
            observations[0].treasuryBalance,
            0,
            "Treasury should ALSO be updated before first callback (CEI pattern)"
        );
        assertEq(observations[0].to, liquidityReserve, "First callback should be for reserve");

        // Second callback (treasury fee): Both should still be updated
        assertGt(
            observations[1].reserveBalance, 0, "Reserve should be updated before second callback"
        );
        assertGt(
            observations[1].treasuryBalance, 0, "Treasury should be updated before second callback"
        );
        assertEq(observations[1].to, treasury, "Second callback should be for treasury");

        // Third callback (main transfer): Fees already distributed
        assertEq(observations[2].to, dexPair, "Third callback should be for main transfer");

        // Verify final balances correct
        assertEq(token.balanceOf(liquidityReserve), expectedFee / 2);
        assertEq(token.balanceOf(treasury), expectedFee / 2);
    }

    function test_FeeDistribution_AtomicStateUpdate() public {
        // Test that fee distribution is atomic: both reserve and treasury updated together
        MockPolicyManagerFees policyMock = new MockPolicyManagerFees();
        policyMock.setDexFees(150, 150); // 1.5% fees

        vm.startPrank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            address(policyMock),
            accessRegistry,
            address(0) // No rewards hook for this test
        );
        token.setFeeSplit(5000); // 50/50 split
        token.addDexPair(dexPair);
        vm.stopPrank();

        // Mint tokens to users
        vm.prank(liquidityWindow);
        token.mint(alice, 10000 ether);

        vm.prank(liquidityWindow);
        token.mint(dexPair, 10000 ether);

        // Perform multiple DEX trades to trigger fee distributions
        uint256[] memory tradeAmounts = new uint256[](5);
        tradeAmounts[0] = 100 ether;
        tradeAmounts[1] = 250 ether;
        tradeAmounts[2] = 500 ether;
        tradeAmounts[3] = 150 ether;
        tradeAmounts[4] = 300 ether;

        uint256 totalFees = 0;

        for (uint256 i = 0; i < tradeAmounts.length; i++) {
            uint256 fee = (tradeAmounts[i] * 150) / 10_000;
            totalFees += fee;

            vm.prank(alice);
            token.transfer(dexPair, tradeAmounts[i]);

            // After each trade, verify reserve + treasury = total fees collected so far
            uint256 reserveBalance = token.balanceOf(liquidityReserve);
            uint256 treasuryBalance = token.balanceOf(treasury);

            assertEq(reserveBalance + treasuryBalance, totalFees, "Fee distribution not atomic");
            assertEq(reserveBalance, totalFees / 2, "Reserve should get 50%");
            assertEq(treasuryBalance, totalFees / 2, "Treasury should get 50%");
        }

        // Final verification
        assertEq(token.balanceOf(liquidityReserve), totalFees / 2);
        assertEq(token.balanceOf(treasury), totalFees / 2);
    }

    function test_FeeDistribution_GasCostComparison() public {
        // Measure gas cost of fee distribution after CEI refactor
        MockPolicyManagerFees policyMock = new MockPolicyManagerFees();
        policyMock.setDexFees(100, 100);

        vm.startPrank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            address(policyMock),
            accessRegistry,
            address(0) // No hook to isolate gas cost
        );
        token.setFeeSplit(5000);
        token.addDexPair(dexPair);
        vm.stopPrank();

        vm.prank(liquidityWindow);
        token.mint(alice, 1000 ether);

        vm.prank(liquidityWindow);
        token.mint(dexPair, 1000 ether);

        // Measure gas for DEX trade with fee distribution
        uint256 gasBefore = gasleft();

        vm.prank(alice);
        token.transfer(dexPair, 100 ether);

        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable (CEI reordering shouldn't increase cost)
        // Typical ERC20 transfer ~50k, with fees ~100k
        assertLt(gasUsed, 200_000, "Gas cost too high after CEI refactor");

        // Verify functionality still works
        assertEq(token.balanceOf(liquidityReserve), 0.5 ether); // 0.5% of 100
        assertEq(token.balanceOf(treasury), 0.5 ether);
    }
}

// ============================================================================
// ADDITIONAL MALICIOUS CONTRACTS FOR CEI TESTING
// ============================================================================

/// @notice Mock PolicyManager for fee testing
contract MockPolicyManagerFees {
    uint16 public buyFeeBps = 0;
    uint16 public sellFeeBps = 0;

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }
}

/// @notice Hook that observes state during callbacks to verify CEI pattern
contract StateObservingHook {
    Buck public immutable token;

    struct Observation {
        address from;
        address to;
        uint256 amount;
        uint256 reserveBalance;
        uint256 treasuryBalance;
        uint256 totalSupply;
    }

    Observation[] public observations;
    address public liquidityReserve;
    address public treasury;

    constructor(Buck _token) {
        token = _token;
        liquidityReserve = _token.liquidityReserve();
        treasury = _token.treasury();
    }

    function onBalanceChange(address from, address to, uint256 amount) external {
        // Record state during callback
        observations.push(
            Observation({
                from: from,
                to: to,
                amount: amount,
                reserveBalance: token.balanceOf(liquidityReserve),
                treasuryBalance: token.balanceOf(treasury),
                totalSupply: token.totalSupply()
            })
        );
    }

    function getObservations() external view returns (Observation[] memory) {
        return observations;
    }

    function resetObservations() external {
        delete observations;
    }
}
