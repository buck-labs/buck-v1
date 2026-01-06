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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock BUCK token for regression testing
contract MockSTRXForFloor is IBuckToken {
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

/// @notice Mock PolicyManager with CONFIGURABLE floor to test both correct and buggy scenarios
/// @dev Can switch between correct and wrong (smaller) floor to prove the fix works
contract MockPolicyManagerForFloorRegression is IPolicyManager {
    // CRITICAL: The real bug used deviationThresholdBps (25-100 bps) instead of floorBps
    // This is SMALLER, meaning LESS reserve protection - refunds allowed when they shouldn't be!
    // Real values from PolicyManager:
    //   - deviationThresholdBps: 25 bps (Green), 50 bps (Yellow), 100 bps (Red)
    //   - floorBps: 100 bps (all bands)
    // For test clarity, we use larger differences:
    uint16 public constant CORRECT_FLOOR_BPS = 500;   // 5% - correct reserve protection
    uint16 public constant WRONG_FLOOR_BPS = 25;      // 0.25% - simulates deviationThresholdBps (too low!)

    uint256 public capPrice = 1e18;
    bool public useWrongFloor = false; // Toggle to simulate the bug

    function setCAPPrice(uint256 price) external {
        capPrice = price;
    }

    /// @notice Toggle between correct and wrong floor to test both scenarios
    function setUseWrongFloor(bool _useWrong) external {
        useWrongFloor = _useWrong;
    }

    function checkMintCap(uint256) external pure returns (bool) {
        return true;
    }

    function recordMint(uint256) external {}

    function checkRefundCap(uint256) external pure returns (bool) {
        return true;
    }

    function recordRefund(uint256) external {}

    function getFees() external pure returns (uint16, uint16) {
        return (0, 0);
    }

    function getHalfSpread() external pure returns (uint16) {
        return 0;
    }

    function getDexFees() external pure returns (uint16, uint16) {
        return (0, 0);
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

    /// @notice Returns floor based on toggle - allows testing both correct and buggy behavior
    function getBandFloorBps(Band) external view returns (uint16) {
        return useWrongFloor ? WRONG_FLOOR_BPS : CORRECT_FLOOR_BPS;
    }

    function getMintParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        return MintParameters({
            capPrice: capPrice,
            halfSpreadBps: 0,
            mintFeeBps: 0,
            refundFeeBps: 0,
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
            halfSpreadBps: 0,
            mintFeeBps: 0,
            refundFeeBps: 0,
            mintCapPassed: true,
            currentBand: Band.Green
        });
    }
}

/// @notice Mock Oracle for testing
contract MockOracleForFloor is IOracleAdapter {
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

/// @notice Mock Reserve that tracks withdrawals
contract MockReserveForFloor is ILiquidityReserve {
    address public usdc;
    address public liquidityWindow;
    uint256 public lastWithdrawalAmount;

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setLiquidityWindow(address _window) external {
        liquidityWindow = _window;
    }

    function recordDeposit(uint256) external {}

    function queueWithdrawal(address to, uint256 amount) external {
        lastWithdrawalAmount = amount;
        if (msg.sender == liquidityWindow && usdc != address(0)) {
            MockUSDC(usdc).transfer(to, amount);
        }
    }
}

/// @title BandFloorRegressionTest
/// @notice Regression test ensuring refunds use getBandFloorBps (not deviationThresholdBps)
/// @dev Tests the fix for ABI struct mismatch between LiquidityWindow and PolicyManager
contract BandFloorRegressionTest is Test, BaseTest {
    LiquidityWindow internal window;
    MockSTRXForFloor internal token;
    MockPolicyManagerForFloorRegression internal policy;
    MockOracleForFloor internal oracle;
    MockReserveForFloor internal reserve;
    MockUSDC internal usdc;

    address internal constant ADMIN = address(0x1000);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant USDC_SCALE = 1e12; // 18 - 6 decimals

    function setUp() public {
        token = new MockSTRXForFloor();
        policy = new MockPolicyManagerForFloorRegression();
        oracle = new MockOracleForFloor();
        reserve = new MockReserveForFloor();
        usdc = new MockUSDC();

        window = deployLiquidityWindow(ADMIN, address(token), address(reserve), address(policy));

        vm.startPrank(ADMIN);
        window.setUSDC(address(usdc));
        vm.stopPrank();

        reserve.setUSDC(address(usdc));
        reserve.setLiquidityWindow(address(window));

        // Fund user with USDC for minting
        usdc.mint(USER, 1_000_000e6);

        // Move past block-fresh window
        vm.roll(block.number + 2);
    }

    /// @notice Calculate expected floor using CORRECT floorBps (5%)
    function _calculateExpectedFloorCorrect(uint256 totalSupply) internal pure returns (uint256) {
        // floorBps = 500 (5%) - proper reserve protection
        uint256 floorAmount18 = (totalSupply * 500) / BPS_DENOMINATOR;
        return floorAmount18 / USDC_SCALE; // Convert to 6 decimals
    }

    /// @notice Calculate expected floor using WRONG deviationThresholdBps (0.25%)
    /// @dev The real bug: deviationThresholdBps is SMALLER than floorBps, giving LESS protection
    function _calculateExpectedFloorWrong(uint256 totalSupply) internal pure returns (uint256) {
        // deviationThresholdBps = 25 (0.25%) - dangerously low floor!
        uint256 floorAmount18 = (totalSupply * 25) / BPS_DENOMINATOR;
        return floorAmount18 / USDC_SCALE; // Convert to 6 decimals
    }

    /// @notice REGRESSION TEST: Proves correct floor blocks drain, wrong floor allows it
    /// @dev The real bug: wrong floor (0.25%) is SMALLER, allowing reserve to drain!
    function test_RefundUsesCorrectFloorBps_NotDeviationThreshold() public {
        // Setup: Directly mint BUCK to user (bypass requestMint to control reserve funding)
        uint256 strxMinted = 100_000e18; // 100k STRX
        token.mint(USER, strxMinted);

        // Calculate floors using both values
        uint256 totalSupply = token.totalSupply();
        uint256 correctFloor = _calculateExpectedFloorCorrect(totalSupply);   // 5% = 5,000 USDC
        uint256 wrongFloor = _calculateExpectedFloorWrong(totalSupply);       // 0.25% = 250 USDC

        // Verify our test setup: wrong floor is SMALLER (the real danger!)
        assertEq(correctFloor, 5_000e6, "Correct floor should be 5% of 100k = 5k USDC");
        assertEq(wrongFloor, 250e6, "Wrong floor should be 0.25% of 100k = 250 USDC");
        assertLt(wrongFloor, correctFloor, "Wrong floor must be SMALLER (this is the bug!)");

        // Fund reserve with amount BETWEEN the two floors: 2% = 2,000 USDC
        // - Correct (5% floor): 2k < 5k floor → not enough → refund should FAIL
        // - Wrong (0.25% floor): 2k > 250 floor → appears fine → refund would SUCCEED (BUG!)
        uint256 reserveFunding = 2_000e6; // 2% of supply
        usdc.mint(address(reserve), reserveFunding);

        // Verify reserve is BETWEEN the two floors
        assertGt(reserveFunding, wrongFloor, "Reserve must be > wrong floor (250 USDC)");
        assertLt(reserveFunding, correctFloor, "Reserve must be < correct floor (5k USDC)");

        uint256 refundStrx = 1_000e18; // 1k BUCK = 1k USDC at $1
        uint256 expectedGrossUsdc = refundStrx / USDC_SCALE;

        // ========== PART 1: Prove WRONG floor (0.25%) would ALLOW drain (BUG!) ==========
        policy.setUseWrongFloor(true);

        vm.startPrank(USER);
        // With wrong floor: available = 2000 - 250 = 1750 USDC, enough for 1k refund
        // This is DANGEROUS - reserve drains below intended protection!
        (uint256 buggyUsdcOut,) = window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();

        assertEq(buggyUsdcOut, expectedGrossUsdc, "Bug allows refund that drains reserve!");

        // ========== PART 2: Prove CORRECT floor (5%) BLOCKS drain (FIX!) ==========
        policy.setUseWrongFloor(false);

        // Mint more BUCK for second refund attempt
        token.mint(USER, refundStrx);

        vm.startPrank(USER);
        // With correct floor: available = 1000 - 5000 = 0, refund blocked!
        // Reserve now has 1000 USDC after first refund (2000 - 1000), still < 5k floor
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.InsufficientLiquidity.selector,
                expectedGrossUsdc, // 1000 USDC requested
                0                  // 0 available (reserve < floor)
            )
        );
        window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();
    }

    /// @notice Verify that with reserve BELOW correct floor, refund is blocked
    /// @dev This confirms the floor check is actually working
    function test_RefundBlockedWhenBelowCorrectFloor() public {
        // Directly mint BUCK to user (bypass requestMint which would fund reserve)
        uint256 strxMinted = 100_000e18; // 100k STRX
        token.mint(USER, strxMinted);

        // Fund reserve with less than 5% floor
        // Floor = 5% of 100k BUCK = 5k USDC
        // Fund with only 4k USDC (below floor)
        uint256 reserveFunding = 4_000e6;
        usdc.mint(address(reserve), reserveFunding);

        // Try to refund - should fail due to insufficient liquidity
        uint256 refundStrx = strxMinted / 10; // 10k STRX
        // grossUsdc = 10k USDC (at $1 price), availableLiquidity = 0 (4k < 5k floor)
        uint256 expectedGrossUsdc = refundStrx / USDC_SCALE; // 10k USDC

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.InsufficientLiquidity.selector,
                expectedGrossUsdc,
                0 // availableLiquidity is 0 when reserve < floor
            )
        );
        window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();
    }

    /// @notice Verify refund works when reserve is exactly at correct floor + refund amount
    function test_RefundSucceedsAtExactAvailableLiquidity() public {
        // Directly mint BUCK to user (bypass requestMint to control reserve funding)
        uint256 strxMinted = 100_000e18; // 100k STRX
        token.mint(USER, strxMinted);

        // Calculate exact amounts needed
        uint256 correctFloor = _calculateExpectedFloorCorrect(token.totalSupply()); // 5k USDC
        uint256 refundStrx = 10_000e18; // 10k STRX
        uint256 expectedUsdcOut = 10_000e6; // At $1, get 10k USDC

        // Fund reserve with exactly floor + refund amount
        uint256 reserveFunding = correctFloor + expectedUsdcOut; // 5k + 10k = 15k
        usdc.mint(address(reserve), reserveFunding);

        // Refund should succeed exactly
        vm.startPrank(USER);
        (uint256 usdcOut,) = window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();

        assertEq(usdcOut, expectedUsdcOut, "Should get exact expected USDC");
    }

    /// @notice Fuzz test: proves wrong floor allows drain, correct floor blocks it
    /// @dev The real bug: wrong floor is SMALLER, so refunds succeed when they shouldn't
    function test_Fuzz_FloorAlwaysUsesCorrectBps(uint256 strxSupply) public {
        // Bound BUCK supply to reasonable range (10k to 10M STRX)
        // Minimum 10k ensures floors have enough precision in USDC (6 decimals)
        strxSupply = bound(strxSupply, 10_000e18, 10_000_000e18);

        // Directly mint BUCK to user (bypass requestMint to control reserve funding)
        token.mint(USER, strxSupply);

        // Calculate both floors
        uint256 totalSupply = token.totalSupply();
        uint256 correctFloor = _calculateExpectedFloorCorrect(totalSupply); // 5%
        uint256 wrongFloor = _calculateExpectedFloorWrong(totalSupply);     // 0.25%

        // Fund reserve BETWEEN the two floors (at 2% of supply in USDC terms)
        // Wrong floor (0.25%) < reserve (2%) < correct floor (5%)
        uint256 reserveFunding = (totalSupply * 200) / BPS_DENOMINATOR / USDC_SCALE;
        usdc.mint(address(reserve), reserveFunding);

        // CRITICAL: Verify reserve is BETWEEN the two floors
        assertGt(reserveFunding, wrongFloor, "Reserve must be > wrong 0.25% floor");
        assertLt(reserveFunding, correctFloor, "Reserve must be < correct 5% floor");

        // Small refund that fits within "available" liquidity if using wrong floor
        uint256 refundStrx = strxSupply / 1000; // 0.1% of supply

        // ========== PART 1: Prove WRONG floor would ALLOW drain (BUG!) ==========
        policy.setUseWrongFloor(true);

        vm.startPrank(USER);
        // With wrong floor: refund succeeds (reserve drains below intended protection)
        (uint256 buggyUsdcOut,) = window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();

        assertGt(buggyUsdcOut, 0, "Bug: wrong floor allows dangerous refund");

        // ========== PART 2: Prove CORRECT floor BLOCKS drain (FIX!) ==========
        policy.setUseWrongFloor(false);

        // Mint more BUCK for second refund attempt
        token.mint(USER, refundStrx);

        // Calculate expected gross USDC for error check
        uint256 expectedGrossUsdc = refundStrx / USDC_SCALE;

        vm.startPrank(USER);
        // With correct floor: refund blocked (reserve protected)
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.InsufficientLiquidity.selector,
                expectedGrossUsdc, // requested amount
                0                  // 0 available (reserve < floor after first refund)
            )
        );
        window.requestRefund(USER, refundStrx, 0, 0);
        vm.stopPrank();
    }
}
