// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title MockAccessRegistry
 * @notice Simple mock for testing access registry functionality
 */
contract MockAccessRegistry {
    mapping(address => bool) private _allowed;

    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }

    function setAllowed(address account, bool allowed) external {
        _allowed[account] = allowed;
    }
}
