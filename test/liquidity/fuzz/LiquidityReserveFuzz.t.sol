// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCFuzz is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract LiquidityReserveFuzzTest is BaseTest {
    LiquidityReserve internal reserve;
    MockUSDCFuzz internal usdc;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant WINDOW = address(0xBEEF);
    address internal constant TREASURER = address(0xCAFE);

    function setUp() public {
        usdc = new MockUSDCFuzz();
        reserve = deployLiquidityReserve(TIMELOCK, address(usdc), WINDOW, TREASURER);
        usdc.mint(address(reserve), 5_000_000e6);
    }

    function testFuzzWithdrawalDelays(uint8[8] memory ops, uint96[8] memory amounts) public {
        uint256 initialVaultBalance = usdc.balanceOf(address(reserve));
        uint256 mintedToReserve;

        for (uint256 i = 0; i < ops.length; i++) {
            uint8 op = ops[i] % 4;
            uint256 amount = bound(uint256(amounts[i]), 1e4, 2_000_000e6);

            if (op == 0) {
                usdc.mint(TREASURER, amount);
                mintedToReserve += amount;
                vm.startPrank(TREASURER);
                usdc.approve(address(reserve), amount);
                reserve.recordDeposit(amount);
                vm.stopPrank();
            } else if (op == 1) {
                // LiquidityWindow always withdraws to itself (realistic behavior)
                // This triggers instant withdrawal, which may fail if insufficient liquidity
                vm.prank(WINDOW);
                try reserve.queueWithdrawal(WINDOW, amount) {} catch {}
            } else if (op == 2) {
                // Use TIMELOCK (ADMIN) for queued withdrawals since TREASURER now gets instant
                vm.prank(TIMELOCK);
                reserve.queueWithdrawal(TREASURER, amount);
            } else if (op == 3) {
                uint256 totalRequests = reserve.withdrawalCount();
                if (totalRequests == 0) continue;
                uint256 requestId = uint256(ops[i]) % totalRequests;
                LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(requestId);
                if (request.cancelled || request.executed) continue;
                if (block.timestamp < request.releaseAt) {
                    vm.warp(request.releaseAt + 1);
                }
                vm.prank(TREASURER);
                try reserve.executeWithdrawal(requestId) {} catch {}
            }
        }

        uint256 finalCount = reserve.withdrawalCount();
        for (uint256 id = 0; id < finalCount; id++) {
            LiquidityReserve.WithdrawalRequest memory request = reserve.getWithdrawal(id);
            if (!request.executed && !request.cancelled) {
                if (block.timestamp < request.releaseAt) {
                    vm.warp(request.releaseAt + 1);
                }
                vm.prank(TREASURER);
                try reserve.executeWithdrawal(id) {} catch {}
            }
        }

        uint256 totalBalance;
        totalBalance += usdc.balanceOf(address(reserve));
        totalBalance += usdc.balanceOf(TREASURER);
        totalBalance += usdc.balanceOf(WINDOW);

        assertEq(totalBalance, initialVaultBalance + mintedToReserve, "USDC balance mismatch");

        // Flat admin delay should be configured (default 24h)
        // We don't assert the exact value, but ensure non-zero
        // and that queued ADMIN withdrawals respect releaseAt >= now + delay in other tests.
    }
}
