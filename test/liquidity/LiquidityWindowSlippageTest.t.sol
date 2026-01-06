// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {
    LiquidityWindow,
    IBuckToken,
    IPolicyManager,
    ILiquidityReserve
} from "src/liquidity/LiquidityWindow.sol";
import {IOracleAdapter} from "src/policy/PolicyManager.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

// Mock contracts
contract MockStrc is IBuckToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract MockPolicyManager is IPolicyManager {
    bool public mintAllowed = true;
    bool public refundAllowed = true;
    uint16 public mintFeeBps = 50;
    uint16 public refundFeeBps = 50;
    uint16 public halfSpreadBps = 50;
    address public oracle; // Oracle reference for CAP pricing

    function setOracle(address oracle_) external {
        oracle = oracle_;
    }

    function checkMintCap(uint256) external view returns (bool) {
        return mintAllowed;
    }

    function recordMint(uint256) external {}

    function checkRefundCap(uint256) external view returns (bool) {
        return refundAllowed;
    }

    function recordRefund(uint256) external {}

    function getFees() external view returns (uint16, uint16) {
        return (mintFeeBps, refundFeeBps);
    }

    function getHalfSpread() external view returns (uint16) {
        return halfSpreadBps;
    }

    function getDexFees() external pure returns (uint16, uint16) {
        return (10, 10); // 0.1% buy, 0.1% sell (10 bps each)
    }

    function getCAPPrice() external view returns (uint256) {
        // If oracle is set, use its price (for backward compatibility)
        if (oracle != address(0)) {
            (uint256 price,) = IOracleAdapter(oracle).latestPrice();
            return price;
        }
        return 1e18; // $1.00 default internal
    }

    function currentBand() external pure returns (Band) {
        return Band.Green; // Default to GREEN band for tests
    }

    function refreshBand() external pure returns (Band) {
        return Band.Green; // Mock: always return GREEN for tests
    }

    function getBandFloorBps(Band) external pure returns (uint16) {
        return 500; // 5% floor
    }

    function getMintParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        uint256 capPrice = 1e18;
        if (oracle != address(0)) {
            (capPrice,) = IOracleAdapter(oracle).latestPrice();
        }
        return MintParameters({
            capPrice: capPrice,
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: mintAllowed,
            currentBand: Band.Green
        });
    }

    function getRefundParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        uint256 capPrice = 1e18;
        if (oracle != address(0)) {
            (capPrice,) = IOracleAdapter(oracle).latestPrice();
        }
        return MintParameters({
            capPrice: capPrice,
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: refundAllowed,
            currentBand: Band.Green
        });
    }
}

contract MockOracleAdapter is IOracleAdapter {
    uint256 public price = 1e18;
    uint256 public updatedAt = block.timestamp;
    uint256 public lastUpdateBlock;

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isHealthy(uint256) external pure returns (bool) {
        return true;
    }

    function getLastPriceUpdateBlock() external view returns (uint256) {
        return lastUpdateBlock;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
        updatedAt = block.timestamp;
        lastUpdateBlock = block.number;
    }

    function setStrictMode(bool) external {}
}

contract MockLiquidityReserve is ILiquidityReserve {
    uint256 public lastDeposit;
    uint256 public lastWithdrawalAmount;
    address public lastWithdrawTo;
    address public usdc;
    address public liquidityWindow;

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setLiquidityWindow(address _window) external {
        liquidityWindow = _window;
    }

    function recordDeposit(uint256 amount) external {
        lastDeposit = amount;
    }

    function queueWithdrawal(address to, uint256 amount) external {
        lastWithdrawTo = to;
        lastWithdrawalAmount = amount;

        // Mimic real LiquidityReserve behavior: instant withdrawal for LiquidityWindow refunds
        if (msg.sender == liquidityWindow && usdc != address(0)) {
            // Transfer USDC to recipient (instant withdrawal)
            MockUSDC(usdc).transfer(to, amount);
        }
    }
}

