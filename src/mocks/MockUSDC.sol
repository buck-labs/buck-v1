// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testnet deployments
 * @dev DO NOT USE IN PRODUCTION - This has a public mint function!
 */
contract MockUSDC is ERC20 {
    uint8 private constant USDC_DECIMALS = 6; // USDC uses 6 decimals

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return USDC_DECIMALS;
    }

    /**
     * @notice Mint tokens to any address (TESTNET ONLY)
     * @param to Recipient address
     * @param amount Amount to mint (in 6 decimal format)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Convenience function to mint with 18 decimal input
     * @param to Recipient address
     * @param amountWith18Decimals Amount in 18 decimals (will be converted to 6)
     */
    function mintWith18Decimals(address to, uint256 amountWith18Decimals) external {
        uint256 amount = amountWith18Decimals / 1e12; // Convert from 18 to 6 decimals
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from sender
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
