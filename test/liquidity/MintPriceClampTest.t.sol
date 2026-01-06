// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {
    LiquidityWindow,
    IBuckToken,
    IPolicyManager,
    ILiquidityReserve
} from "src/liquidity/LiquidityWindow.sol";
import {IOracleAdapter} from "src/policy/PolicyManager.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice Mock BUCK token for testing
contract MockSTRXForClamp is IBuckToken {
    uint256 private _totalSupply;
    mapping(address => uint256) public balanceOf;

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        _totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        _totalSupply -= amount;
    }
}

/// @notice Mock PolicyManager with configurable CAP price for edge case testing
contract MockPolicyManagerForClamp is IPolicyManager {
    uint256 public capPrice = 1e18;
    uint16 public halfSpreadBps = 0;
    uint16 public mintFeeBps = 0;
    uint16 public refundFeeBps = 0;

    function setCAPPrice(uint256 price) external {
        capPrice = price;
    }

    function setHalfSpreadBps(uint16 spread) external {
        halfSpreadBps = spread;
    }

    function setFees(uint16 mintFee, uint16 refundFee) external {
        mintFeeBps = mintFee;
        refundFeeBps = refundFee;
    }

    function checkMintCap(uint256) external pure returns (bool) {
        return true;
    }

    function recordMint(uint256) external {}

    function checkRefundCap(uint256) external pure returns (bool) {
        return true;
    }

    function recordRefund(uint256) external {}

    function getFees() external view returns (uint16, uint16) {
        return (mintFeeBps, refundFeeBps);
    }

    function getHalfSpread() external view returns (uint16) {
        return halfSpreadBps;
    }

    function getDexFees() external pure returns (uint16, uint16) {
        return (10, 10);
    }

    function getCAPPrice() external view returns (uint256) {
        return capPrice;
    }

    function currentBand() external pure returns (Band) {
        return Band.Green;
    }

    function refreshBand() external pure returns (Band) {
        return Band.Green;
    }

    function getBandFloorBps(Band) external pure returns (uint16) {
        return 500; // 5% floor
    }

    function getMintParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        return MintParameters({
            capPrice: capPrice,
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: true,
            currentBand: Band.Green
        });
    }

    function getRefundParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        return MintParameters({
            capPrice: capPrice,
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: true,
            currentBand: Band.Green
        });
    }
}

/// @notice Mock Oracle for testing
contract MockOracleForClamp is IOracleAdapter {
    uint256 public price = 1e18;
    uint256 public lastUpdateBlock;

    constructor() {
        lastUpdateBlock = block.number;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, block.timestamp);
    }

    function isHealthy(uint256) external pure returns (bool) {
        return true;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastUpdateBlock;
    }

    function setStrictMode(bool) external {}
}

/// @notice Mock Reserve for testing
contract MockReserveForClamp is ILiquidityReserve {
    address public usdc;
    address public liquidityWindow;

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setLiquidityWindow(address _window) external {
        liquidityWindow = _window;
    }

    function recordDeposit(uint256) external {}

    function queueWithdrawal(address to, uint256 amount) external {
        if (msg.sender == liquidityWindow && usdc != address(0)) {
            MockUSDC(usdc).transfer(to, amount);
        }
    }
}

