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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockSTRX is IBuckToken {
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

contract MockPolicyManager is IPolicyManager {
    bool public mintAllowed = true;
    bool public refundAllowed = true;

    uint256 public lastMintAmountBps;
    uint256 public lastRefundAmountBps;
    uint16 public mintFeeBps;
    uint16 public refundFeeBps;
    uint16 public halfSpreadBps;
    address public oracle; // Oracle reference for CAP pricing

    function setOracle(address oracle_) external {
        oracle = oracle_;
    }

    function setMintAllowed(bool allowed) external {
        mintAllowed = allowed;
    }

    function setRefundAllowed(bool allowed) external {
        refundAllowed = allowed;
    }

    function setFees(uint16 mintFee, uint16 refundFee, uint16 halfSpread) external {
        mintFeeBps = mintFee;
        refundFeeBps = refundFee;
        halfSpreadBps = halfSpread;
    }

    function checkMintCap(uint256) external view returns (bool) {
        return mintAllowed;
    }

    function recordMint(uint256 amountBps) external {
        lastMintAmountBps = amountBps;
    }

    function checkRefundCap(uint256) external view returns (bool) {
        return refundAllowed;
    }

    function recordRefund(uint256 amountBps) external {
        lastRefundAmountBps = amountBps;
    }

    function getFees() external view returns (uint16, uint16) {
        return (mintFeeBps, refundFeeBps);
    }

    function getHalfSpread() external view returns (uint16) {
        return halfSpreadBps;
    }

    function getDexFees() external pure returns (uint16, uint16) {
        return (10, 10); // 0.1% buy, 0.1% sell (10 bps each)
    }

    function getCAPPrice() external pure returns (uint256) {
        return 1e18; // $1.00 default for tests
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

    error OracleUnhealthy();

    function getMintParameters(uint256)
        external
        view
        returns (MintParameters memory)
    {
        // Simulate getCAPPrice with oracle health check (legacy behavior when no collateralAttestation)
        if (oracle != address(0)) {
            bool healthy = IOracleAdapter(oracle).isHealthy(0);
            if (!healthy) {
                revert OracleUnhealthy();
            }
        }

        return MintParameters({
            capPrice: 1e18, // $1.00
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
        return MintParameters({
            capPrice: 1e18, // $1.00
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: refundAllowed,
            currentBand: Band.Green
        });
    }
}

contract MockOracle is IOracleAdapter {
    uint256 public price;
    uint256 public updatedAt;
    bool public healthy = true;
    uint256 public lastUpdateBlock;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
        updatedAt = block.timestamp;
        lastUpdateBlock = block.number;
    }

    function setHealthy(bool newHealthy) external {
        healthy = newHealthy;
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

contract MockReserve is ILiquidityReserve {
    uint256 public deposits;
    address public lastWithdrawTo;
    uint256 public lastWithdrawalAmount;
    address public usdc;
    address public liquidityWindow;

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setLiquidityWindow(address _window) external {
        liquidityWindow = _window;
    }

    function recordDeposit(uint256 amount) external {
        deposits += amount;
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

contract MockRecoveryToken is ERC20 {
    constructor() ERC20("Mock Recovery Token", "MRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquidityWindowTest is BaseTest {
    LiquidityWindow internal window;
    MockSTRX internal token;
    MockPolicyManager internal policy;
    MockOracle internal oracle;
    MockReserve internal reserve;
    MockUSDC internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant STEWARD = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        token = new MockSTRX();
        policy = new MockPolicyManager();
        oracle = new MockOracle();
        reserve = new MockReserve();
        usdc = new MockUSDC();

        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));

        vm.startPrank(TIMELOCK);
        window.setUSDC(address(usdc));
        vm.stopPrank();

        // Configure MockReserve
        reserve.setUSDC(address(usdc));
        reserve.setLiquidityWindow(address(window));

        // Configure MockPolicyManager
        policy.setOracle(address(oracle));
        policy.setFees(0, 0, 0);

        oracle.setPrice(1e18); // 1 USDC per STRC

        // Move past block-fresh window after oracle price update
        vm.roll(block.number + 2);

        // Fund test accounts with USDC
        usdc.mint(STEWARD, 1_000_000e6); // 1M USDC
        usdc.mint(address(reserve), 1_000_000e6); // Fund reserve for refunds
    }

    function testMintHappyPath() public {
        uint256 usdcAmount = 1_000e6; // 1000 USDC (6 decimals)

        vm.startPrank(STEWARD);
        usdc.approve(address(window), usdcAmount);
        (uint256 strcOut, uint256 fee) = window.requestMint(RECIPIENT, usdcAmount, 900e18, 0);
        vm.stopPrank();

        // With price of 1:1 and scaling, expect 1000e18 STRC for 1000e6 USDC
        assertEq(strcOut, 1_000e18);
        assertEq(fee, 0);
        assertEq(token.balanceOf(RECIPIENT), 1_000e18);
        assertEq(reserve.deposits(), usdcAmount);
    }

    function testMintRespectsMaxPrice() public {
        policy.setFees(0, 0, 100); // 1% half spread

        uint256 expectedPrice = (1e18 * (10_000 + 100)) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityWindow.PriceTooHigh.selector, expectedPrice, 1_005e15)
        );
        vm.prank(STEWARD);
        window.requestMint(RECIPIENT, 1_000e6, 0, 1_005e15); // 1000 USDC
    }

    function testRefundHappyPath() public {
        // Mint first so steward has balance
        uint256 mintAmount = 1_000e6; // 1000 USDC
        vm.startPrank(STEWARD);
        usdc.approve(address(window), mintAmount);
        window.requestMint(STEWARD, mintAmount, 0, 0);

        // Now refund half the STRC
        uint256 recipientBalanceBefore = usdc.balanceOf(RECIPIENT);
        (uint256 usdcOut, uint256 fee) = window.requestRefund(RECIPIENT, 500e18, 400e6, 0);
        vm.stopPrank();

        assertEq(usdcOut, 500e6); // Should get 500 USDC back
        assertEq(fee, 0);

        // With Option A: Reserve sends to LiquidityWindow, then LiquidityWindow routes fees and sends to recipient
        assertEq(
            reserve.lastWithdrawTo(), address(window), "Reserve sends to LiquidityWindow first"
        );
        assertEq(reserve.lastWithdrawalAmount(), 500e6, "Reserve sends gross amount");

        // Recipient should actually receive the USDC
        assertEq(
            usdc.balanceOf(RECIPIENT) - recipientBalanceBefore, 500e6, "Recipient receives net USDC"
        );
    }

    // ---------------------------------------------------------------------
    // Recovery admin
    // ---------------------------------------------------------------------

    function testRecoverERC20HappyPath() public {
        MockRecoveryToken extra = new MockRecoveryToken();
        extra.mint(address(window), 1_000e18);

        address sink = address(0xF00D);
        vm.prank(TIMELOCK);
        window.setRecoverySink(sink, true);

        vm.prank(TIMELOCK);
        window.recoverERC20(address(extra), sink, 600e18);

        assertEq(extra.balanceOf(sink), 600e18);
        assertEq(extra.balanceOf(address(window)), 400e18);
    }

    function testRecoverERC20BlockedAssetStrc() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.UnsupportedRecoveryAsset.selector, address(token)
            )
        );
        vm.prank(TIMELOCK);
        window.recoverERC20(address(token), address(reserve), 1);
    }

    function testRecoverERC20UnauthorizedCaller() public {
        MockRecoveryToken extra = new MockRecoveryToken();
        extra.mint(address(window), 500e18);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STEWARD)
        );
        vm.prank(STEWARD);
        window.recoverERC20(address(extra), address(reserve), 100e18);
    }

    function testRefundEnforcesMinPrice() public {
        policy.setFees(0, 0, 100); // 1% spread

        // Mint first
        uint256 mintAmount = 1_000e6;
        vm.startPrank(STEWARD);
        usdc.approve(address(window), mintAmount);
        window.requestMint(STEWARD, mintAmount, 0, 0);

        uint256 expectedRefundPrice = (1e18 * (10_000 - 100)) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityWindow.PriceTooLow.selector, expectedRefundPrice, 995e15
            )
        );
        window.requestRefund(RECIPIENT, 100e18, 0, 995e15);
        vm.stopPrank();
    }

    function testMintCapFailure() public {
        // Disable testnet mode to actually test cap enforcement
        vm.prank(TIMELOCK);

        // Set policy to reject mints (cap failure)
        policy.setMintAllowed(false);

        uint256 mintAmount = 1_000e6;
        vm.startPrank(STEWARD);
        usdc.approve(address(window), mintAmount);

        // Should revert due to cap check failure
        vm.expectRevert(LiquidityWindow.CapCheckFailed.selector);
        window.requestMint(RECIPIENT, mintAmount, 0, 0);
        vm.stopPrank();

        // Verify mint did NOT succeed (balance should be 0)
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testPauseLiquidityWindowBlocksMint() public {
        vm.prank(TIMELOCK);
        window.pauseLiquidityWindow();

        uint256 mintAmount = 1_000e6;
        vm.startPrank(STEWARD);
        usdc.approve(address(window), mintAmount);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        window.requestMint(RECIPIENT, mintAmount, 0, 0);
        vm.stopPrank();

        vm.prank(TIMELOCK);
        window.unpauseLiquidityWindow();

        vm.startPrank(STEWARD);
        window.requestMint(RECIPIENT, mintAmount, 0, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(RECIPIENT), 1_000e18);
    }

    function skip_testEnqueueAndCancelRefundTicket() public {
        token.mint(STEWARD, 1_000e18);

        vm.prank(STEWARD);
        // TODO: Queue removed - uint256 ticketId = window.enqueueRefundTicket(RECIPIENT, 200e18, 0);
        // TODO: Queue removed - assertEq(ticketId, 0);
        // TODO: Queue removed - assertEq(token.balanceOf(STEWARD), 800e18);

        // TODO: Queue removed - vm.prank(STEWARD);
        // TODO: Queue removed - window.cancelRefundTicket(ticketId);
        // TODO: Queue removed - assertEq(token.balanceOf(STEWARD), 1_000e18);
    }

    function skip_testSettleRefundTicketsProcessesFIFO() public view {
        // TODO: Queue removed - token.mint(STEWARD, 1_000e18);
        // TODO: Queue removed - policy.setRefundAllowed(true);
        // TODO: Queue removed - oracle.setPrice(1e18);

        // TODO: Queue removed - // Move past block-fresh window after oracle price update
        // TODO: Queue removed - vm.roll(block.number + 2);

        // TODO: Queue removed - vm.prank(STEWARD);
        // TODO: Queue removed - window.enqueueRefundTicket(RECIPIENT, 200e18, 0);

        // TODO: Queue removed - vm.prank(STEWARD);
        // TODO: Queue removed - window.enqueueRefundTicket(RECIPIENT, 150e18, 0);

        // TODO: Queue removed - vm.prank(STEWARD);
        // TODO: Queue removed - window.cancelRefundTicket(1);

        // TODO: Queue removed - vm.prank(STEWARD);
        // TODO: Queue removed - window.enqueueRefundTicket(RECIPIENT, 100e18, 0);

        // TODO: Queue removed - window.settleRefundTickets(2, 0, 0);

        // With Option A: Reserve sends to LiquidityWindow, then LiquidityWindow routes to recipient
        assertEq(
            reserve.lastWithdrawTo(), address(window), "Reserve sends to LiquidityWindow first"
        );
        assertGt(reserve.lastWithdrawalAmount(), 0);
    }

    function testNonOwnerCannotPauseLiquidityWindow() public {
        address unauthorizedCaller = address(0xBAD);

        // Non-owner account cannot call pauseLiquidityWindow()
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller)
        );
        vm.prank(unauthorizedCaller);
        window.pauseLiquidityWindow();

        // Owner (TIMELOCK) can call pauseLiquidityWindow()
        vm.prank(TIMELOCK);
        window.pauseLiquidityWindow();
    }

    function testNonOwnerCannotConfigureFeeSplit() public {
        address unauthorizedCaller = address(0xBAD);

        // Non-owner account cannot call configureFeeSplit()
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller)
        );
        vm.prank(unauthorizedCaller);
        window.configureFeeSplit(6000, address(0x9999));

        // Owner (TIMELOCK) can call configureFeeSplit()
        vm.prank(TIMELOCK);
        window.configureFeeSplit(6000, address(0x9999));
    }
}
