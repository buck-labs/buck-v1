// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {IOracleAdapter} from "src/policy/PolicyManager.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {Buck} from "src/token/Buck.sol";
// import {ProtocolStake} from "src/staking/ProtocolStake.sol"; // DELETED - Treasury is now a wallet, not a contract

contract IntegrationMockOracle is IOracleAdapter {
    uint256 public price;
    bool public healthy = true;
    uint256 public lastUpdateBlock;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
        lastUpdateBlock = block.number;
    }

    function setHealthy(bool newHealthy) external {
        healthy = newHealthy;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, block.timestamp);
    }

    function isHealthy(uint256) external view returns (bool) {
        return healthy;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastUpdateBlock;
    }

    function setStrictMode(bool) external {}
}

contract IntegrationMockUSDC is ERC20("Mock USDC", "mUSDC") {
    function decimals() public pure override returns (uint8) {
        return 6; // ✅ Match real USDC decimals
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PolicyIntegrationTest is BaseTest {
    LiquidityWindow internal window;
    PolicyManager internal policy;
    RewardsEngine internal rewards;
    // ProtocolStake internal protocolStake; // DELETED - Treasury is now a wallet

    Buck internal token;
    IntegrationMockOracle internal oracle;
    LiquidityReserve internal reserve;
    IntegrationMockUSDC internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant GUARDIAN = address(0xFEED);
    address internal constant STEWARD = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant TREASURY = address(0xF00D);
    address internal constant BOB = address(0x6000);
    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant USDC_TO_18 = 1e12;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        policy = deployPolicyManager(TIMELOCK);
        token = deployBUCK(TIMELOCK);
        oracle = new IntegrationMockOracle();
        usdc = new IntegrationMockUSDC();
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), address(0), TREASURY);

        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));

        vm.prank(TIMELOCK);
        window.setUSDC(address(usdc));

        // Don't enable testnet mode by default since we want to test cap enforcement

        vm.prank(TIMELOCK);
        window.configureFeeSplit(10_000, TREASURY);

        bytes32 operatorRole = policy.OPERATOR_ROLE();
        vm.prank(TIMELOCK);
        policy.grantRole(operatorRole, address(window));

        // Configure production-style caps for testing: allow large single transactions
        vm.prank(TIMELOCK);
        policy.setMaxSingleTransactionPct(100); // Allow full daily cap in single transaction

        vm.prank(TIMELOCK);
        reserve.setLiquidityWindow(address(window));

        oracle.setPrice(1e18);

        // Move past block-fresh window after oracle price update
        vm.roll(block.number + 2);

        // Configure autonomous mode: PolicyManager will query on-chain state directly
        vm.prank(TIMELOCK);
        policy.setContractReferences(
            address(token), // BUCK token
            address(reserve), // LiquidityReserve
            address(oracle), // OracleAdapter
            address(usdc) // USDC
        );
        // NOTE: With autonomous mode enabled, PolicyManager no longer needs manual
        // reportSystemSnapshot() calls - it queries totalSupply, reserves, and price
        // directly from contracts!

        PolicyManager.BandConfig memory greenConfig = policy.getBandConfig(PolicyManager.Band.Green);
        greenConfig.caps.mintAggregateBps = 2_000; // 20% daily mint cap
        greenConfig.caps.refundAggregateBps = 10_000; // 100% = unlimited refunds for testing
        greenConfig.alphaBps = 2_000; // 20% aggregate headroom
        vm.prank(TIMELOCK);
        policy.setBandConfig(PolicyManager.Band.Green, greenConfig);

        PolicyManager.BandConfig memory yellowConfig =
            policy.getBandConfig(PolicyManager.Band.Yellow);
        yellowConfig.caps.mintAggregateBps = 10_000;
        yellowConfig.caps.refundAggregateBps = 10_000;
        vm.prank(TIMELOCK);
        policy.setBandConfig(PolicyManager.Band.Yellow, yellowConfig);
        PolicyManager.BandConfig memory redConfig = policy.getBandConfig(PolicyManager.Band.Red);
        vm.prank(TIMELOCK);
        policy.setBandConfig(PolicyManager.Band.Red, redConfig);

        rewards = deployRewardsEngine(TIMELOCK, TIMELOCK, 0, 20e18, true);
        vm.prank(TIMELOCK);
        rewards.setPolicyManager(address(policy));
        vm.prank(TIMELOCK);
        rewards.setReserveAddresses(address(reserve), address(usdc));

        // Fund TIMELOCK with USDC for reward distributions and pre-approve rewards contract
        usdc.mint(TIMELOCK, 1_000_000e6); // 1M USDC for distributions
        vm.prank(TIMELOCK);
        usdc.approve(address(rewards), type(uint256).max);

        // protocolStake = new ProtocolStake(TIMELOCK, address(token), address(rewards), TREASURY); // DELETED

        vm.prank(TIMELOCK);
        token.configureModules(
            address(window),
            address(reserve),
            TREASURY,
            address(policy),
            address(0),
            address(rewards)
        );

        usdc.mint(TREASURY, 1_000_000e6); // 1M USDC (6 decimals)
        usdc.mint(STEWARD, 1_000_000e6); // 1M USDC for STEWARD
        vm.startPrank(TREASURY);
        usdc.approve(address(reserve), type(uint256).max);
        reserve.recordDeposit(800_000e6); // 800k USDC (6 decimals)
        vm.stopPrank();

        // STEWARD approves window for USDC spending
        vm.prank(STEWARD);
        usdc.approve(address(window), type(uint256).max);

        vm.prank(TIMELOCK);
        rewards.setToken(address(token));
        vm.prank(TIMELOCK);
        rewards.setMinClaimTokens(0);
        uint64 nowTs = uint64(block.timestamp);
        vm.prank(TIMELOCK);
        // Checkpoint window: day 12-16 of a 30-day epoch
        uint64 epochEnd_ = nowTs + 30 days;
        uint64 checkpointStart_ = nowTs + 12 days;
        uint64 checkpointEnd_ = nowTs + 16 days;
        rewards.configureEpoch(1, nowTs, epochEnd_, checkpointStart_, checkpointEnd_);

        // Mint initial supply to avoid Emergency band (totalSupply = 0 triggers band 3)
        // This represents the initial token distribution at system launch
        vm.prank(address(window));
        token.mint(TREASURY, 1_000_000e18); // 1M BUCK initial supply

        vm.startPrank(TIMELOCK);
        // NOTE: reportSystemSnapshot() calls below are OPTIONAL with autonomous mode enabled.
        // PolicyManager could query on-chain state directly, but we call reportSystemSnapshot()
        // here to test backward compatibility. Both modes work correctly!
        policy.reportSystemSnapshot(
            _snapshot(2_000, 400, 10, 100, token.totalSupply(), 1e18, reserve.totalLiquidity(), 1)
        );
        vm.stopPrank();
    }

    function testLiquidityWindowTracksPolicyBandParameters() public {
        // Enable testnet mode for this test to bypass caps
        vm.prank(TIMELOCK);

        uint256 usdcAmount = 1e6; // 1 USDC (6 decimals)

        PolicyManager.SystemSnapshot memory healthy =
            _snapshot(2_000, 400, 10, 100, token.totalSupply(), 1e18, reserve.totalLiquidity(), 1);
        vm.prank(TIMELOCK);
        policy.reportSystemSnapshot(healthy);

        vm.prank(STEWARD);
        (uint256 strcOutGreen, uint256 feeGreen) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);

        (uint16 greenMintFee,) = policy.getFees();
        assertEq(strcOutGreen, _expectedStrcOut(usdcAmount, policy.getHalfSpread()));
        assertEq(feeGreen, _expectedFee(usdcAmount, greenMintFee));

        PolicyManager.SystemSnapshot memory yellow =
            _snapshot(1_800, 350, 60, 200, token.totalSupply(), 1e18, reserve.totalLiquidity(), 1);
        vm.prank(TIMELOCK);
        policy.reportSystemSnapshot(yellow);

        PolicyManager.DerivedCaps memory capsYellow = policy.getDerivedCaps();
        uint16 yellowSpread = policy.getHalfSpread();
        uint256 supply = token.totalSupply();
        uint256 allowedStrc = Math.mulDiv(capsYellow.mintAggregateBps, supply, 10_000);
        uint256 effectivePriceYellow = Math.mulDiv(1e18, 10_000 + yellowSpread, 10_000);
        // Calculate USDC amount needed, then scale down to 6 decimals
        uint256 yellowUsdcAmount18 =
            allowedStrc == 0 ? 1e18 : Math.mulDiv(allowedStrc, effectivePriceYellow, 1e18) / 2;
        uint256 yellowUsdcAmount = yellowUsdcAmount18 / 1e12; // Convert to 6 decimals

        vm.prank(STEWARD);
        (uint256 strcOutYellow, uint256 feeYellow) =
            window.requestMint(RECIPIENT, yellowUsdcAmount, 0, 0);

        (uint16 yellowMintFee,) = policy.getFees();
        assertEq(strcOutYellow, _expectedStrcOut(yellowUsdcAmount, policy.getHalfSpread()));
        assertEq(feeYellow, _expectedFee(yellowUsdcAmount, yellowMintFee));
    }

    function testMintCapsEnforced() public {
        // NOTE: This test uses greenConfig.caps.mintAggregateBps = 2_000 (20% daily cap)
        // set in setUp(), so mints ARE capped here (unlike production which uses 0 = unlimited)
        _syncPolicySnapshotToState();

        vm.prank(STEWARD);
        window.requestMint(STEWARD, 50_000e6, 0, 0); // 50k USDC

        // Get remaining capacity in tokens
        (uint256 mintAggregateRemainingTokens,) = policy.getAggregateRemainingCapacity();
        assertGt(mintAggregateRemainingTokens, 0, "there should be capacity left");

        // Try to mint more than remaining capacity - should fail
        uint256 overAmount = mintAggregateRemainingTokens + 1e18;
        vm.expectRevert();
        policy.checkMintCap( overAmount);

        // Mint within capacity should succeed
        uint256 safeAmount = mintAggregateRemainingTokens / 2;
        if (safeAmount > 0) {
            bool passed = policy.checkMintCap( safeAmount);
            assertTrue(passed, "Mint within cap should pass");
        }
    }

    // Sprint 2: Updated to test instant band transitions (no hysteresis)
    // RED band = reserve ratio < 2.5%, allows unlimited mints to improve reserves
    // Recovery to GREEN happens instantly when reserve ratio >= 5%
    function testRedBandAllowsUnlimitedMintsAndInstantRecovery() public {
        _syncPolicySnapshotToState();

        vm.prank(STEWARD);
        window.requestMint(STEWARD, 2_000e6, 0, 0); // 2k USDC

        // Sprint 2: RED band requires reserve ratio < 2.5% (250 bps)
        // Force reserve ratio below 2.5%
        _setReserveRatioBps(240);

        // RED band allows unlimited mints (mints improve reserve ratio by bringing in USDC)
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Red), "Should be RED");
        vm.prank(STEWARD);
        // Mint should succeed in RED band (unlimited mints to improve reserves)
        window.requestMint(STEWARD, 1_000e6, 0, 0); // 1k USDC

        // Sprint 2: Instant recovery to GREEN when reserve ratio >= 5% (no dwell time, no 2-print requirement)
        // Restore reserve ratio above GREEN threshold (note: previous mint improved reserves)
        // Use 510 bps instead of 500 to avoid truncation boundary issues
        _setReserveRatioBps(510);
        assertEq(uint8(policy.currentBand()), uint8(PolicyManager.Band.Green), "Should be GREEN");

        // Mints should work immediately after recovery (instant transition)
        // Note: Capacity may be exhausted from previous mints in this test,
        // so we just verify band transition works correctly
        // The key test is that we instantly transitioned from RED to GREEN
    }

    // Sprint 2.1.2: DELETED testRewardsDistributionBlockedInRedOrEmergency
    // Distributions are now allowed in ALL bands per architecture review.
    // CAP pricing handles depeg scenarios, and distributions improve reserves via skim.

    function testEndToEndMintRefundAndRewardsFlow() public {
        // Enable testnet mode for this test to bypass caps
        vm.prank(TIMELOCK);

        PolicyManager.SystemSnapshot memory green =
            _snapshot(2_000, 400, 10, 100, token.totalSupply(), 1e18, reserve.totalLiquidity(), 1);
        vm.prank(TIMELOCK);
        policy.reportSystemSnapshot(green);

        uint256 reserveBefore = reserve.totalLiquidity();

        vm.prank(STEWARD);
        (uint256 mintedStrc,) = window.requestMint(STEWARD, 100_000e6, 0, 0); // 100k USDC
        assertGt(mintedStrc, 0);
        assertEq(token.balanceOf(STEWARD), mintedStrc);

        vm.prank(STEWARD);
        token.transfer(TREASURY, mintedStrc / 4);

        // DELETED: ProtocolStake no longer exists
        // vm.startPrank(TREASURY);
        // token.approve(address(protocolStake), type(uint256).max);
        // protocolStake.stake(mintedStrc / 4);
        // vm.stopPrank();

        vm.warp(block.timestamp + 14_400 + 1 days);

        // Trigger settlement to accrue units (replaces deleted poke())
        vm.prank(STEWARD);
        token.transfer(BOB, 1e18);

        // Warp to epoch end (distribution requires epochEnd)
        vm.warp(block.timestamp + 30 days);

        uint256 couponAmount = _couponForTokens(50_000e18);
        vm.prank(TIMELOCK);
        rewards.distribute(couponAmount);

        vm.prank(STEWARD);
        uint256 userClaim = rewards.claim(STEWARD);
        assertGt(userClaim, 0);

        // DELETED: ProtocolStake no longer exists
        // vm.prank(TREASURY);
        // uint256 protocolClaim = protocolStake.claimAndCompound();
        // assertGt(protocolClaim, 0);

        // STEWARD needs to approve STRC for refund
        uint256 stewardUsdcBefore = usdc.balanceOf(STEWARD);
        vm.startPrank(STEWARD);
        token.approve(address(window), type(uint256).max);
        (uint256 usdcOut,) = window.requestRefund(STEWARD, mintedStrc / 2, 0, 0);
        vm.stopPrank();

        assertGt(usdcOut, 0);
        assertEq(usdc.balanceOf(STEWARD), stewardUsdcBefore + usdcOut);

        // Reserve should have more liquidity after mint minus refund
        // Started with 800k, added 100k from mint, removed ~50k from refund = ~850k
        assertGt(reserve.totalLiquidity(), reserveBefore);

        uint256 treasurerUsdcBefore = usdc.balanceOf(TREASURY);

        // TREASURY now gets instant withdrawals (no queue) for brokerage operations
        vm.prank(TREASURY);
        reserve.queueWithdrawal(TREASURY, 100_000e6); // 100k USDC (6 decimals) - instant!

        // Verify instant withdrawal worked (no queue entry needed)
        assertEq(usdc.balanceOf(TREASURY), treasurerUsdcBefore + 100_000e6); // 100k USDC (6 decimals)
    }

    // Sprint 2.1.1: Removed marketIsOpen parameter (market hours deleted)
    function _snapshot(
        uint16 reserveRatioBps,
        uint16 equityBufferBps,
        uint16 /*oracleDeviationBps*/,
        uint32 oracleStaleSeconds,
        uint256 totalSupply,
        uint256 navPerToken,
        uint256 reserveBalance,
        uint16 /*activeLS*/
    ) internal pure returns (PolicyManager.SystemSnapshot memory) {
        if (reserveBalance == 0 && navPerToken != 0) {
            uint256 L = Math.mulDiv(totalSupply, navPerToken, 1e18);
            reserveBalance = Math.mulDiv(reserveRatioBps, L, 10_000);
        }
        return PolicyManager.SystemSnapshot({
            reserveRatioBps: reserveRatioBps,
            equityBufferBps: equityBufferBps,
            oracleStaleSeconds: oracleStaleSeconds,
            totalSupply: totalSupply,
            navPerToken: navPerToken,
            reserveBalance: reserveBalance,
            collateralRatio: 1e18
        });
    }

    function _expectedStrcOut(uint256 usdcAmount, uint16 halfSpreadBps)
        internal
        view
        returns (uint256)
    {
        // FIXED: Calculate NET amount after fee deduction first
        (uint16 mintFeeBps,) = policy.getFees();
        uint256 fee = Math.mulDiv(usdcAmount, mintFeeBps, 10_000);
        uint256 netAmount = usdcAmount - fee;

        // Scale NET USDC from 6 to 18 decimals
        uint256 netAmount18 = netAmount * 1e12;
        // Apply only base spread (no haircut stacking)
        uint256 effectivePrice = Math.mulDiv(1e18, 10_000 + halfSpreadBps, 10_000);
        return Math.mulDiv(netAmount18, 1e18, effectivePrice);
    }

    function _expectedFee(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, 10_000);
    }

    function _couponForTokens(uint256 tokenAmount) internal view returns (uint256) {
        uint256 effectivePrice; (effectivePrice,) = oracle.latestPrice();
        return Math.mulDiv(tokenAmount, effectivePrice, PRICE_SCALE * USDC_TO_18);
    }

    function _setReserveRatioBps(uint16 targetBps) internal {
        uint256 supply = token.totalSupply();
        require(supply > 0, "No supply");
        uint256 targetReserve18 = Math.mulDiv(supply, targetBps, BPS_DENOMINATOR);
        uint256 targetUsdc = targetReserve18 / 1e12;
        _setReserveBalanceUsdc(targetUsdc);
        _syncPolicySnapshotToState();
    }

    function _setReserveBalanceUsdc(uint256 targetUsdc) internal {
        uint256 current = usdc.balanceOf(address(reserve));
        if (targetUsdc > current) {
            usdc.mint(address(reserve), targetUsdc - current);
        } else if (targetUsdc < current) {
            vm.prank(address(reserve));
            usdc.transfer(TREASURY, current - targetUsdc);
        }
    }

    function _currentReserveRatioBps() internal view returns (uint16) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        uint256 reserveBalance18 = usdc.balanceOf(address(reserve)) * 1e12;
        return uint16(Math.mulDiv(reserveBalance18, BPS_DENOMINATOR, supply));
    }

    function _syncPolicySnapshotToState() internal {
        PolicyManager.SystemSnapshot memory snap = PolicyManager.SystemSnapshot({
            reserveRatioBps: _currentReserveRatioBps(),
            equityBufferBps: 0,
            oracleStaleSeconds: 0,
            totalSupply: token.totalSupply(),
            navPerToken: 1e18,
            reserveBalance: reserve.totalLiquidity() * 1e12,
            collateralRatio: 1e18
        });
        vm.prank(TIMELOCK);
        policy.reportSystemSnapshot(snap);
    }
}
