// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck} from "src/token/Buck.sol";

// Mock contracts for testing
contract MockAccessRegistryFuzz {
    mapping(address => bool) public allowed;
    mapping(address => bool) public isDenylisted;

    function isAllowed(address account) external view returns (bool) {
        return allowed[account];
    }

    function allow(address account) external {
        allowed[account] = true;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

contract MockRewardsHookFuzz {
    uint256 public callCount;
    mapping(address => uint256) public balanceChanges;

    function onBalanceChange(address from, address to, uint256 /*amount*/ ) external {
        callCount++;
        if (from != address(0)) balanceChanges[from]++;
        if (to != address(0)) balanceChanges[to]++;
    }
}

contract MockDexPair {
    Buck public token;
    uint256 public reserves;

    function setToken(Buck _token) external {
        token = _token;
    }

    function seedReserves(uint256 amount) external {
        reserves = amount;
    }

    function getReserves() external view returns (uint256) {
        return reserves;
    }

    function simulateBuy(address buyer, uint256 amount) external {
        // Simulate DEX buying from user (user sells to pool)
        token.transferFrom(buyer, address(this), amount);
        reserves += amount;
    }

    function simulateSell(address seller, uint256 amount) external {
        // Simulate DEX selling to user (user buys from pool)
        require(reserves >= amount, "Insufficient reserves");
        token.transfer(seller, amount);
        reserves -= amount;
    }
}

contract MockPolicyManagerFuzz {
    uint16 public buyFeeBps;
    uint16 public sellFeeBps;

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        require(_buyFee <= 200 && _sellFee <= 200, "Fee too high");
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }
}

/**
 * @title STRCFeeFuzzTest
 * @notice Fuzz tests for STRC token fee mechanics
 * @dev Tests fee collection, distribution, and edge cases with random inputs
 */
contract BUCKFeeFuzzTest is BaseTest {
    Buck public buck;
    MockAccessRegistryFuzz public kyc;
    MockRewardsHookFuzz public rewards;
    MockDexPair public dexPair;
    MockPolicyManagerFuzz public policyManager;

    address constant TIMELOCK = address(0x1111);
    address constant LIQUIDITY_WINDOW = address(0x2222);
    address constant LIQUIDITY_RESERVE = address(0x3333);
    address constant TREASURY = address(0x4444);
    address constant LIQUIDITY_STEWARD = address(0x6666);

    uint256 constant NUM_USERS = 10;
    address[] public users;

    // Tracking variables for invariant checks
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalFeesCollected;

    function setUp() public {
        // Deploy mocks
        kyc = new MockAccessRegistryFuzz();
        rewards = new MockRewardsHookFuzz();
        dexPair = new MockDexPair();
        policyManager = new MockPolicyManagerFuzz();

        // Deploy STRC
        buck = deployBUCK(TIMELOCK);

        // Configure modules
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(kyc),
            address(rewards)
        );

        // Set up DEX pair
        vm.prank(TIMELOCK);
        buck.addDexPair(address(dexPair));
        dexPair.setToken(buck);

        // Configure fees (70% to reserve)
        // Note: DEX fees (buy/sell) are now set via PolicyManager, not BUCK token
        vm.prank(TIMELOCK);
        buck.setFeeSplit(7000);

        // Set default DEX fees for testing (1% buy, 1% sell)
        policyManager.setDexFees(100, 100); // 100 bps = 1%

        // Set up liquidity steward as fee exempt
        vm.prank(TIMELOCK);
        buck.setFeeExempt(LIQUIDITY_STEWARD, true);

        // Create test users and KYC them
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(0x7000 + i));
            users.push(user);
            kyc.allow(user);
        }

        // KYC system accounts
        kyc.allow(LIQUIDITY_WINDOW);
        kyc.allow(LIQUIDITY_RESERVE);
        kyc.allow(TREASURY);
        kyc.allow(address(policyManager));
        kyc.allow(LIQUIDITY_STEWARD);
        kyc.allow(address(dexPair));

        // Initial mint to DEX pair
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(address(dexPair), 1_000_000e18);
        dexPair.seedReserves(1_000_000e18);
        totalMinted = 1_000_000e18;
    }

    /**
     * @notice Test fee exemption logic under various conditions
     */
    function testFuzzFeeExemption(
        uint8[10] memory exemptOps,
        address[10] memory addresses,
        uint96[10] memory amounts
    ) public {
        for (uint256 i = 0; i < exemptOps.length; i++) {
            uint8 op = exemptOps[i] % 3;
            address addr = addresses[i];

            // Skip invalid or system addresses
            if (addr == address(0)) continue;
            if (addr == address(dexPair)) continue;
            if (addr == LIQUIDITY_WINDOW) continue;
            if (addr == LIQUIDITY_RESERVE) continue;
            if (addr == TREASURY) continue;

            // KYC the address first
            kyc.allow(addr);

            if (op == 0) {
                // Set fee exempt
                vm.prank(TIMELOCK);
                buck.setFeeExempt(addr, true);
                assertTrue(buck.isFeeExempt(addr));
            } else if (op == 1) {
                // Remove fee exemption
                vm.prank(TIMELOCK);
                buck.setFeeExempt(addr, false);
                assertFalse(buck.isFeeExempt(addr));
            } else {
                // Test trading with current exemption status
                uint256 amount = bound(uint256(amounts[i]), 1e16, 10_000e18);

                // Ensure user has sufficient balance
                uint256 currentBalance = buck.balanceOf(addr);
                if (currentBalance < amount) {
                    vm.prank(LIQUIDITY_WINDOW);
                    buck.mint(addr, amount - currentBalance);
                }

                uint256 preBal = buck.balanceOf(address(dexPair));
                vm.prank(addr);
                buck.transfer(address(dexPair), amount);
                uint256 postBal = buck.balanceOf(address(dexPair));

                assertGe(postBal, preBal, "DEX balance decreased unexpectedly");

                if (buck.isFeeExempt(addr)) {
                    // No fees should be taken
                    assertEq(postBal - preBal, amount, "Fee taken from exempt address");
                } else {
                    // Fees should be taken
                    assertLt(postBal - preBal, amount, "No fee taken from non-exempt address");
                }
            }
        }
    }

    /**
     * @notice Test fee parameter bounds and edge cases
     */
    function testFuzzFeeParameterBounds(
        uint16[10] memory buyFees,
        uint16[10] memory sellFees,
        uint16[10] memory feeSplits
    ) public {
        for (uint256 i = 0; i < buyFees.length; i++) {
            uint16 buyFee = buyFees[i];
            uint16 sellFee = sellFees[i];
            uint16 feeSplit = feeSplits[i];

            vm.startPrank(TIMELOCK);

            // Test buy/sell fee bounds (max 200 = 2%) - now on PolicyManager
            if (buyFee <= 200 && sellFee <= 200) {
                policyManager.setDexFees(buyFee, sellFee);
                (uint16 currentBuy, uint16 currentSell) = policyManager.getDexFees();
                assertEq(currentBuy, buyFee);
                assertEq(currentSell, sellFee);
            } else {
                // MockPolicyManagerFuzz will revert on fees > 200
                try policyManager.setDexFees(buyFee, sellFee) {
                    // Should not succeed if either fee > 200
                    assertTrue(buyFee <= 200 && sellFee <= 200, "Fee validation failed");
                } catch {
                    // Expected to revert
                }
            }

            // Fee split bounds (0-10000 = 0-100%)
            if (feeSplit <= 10000) {
                buck.setFeeSplit(feeSplit);
                assertEq(buck.feeToReservePct(), feeSplit);
            } else {
                vm.expectRevert(Buck.InvalidFee.selector);
                buck.setFeeSplit(feeSplit);
            }

            vm.stopPrank();
        }
    }
}
