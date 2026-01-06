// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";

/**
 * @title BUCKReentrancyFuzz
 * @notice FUZZ TESTS: Reentrancy protection with random amounts and attack sequences
 * @dev Sprint 30 - Fuzz Testing for Audit Fixes
 *      Tests that reentrancy guards block all attack vectors with random inputs
 */
contract BUCKReentrancyFuzz is BaseTest {
    Buck public token;

    address public timelock;
    address public liquidityWindow;
    address public liquidityReserve;
    address public treasury;
    address public policyManager;
    address public dexPair;

    address public alice;
    address public bob;

    MaliciousRewardsHook public maliciousHook;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // Setup addresses
        timelock = makeAddr("timelock");
        liquidityWindow = makeAddr("liquidityWindow");
        liquidityReserve = makeAddr("liquidityReserve");
        treasury = makeAddr("treasury");
        policyManager = makeAddr("policyManager");
        dexPair = makeAddr("dexPair");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy token
        vm.prank(timelock);
        token = deployBUCK(timelock);

        // Deploy malicious hook
        maliciousHook = new MaliciousRewardsHook(token);

        // Configure token with malicious hook
        vm.prank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            policyManager,
            address(0), // No KYC
            address(maliciousHook)
        );

        // Mint initial tokens
        vm.prank(liquidityWindow);
        token.mint(alice, 1_000_000 ether);

        vm.prank(liquidityWindow);
        token.mint(bob, 1_000_000 ether);

        vm.prank(liquidityWindow);
        token.mint(address(maliciousHook), 1_000_000 ether);
    }

    // ============================================================================
    // FUZZ TEST 1: Random transfer amounts during reentrancy
    // ============================================================================

    /// @notice Fuzz: Reentrancy blocked for random transfer amounts
    /// @dev Tests that reentrancy guard works for any amount
    function testFuzz_ReentrancyBlockedForRandomTransferAmounts(
        uint256 userAmount,
        uint256 attackAmount
    ) public {
        // Bound amounts to valid ranges
        userAmount = bound(userAmount, 1 ether, 100_000 ether);
        attackAmount = bound(attackAmount, 1 ether, 100_000 ether);

        // Configure attack: Hook will try to transfer during callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, attackAmount, 1);

        // Alice's transfer triggers hook, which attempts reentrant transfer
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(bob, userAmount);

        // Verify no state changed
        assertEq(token.balanceOf(alice), 1_000_000 ether, "Alice balance unchanged");
        assertEq(token.balanceOf(bob), 1_000_000 ether, "Bob balance unchanged");
    }

    /// @notice Fuzz: Reentrancy blocked for random transferFrom amounts
    function testFuzz_ReentrancyBlockedForRandomTransferFromAmounts(
        uint256 userAmount,
        uint256 attackAmount
    ) public {
        userAmount = bound(userAmount, 1 ether, 100_000 ether);
        attackAmount = bound(attackAmount, 1 ether, 100_000 ether);

        // Alice approves hook
        vm.prank(alice);
        token.approve(address(maliciousHook), type(uint256).max);

        // Configure attack: Hook will try transferFrom during callback
        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER_FROM, alice, attackAmount, 1
        );

        // Bob's transfer triggers hook attack
        vm.prank(bob);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(alice, userAmount);
    }

    /// @notice Fuzz: Reentrancy blocked for random mint amounts
    function testFuzz_ReentrancyBlockedForRandomMintAmounts(
        uint256 userAmount,
        uint256 attackMintAmount
    ) public {
        userAmount = bound(userAmount, 1 ether, 100_000 ether);
        attackMintAmount = bound(attackMintAmount, 1 ether, 500_000 ether);

        // Configure attack: Hook will try to mint during callback
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.MINT, alice, attackMintAmount, 1);

        // Transfer triggers hook, which attempts reentrant mint
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(bob, userAmount);
    }

    // ============================================================================
    // FUZZ TEST 2: Random number of attack attempts
    // ============================================================================

    /// @notice Fuzz: Multiple random reentry attempts all fail
    /// @dev Tests that reentrancy guard doesn't degrade after many attempts
    function testFuzz_MultipleReentryAttemptsFail(uint256 transferAmount, uint8 numAttempts)
        public
    {
        transferAmount = bound(transferAmount, 1 ether, 10_000 ether);
        numAttempts = uint8(bound(numAttempts, 1, 50));

        // Configure for multiple attack attempts
        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER,
            bob,
            1 ether,
            numAttempts // Try N times
        );

        // Should fail on first reentry attempt (whole tx reverts)
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, transferAmount);

        // Verify attack count is still 0 (tx reverted before multiple attempts)
        assertEq(maliciousHook.attackCount(), 0, "Attack should fail immediately");
    }

    // ============================================================================
    // FUZZ TEST 3: Random attack vectors
    // ============================================================================

    /// @notice Fuzz: Random attack types all blocked
    /// @dev Tests all attack vectors with random selection
    function testFuzz_RandomAttackTypesBlocked(
        uint8 attackTypeIndex,
        uint256 transferAmount,
        uint256 attackAmount
    ) public {
        transferAmount = bound(transferAmount, 1 ether, 50_000 ether);
        attackAmount = bound(attackAmount, 1 ether, 50_000 ether);

        // Map index to attack type (0-3 are valid attack types)
        MaliciousRewardsHook.AttackType attackType;
        if (attackTypeIndex % 4 == 0) {
            attackType = MaliciousRewardsHook.AttackType.TRANSFER;
        } else if (attackTypeIndex % 4 == 1) {
            attackType = MaliciousRewardsHook.AttackType.TRANSFER_FROM;
            // Setup approval for transferFrom attack
            vm.prank(alice);
            token.approve(address(maliciousHook), type(uint256).max);
        } else if (attackTypeIndex % 4 == 2) {
            attackType = MaliciousRewardsHook.AttackType.MINT;
        } else {
            attackType = MaliciousRewardsHook.AttackType.BURN;
        }

        // Configure attack
        maliciousHook.setAttack(attackType, alice, attackAmount, 1);

        // Transfer should trigger reentrancy protection
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, transferAmount);
    }

    // ============================================================================
    // FUZZ TEST 4: Random actors and targets
    // ============================================================================

    /// @notice Fuzz: Reentrancy blocked for random sender/receiver combinations
    function testFuzz_ReentrancyBlockedForRandomActors(
        address sender,
        address receiver,
        uint256 amount
    ) public {
        // Bound inputs
        vm.assume(sender != address(0) && receiver != address(0));
        vm.assume(sender != receiver);
        vm.assume(sender != address(token));
        vm.assume(receiver != address(token));
        amount = bound(amount, 1, 100_000 ether);

        // Give sender tokens
        vm.prank(liquidityWindow);
        token.mint(sender, amount * 2);

        // Configure attack
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, receiver, 1 ether, 1);

        // Random sender transfers to random receiver
        vm.prank(sender);
        vm.expectRevert();
        token.transfer(receiver, amount);
    }

    // ============================================================================
    // FUZZ TEST 5: Fee distribution reentrancy with random amounts
    // ============================================================================

    /// @notice Fuzz: Fee distribution reentrancy blocked for random amounts
    /// @dev Tests CEI pattern with random DEX trade amounts
    function testFuzz_FeeDistributionReentrancyBlocked(uint256 sellAmount) public {
        sellAmount = bound(sellAmount, 1 ether, 100_000 ether);

        // Configure token with DEX fees
        MockPolicyManagerFees policyMock = new MockPolicyManagerFees();
        policyMock.setDexFees(100, 100); // 1% fees

        vm.startPrank(timelock);
        token.configureModules(
            liquidityWindow,
            liquidityReserve,
            treasury,
            address(policyMock),
            address(0),
            address(maliciousHook)
        );
        token.setFeeSplit(5000); // 50/50 split
        token.addDexPair(dexPair);
        vm.stopPrank();

        // Configure attack: Hook will try to reenter during fee distribution
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 1 ether, 1);

        uint256 aliceBefore = token.balanceOf(alice);

        // Alice sells to DEX, triggering fee distribution
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to reentrancy guard
        token.transfer(dexPair, sellAmount);

        // Verify balances unchanged
        assertEq(token.balanceOf(alice), aliceBefore, "Alice balance unchanged");
    }

    // ============================================================================
    // FUZZ TEST 6: State consistency with random operations
    // ============================================================================

    /// @notice Fuzz: State remains consistent after failed reentrancy attempts
    function testFuzz_StateConsistencyAfterFailedAttack(
        uint256 aliceAmount,
        uint256 bobAmount,
        uint256 attackAmount
    ) public {
        aliceAmount = bound(aliceAmount, 1 ether, 50_000 ether);
        bobAmount = bound(bobAmount, 1 ether, 50_000 ether);
        attackAmount = bound(attackAmount, 1 ether, 100_000 ether);

        // Record state before attack
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);
        uint256 hookBalanceBefore = token.balanceOf(address(maliciousHook));
        uint256 totalSupplyBefore = token.totalSupply();

        // Configure attack
        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, alice, attackAmount, 1);

        // Attempt transfer that triggers attack
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, aliceAmount);

        // Verify state unchanged
        assertEq(token.balanceOf(alice), aliceBalanceBefore, "Alice balance unchanged");
        assertEq(token.balanceOf(bob), bobBalanceBefore, "Bob balance unchanged");
        assertEq(
            token.balanceOf(address(maliciousHook)), hookBalanceBefore, "Hook balance unchanged"
        );
        assertEq(token.totalSupply(), totalSupplyBefore, "Total supply unchanged");
    }

    // ============================================================================
    // FUZZ TEST 7: Rapid sequential attacks with random timing
    // ============================================================================

    /// @notice Fuzz: Rapid attacks at random intervals all fail
    function testFuzz_RapidAttacksAtRandomIntervalsFail(
        uint256[10] memory amounts,
        uint256[10] memory timeDelays
    ) public {
        for (uint256 i = 0; i < amounts.length; i++) {
            // Bound inputs
            amounts[i] = bound(amounts[i], 1 ether, 10_000 ether);
            timeDelays[i] = bound(timeDelays[i], 1, 1 hours);

            // Advance time
            vm.warp(block.timestamp + timeDelays[i]);

            // Configure fresh attack
            maliciousHook.disableAttack();
            maliciousHook.setAttack(MaliciousRewardsHook.AttackType.TRANSFER, bob, 1 ether, 1);

            // Attack should fail
            vm.prank(alice);
            vm.expectRevert();
            token.transfer(bob, amounts[i]);
        }

        // Verify Alice's balance unchanged after all attacks
        assertEq(token.balanceOf(alice), 1_000_000 ether, "Alice balance should be unchanged");
    }

    // ============================================================================
    // FUZZ TEST 8: Cross-function reentrancy with random amounts
    // ============================================================================

    /// @notice Fuzz: Transfer → Mint reentrancy blocked for random amounts
    function testFuzz_TransferToMintReentrancyBlocked(uint256 transferAmount, uint256 mintAmount)
        public
    {
        transferAmount = bound(transferAmount, 1 ether, 50_000 ether);
        mintAmount = bound(mintAmount, 1 ether, 100_000 ether);

        maliciousHook.setAttack(MaliciousRewardsHook.AttackType.MINT, alice, mintAmount, 1);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, transferAmount);
    }

    /// @notice Fuzz: Mint → Transfer reentrancy blocked for random amounts
    function testFuzz_MintToTransferReentrancyBlocked(
        uint256 mintAmount,
        uint256 attackTransferAmount
    ) public {
        mintAmount = bound(mintAmount, 1 ether, 100_000 ether);
        attackTransferAmount = bound(attackTransferAmount, 1 ether, 50_000 ether);

        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER, bob, attackTransferAmount, 1
        );

        vm.prank(liquidityWindow);
        vm.expectRevert();
        token.mint(alice, mintAmount);
    }

    /// @notice Fuzz: Burn → Transfer reentrancy blocked for random amounts
    function testFuzz_BurnToTransferReentrancyBlocked(
        uint256 burnAmount,
        uint256 attackTransferAmount
    ) public {
        burnAmount = bound(burnAmount, 1 ether, 50_000 ether);
        attackTransferAmount = bound(attackTransferAmount, 1 ether, 50_000 ether);

        maliciousHook.setAttack(
            MaliciousRewardsHook.AttackType.TRANSFER, bob, attackTransferAmount, 1
        );

        vm.prank(liquidityWindow);
        vm.expectRevert();
        token.burn(alice, burnAmount);
    }
}

// ============================================================================
// MALICIOUS CONTRACTS FOR FUZZ TESTING
// ============================================================================

/// @notice Malicious rewards hook that attempts reentrancy during callback
contract MaliciousRewardsHook {
    Buck public immutable token;

    bool public attackEnabled;
    uint256 public attackCount;
    uint256 public maxAttacks = 1;

    enum AttackType {
        NONE,
        TRANSFER,
        TRANSFER_FROM,
        MINT,
        BURN
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

    function onBalanceChange(address, address, uint256) external {
        if (!attackEnabled || attackCount >= maxAttacks) return;
        attackCount++;

        if (currentAttack == AttackType.TRANSFER) {
            token.transfer(attackTarget, attackAmount);
        } else if (currentAttack == AttackType.TRANSFER_FROM) {
            token.transferFrom(attackTarget, address(this), attackAmount);
        } else if (currentAttack == AttackType.MINT) {
            token.mint(attackTarget, attackAmount);
        } else if (currentAttack == AttackType.BURN) {
            token.burn(attackTarget, attackAmount);
        }
    }
}

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
