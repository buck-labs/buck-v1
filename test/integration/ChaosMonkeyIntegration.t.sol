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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Oracle adapter compatible with LiquidityWindow and PolicyManager
contract CMOracle {
    uint256 public price;
    uint256 public updatedAt;
    uint256 public lastBlock;
    bool public stale;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isHealthy(uint256 maxStale) external view returns (bool) {
        if (stale) return false;
        return block.timestamp - updatedAt <= maxStale;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastBlock;
    }

    function setStrictMode(bool) external {}

    // Test helpers
    function setPrice(uint256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        lastBlock = block.number;
    }

    function setStaleness(bool _stale) external {
        stale = _stale;
        if (!_stale) {
            updatedAt = block.timestamp;
            lastBlock = block.number;
        }
    }
}

/**
 * @title ChaosMonkeyIntegration
 * @notice Aggressive system-level stress test wired for the refactored RewardsEngine
 */
contract ChaosMonkeyIntegration is BaseTest {
    // Core contracts
    Buck public buck;
    LiquidityWindow public window;
    LiquidityReserve public reserve;
    RewardsEngine public rewards;
    PolicyManager public policy;
    CollateralAttestation public attestation;
    CMOracle public oracle;
    MockUSDC public usdc;

    // Actors
    address public constant TIMELOCK = address(0x1000);
    address public constant TREASURY = address(0x2000);
    address public constant ATTESTOR = address(0x3000);
    address public constant TREASURER = address(0x4000);

    // Params (kept moderate for CI; scale up locally if desired)
    uint256 constant SIMULATION_DAYS = 7;     // Use 60 for heavy runs
    uint256 constant NUM_ACTORS = 10;         // Use 20 for heavy runs
    uint256 constant OPERATIONS_PER_DAY = 25; // Use 100 for heavy runs
    uint256 constant INITIAL_CAPITAL = 50_000e6; // USDC per actor

    enum ActorRole {
        HONEST_TRADER,
        WHALE,
        MALICIOUS_MINTER,
        MALICIOUS_REFUNDER,
        FEE_DODGER,
        ORACLE_MANIPULATOR,
        RESERVE_DRAINER,
        REWARDS_EXPLOITER
    }

    struct Actor {
        address addr;
        ActorRole role;
        uint256 totalMinted;
        uint256 totalRefunded;
        uint256 totalClaimed;
        bool isMalicious;
        uint256 exploitAttempts;
    }

    struct SystemSnapshot {
        uint256 day;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 reserveBalance;
        uint256 treasuryBalance;
        uint256 collateralRatio;
        PolicyManager.Band currentBand;
        uint256 oraclePrice;
        uint256 capPrice;
        bool oracleIsStale;
        uint256 totalRewardsClaimed;
        uint256 pendingRewards;
    }

    Actor[NUM_ACTORS] public actors;
    SystemSnapshot[] public snapshots;
    uint64 public currentEpochId;
    uint256 public totalExploitAttempts;
    uint256 public successfulExploits;

    event ExploitAttempted(address actor, string exploitType, bool success);

    function setUp() public {
        // Deploy USDC
        usdc = new MockUSDC();

        vm.startPrank(TIMELOCK);

        // Deploy core
        buck = deployBUCK(TIMELOCK);
        policy = deployPolicyManager(TIMELOCK);
        oracle = new CMOracle(1e18);
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);
        window = deployLiquidityWindow(TIMELOCK, address(buck), address(reserve), address(policy));
        rewards = deployRewardsEngine(TIMELOCK, TIMELOCK, 0, 0, false);
        attestation = deployCollateralAttestation(
            TIMELOCK, ATTESTOR, address(buck), address(reserve), address(usdc)
        );

        // Wire modules
        buck.configureModules(
            address(window), address(reserve), TREASURY, address(policy), address(0), address(rewards)
        );

        reserve.setLiquidityWindow(address(window));
        reserve.setRewardsEngine(address(rewards));

        window.setUSDC(address(usdc));
        window.configureFeeSplit(7000, TREASURY);

        // Policy wiring
        policy.setContractReferences(address(buck), address(reserve), address(oracle), address(usdc));
        policy.setCollateralAttestation(address(attestation));

        // Roles
        bytes32 opRole = policy.OPERATOR_ROLE();
        policy.grantRole(opRole, address(window));
        // Treasurer is granted in initialize; ensure role set if needed
        reserve.setTreasurer(TREASURER);

        // Band configs (loose caps for testing)
        PolicyManager.BandConfig memory green = policy.getBandConfig(PolicyManager.Band.Green);
        green.halfSpreadBps = 25;
        green.mintFeeBps = 50;
        green.refundFeeBps = 50;
        green.alphaBps = 300;
        green.floorBps = 500;
        green.distributionSkimBps = 250;
        green.caps.mintAggregateBps = 10_000;
        green.caps.refundAggregateBps = 10_000;
        policy.setBandConfig(PolicyManager.Band.Green, green);

        // RewardsEngine wiring
        rewards.setToken(address(buck));
        rewards.setPolicyManager(address(policy));
        rewards.setTreasury(TREASURY);
        rewards.setReserveAddresses(address(reserve), address(usdc));
        rewards.setMaxTokensToMintPerEpoch(type(uint256).max);
        rewards.setBreakageSink(TREASURY);

        // Epoch configuration with checkpoint
        currentEpochId = 1;
        uint64 start = uint64(block.timestamp);
        uint64 end = start + 30 days;
        rewards.configureEpoch(currentEpochId, start, end, start + 12 days, start + 16 days);

        vm.stopPrank();

        // Fund reserve and treasury
        usdc.mint(address(reserve), 1_000_000e6);
        usdc.mint(TREASURY, 500_000e6);

        // Initialize actors and fund USDC
        _initActors();
    }

    function _initActors() internal {
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address addr = address(uint160(0x10000 + i));
            ActorRole role;
            bool isMal = false;
            if (i < 4) role = ActorRole.HONEST_TRADER;
            else if (i < 6) role = ActorRole.WHALE;
            else if (i == 6) { role = ActorRole.MALICIOUS_MINTER; isMal = true; }
            else if (i == 7) { role = ActorRole.RESERVE_DRAINER; isMal = true; }
            else if (i == 8) { role = ActorRole.ORACLE_MANIPULATOR; isMal = true; }
            else { role = ActorRole.REWARDS_EXPLOITER; isMal = true; }

            actors[i] = Actor({
                addr: addr,
                role: role,
                totalMinted: 0,
                totalRefunded: 0,
                totalClaimed: 0,
                isMalicious: isMal,
                exploitAttempts: 0
            });

            uint256 funding = role == ActorRole.WHALE ? INITIAL_CAPITAL * 10 : INITIAL_CAPITAL;
            usdc.mint(addr, funding);
        }
    }

    function test_ChaosMonkey() public {
        console.log("\n=== CHAOS MONKEY STRESS TEST ===");
        _snapshot(0);

        for (uint256 day = 1; day <= SIMULATION_DAYS; day++) {
            _morningChaos(day);
            for (uint256 op = 0; op < OPERATIONS_PER_DAY; op++) {
                uint256 idx = _rand(day, op, 0) % NUM_ACTORS;
                _doOp(actors[idx], day, op);
                if (op % 8 == 0) _injectChaos(day, op);
            }
            _eveningChaos(day);
            _endOfDay(day);

            if (day % 3 == 0) {
                _snapshot(day);
                _validateAccounts();
            }

            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 7200);
        }

        _finalChecks();
    }

    // ---------- Chaos helpers ----------

    function _morningChaos(uint256 day) internal {
        uint256 s = _rand(day, 0, 1);
        if (s % 3 == 0) {
            oracle.setStaleness(true);
        } else if (s % 3 == 1) {
            uint256 p = 0.7e18 + (s % 6e17); // 0.7 - 1.3
            oracle.setPrice(p);
            oracle.setStaleness(false);
        } else {
            oracle.setStaleness(false);
            oracle.setPrice(1e18);
        }
    }

    function _eveningChaos(uint256 day) internal {
        // Attempt distribution at or after epoch end only
        uint64 epochEnd = rewards.epochEnd();
        if (block.timestamp >= epochEnd) {
            uint256 coupon = 50_000e6 + (day * 1_000e6);
            usdc.mint(TIMELOCK, coupon);
            vm.startPrank(TIMELOCK);
            usdc.approve(address(rewards), coupon);
            try rewards.distribute(coupon) {
                // Configure next epoch immediately
                currentEpochId++;
                uint64 start = uint64(block.timestamp);
                uint64 end = start + 30 days;
                rewards.configureEpoch(currentEpochId, start, end, start + 12 days, start + 16 days);
            } catch {}
            vm.stopPrank();
        }
    }

    function _doOp(Actor storage a, uint256 day, uint256 op) internal {
        if (a.isMalicious) _malOp(a, day, op);
        else _normOp(a, day, op);
    }

    function _malOp(Actor storage a, uint256 day, uint256 op) internal {
        uint256 s = _rand(day, op, uint256(uint160(a.addr)));
        vm.startPrank(a.addr);
        if (a.role == ActorRole.MALICIOUS_MINTER) {
            // Try invalid mint sizes
            try window.requestMint(a.addr, 0, 0, type(uint256).max) {
                successfulExploits++;
                emit ExploitAttempted(a.addr, "ZERO_MINT", true);
            } catch { emit ExploitAttempted(a.addr, "ZERO_MINT", false); }
        } else if (a.role == ActorRole.RESERVE_DRAINER) {
            uint256 bal = buck.balanceOf(a.addr);
            if (bal > 0) {
                buck.approve(address(window), bal);
                uint256 chunk = bal / 5;
                for (uint256 i = 0; i < 3 && chunk > 0; i++) {
                    try window.requestRefund(a.addr, chunk, 0, 0) {} catch {}
                }
            }
        } else if (a.role == ActorRole.ORACLE_MANIPULATOR) {
            // Stale oracle mint attempt
            oracle.setStaleness(true);
            uint256 amt = 5_000e6;
            if (usdc.balanceOf(a.addr) >= amt) {
                usdc.approve(address(window), amt);
                try window.requestMint(a.addr, amt, 0, type(uint256).max) {
                    emit ExploitAttempted(a.addr, "STALE_ORACLE_MINT", true);
                } catch { emit ExploitAttempted(a.addr, "STALE_ORACLE_MINT", false); }
            }
            oracle.setStaleness(false);
        } else if (a.role == ActorRole.REWARDS_EXPLOITER) {
            // Multi-claim attempt
            for (uint256 i = 0; i < 2; i++) {
                try rewards.claim(a.addr) {
                    emit ExploitAttempted(a.addr, "MULTI_CLAIM", true);
                } catch {}
            }
        }
        vm.stopPrank();
        a.exploitAttempts++;
        totalExploitAttempts++;
    }

    function _normOp(Actor storage a, uint256 day, uint256 op) internal {
        uint256 s = _rand(day, op, uint256(uint160(a.addr)));
        uint256 t = s % 100;
        if (t < 40) {
            // Mint
            uint256 amt = (a.role == ActorRole.WHALE) ? ((s % 50_000e6) + 10_000e6) : ((s % 10_000e6) + 1_000e6);
            if (usdc.balanceOf(a.addr) < amt) amt = usdc.balanceOf(a.addr);
            if (amt == 0) return;
            vm.startPrank(a.addr);
            usdc.approve(address(window), amt);
            try window.requestMint(a.addr, amt, 0, type(uint256).max) returns (uint256 out, uint256) {
                a.totalMinted += out;
            } catch {}
            vm.stopPrank();
        } else if (t < 70) {
            // Refund
            uint256 bal = buck.balanceOf(a.addr);
            if (bal == 0) return;
            uint256 pct = (s % 50) + 10;
            uint256 amount = (bal * pct) / 100;
            vm.startPrank(a.addr);
            buck.approve(address(window), amount);
            try window.requestRefund(a.addr, amount, 0, 0) { a.totalRefunded += amount; } catch {}
            vm.stopPrank();
        } else if (t < 90) {
            // Claim
            uint256 pending = rewards.pendingRewards(a.addr);
            if (pending >= rewards.minClaimTokens()) {
                vm.startPrank(a.addr);
                try rewards.claim(a.addr) returns (uint256 claimed) { a.totalClaimed += claimed; } catch {}
                vm.stopPrank();
            }
        }
    }

    function _injectChaos(uint256 day, uint256 op) internal {
        uint256 s = _rand(day, op, 999);
        if (s % 5 == 0) oracle.setStaleness(!oracle.stale());
        else if (s % 5 == 1) oracle.setPrice(0.8e18 + (s % 4e17));
        else if (s % 5 == 2) {
            vm.startPrank(ATTESTOR);
            try attestation.publishAttestation(100e18, 0.98e18, block.timestamp) {} catch {}
            vm.stopPrank();
        }
    }

    function _endOfDay(uint256 day) internal {
        if (day % 3 == 0) {
            vm.startPrank(ATTESTOR);
            try attestation.publishAttestation(100e18, 0.98e18, block.timestamp) {} catch {}
            vm.stopPrank();
        }
    }

    // ---------- Validation ----------

    function _snapshot(uint256 day) internal {
        uint256 supply = buck.totalSupply();
        uint256 resBal = usdc.balanceOf(address(reserve));
        uint256 treBal = usdc.balanceOf(TREASURY);
        uint256 cr = attestation.getCollateralRatio();
        PolicyManager.Band band = policy.currentBand();
        (uint256 p,) = oracle.latestPrice();
        uint256 cap = policy.getCAPPrice();

        uint256 totClaimed = 0;
        uint256 totPending = 0;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            totClaimed += actors[i].totalClaimed;
            totPending += rewards.pendingRewards(actors[i].addr);
        }

        snapshots.push(SystemSnapshot({
            day: day,
            timestamp: block.timestamp,
            totalSupply: supply,
            reserveBalance: resBal,
            treasuryBalance: treBal,
            collateralRatio: cr,
            currentBand: band,
            oraclePrice: p,
            capPrice: cap,
            oracleIsStale: oracle.stale(),
            totalRewardsClaimed: totClaimed,
            pendingRewards: totPending
        }));
    }

    function _validateAccounts() internal {
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address acct = actors[i].addr;
            (
                uint256 bal,
                , // lastClaimedEpoch
                , // lastAccrual
                , // lastInflow
                uint256 unitsAccrued,
                bool excluded,
                bool eligible
            ) = rewards.getAccountFullState(acct);

            // If balance > 0 and not excluded, eligibility should be coherent
            if (bal > 0 && !excluded) {
                // Either accruing units now or flagged eligible
                uint256 unitsLive = rewards.accruedUnitsThisEpoch(acct);
                assertTrue(eligible || unitsAccrued > 0 || unitsLive > 0, "incoherent accrual state");
            }
        }
    }

    function _finalChecks() internal {
        // No successful exploits recorded
        assertEq(successfulExploits, 0, "System was exploited");

        // Solvency sanity
        uint256 finalRes = usdc.balanceOf(address(reserve));
        uint256 finalSupply = buck.totalSupply();
        assertTrue(finalRes > 0 || finalSupply == 0, "System insolvent");
    }

    // ---------- Utils ----------

    function _rand(uint256 a, uint256 b, uint256 c) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, a, b, c)));
    }
}

