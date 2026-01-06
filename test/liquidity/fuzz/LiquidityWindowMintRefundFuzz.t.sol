// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    LiquidityWindow,
    IPolicyManager,
    ILiquidityReserve,
    IBuckToken
} from "src/liquidity/LiquidityWindow.sol";
import {IOracleAdapter} from "src/policy/PolicyManager.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract MockSTRXMintRefundFuzz is IBuckToken {
    mapping(address => uint256) public balanceOf;
    uint256 private _totalSupply;

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        _totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "burn");
        balanceOf[from] = bal - amount;
        _totalSupply -= amount;
    }
}

contract MockPolicyMintRefundFuzz is IPolicyManager {
    uint16 public mintFeeBps;
    uint16 public refundFeeBps;
    uint16 public halfSpreadBps;
    uint256 public mintAggregateBps = 10_000; // 100% for testing
    uint256 public refundAggregateBps = 10_000;
    uint256 public usedMintBps;
    uint256 public usedRefundBps;

    function setFees(uint16 mintFee, uint16 refundFee, uint16 spread) external {
        mintFeeBps = mintFee;
        refundFeeBps = refundFee;
        halfSpreadBps = spread;
    }

    function setCaps(uint256 mintCap, uint256 refundCap) external {
        mintAggregateBps = mintCap;
        refundAggregateBps = refundCap;
    }

    function resetUsage() external {
        usedMintBps = 0;
        usedRefundBps = 0;
    }

    function checkMintCap(uint256 amountBps) external view returns (bool) {
        return usedMintBps + amountBps <= mintAggregateBps;
    }

    function recordMint(uint256 amountBps) external {
        usedMintBps += amountBps;
    }

    function checkRefundCap(uint256 amountBps) external view returns (bool) {
        return usedRefundBps + amountBps <= refundAggregateBps;
    }

    function recordRefund(uint256 amountBps) external {
        usedRefundBps += amountBps;
    }

    function getFees() external view returns (uint16, uint16) {
        return (mintFeeBps, refundFeeBps);
    }

    function getHalfSpread() external view returns (uint16) {
        return halfSpreadBps;
    }

    function getDexFees() external pure returns (uint16, uint16) {
        return (10, 10);
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

    function getMintParameters(uint256 amountBps)
        external
        view
        returns (MintParameters memory)
    {
        return MintParameters({
            capPrice: 1e18, // $1.00
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: usedMintBps + amountBps <= mintAggregateBps,
            currentBand: Band.Green
        });
    }

    function getRefundParameters(uint256 amountBps)
        external
        view
        returns (MintParameters memory)
    {
        return MintParameters({
            capPrice: 1e18, // $1.00
            halfSpreadBps: halfSpreadBps,
            mintFeeBps: mintFeeBps,
            refundFeeBps: refundFeeBps,
            mintCapPassed: usedRefundBps + amountBps <= refundAggregateBps,
            currentBand: Band.Green
        });
    }
}

contract MockOracleMintRefundFuzz is IOracleAdapter {
    uint256 public price = 1e18;
    uint256 public lastUpdateBlock;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
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

contract MockReserveMintRefundFuzz is ILiquidityReserve {
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    address public usdc;
    address public liquidityWindow;

    function setUSDC(address _usdc) external {
        usdc = _usdc;
    }

    function setLiquidityWindow(address _window) external {
        liquidityWindow = _window;
    }

    function recordDeposit(uint256 amount) external {
        totalDeposits += amount;
    }

    function queueWithdrawal(address to, uint256 amount) external {
        totalWithdrawals += amount;
        if (msg.sender == liquidityWindow && usdc != address(0)) {
            MockUSDC(usdc).transfer(to, amount);
        }
    }
}

/**
 * @title LiquidityWindowMintRefundFuzzTest
 * @notice Comprehensive fuzz tests for LiquidityWindow mint and refund operations
 * @dev Tests with random amounts, prices, slippage, and invariants
 */
contract LiquidityWindowMintRefundFuzzTest is BaseTest {
    LiquidityWindow internal window;
    MockSTRXMintRefundFuzz internal token;
    MockPolicyMintRefundFuzz internal policy;
    MockOracleMintRefundFuzz internal oracle;
    MockReserveMintRefundFuzz internal reserve;
    MockUSDC internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant USER1 = address(0xBEEF);
    address internal constant USER2 = address(0xCAFE);
    address internal constant USER3 = address(0xD00D);

    uint256 internal constant INITIAL_RESERVE_USDC = 10_000_000e6; // 10M USDC

    function setUp() public {
        token = new MockSTRXMintRefundFuzz();
        policy = new MockPolicyMintRefundFuzz();
        oracle = new MockOracleMintRefundFuzz();
        reserve = new MockReserveMintRefundFuzz();
        usdc = new MockUSDC();

        window = deployLiquidityWindow(TIMELOCK, address(token), address(reserve), address(policy));

        reserve.setUSDC(address(usdc));
        reserve.setLiquidityWindow(address(window));

        vm.startPrank(TIMELOCK);
        window.setUSDC(address(usdc));
        vm.stopPrank();

        // Fund reserve with 10M USDC
        usdc.mint(address(reserve), INITIAL_RESERVE_USDC);

        // Fund users with USDC
        usdc.mint(USER1, 1_000_000e6);
        usdc.mint(USER2, 1_000_000e6);
        usdc.mint(USER3, 1_000_000e6);

        // Set default fees: 0.5% spread, 0.1% mint fee, 0.2% refund fee
        policy.setFees(10, 20, 50);

        // Set price to $1
        oracle.setPrice(1e18);
        vm.roll(block.number + 2); // Move past block-fresh window
    }

    /// @notice Fuzz test: Random mint amounts with various prices
    function testFuzzRandomMintAmounts(
        uint96[10] memory amounts,
        uint16[10] memory priceBps // Price multiplier in bps (5000-20000 = $0.50-$2.00)
    ) public {
        uint256 totalMinted = 0;
        uint256 totalUsdcSpent = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Bound mint amount: 100 USDC to 100k USDC
            uint256 usdcAmount = bound(uint256(amounts[i]), 100e6, 100_000e6);

            // Bound price: $0.50 to $2.00 (5000-20000 bps)
            uint256 price = bound(uint256(priceBps[i]), 5_000, 20_000);
            price = (1e18 * price) / 10_000;

            // Set oracle price and move past block-fresh
            oracle.setPrice(price);
            vm.roll(block.number + 2);

            address user = _selectUser(i);

            vm.startPrank(user);
            usdc.approve(address(window), usdcAmount);

            try window.requestMint(user, usdcAmount, 0, 0) returns (uint256 strcOut, uint256 fee) {
                totalMinted += strcOut;
                totalUsdcSpent += usdcAmount;

                // Invariant: User received some STRX
                assertGt(strcOut, 0, "Mint produced 0 STRX");

                // Invariant: Fee should be reasonable (< 5% of input)
                assertLe(fee, usdcAmount / 20, "Fee too high");
            } catch {
                // Mint might fail due to caps, that's OK
            }
            vm.stopPrank();
        }

        // Invariant: Total BUCK supply equals what we minted
        assertEq(token.totalSupply(), totalMinted, "Supply mismatch");

        // Invariant: Reserve received all USDC
        assertEq(reserve.totalDeposits(), totalUsdcSpent, "Reserve deposits mismatch");
    }

    /// @notice Fuzz test: Random refund amounts
    function testFuzzRandomRefundAmounts(
        uint96[10] memory mintAmounts,
        uint96[10] memory refundAmounts
    ) public {
        // First, do some mints to get STRX
        for (uint256 i = 0; i < mintAmounts.length; i++) {
            uint256 usdcAmount = bound(uint256(mintAmounts[i]), 1_000e6, 50_000e6);

            address user = _selectUser(i);

            vm.startPrank(user);
            usdc.approve(address(window), usdcAmount);
            try window.requestMint(user, usdcAmount, 0, 0) {} catch {}
            vm.stopPrank();
        }

        uint256 supplyBeforeRefunds = token.totalSupply();
        uint256 totalRefunded = 0;
        uint256 totalGrossUsdcOut = 0;

        // Now do refunds
        for (uint256 i = 0; i < refundAmounts.length; i++) {
            address user = _selectUser(i);
            uint256 userBalance = token.balanceOf(user);

            // Skip if user has less than minimum refund amount
            if (userBalance < 1e18) continue;

            // Bound refund amount to user's balance
            uint256 refundAmount = bound(uint256(refundAmounts[i]), 1e18, userBalance);

            vm.startPrank(user);
            try window.requestRefund(user, refundAmount, 0, 0) returns (
                uint256 usdcOut, uint256 fee
            ) {
                totalRefunded += refundAmount;
                // Track gross withdrawals (usdcOut + fee) to match reserve accounting
                totalGrossUsdcOut += usdcOut + fee;

                // Invariant: User got some USDC back
                assertGt(usdcOut, 0, "Refund produced 0 USDC");

                // Invariant: Fee should be reasonable
                assertLe(fee, usdcOut / 10, "Refund fee too high");
            } catch {
                // Refund might fail due to caps, that's OK
            }
            vm.stopPrank();
        }

        // Invariant: Supply decreased by refunded amount
        assertEq(
            token.totalSupply(),
            supplyBeforeRefunds - totalRefunded,
            "Supply after refunds mismatch"
        );

        // Invariant: Reserve withdrew USDC (gross amount including fees)
        assertEq(reserve.totalWithdrawals(), totalGrossUsdcOut, "Reserve withdrawals mismatch");
    }

    /// @notice Fuzz test: Slippage protection on mints
    function testFuzzMintSlippageProtection(
        uint96 usdcAmount,
        uint16 priceBps,
        uint16 slippageBps // 0-500 = 0-5% slippage tolerance
    ) public {
        // Bound inputs
        uint256 amount = bound(uint256(usdcAmount), 1_000e6, 100_000e6);
        uint256 price = bound(uint256(priceBps), 8_000, 12_000); // $0.80-$1.20
        price = (1e18 * price) / 10_000;
        uint256 slippage = bound(uint256(slippageBps), 0, 500); // 0-5%

        // Set oracle price
        oracle.setPrice(price);
        vm.roll(block.number + 2);

        // Calculate expected BUCK out (simplified)
        uint256 amount18 = amount * 1e12;
        uint256 spread = policy.halfSpreadBps();
        uint256 effectivePrice = Math.mulDiv(price, 10_000 + spread, 10_000);
        uint256 expectedOut = Math.mulDiv(amount18, 1e18, effectivePrice);

        // Calculate slippage tolerance
        uint256 minOut = Math.mulDiv(expectedOut, 10_000 - slippage, 10_000);

        vm.startPrank(USER1);
        usdc.approve(address(window), amount);

        try window.requestMint(USER1, amount, minOut, 0) returns (uint256 strcOut, uint256) {
            // If successful, output should meet minimum
            assertGe(strcOut, minOut, "Output below minimum");
        } catch {
            // Slippage protection might reject, that's OK
        }
        vm.stopPrank();
    }

    /// @notice Fuzz test: Cap exhaustion scenarios
    function testFuzzCapExhaustion(
        uint96[8] memory amounts,
        uint16 capBps // Aggregate cap in bps (100-10000 = 1%-100%)
    ) public {
        // Set a restrictive cap
        uint256 cap = bound(uint256(capBps), 100, 10_000);
        policy.setCaps(cap, cap);

        uint256 totalMintBps = 0;
        uint256 successfulMints = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 usdcAmount = bound(uint256(amounts[i]), 1_000e6, 10_000e6);

            address user = _selectUser(i);

            vm.startPrank(user);
            usdc.approve(address(window), usdcAmount);

            try window.requestMint(user, usdcAmount, 0, 0) returns (uint256 strcOut, uint256) {
                // Calculate bps of this mint
                uint256 supply = token.totalSupply();
                if (supply > 0) {
                    uint256 mintBps = Math.mulDiv(strcOut, 10_000, supply);
                    totalMintBps += mintBps;
                }
                successfulMints++;
            } catch {
                // Expected to fail once cap is exhausted
            }
            vm.stopPrank();
        }

        // Invariant: Cap usage should not exceed the cap (with small tolerance for rounding)
        // Note: With very restrictive caps, all mints might fail so successfulMints can be 0
        assertLe(policy.usedMintBps(), cap + 100, "Policy cap exceeded");
    }

    /// @notice Fuzz test: Mixed mint/refund operations
    function testFuzzMixedOperations(
        uint8[20] memory ops, // 0 = mint, 1 = refund
        uint96[20] memory amounts
    ) public {
        uint256 initialReserveBalance = INITIAL_RESERVE_USDC;

        for (uint256 i = 0; i < ops.length; i++) {
            uint8 op = ops[i] % 2;
            address user = _selectUser(i);

            if (op == 0) {
                // Mint
                uint256 usdcAmount = bound(uint256(amounts[i]), 100e6, 10_000e6);

                vm.startPrank(user);
                usdc.approve(address(window), usdcAmount);
                try window.requestMint(user, usdcAmount, 0, 0) {} catch {}
                vm.stopPrank();
            } else {
                // Refund
                uint256 userBalance = token.balanceOf(user);
                // Skip if user has less than minimum refund amount
                if (userBalance < 1e18) continue;

                uint256 refundAmount = bound(uint256(amounts[i]), 1e18, userBalance);

                vm.startPrank(user);
                try window.requestRefund(user, refundAmount, 0, 0) {} catch {}
                vm.stopPrank();
            }
        }

        // Invariant: Total supply should equal sum of balances
        uint256 totalBalance =
            token.balanceOf(USER1) + token.balanceOf(USER2) + token.balanceOf(USER3);
        assertEq(token.totalSupply(), totalBalance, "Supply != sum of balances");

        // Invariant: Net USDC flow should be: deposits - withdrawals
        uint256 netReserveChange = reserve.totalDeposits();
        uint256 netReserveOut = reserve.totalWithdrawals();

        // Reserve should have: initial + deposits - withdrawals
        uint256 expectedReserveBalance = initialReserveBalance + netReserveChange - netReserveOut;
        assertEq(usdc.balanceOf(address(reserve)), expectedReserveBalance, "Reserve USDC mismatch");
    }

    /// @notice Helper to select user based on index
    function _selectUser(uint256 i) internal pure returns (address) {
        if (i % 3 == 0) return USER1;
        if (i % 3 == 1) return USER2;
        return USER3;
    }
}
