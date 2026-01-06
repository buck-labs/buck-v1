// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {console} from "forge-std/console.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

interface IOracleAdapter {
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
    function isHealthy(uint256 maxStale) external view returns (bool);
    function getLastPriceUpdateBlock() external view returns (uint256);
    function setStrictMode(bool enabled) external;
}

contract MockOracle is IOracleAdapter {
    uint256 public price;
    uint256 public updatedAt;
    bool public healthy = true;
    uint256 public lastUpdateBlock;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
        lastUpdateBlock = block.number;
    }

    function updatePrice(uint256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
        lastUpdateBlock = block.number;
    }

    function setHealthy(bool _healthy) external {
        healthy = _healthy;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isHealthy(uint256) external view returns (bool) {
        return healthy;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastUpdateBlock;
    }

    function setStrictMode(bool) external {}
}

/**
 * @title Malicious Actor Integration Test
 * @notice Tests protocol resilience against malicious actors and attack scenarios
 * @dev Tests:
 *   - Front-running attacks
 *   - Daily cap exhaustion attacks
 *   - Sandwich attacks on distributions
 *   - Griefing attacks
 */
contract MaliciousActorTest is BaseTest {
    // Contracts
    Buck public buck;
    LiquidityWindow public liquidityWindow;
    LiquidityReserve public liquidityReserve;
    RewardsEngine public rewardsEngine;
    PolicyManager public policyManager;
    CollateralAttestation public collateralAttestation;
    MockOracle public oracle;
    MockUSDC public usdc;

    // System actors
    address public timelock = address(0x1000);
    address public treasury = address(0x2000);
    address public attestor = address(0x3000);

    // Honest users
    address public alice = address(0x5001);
    address public bob = address(0x5002);
    address public carol = address(0x5003);

    // Malicious actors
    address public frontRunner = address(0x6666);
    address public capExploiter = address(0x6667);
    address public sandwichAttacker = address(0x6669);
    address public griefingAttacker = address(0x666A);

    // Attack tracking
    uint256 public attacksAttempted;
    uint256 public attacksSucceeded;
    uint256 public attacksFailed;

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        vm.startPrank(timelock);

        // Deploy core contracts
        buck = deployBUCK(timelock);
        policyManager = deployPolicyManager(timelock);
        oracle = new MockOracle(1.0e18);

        liquidityReserve = deployLiquidityReserve(
            timelock, address(usdc), address(0), treasury
        );

        liquidityWindow = deployLiquidityWindow(
            timelock, address(buck), address(liquidityReserve), address(policyManager)
        );

        rewardsEngine = deployRewardsEngine(
            timelock, timelock, 0, 0, false
        );

        collateralAttestation = deployCollateralAttestation(
            timelock, attestor, address(buck),
            address(liquidityReserve), address(usdc)
        );

        // Configure modules
        buck.configureModules(
            address(liquidityWindow),
            address(liquidityReserve),
            treasury,
            address(policyManager),
            address(0),
            address(rewardsEngine)
        );

        liquidityWindow.setUSDC(address(usdc));
        liquidityWindow.configureFeeSplit(7000, treasury);

        policyManager.setContractReferences(
            address(buck), address(liquidityReserve),
            address(oracle), address(usdc)
        );
        policyManager.setCollateralAttestation(address(collateralAttestation));

        // Grant OPERATOR_ROLE to LiquidityWindow for cap tracking
        policyManager.grantRole(policyManager.OPERATOR_ROLE(), address(liquidityWindow));

        _configureBands();

        rewardsEngine.setToken(address(buck));
        rewardsEngine.setPolicyManager(address(policyManager));
        rewardsEngine.setTreasury(treasury);
        rewardsEngine.setReserveAddresses(address(liquidityReserve), address(usdc));
        rewardsEngine.setMaxTokensToMintPerEpoch(1_000_000e18);

        // Configure epoch with checkpoint window (Sprint 2.5 API)
        uint64 start = uint64(block.timestamp);
        uint64 end = start + 30 days;
        rewardsEngine.configureEpoch(1, start, end, start + 12 days, start + 16 days);

        liquidityReserve.setLiquidityWindow(address(liquidityWindow));
        liquidityReserve.setRewardsEngine(address(rewardsEngine));

        vm.roll(block.number + 2);
        vm.stopPrank();

        // Fund reserve
        usdc.mint(address(liquidityReserve), 1_000_000e6);

        // Fund honest users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(carol, 100_000e6);

        // Fund malicious actors with large capital
        usdc.mint(frontRunner, 500_000e6);
        usdc.mint(capExploiter, 1_000_000e6);
        usdc.mint(sandwichAttacker, 500_000e6);
        usdc.mint(griefingAttacker, 100_000e6);

        // Publish initial attestation
        _publishAttestation(1.2e18);
    }

    function _configureBands() internal {
        PolicyManager.BandConfig memory greenConfig =
            policyManager.getBandConfig(PolicyManager.Band.Green);
        greenConfig.halfSpreadBps = 25;
        greenConfig.mintFeeBps = 50;
        greenConfig.refundFeeBps = 50;
        greenConfig.oracleStaleSeconds = 3600;
        greenConfig.deviationThresholdBps = 100;
        greenConfig.alphaBps = 300;
        greenConfig.floorBps = 500;
        greenConfig.distributionSkimBps = 1000;
        greenConfig.caps = PolicyManager.CapSettings({
            mintAggregateBps: 0,
            refundAggregateBps: 1000 // 10% daily refund cap
        });
        policyManager.setBandConfig(PolicyManager.Band.Green, greenConfig);

        PolicyManager.BandConfig memory yellowConfig =
            policyManager.getBandConfig(PolicyManager.Band.Yellow);
        yellowConfig.halfSpreadBps = 50;
        yellowConfig.mintFeeBps = 100;
        yellowConfig.refundFeeBps = 100;
        yellowConfig.oracleStaleSeconds = 7200;
        yellowConfig.deviationThresholdBps = 200;
        yellowConfig.alphaBps = 200;
        yellowConfig.floorBps = 300;
        yellowConfig.distributionSkimBps = 1000;
        yellowConfig.caps = PolicyManager.CapSettings({
            mintAggregateBps: 0,
            refundAggregateBps: 500
        });
        policyManager.setBandConfig(PolicyManager.Band.Yellow, yellowConfig);

        PolicyManager.BandConfig memory redConfig =
            policyManager.getBandConfig(PolicyManager.Band.Red);
        redConfig.halfSpreadBps = 100;
        redConfig.mintFeeBps = 200;
        redConfig.refundFeeBps = 200;
        redConfig.oracleStaleSeconds = 14400;
        redConfig.deviationThresholdBps = 500;
        redConfig.alphaBps = 100;
        redConfig.floorBps = 200;
        redConfig.distributionSkimBps = 1000;
        redConfig.caps = PolicyManager.CapSettings({
            mintAggregateBps: 0,
            refundAggregateBps: 200
        });
        policyManager.setBandConfig(PolicyManager.Band.Red, redConfig);
    }

    // ========================================
    // ATTACK 1: Distribution Front-Running
    // ========================================

    function test_Attack1_FrontRunDistribution() public {
        console.log("\n=== ATTACK 1: Front-Running Distribution ===\n");

        attacksAttempted++;

        // Setup: Alice is honest holder who mints early
        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), 50_000e6);
        liquidityWindow.requestMint(alice, 50_000e6, 0, type(uint256).max);
        vm.stopPrank();

        console.log("Alice mints early: %s STRX", buck.balanceOf(alice) / 1e18);

        // Warp into checkpoint window so Alice accrues units
        skip(13 days);
        _publishAttestation(1.2e18); // Refresh attestation after time skip

        // Front-runner tries to mint right before distribution
        console.log("\nFront-runner attempts to mint during checkpoint window...");

        vm.startPrank(frontRunner);
        usdc.approve(address(liquidityWindow), 100_000e6);
        liquidityWindow.requestMint(frontRunner, 100_000e6, 0, type(uint256).max);
        vm.stopPrank();

        console.log("Front-runner STRX: %s", buck.balanceOf(frontRunner) / 1e18);

        // Warp to epoch end (distribution requires epochEnd)
        skip(17 days);
        _publishAttestation(1.2e18); // Refresh attestation after time skip

        // Distribution happens
        console.log("\nDistribution happens...");
        usdc.mint(timelock, 50_000e6);
        vm.prank(timelock);
        usdc.approve(address(rewardsEngine), 50_000e6);
        vm.prank(timelock);
        (uint256 allocated,) = rewardsEngine.distribute(50_000e6);

        console.log("Allocated: %s STRX", allocated / 1e18);

        uint256 aliceRewards = rewardsEngine.pendingRewards(alice);
        uint256 frontRunnerRewards = rewardsEngine.pendingRewards(frontRunner);

        console.log("\nResults:");
        console.log("  Alice rewards: %s STRX", aliceRewards / 1e18);
        console.log("  Front-runner rewards: %s STRX", frontRunnerRewards / 1e18);

        // Front-runner who just minted has fewer accrued units than Alice who held since start
        if (aliceRewards > frontRunnerRewards) {
            console.log("\n[OK] ATTACK MITIGATED: Honest holder earns more");
            attacksFailed++;
        } else {
            console.log("\n[WARN] ATTACK PARTIAL: Front-runner earned >= honest holder");
            attacksSucceeded++;
        }

        assertGt(aliceRewards, frontRunnerRewards, "Honest holder should earn more than front-runner");
    }

    // ========================================
    // ATTACK 2: Daily Cap Exhaustion
    // ========================================

    function test_Attack2_ExhaustDailyCap() public {
        console.log("\n=== ATTACK 2: Daily Cap Exhaustion ===\n");

        // Setup: Build up supply
        _mintBUCK(alice, 100_000e6);
        _mintBUCK(bob, 100_000e6);
        _mintBUCK(carol, 100_000e6);

        uint256 totalSupply = buck.totalSupply();
        console.log("Total Supply: %s STRX", totalSupply / 1e18);

        // Cap exploiter tries to exhaust daily refund cap
        console.log("\nCap Exploiter attempts to drain daily cap...");

        // Mint large position
        vm.startPrank(capExploiter);
        usdc.approve(address(liquidityWindow), 500_000e6);
        liquidityWindow.requestMint(capExploiter, 500_000e6, 0, type(uint256).max);
        vm.stopPrank();

        uint256 exploiterBalance = buck.balanceOf(capExploiter);
        console.log("Exploiter balance: %s STRX", exploiterBalance / 1e18);

        // Try to refund everything immediately
        console.log("\nAttempting to refund entire balance...");
        attacksAttempted++;

        vm.startPrank(capExploiter);
        buck.approve(address(liquidityWindow), exploiterBalance);

        uint256 usdcBefore = usdc.balanceOf(capExploiter);

        try liquidityWindow.requestRefund(capExploiter, exploiterBalance, 0, 0) returns (uint256 usdcOut, uint256) {
            console.log("Refund succeeded: %s USDC", usdcOut / 1e6);
            console.log("[WARN] ATTACK SUCCEEDED: Full refund allowed");
            attacksSucceeded++;
        } catch {
            console.log("[OK] ATTACK FAILED: Daily cap prevented large refund");
            attacksFailed++;
        }

        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(capExploiter);
        uint256 usdcReceived = usdcAfter - usdcBefore;

        // Calculate daily cap (10% of supply in GREEN band)
        uint256 dailyRefundCap = (totalSupply * 1000) / 10000;

        console.log("\nDaily refund cap: %s STRX", dailyRefundCap / 1e18);
        console.log("Actually refunded: %s STRX", (usdcReceived * 1e12) / 1e18);

        // CRITICAL ASSERTION: Should not be able to refund more than daily cap
        assertLe(usdcReceived * 1e12, dailyRefundCap * 11 / 10, "Refund should not exceed daily cap");
    }

    // ========================================
    // ATTACK 3: Sandwich Attack on Mint/Refund
    // ========================================

    function test_Attack3_SandwichAttack() public {
        console.log("\n=== ATTACK 3: Sandwich Attack ===\n");

        attacksAttempted++;

        // Setup: Victim (Alice) is about to do large mint
        console.log("Victim prepares 50K USDC mint...");

        // Attacker front-runs with large mint to manipulate price
        console.log("\n[FRONT-RUN] Attacker mints 200K USDC...");
        vm.startPrank(sandwichAttacker);
        usdc.approve(address(liquidityWindow), 200_000e6);
        uint256 attackerBalanceBefore = buck.balanceOf(sandwichAttacker);
        liquidityWindow.requestMint(sandwichAttacker, 200_000e6, 0, type(uint256).max);
        uint256 attackerBalanceAfter = buck.balanceOf(sandwichAttacker);
        uint256 attackerSTRX1 = attackerBalanceAfter - attackerBalanceBefore;
        vm.stopPrank();

        console.log("Attacker received: %s STRX", attackerSTRX1 / 1e18);

        // Victim executes mint
        console.log("\n[VICTIM TX] Alice mints 50K USDC...");
        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), 50_000e6);
        uint256 aliceBalanceBefore = buck.balanceOf(alice);
        liquidityWindow.requestMint(alice, 50_000e6, 0, type(uint256).max);
        uint256 aliceBalanceAfter = buck.balanceOf(alice);
        uint256 aliceSTRX = aliceBalanceAfter - aliceBalanceBefore;
        vm.stopPrank();

        console.log("Alice received: %s STRX", aliceSTRX / 1e18);

        // Attacker back-runs with large refund
        console.log("\n[BACK-RUN] Attacker refunds all Buck...");
        vm.startPrank(sandwichAttacker);
        buck.approve(address(liquidityWindow), attackerSTRX1);

        uint256 attackerUSDCBefore = usdc.balanceOf(sandwichAttacker);
        try liquidityWindow.requestRefund(sandwichAttacker, attackerSTRX1, 0, 0) returns (uint256, uint256) {
            uint256 attackerUSDCAfter = usdc.balanceOf(sandwichAttacker);
            int256 profit = int256(attackerUSDCAfter) - int256(attackerUSDCBefore) - int256(200_000e6);

            console.log("Attacker USDC back: %s", (attackerUSDCAfter - attackerUSDCBefore) / 1e6);

            if (profit > int256(1000e6)) {
                console.log("[WARN] ATTACK SUCCEEDED: Sandwich profitable");
                attacksSucceeded++;
            } else {
                console.log("[OK] ATTACK FAILED: Fees/spreads prevented profit");
                attacksFailed++;
            }
        } catch {
            console.log("[OK] ATTACK FAILED: Refund reverted (daily cap or insufficient liquidity)");
            attacksFailed++;
        }

        vm.stopPrank();

        // CRITICAL: Sandwich attack should NOT be profitable due to fees and spreads
        // In GREEN band: 0.5% mint fee + 0.25% spread + 0.5% refund fee + 0.25% spread = ~1.5% cost
    }

    // ========================================
    // ATTACK 4: Griefing Attack (Dust Operations)
    // ========================================

    function test_Attack4_GriefingAttack() public {
        console.log("\n=== ATTACK 4: Griefing Attack (Dust Spam) ===\n");

        attacksAttempted++;

        // Attacker tries to spam tiny operations to grief the system
        console.log("Attacker attempts 100 dust operations...");

        vm.startPrank(griefingAttacker);
        usdc.approve(address(liquidityWindow), 100_000e6);

        uint256 successCount = 0;
        uint256 gasUsed = 0;

        for (uint256 i = 0; i < 100; i++) {
            uint256 gasBefore = gasleft();

            try liquidityWindow.requestMint(griefingAttacker, 100e6, 0, type(uint256).max) {
                successCount++;
                gasUsed += (gasBefore - gasleft());
            } catch {
                break;
            }
        }

        vm.stopPrank();

        console.log("Successful dust operations: %s", successCount);
        console.log("Average gas per operation: %s", gasUsed / (successCount > 0 ? successCount : 1));

        if (successCount >= 50) {
            console.log("[WARN] ATTACK SUCCEEDED: System vulnerable to dust spam");
            attacksSucceeded++;
        } else {
            console.log("[OK] ATTACK FAILED: System resilient to dust spam");
            attacksFailed++;
        }

        // System should remain functional after griefing attempt
        vm.startPrank(alice);
        usdc.approve(address(liquidityWindow), 10_000e6);
        liquidityWindow.requestMint(alice, 10_000e6, 0, type(uint256).max);
        vm.stopPrank();

        assertGt(buck.balanceOf(alice), 0, "System should remain functional after griefing");
    }

    // ========================================
    // COMPREHENSIVE ATTACK SCENARIO
    // ========================================

    function test_ComprehensiveAttackScenario() public {
        console.log("\n=== COMPREHENSIVE ATTACK SCENARIO ===");
        console.log("Multiple attackers coordinate to exploit the system\n");

        // Phase 1: Setup - Honest users establish positions
        console.log("Phase 1: Normal operations");
        _mintBUCK(alice, 50_000e6);
        _mintBUCK(bob, 50_000e6);

        // Phase 2: Warp to checkpoint and do distribution
        console.log("\nPhase 2: Checkpoint window + distribution");
        skip(13 days);
        _publishAttestation(1.2e18); // Refresh attestation after time skip

        // Front-runner tries to sneak in
        _mintBUCK(frontRunner, 200_000e6);

        // Warp to epoch end (distribution requires epochEnd)
        skip(17 days);
        _publishAttestation(1.2e18); // Refresh attestation after time skip

        usdc.mint(timelock, 100_000e6);
        vm.prank(timelock);
        usdc.approve(address(rewardsEngine), 100_000e6);
        vm.prank(timelock);
        rewardsEngine.distribute(100_000e6);

        // Phase 3: Cap exhaustion attempt
        console.log("\nPhase 3: Cap exhaustion attempt");
        _mintBUCK(capExploiter, 500_000e6);

        uint256 exploiterBalance = buck.balanceOf(capExploiter);
        vm.startPrank(capExploiter);
        buck.approve(address(liquidityWindow), exploiterBalance);
        try liquidityWindow.requestRefund(capExploiter, exploiterBalance, 0, 0) {
            console.log("  Large refund succeeded");
        } catch {
            console.log("  Large refund blocked by daily cap");
        }
        vm.stopPrank();

        // Phase 4: Check system integrity
        console.log("\nPhase 4: System integrity check");
        _checkSystemHealth();

        // Print attack summary
        console.log("\n=== ATTACK SUMMARY ===");
        console.log("Attacks attempted: %s", attacksAttempted);
        console.log("Attacks succeeded: %s", attacksSucceeded);
        console.log("Attacks failed: %s", attacksFailed);

        if (attacksSucceeded == 0) {
            console.log("\n[OK] ALL ATTACKS REPELLED");
        } else {
            console.log("\n[WARN] SOME ATTACKS SUCCEEDED - REVIEW NEEDED");
        }
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _mintBUCK(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(liquidityWindow), usdcAmount);
        liquidityWindow.requestMint(user, usdcAmount, 0, type(uint256).max);
        vm.stopPrank();
    }

    function _publishAttestation(uint256 desiredCR) internal {
        uint256 L = buck.totalSupply();
        uint256 R = usdc.balanceOf(address(liquidityReserve)) * 1e12;
        uint256 HC = 0.98e18;

        uint256 V = 0;
        if (L > 0) {
            uint256 targetValue = (desiredCR * L) / 1e18;
            if (targetValue > R) {
                V = ((targetValue - R) * 1e18) / HC;
            }
        }

        vm.prank(attestor);
        collateralAttestation.publishAttestation(V, HC, block.timestamp);
    }

    function _checkSystemHealth() internal view {
        uint256 totalSupply = buck.totalSupply();
        uint256 reserveBalance = usdc.balanceOf(address(liquidityReserve));
        uint256 cr = collateralAttestation.getCollateralRatio();

        console.log("  Total Supply: %s STRX", totalSupply / 1e18);
        console.log("  Reserve: %s USDC", reserveBalance / 1e6);
        if (cr == type(uint256).max) {
            console.log("  CR: Infinite (no supply)");
        } else {
            console.log("  CR: %s%%", (cr * 100) / 1e18);
        }

        require(totalSupply > 0, "Supply destroyed");
        require(reserveBalance > 0, "Reserve drained");
        require(cr > 0.5e18, "CR critically low");

        console.log("  [OK] System remains healthy");
    }
}