/// @title LiquidityWindowSlippageTest
/// @notice Comprehensive tests for slippage protection in LiquidityWindow
contract LiquidityWindowSlippageTest is BaseTest {
    LiquidityWindow public window;
    MockStrc public token;
    MockPolicyManager public policy;
    MockOracleAdapter public oracle;
    MockLiquidityReserve public reserve;
    MockUSDC public usdc;

    address constant TIMELOCK = address(0x1000);
    address constant TREASURY = address(0x2000);
    address constant STEWARD = address(0x3000);
    address constant RECIPIENT = address(0x4000);
    address constant SETTLER = address(0x5000);

    uint256 constant INITIAL_PRICE = 1e18; // $1.00
    uint256 constant PRICE_SCALE = 1e18;

    event PriceTooHigh(uint256 effectivePrice, uint256 maxPrice);
    event PriceTooLow(uint256 effectivePrice, uint256 minPrice);
    event MinAmountNotMet();
    event TicketTooOld(uint256 age, uint256 maxAge);

    function setUp() public {
        // Deploy mocks
        token = new MockStrc();
        policy = new MockPolicyManager();
        oracle = new MockOracleAdapter();
        reserve = new MockLiquidityReserve();
        usdc = new MockUSDC();

        // Deploy LiquidityWindow
        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));

        // Configure MockReserve
        reserve.setUSDC(address(usdc));
        reserve.setLiquidityWindow(address(window));

        // Configure MockPolicy to use oracle for CAP pricing
        policy.setOracle(address(oracle));

        // Configure window
        vm.startPrank(TIMELOCK);
        window.setUSDC(address(usdc));
        vm.stopPrank();

        vm.prank(TIMELOCK);
        window.configureFeeSplit(5000, TREASURY);

        // Setup oracle price
        oracle.setPrice(INITIAL_PRICE);

        // Move past block-fresh window after oracle price update
        vm.roll(block.number + 2);

        // Setup balances and USDC
        token.mint(STEWARD, 10_000e18);
        usdc.mint(STEWARD, 10_000e6); // 10,000 USDC
        usdc.mint(address(reserve), 10_000e6); // Fund reserve for refunds

        vm.startPrank(STEWARD);
        token.approve(address(window), type(uint256).max);
        usdc.approve(address(window), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Mint Slippage Protection Tests
    // -------------------------------------------------------------------------

    function testMintSlippageProtection_MinStrcOut() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        // FIXED: Now mints NET amount after fee deduction
        // Mint fee: 0.5% = 5 USDC
        // Net: 995 USDC
        // With 0.5% spread: effectivePrice = 1.005e18
        // strcOut = (995e18) / 1.005e18 ≈ 990.049751e18
        uint256 minStrcOut = 990e18;

        // Should succeed with minimum requirement
        vm.prank(STEWARD);
        (uint256 strcOut,) = window.requestMint(RECIPIENT, usdcAmount, minStrcOut, 0);
        assertGe(strcOut, minStrcOut, "Output less than minimum");
        // Verify approximate value (accounting for rounding)
        assertApproxEqRel(strcOut, 990.049751e18, 0.001e18); // 0.1% tolerance
    }

    function testMintSlippageProtection_MinStrcOutReverts() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 minStrcOut = 1000e18; // Impossible due to spread

        vm.prank(STEWARD);
        vm.expectRevert(LiquidityWindow.MinAmountNotMet.selector);
        window.requestMint(RECIPIENT, usdcAmount, minStrcOut, 0);
    }

    function testMintSlippageProtection_MaxEffectivePrice() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 maxPrice = 1.005e18; // Max acceptable price

        // Should succeed when price is below max
        vm.prank(STEWARD);
        (uint256 strcOut,) = window.requestMint(RECIPIENT, usdcAmount, 0, maxPrice);
        assertGt(strcOut, 0);
    }

    function testMintSlippageProtection_MaxEffectivePriceReverts() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 maxPrice = 0.999e18; // Below current effective price

        vm.prank(STEWARD);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.PriceTooHigh.selector,
                1.005e18, // effective price with spread
                maxPrice
            )
        );
        window.requestMint(RECIPIENT, usdcAmount, 0, maxPrice);
    }

    // -------------------------------------------------------------------------
    // Refund Slippage Protection Tests
    // -------------------------------------------------------------------------

    function testRefundSlippageProtection_MinUsdcOut() public {
        // First mint some STRC
        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, 0); // 1000 USDC (6 decimals)

        uint256 strcAmount = 500e18;
        // With 0.5% spread: effectivePrice = 0.995e18
        // grossUsdc = 500e18 * 0.995e18 / 1e18 = 497.5e18
        // Scaled to 6 decimals: 497.5e6
        // fee = 497.5e6 * 0.005 = 2.4875e6
        // net = 497.5e6 - 2.4875e6 ≈ 495e6
        uint256 minUsdcOut = 495e6; // 495 USDC

        vm.prank(STEWARD);
        (uint256 usdcOut,) = window.requestRefund(RECIPIENT, strcAmount, minUsdcOut, 0);
        assertGe(usdcOut, minUsdcOut);
    }

    function testRefundSlippageProtection_MinUsdcOutReverts() public {
        // First mint some STRC
        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, 0); // 1000 USDC

        uint256 strcAmount = 500e18;
        uint256 minUsdcOut = 500e6; // Impossible due to spread and fees

        vm.prank(STEWARD);
        vm.expectRevert(LiquidityWindow.MinAmountNotMet.selector);
        window.requestRefund(RECIPIENT, strcAmount, minUsdcOut, 0);
    }

    function testRefundSlippageProtection_MinEffectivePrice() public {
        // First mint some STRC
        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, 0); // 1000 USDC

        uint256 strcAmount = 500e18;
        uint256 minPrice = 0.99e18; // Min acceptable price

        vm.prank(STEWARD);
        (uint256 usdcOut,) = window.requestRefund(RECIPIENT, strcAmount, 0, minPrice);
        assertGt(usdcOut, 0);
    }

    function testRefundSlippageProtection_MinEffectivePriceReverts() public {
        // First mint some STRC
        vm.prank(STEWARD);
        window.requestMint(STEWARD, 1000e6, 0, 0); // 1000 USDC

        uint256 strcAmount = 500e18;
        uint256 minPrice = 0.996e18; // Above current effective price after spread

        vm.prank(STEWARD);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.PriceTooLow.selector,
                0.995e18, // effective price with spread
                minPrice
            )
        );
        window.requestRefund(RECIPIENT, strcAmount, 0, minPrice);
    }
}