/// @title MintPriceClampTest
/// @notice Tests the CAP price invariant: effective mint price < $1 when CR < 1
/// @dev Verifies fix for Cyfrin Issue #4
contract MintPriceClampTest is Test, BaseTest {
    LiquidityWindow internal window;
    MockSTRXForClamp internal token;
    MockPolicyManagerForClamp internal policy;
    MockOracleForClamp internal oracle;
    MockReserveForClamp internal reserve;
    MockUSDC internal usdc;

    address internal constant ADMIN = address(0x1000);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        token = new MockSTRXForClamp();
        policy = new MockPolicyManagerForClamp();
        oracle = new MockOracleForClamp();
        reserve = new MockReserveForClamp();
        usdc = new MockUSDC();

        window = deployLiquidityWindow(ADMIN, address(token), address(reserve), address(policy));

        vm.startPrank(ADMIN);
        window.setUSDC(address(usdc));
        vm.stopPrank();

        reserve.setUSDC(address(usdc));
        reserve.setLiquidityWindow(address(window));

        // Fund user with USDC
        usdc.mint(USER, 1_000_000e6);

        // Move past block-fresh window
        vm.roll(block.number + 2);
    }

    /// @notice Helper to calculate expected BUCK output for a given effective price
    function _expectedStrxOut(uint256 usdcAmount, uint256 effectivePrice) internal pure returns (uint256) {
        uint256 netAmount18 = usdcAmount * 1e12; // Scale 6 decimals to 18
        return (netAmount18 * PRICE_SCALE) / effectivePrice;
    }

    /// @notice Helper to calculate effective price with spread (same logic as LiquidityWindow)
    function _calcEffectivePrice(uint256 basePrice, uint16 spreadBps) internal pure returns (uint256) {
        if (spreadBps == 0) return basePrice;
        uint256 num = basePrice * (BPS_DENOMINATOR + spreadBps);
        return (num + (BPS_DENOMINATOR - 1)) / BPS_DENOMINATOR; // Round up
    }

    /// @notice Test: Without clamp, spread would push price above $1
    /// @dev This test verifies the edge case exists and the clamp fixes it
    function test_MintPriceClampedBelowOneDollar() public {
        // Set CAP price to just below $1 (simulating CR < 1 scenario)
        // Using 1e18 - 1 as the max possible CAP when CR < 1
        uint256 capPriceBelowPeg = 1e18 - 1;
        policy.setCAPPrice(capPriceBelowPeg);

        // Set spread to 20 bps (RED band spread)
        uint16 spreadBps = 20;
        policy.setHalfSpreadBps(spreadBps);

        // Calculate what effective price WOULD be without clamp
        uint256 unclampedEffectivePrice = _calcEffectivePrice(capPriceBelowPeg, spreadBps);

        // Verify the edge case: unclampedEffectivePrice > $1
        assertGt(unclampedEffectivePrice, PRICE_SCALE, "Edge case: unclamped price should exceed $1");

        // Now mint and verify the clamp was applied
        uint256 usdcAmount = 1000e6; // 1000 USDC

        vm.startPrank(USER);
        usdc.approve(address(window), usdcAmount);
        (uint256 strxOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);
        vm.stopPrank();

        // Calculate expected BUCK if price was clamped to $1 - 1 wei
        uint256 clampedPrice = PRICE_SCALE - 1;
        uint256 expectedStrxClamped = _expectedStrxOut(usdcAmount, clampedPrice);

        // Calculate what BUCK would be without clamping (lower amount due to higher price)
        uint256 expectedStrxUnclamped = _expectedStrxOut(usdcAmount, unclampedEffectivePrice);

        // Verify: User got the clamped amount (more BUCK than unclamped would give)
        assertEq(strxOut, expectedStrxClamped, "STRX output should match clamped price calculation");
        assertGt(strxOut, expectedStrxUnclamped, "Clamped output should be greater than unclamped");
    }

    /// @notice Test: When CAP >= $1, no clamping occurs (spread applies normally)
    function test_NoClamping_WhenCAPAtPeg() public {
        // CAP at exactly $1 (CR >= 1 scenario) - no clamping should occur
        policy.setCAPPrice(1e18);
        policy.setHalfSpreadBps(20);

        uint256 usdcAmount = 1000e6;
        uint256 expectedEffectivePrice = _calcEffectivePrice(1e18, 20);

        vm.startPrank(USER);
        usdc.approve(address(window), usdcAmount);
        (uint256 strxOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);
        vm.stopPrank();

        // With CAP at $1, spread pushes price above $1 - this is allowed when CR >= 1
        uint256 expectedStrx = _expectedStrxOut(usdcAmount, expectedEffectivePrice);
        assertEq(strxOut, expectedStrx, "When CAP >= $1, spread should apply normally");
    }

    /// @notice Test: Edge case with maximum spread (RED band: 20 bps)
    function test_ClampWithMaximumSpread() public {
        // CAP just below $1
        policy.setCAPPrice(0.999e18); // $0.999
        policy.setHalfSpreadBps(20); // 20 bps spread

        // Without clamp: $0.999 * 1.002 = $1.000998 (above $1)
        uint256 unclampedPrice = _calcEffectivePrice(0.999e18, 20);
        assertGt(unclampedPrice, PRICE_SCALE, "Unclamped should exceed $1");

        uint256 usdcAmount = 1000e6;

        vm.startPrank(USER);
        usdc.approve(address(window), usdcAmount);
        (uint256 strxOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);
        vm.stopPrank();

        // Verify clamped to $1 - 1 wei
        uint256 expectedClamped = _expectedStrxOut(usdcAmount, PRICE_SCALE - 1);
        assertEq(strxOut, expectedClamped, "Should be clamped at max spread");
    }

    /// @notice Test: When spread doesn't push over $1, no clamping needed
    function test_NoClamping_WhenSpreadStaysBelowDollar() public {
        // CAP at $0.99 with small spread won't exceed $1
        policy.setCAPPrice(0.99e18); // $0.99
        policy.setHalfSpreadBps(10); // 10 bps spread

        // $0.99 * 1.001 = $0.99099 (still below $1)
        uint256 effectivePrice = _calcEffectivePrice(0.99e18, 10);
        assertLt(effectivePrice, PRICE_SCALE, "Should stay below $1");

        uint256 usdcAmount = 1000e6;

        vm.startPrank(USER);
        usdc.approve(address(window), usdcAmount);
        (uint256 strxOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);
        vm.stopPrank();

        // Should use the unclamped effective price
        uint256 expected = _expectedStrxOut(usdcAmount, effectivePrice);
        assertEq(strxOut, expected, "No clamping when price stays below $1");
    }

    /// @notice Test: Verify invariant holds across range of CAP prices near $1
    function test_Fuzz_InvariantMintPriceBelowDollar(uint256 capPrice) public {
        // Bound CAP price to realistic range: $0.95 to $0.9999999...
        capPrice = bound(capPrice, 0.95e18, 1e18 - 1);

        policy.setCAPPrice(capPrice);
        policy.setHalfSpreadBps(20); // Use max spread

        uint256 usdcAmount = 1000e6;

        vm.startPrank(USER);
        usdc.approve(address(window), usdcAmount);
        (uint256 strxOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, 0);
        vm.stopPrank();

        // Calculate what effective price was used based on BUCK output
        // strxOut = (usdcAmount * 1e12 * PRICE_SCALE) / effectivePrice
        // effectivePrice = (usdcAmount * 1e12 * PRICE_SCALE) / strxOut
        uint256 impliedEffectivePrice = (usdcAmount * 1e12 * PRICE_SCALE) / strxOut;

        // INVARIANT: When CAP < $1, effective price must be < $1
        assertLt(impliedEffectivePrice, PRICE_SCALE, "Invariant violated: effective price >= $1 when CAP < $1");
    }
}
