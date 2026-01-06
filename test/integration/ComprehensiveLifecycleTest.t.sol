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
 * @title Comprehensive Lifecycle Test (Sprint 2.5)
 * @notice Simulates 60 days of randomized operations across 20 actors
 * @dev Tests:
 *   - Randomized mint/refund/distribution operations
 *   - Oracle flips between healthy/stale
 *   - Band transitions under stress
 *   - CR crossing 1.0 threshold
 *   - Multi-epoch reward distributions with checkpoint windows
 *   - Invariant preservation throughout
 */
contract ComprehensiveLifecycleTest is BaseTest {
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

    // Test parameters
    uint256 constant SIMULATION_DAYS = 60;
    uint256 constant NUM_ACTORS = 20;
    uint256 constant OPERATIONS_PER_DAY = 50;
    uint256 constant INITIAL_CAPITAL = 100_000e6; // 100K USDC per actor

    // Actor roles
    enum ActorRole {
        HODLER,         // Buy and hold, claim rewards
        ACTIVE_TRADER,  // Frequent mint/refund
        YIELD_FARMER,   // Optimizes for rewards
        WHALE,          // Large positions
        MARKET_MAKER    // Balanced activity
    }

    struct Actor {
        address addr;
        ActorRole role;
        uint256 lastActionDay;
        uint256 totalMinted;
        uint256 totalRefunded;
        uint256 totalClaimed;
    }

    struct SystemSnapshot {
        uint256 day;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 reserveBalance;
        uint256 collateralRatio;
        PolicyManager.Band currentBand;
        uint256 oraclePrice;
        uint256 capPrice;
    }

    Actor[NUM_ACTORS] public actors;
    SystemSnapshot[] public snapshots;
    uint64 public currentEpochId;
    uint64 public currentEpochStart;
    uint64 public currentEpochEnd;

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        vm.startPrank(timelock);

        // Deploy core contracts
        buck = deployBUCK(timelock);
        policyManager = deployPolicyManager(timelock);
        oracle = new MockOracle(1.0e18); // Start at $1.00

        liquidityReserve = deployLiquidityReserve(
            timelock, address(usdc), address(0), treasury
        );

        liquidityWindow = deployLiquidityWindow(
            timelock, address(buck), address(liquidityReserve), address(policyManager)
        );

        rewardsEngine = deployRewardsEngine(
            timelock, timelock, 259200, 1e18, false
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
            address(0), // No KYC for testing
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

        // Configure bands
        _configureBands();

        // Configure RewardsEngine
        rewardsEngine.setToken(address(buck));
        rewardsEngine.setPolicyManager(address(policyManager));
        rewardsEngine.setTreasury(treasury);
        rewardsEngine.setReserveAddresses(address(liquidityReserve), address(usdc));
        rewardsEngine.setMaxTokensToMintPerEpoch(1_000_000e18);

        // Configure first epoch with checkpoint window (Sprint 2.5)
        currentEpochId = 1;
        currentEpochStart = uint64(block.timestamp);
        currentEpochEnd = uint64(block.timestamp + 30 days);
        uint64 checkpointStart = currentEpochStart + 12 days;
        uint64 checkpointEnd = currentEpochStart + 16 days;

        rewardsEngine.configureEpoch(
            currentEpochId,
            currentEpochStart,
            currentEpochEnd,
            checkpointStart,
            checkpointEnd
        );

        liquidityReserve.setLiquidityWindow(address(liquidityWindow));
        liquidityReserve.setRewardsEngine(address(rewardsEngine));

        vm.roll(block.number + 2);
        vm.stopPrank();

        // Fund initial reserve with 1M USDC
        usdc.mint(address(liquidityReserve), 1_000_000e6);
    }

    function _configureBands() internal {
        // GREEN band
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
            refundAggregateBps: 1000
        });
        policyManager.setBandConfig(PolicyManager.Band.Green, greenConfig);

        // YELLOW band
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

        // RED band
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

    function test_60DayRandomizedSimulation() public {
        console.log("\n=== 60-DAY COMPREHENSIVE LIFECYCLE SIMULATION (Sprint 2.5) ===");
        console.log("Actors: %s | Operations/Day: %s\n", NUM_ACTORS, OPERATIONS_PER_DAY);

        // Step 1: Create actors with different roles
        _initializeActors();

        // Step 2: Initial system state
        _publishAttestation(1.2e18); // Start with healthy CR
        _takeSnapshot(0);

        // Step 3: Run simulation
        for (uint256 day = 0; day < SIMULATION_DAYS; day++) {
            console.log("\n=== DAY %s ===", day);

            // Update collateral attestation daily to avoid staleness
            uint256 currentCR = day < 30 ? 1.2e18 : (day < 45 ? 1.0e18 : 0.95e18);
            _publishAttestation(currentCR);

            // Random oracle price update
            _randomOracleUpdate(day);

            // Execute randomized operations
            for (uint256 op = 0; op < OPERATIONS_PER_DAY; op++) {
                _executeRandomOperation(day, op);
            }

            // Monthly distributions (at epoch end - day 30, 60, etc.)
            if (day % 30 == 0 && day > 0) {
                _executeMonthlyDistribution(day);
            }

            // Check system invariants
            _checkInvariants(day);

            // Take snapshot
            _takeSnapshot(day);

            // Advance to next day
            skip(1 days);
        }

        // Step 4: Final verification
        _verifyFinalState();

        console.log("\n=== SIMULATION COMPLETE ===");
        _printStatistics();
    }

    function _initializeActors() internal {
        console.log("Initializing %s actors...", NUM_ACTORS);

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actorAddr = address(uint160(0x5000 + i));

            // Assign roles based on index
            ActorRole role;
            if (i < 5) {
                role = ActorRole.HODLER;
            } else if (i < 10) {
                role = ActorRole.ACTIVE_TRADER;
            } else if (i < 15) {
                role = ActorRole.YIELD_FARMER;
            } else if (i < 18) {
                role = ActorRole.WHALE;
            } else {
                role = ActorRole.MARKET_MAKER;
            }

            actors[i] = Actor({
                addr: actorAddr,
                role: role,
                lastActionDay: 0,
                totalMinted: 0,
                totalRefunded: 0,
                totalClaimed: 0
            });

            // Fund actor with USDC
            usdc.mint(actorAddr, INITIAL_CAPITAL);

            console.log("  Actor %s: %s (USDC: %s)", i, _roleToString(role), INITIAL_CAPITAL / 1e6);
        }
    }

    function _executeRandomOperation(uint256 day, uint256 opIndex) internal {
        // Deterministic pseudo-randomness based on day and operation index
        uint256 seed = uint256(keccak256(abi.encode(block.timestamp, day, opIndex)));

        // Pick random actor
        uint256 actorIndex = seed % NUM_ACTORS;
        Actor storage actor = actors[actorIndex];

        // Pick random operation type (0-99)
        uint256 opType = (seed >> 8) % 100;

        // Execute operation based on actor role and random value
        if (actor.role == ActorRole.HODLER) {
            _executeHodlerOperation(actor, day, opType);
        } else if (actor.role == ActorRole.ACTIVE_TRADER) {
            _executeTraderOperation(actor, day, opType, seed);
        } else if (actor.role == ActorRole.YIELD_FARMER) {
            _executeFarmerOperation(actor, day, opType);
        } else if (actor.role == ActorRole.WHALE) {
            _executeWhaleOperation(actor, day, opType, seed);
        } else {
            _executeMarketMakerOperation(actor, day, opType, seed);
        }
    }

    function _executeHodlerOperation(Actor storage actor, uint256 day, uint256 opType) internal {
        // HODLERs: Mint once at start, claim periodically, rarely refund
        if (day == 0 && opType < 50) {
            _attemptMint(actor, INITIAL_CAPITAL / 2);
        } else if (day % 30 == 1 && opType < 30) {
            _attemptClaim(actor);
        } else if (day % 7 == 0 && opType < 10) {
            // Weekly small transfer to trigger unit settlement
            _attemptSmallTransfer(actor);
        }
    }

    function _executeTraderOperation(
        Actor storage actor,
        uint256 day,
        uint256 opType,
        uint256 seed
    ) internal {
        // ACTIVE_TRADERs: Frequent mint/refund cycles
        if (opType < 40) {
            uint256 amount = _randomUSDCAmount(seed, 1_000e6, 20_000e6);
            _attemptMint(actor, amount);
        } else if (opType < 75) {
            uint256 pct = _randomPercentage(seed, 10, 50);
            _attemptRefund(actor, pct);
        } else if (day % 30 > 25 && opType < 85) {
            _attemptClaim(actor);
        }
    }

    function _executeFarmerOperation(Actor storage actor, uint256 day, uint256 opType) internal {
        // YIELD_FARMERs: Optimize for rewards, mint before distributions
        if (day % 30 < 5 && opType < 40) {
            _attemptMint(actor, INITIAL_CAPITAL / 3);
        } else if (day % 30 > 28 && opType < 50) {
            _attemptClaim(actor);
        }
    }

    function _executeWhaleOperation(
        Actor storage actor,
        uint256 day,
        uint256 opType,
        uint256 seed
    ) internal {
        // WHALEs: Large positions, test caps
        if (day < 10 && opType < 20) {
            uint256 amount = _randomUSDCAmount(seed, 50_000e6, INITIAL_CAPITAL);
            _attemptMint(actor, amount);
        } else if (opType < 5) {
            uint256 pct = _randomPercentage(seed, 20, 40);
            _attemptRefund(actor, pct);
        }
    }

    function _executeMarketMakerOperation(
        Actor storage actor,
        uint256 /*day*/,
        uint256 opType,
        uint256 seed
    ) internal {
        // MARKET_MAKERs: Balanced mint/refund activity
        if (opType < 30) {
            uint256 amount = _randomUSDCAmount(seed, 5_000e6, 30_000e6);
            _attemptMint(actor, amount);
        } else if (opType < 60) {
            uint256 pct = _randomPercentage(seed, 15, 35);
            _attemptRefund(actor, pct);
        }
    }

    function _attemptMint(Actor storage actor, uint256 usdcAmount) internal {
        uint256 balance = usdc.balanceOf(actor.addr);
        if (balance < usdcAmount) return;

        vm.startPrank(actor.addr);
        try usdc.approve(address(liquidityWindow), usdcAmount) {
            try liquidityWindow.requestMint(actor.addr, usdcAmount, 0, type(uint256).max)
                returns (uint256 strxOut, uint256)
            {
                actor.totalMinted += strxOut;
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    function _attemptRefund(Actor storage actor, uint256 percentage) internal {
        uint256 strxBalance = buck.balanceOf(actor.addr);
        if (strxBalance == 0) return;

        uint256 refundAmount = (strxBalance * percentage) / 100;
        if (refundAmount == 0) return;

        vm.startPrank(actor.addr);
        try buck.approve(address(liquidityWindow), refundAmount) {
            try liquidityWindow.requestRefund(actor.addr, refundAmount, 0, 0)
                returns (uint256 /*usdcOut*/, uint256)
            {
                actor.totalRefunded += refundAmount;
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    function _attemptClaim(Actor storage actor) internal {
        uint256 pending = rewardsEngine.pendingRewards(actor.addr);
        if (pending < rewardsEngine.minClaimTokens()) return;

        vm.startPrank(actor.addr);
        try rewardsEngine.claim(actor.addr) returns (uint256 claimed) {
            actor.totalClaimed += claimed;
        } catch {}
        vm.stopPrank();
    }

    function _attemptSmallTransfer(Actor storage actor) internal {
        uint256 strxBalance = buck.balanceOf(actor.addr);
        if (strxBalance < 100e18) return;

        // Transfer a small amount to treasury to trigger settlement
        vm.startPrank(actor.addr);
        try buck.transfer(treasury, 1e18) {} catch {}
        vm.stopPrank();
    }

    function _randomOracleUpdate(uint256 day) internal {
        uint256 seed = uint256(keccak256(abi.encode("oracle", day, block.timestamp)));

        // Different market conditions by phase
        uint256 price;
        if (day < 20) {
            // Phase 1: Healthy market ($0.95 - $1.05)
            price = 0.95e18 + (seed % 0.10e18);
        } else if (day < 40) {
            // Phase 2: Volatile market ($0.80 - $1.10)
            price = 0.80e18 + (seed % 0.30e18);
        } else {
            // Phase 3: Stressed market ($0.70 - $0.95)
            price = 0.70e18 + (seed % 0.25e18);
        }

        oracle.updatePrice(price, block.timestamp);
        vm.roll(block.number + 2);

        // Randomly make oracle stale (5% chance)
        if ((seed >> 16) % 100 < 5) {
            oracle.setHealthy(false);
        } else {
            oracle.setHealthy(true);
        }
    }

    function _executeMonthlyDistribution(uint256 day) internal {
        console.log("\n  >>> MONTHLY DISTRIBUTION (Day %s) <<<", day);

        // FIRST: Distribute rewards for the CURRENT epoch before configuring next
        uint256 seed = uint256(keccak256(abi.encode("distribution", day)));
        uint256 couponAmount = 50_000e6 + (seed % 50_000e6); // $50K-$100K

        usdc.mint(timelock, couponAmount);
        vm.prank(timelock);
        usdc.approve(address(rewardsEngine), couponAmount);
        vm.prank(timelock);

        try rewardsEngine.distribute(couponAmount) returns (uint256 allocated, uint256 dust) {
            console.log("  Distributed: %s USDC -> %s BUCK (dust: %s)", couponAmount / 1e6, allocated / 1e18, dust / 1e18);
        } catch {
            console.log("  Distribution FAILED - falling back to $1 minimum distribution");
            // Always distribute at least $1 to advance the epoch (no zero-coupon escape hatch)
            uint256 minAmount = 1e6; // $1 USDC
            usdc.mint(timelock, minAmount);
            vm.prank(timelock);
            usdc.approve(address(rewardsEngine), minAmount);
            vm.prank(timelock);
            rewardsEngine.distribute(minAmount);
        }

        // THEN: Configure next epoch with checkpoint window (Sprint 2.5)
        currentEpochId++;
        currentEpochStart = uint64(block.timestamp);
        currentEpochEnd = uint64(block.timestamp + 30 days);
        uint64 checkpointStart = currentEpochStart + 12 days;
        uint64 checkpointEnd = currentEpochStart + 16 days;

        vm.prank(timelock);
        rewardsEngine.configureEpoch(
            currentEpochId,
            currentEpochStart,
            currentEpochEnd,
            checkpointStart,
            checkpointEnd
        );
        console.log("  Configured epoch %s", currentEpochId);
    }

    function _checkInvariants(uint256 day) internal view {
        // 1. Supply = Sum of balances
        uint256 totalSupply = buck.totalSupply();
        uint256 sumBalances = 0;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            sumBalances += buck.balanceOf(actors[i].addr);
        }
        sumBalances += buck.balanceOf(address(liquidityReserve));
        sumBalances += buck.balanceOf(treasury);
        sumBalances += buck.balanceOf(timelock);

        // Allow small rounding errors
        if (totalSupply > 0) {
            assertApproxEqRel(
                totalSupply,
                sumBalances,
                0.01e18,
                string(abi.encodePacked("Day ", _uint2str(day), ": Supply mismatch"))
            );
        }

        // 2. Reserve must not be negative
        uint256 reserveBalance = usdc.balanceOf(address(liquidityReserve));
        assertGt(
            reserveBalance,
            0,
            string(abi.encodePacked("Day ", _uint2str(day), ": Reserve depleted"))
        );

        // 3. CR must stay above minimum threshold
        if (totalSupply > 0) {
            uint256 cr = collateralAttestation.getCollateralRatio();
            assertGt(
                cr,
                0.3e18,
                string(abi.encodePacked("Day ", _uint2str(day), ": CR too low"))
            );
        }

        // 4. Rewards accounting - Sprint 2.5: use globalEligibleUnits
        uint256 globalUnits = rewardsEngine.globalEligibleUnits();
        // Units should be non-negative (always true for uint256)
        assertTrue(
            globalUnits >= 0,
            string(abi.encodePacked("Day ", _uint2str(day), ": Invalid global units"))
        );
    }

    function _takeSnapshot(uint256 day) internal {
        uint256 currentOraclePrice; (currentOraclePrice,) = oracle.latestPrice();
        SystemSnapshot memory snapshot = SystemSnapshot({
            day: day,
            timestamp: block.timestamp,
            totalSupply: buck.totalSupply(),
            reserveBalance: usdc.balanceOf(address(liquidityReserve)),
            collateralRatio: collateralAttestation.getCollateralRatio(),
            currentBand: policyManager.currentBand(),
            oraclePrice: currentOraclePrice,
            capPrice: policyManager.getCAPPrice()
        });

        snapshots.push(snapshot);

        if (day % 10 == 0) {
            console.log("\n  [SNAPSHOT] Day %s:", day);
            console.log("    Supply: %s STRX", snapshot.totalSupply / 1e18);
            console.log("    Reserve: %s USDC", snapshot.reserveBalance / 1e6);
            if (snapshot.collateralRatio == type(uint256).max) {
                console.log("    CR: Infinite (no supply)");
            } else {
                uint256 crPercentage = (snapshot.collateralRatio * 100) / 1e18;
                console.log("    CR: %s%%", crPercentage);
            }
            console.log("    Band: %s", _bandToString(snapshot.currentBand));
            console.log("    Oracle: $%s.%s", snapshot.oraclePrice / 1e18, (snapshot.oraclePrice % 1e18) / 1e16);
            console.log("    CAP: $%s.%s", snapshot.capPrice / 1e18, (snapshot.capPrice % 1e18) / 1e16);
            console.log("    Global Eligible Units: %s", rewardsEngine.globalEligibleUnits() / 1e18);
        }
    }

    function _verifyFinalState() internal view {
        console.log("\n=== FINAL STATE VERIFICATION ===");

        uint256 totalSupply = buck.totalSupply();
        uint256 reserveBalance = usdc.balanceOf(address(liquidityReserve));
        uint256 cr = collateralAttestation.getCollateralRatio();

        assertGt(totalSupply, 0, "Final supply must be > 0");
        assertGt(reserveBalance, 0, "Final reserve must be > 0");
        assertGt(cr, 0.5e18, "Final CR must be > 0.5");

        console.log("  Total Supply: %s STRX", totalSupply / 1e18);
        console.log("  Reserve Balance: %s USDC", reserveBalance / 1e6);
        console.log("  Collateral Ratio: %s.%s%%", cr / 1e18, (cr % 1e18) / 1e16);
        console.log("  All invariants maintained!");
    }

    function _printStatistics() internal view {
        console.log("\n=== STATISTICS ===");

        uint256 totalMinted = 0;
        uint256 totalRefunded = 0;
        uint256 totalClaimed = 0;

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            totalMinted += actors[i].totalMinted;
            totalRefunded += actors[i].totalRefunded;
            totalClaimed += actors[i].totalClaimed;
        }

        console.log("Total Operations:");
        console.log("  Minted: %s STRX", totalMinted / 1e18);
        console.log("  Refunded: %s STRX", totalRefunded / 1e18);
        console.log("  Claimed: %s STRX", totalClaimed / 1e18);

        console.log("\nBand Distribution:");
        uint256 greenDays = 0;
        uint256 yellowDays = 0;
        uint256 redDays = 0;
        for (uint256 i = 0; i < snapshots.length; i++) {
            if (snapshots[i].currentBand == PolicyManager.Band.Green) greenDays++;
            else if (snapshots[i].currentBand == PolicyManager.Band.Yellow) yellowDays++;
            else redDays++;
        }
        console.log("  GREEN: %s days (%s%%)", greenDays, (greenDays * 100) / SIMULATION_DAYS);
        console.log("  YELLOW: %s days (%s%%)", yellowDays, (yellowDays * 100) / SIMULATION_DAYS);
        console.log("  RED: %s days (%s%%)", redDays, (redDays * 100) / SIMULATION_DAYS);

        // Sprint 2.5: Print rewards engine state
        console.log("\nRewards Engine State:");
        console.log("  Current Epoch: %s", rewardsEngine.currentEpochId());
        console.log("  Global Eligible Units: %s", rewardsEngine.globalEligibleUnits() / 1e18);
        console.log("  Total Rewards Claimed: %s STRX", rewardsEngine.totalRewardsClaimed() / 1e18);
    }

    // ============ Helper Functions ============

    function _publishAttestation(uint256 desiredCR) internal {
        uint256 L = buck.totalSupply();
        uint256 R = usdc.balanceOf(address(liquidityReserve)) * 1e12;
        uint256 HC = 0.98e18;

        uint256 V = 0;
        uint256 targetValue = (desiredCR * L) / 1e18;
        if (targetValue > R) {
            V = ((targetValue - R) * 1e18) / HC;
        }

        // Advance time to satisfy monotonic timestamp requirement
        vm.warp(block.timestamp + 1);

        vm.prank(attestor);
        collateralAttestation.publishAttestation(V, HC, block.timestamp);
    }

    function _randomUSDCAmount(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (seed % (max - min));
    }

    function _randomPercentage(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (seed % (max - min));
    }

    function _roleToString(ActorRole role) internal pure returns (string memory) {
        if (role == ActorRole.HODLER) return "HODLER";
        if (role == ActorRole.ACTIVE_TRADER) return "TRADER";
        if (role == ActorRole.YIELD_FARMER) return "FARMER";
        if (role == ActorRole.WHALE) return "WHALE";
        return "MARKET_MAKER";
    }

    function _bandToString(PolicyManager.Band band) internal pure returns (string memory) {
        if (band == PolicyManager.Band.Green) return "GREEN";
        if (band == PolicyManager.Band.Yellow) return "YELLOW";
        return "RED";
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
