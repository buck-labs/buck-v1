// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {ReentrancyGuardTransient} from "src/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// LiquidityReserve is the on-chain USDC vault the primary market leans on for instant refunds.
// LiquidityWindow pushes deposits here. Treasurer sweeps execute instantly for brokerage windows.
// Admin withdrawals are queued with a single flat delay for a governance reaction window.
contract LiquidityReserve is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    MulticallUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // Role constants
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");


    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotAuthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidConfig();
    error InsufficientLiquidity();
    error WithdrawalNotReady(uint256 availableAt);
    error WithdrawalAlreadyProcessed();
    error InvalidRecoverySink(address account);
    error UnsupportedRecoveryAsset(address token);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    // Reserve holds a single ERC-20 (USDC), all inflows/outflows are tracked against this token.
    IERC20 public asset;

    // LiquidityWindow feeds deposits in and queues instant withdrawals.
    address public liquidityWindow;
    // Treasurer executes delayed withdrawals; we gate long tail funds behind this role.
    address public treasurer;
    // RewardsEngine pulls its distribution skim via a dedicated hook so fees stay accounted for.
    address public rewardsEngine; // RewardsEngine contract for distribution skim withdrawals

    // Flat delay (seconds) applied to ADMIN-queued withdrawals.
    uint32 public adminDelaySeconds;

    // Allowlist of addresses we let recover stray tokens without risking theft.
    mapping(address => bool) public isRecoverySink;

    // Snapshot of a queued withdrawal, including timing and who asked for it.
    struct WithdrawalRequest {
        address to;
        uint256 amount;
        uint64 releaseAt;
        bool executed;
        bool cancelled;
        address requestedBy;
        uint64 enqueuedAt;
    }

    // Keeps queued withdrawals in order so the treasurer can process them later.
    WithdrawalRequest[] private _withdrawals;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event DepositRecorded(address indexed from, uint256 amount);
    event InstantWithdrawal(address indexed caller, address indexed to, uint256 amount);
    event WithdrawalRequested(
        uint256 indexed id,
        address indexed to,
        uint256 amount,
        uint64 releaseAt,
        address indexed requestedBy
    );
    event WithdrawalExecuted(uint256 indexed id, address indexed executor);
    event WithdrawalCancelled(uint256 indexed id, address indexed canceller);
    event LiquidityWindowSet(address indexed newLiquidityWindow);
    event TreasurerSet(address indexed newTreasurer);
    event RewardsEngineSet(address indexed newRewardsEngine);
    event AdminDelayConfigured(uint32 delaySeconds);
    event RecoverySinkSet(address indexed sink, bool allowed);
    event TokensRecovered(
        address indexed caller, address indexed token, address indexed to, uint256 amount
    );

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Sets up roles and ties in LiquidityWindow/treasurer addresses during deployment.
    // Optional pointers can be filled in later if we stage components.
    function initialize(address admin, address asset_, address liquidityWindow_, address treasurer_)
        public
        initializer
    {
        if (admin == address(0) || asset_ == address(0)) revert InvalidAddress();

        // Initialize parents
        __AccessControl_init();
        // ReentrancyGuardTransient uses transient storage - no init needed
        __Pausable_init();
        __Multicall_init();
        __UUPSUpgradeable_init();

        // Grant admin role
        _grantRole(ADMIN_ROLE, admin);

        // Set asset
        asset = IERC20(asset_);

        // Default flat delay for ADMIN-queued withdrawals: 24 hours
        adminDelaySeconds = 24 hours;
        emit AdminDelayConfigured(adminDelaySeconds);

        if (liquidityWindow_ != address(0)) {
            liquidityWindow = liquidityWindow_;
            _grantRole(DEPOSITOR_ROLE, liquidityWindow_);
            isRecoverySink[liquidityWindow_] = true;
            emit LiquidityWindowSet(liquidityWindow_);
            emit RecoverySinkSet(liquidityWindow_, true);
        }
        if (treasurer_ != address(0)) {
            treasurer = treasurer_;
            _grantRole(TREASURER_ROLE, treasurer_);
            _grantRole(DEPOSITOR_ROLE, treasurer_);
            isRecoverySink[treasurer_] = true;
            emit TreasurerSet(treasurer_);
            emit RecoverySinkSet(treasurer_, true);
        }
    }

    // -------------------------------------------------------------------------
    // Access Control
    // -------------------------------------------------------------------------
    // Uses OpenZeppelin AccessControl with ADMIN_ROLE, TREASURER_ROLE, and DEPOSITOR_ROLE

    // -------------------------------------------------------------------------
    // Upgrade Authorization
    // -------------------------------------------------------------------------

    // Only the admin multisig can approve a new implementation for this vault.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    // Repoints the module handling deposits/instant refunds; auto-grants depositor permissions.
    function setLiquidityWindow(address newWindow) external onlyRole(ADMIN_ROLE) {
        if (newWindow == address(0)) revert InvalidAddress();

        // Revoke permissions from old window to prevent stale access
        address oldWindow = liquidityWindow;
        if (oldWindow != address(0)) {
            _revokeRole(DEPOSITOR_ROLE, oldWindow);
            isRecoverySink[oldWindow] = false;
            emit RecoverySinkSet(oldWindow, false);
        }

        liquidityWindow = newWindow;
        _grantRole(DEPOSITOR_ROLE, newWindow);
        isRecoverySink[newWindow] = true;
        emit LiquidityWindowSet(newWindow);
        emit RecoverySinkSet(newWindow, true);
    }

    // Rotates the treasurer signer who manages instant brokerage sweeps and emergency pulls.
    function setTreasurer(address newTreasurer) external onlyRole(ADMIN_ROLE) {
        if (newTreasurer == address(0)) revert InvalidAddress();

        // Revoke roles from old treasurer to prevent them from retaining access
        address oldTreasurer = treasurer;
        if (oldTreasurer != address(0)) {
            _revokeRole(TREASURER_ROLE, oldTreasurer);
            _revokeRole(DEPOSITOR_ROLE, oldTreasurer);
            isRecoverySink[oldTreasurer] = false;
            emit RecoverySinkSet(oldTreasurer, false);
        }

        // Set new treasurer and grant roles
        treasurer = newTreasurer;
        _grantRole(TREASURER_ROLE, newTreasurer);
        _grantRole(DEPOSITOR_ROLE, newTreasurer);
        isRecoverySink[newTreasurer] = true;
        emit TreasurerSet(newTreasurer);
        emit RecoverySinkSet(newTreasurer, true);
    }

    // Hooks up the rewards contract so it can skim distributions without touching treasurer queues.
    function setRewardsEngine(address newRewardsEngine) external onlyRole(ADMIN_ROLE) {
        if (newRewardsEngine == address(0)) revert InvalidAddress();
        rewardsEngine = newRewardsEngine;
        emit RewardsEngineSet(newRewardsEngine);
    }

    /// @notice Configure flat delay for ADMIN-queued withdrawals (in seconds)
    function setAdminDelaySeconds(uint32 delaySeconds) external onlyRole(ADMIN_ROLE) {
        adminDelaySeconds = delaySeconds;
        emit AdminDelayConfigured(delaySeconds);
    }

    // Whitelist or remove destinations that can rescue stray tokens accidentally sent here.
    function setRecoverySink(address sink, bool allowed) external onlyRole(ADMIN_ROLE) {
        if (sink == address(0)) revert InvalidAddress();
        isRecoverySink[sink] = allowed;
        emit RecoverySinkSet(sink, allowed);
    }

    /// @notice Pause all withdrawal operations
    /// @dev Admin-only emergency function to halt withdrawals
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause all withdrawal operations
    /// @dev Admin-only function to resume withdrawals after emergency
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Deposit & withdrawal entrypoints
    // -------------------------------------------------------------------------

    // LiquidityWindow (and other approved roles) call this whenever USDC enters the vault.
    // Non-window callers transfer funds in as part of the call; window assumes it already holds them.
    function recordDeposit(uint256 amount) external {
        if (!hasRole(DEPOSITOR_ROLE, msg.sender)) revert NotAuthorized();
        if (amount == 0) revert InvalidAmount();

        if (msg.sender != liquidityWindow) {
            asset.safeTransferFrom(msg.sender, address(this), amount);
        }
        emit DepositRecorded(msg.sender, amount);
    }

    /// @notice Allows RewardsEngine to withdraw distribution skim fees
    /// @param to Address to send the skim (typically treasury)
    /// @param amount Amount of USDC to withdraw
    /// @dev Protected by nonReentrant to prevent reentrancy during USDC transfer
    /// @dev Protected by whenNotPaused to halt withdrawals during emergency
    function withdrawDistributionSkim(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (msg.sender != rewardsEngine) revert NotAuthorized();
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        _instantWithdrawal(to, amount);
    }

    /// @notice Queue a withdrawal for processing
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @dev LiquidityWindow and Treasurer get instant withdrawals (operational requirement)
    /// @dev Admin calls use a single flat delay
    /// @dev Protected by nonReentrant to prevent reentrancy during USDC transfer
    /// @dev Protected by whenNotPaused to halt withdrawals during emergency
    function queueWithdrawal(address to, uint256 amount) external nonReentrant whenNotPaused {
        // CHECKS: Validate inputs
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // LiquidityWindow fast path: instant withdrawal for refunds
        if (msg.sender == liquidityWindow && to != treasurer) {
            _instantWithdrawal(to, amount);
            return;
        }

        // Treasurer fast path: protocol-controlled hot wallet needs immediate USDC for brokerage
        // Allow TREASURER_ROLE to withdraw instantly to avoid missing bond purchase windows
        if (hasRole(TREASURER_ROLE, msg.sender)) {
            _instantWithdrawal(to, amount);
            return;
        }

        // Authorization check for admin queued withdrawals (flat delay)
        // (LiquidityWindow and Treasurer already handled above with instant paths)
        if (!hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // EFFECTS + INTERACTIONS: Enqueue withdrawal (validates, updates array, emits)
        _enqueueWithdrawal(to, amount, msg.sender);
    }

    /// @notice Execute a queued withdrawal after the delay period
    /// @param id Withdrawal request ID
    /// @dev Follows CEI pattern: validate → mark executed → transfer → emit
    /// @dev Protected by nonReentrant to prevent reentrancy during USDC transfer
    /// @dev Protected by whenNotPaused to halt withdrawals during emergency
    function executeWithdrawal(uint256 id)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        // CHECKS: Load and validate withdrawal request
        WithdrawalRequest storage request = _withdrawals[id];
        if (request.executed || request.cancelled) revert WithdrawalAlreadyProcessed();
        if (block.timestamp < request.releaseAt) revert WithdrawalNotReady(request.releaseAt);

        // EFFECTS: Mark as executed before external call
        request.executed = true;

        // INTERACTIONS: Transfer USDC then emit event
        asset.safeTransfer(request.to, request.amount);
        emit WithdrawalExecuted(id, msg.sender);
    }

    // Governance can rescue mis-sent tokens (not USDC) to pre-approved sinks.
    function recoverERC20(address token_, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (token_ == address(0) || to == address(0)) revert InvalidAddress();
        if (!isRecoverySink[to]) revert InvalidRecoverySink(to);
        if (amount == 0) revert InvalidAmount();
        if (token_ == address(asset)) revert UnsupportedRecoveryAsset(token_);
        IERC20(token_).safeTransfer(to, amount);
        emit TokensRecovered(msg.sender, token_, to, amount);
    }

    /// @notice Cancel a queued withdrawal before execution
    /// @param id Withdrawal request ID
    /// @dev Admin-only emergency function to cancel pending withdrawals
    function cancelWithdrawal(uint256 id) external onlyRole(ADMIN_ROLE) {
        // CHECKS: Load and validate withdrawal request
        WithdrawalRequest storage request = _withdrawals[id];
        if (request.executed || request.cancelled) revert WithdrawalAlreadyProcessed();

        // EFFECTS: Mark as cancelled and emit
        request.cancelled = true;
        emit WithdrawalCancelled(id, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    // Snapshot helper for dashboards/keepers: current USDC sitting in the vault.
    function totalLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // Returns how many withdrawal requests have been logged (executed or not).
    function withdrawalCount() external view returns (uint256) {
        return _withdrawals.length;
    }

    // Fetches metadata for a specific withdrawal queue entry.
    function getWithdrawal(uint256 id) external view returns (WithdrawalRequest memory) {
        return _withdrawals[id];
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @notice Internal instant withdrawal helper
    /// @dev CEI pattern: check balance → transfer → emit
    /// @dev No state updates, only validation then external call
    function _instantWithdrawal(address to, uint256 amount) internal {
        // CHECKS: Validate sufficient balance
        uint256 balance = asset.balanceOf(address(this));
        if (amount > balance) revert InsufficientLiquidity();

        // INTERACTIONS: Transfer USDC then emit
        asset.safeTransfer(to, amount);
        emit InstantWithdrawal(msg.sender, to, amount);
    }

    /// @notice Internal helper to enqueue an admin withdrawal with flat delay
    /// @dev CEI pattern: validate → update array → emit
    /// @dev No external calls, purely state updates
    function _enqueueWithdrawal(address to, uint256 amount, address requestedBy) internal {
        // CHECKS: Compute release time using flat admin delay
        uint64 nowTs = uint64(block.timestamp);
        uint64 releaseAt = nowTs + adminDelaySeconds;

        // EFFECTS: Add withdrawal to queue
        _withdrawals.push(
            WithdrawalRequest({
                to: to,
                amount: amount,
                releaseAt: releaseAt,
                executed: false,
                cancelled: false,
                requestedBy: requestedBy,
                enqueuedAt: nowTs
            })
        );

        // INTERACTIONS: Emit event (no external call, but follows pattern)
        emit WithdrawalRequested(_withdrawals.length - 1, to, amount, releaseAt, requestedBy);
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    // Reserved padding so future upgrades can add fields without clobbering layout.
    uint256[50] private __gap;
}
