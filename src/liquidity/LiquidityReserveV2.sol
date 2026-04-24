//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝
//
// LIQUIDITY RESERVE V2
// ON-CHAIN USDC VAULT
//
// SPDX-License-Identifier: UNLICENSED
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
import {ICollateralAttestationV2} from "src/interfaces/ICollateralAttestationV2.sol";
import {IPolicyManagerV2} from "src/interfaces/IPolicyManagerV2.sol";

/**
 * @title LiquidityReserveV2
 * @notice On-chain USDC vault for primary market operations.
 *
 * @dev Withdrawal paths:
 * - LiquidityWindow -> instant, no cash-in-flight tracking
 * - Treasurer to treasury -> instant, cash-in-flight tracked
 * - Treasurer to other addresses -> instant, no cash-in-flight tracking
 * - Admin -> queued with delay, cash-in-flight tracked on execution
 *
 * Treasurer withdrawals only track cash in flight when the destination
 * is the treasury address.
 */
contract LiquidityReserveV2 is
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
    error EcosystemPaused();

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    IERC20 public asset;
    address public liquidityWindow;
    address public treasurer;
    /// @dev Reserved slot. Do not use.
    address public rewardsEngine;
    uint32 public adminDelaySeconds;
    mapping(address => bool) public isRecoverySink;

    struct WithdrawalRequest {
        address to;
        uint256 amount;
        uint64 releaseAt;
        bool executed;
        bool cancelled;
        address requestedBy;
        uint64 enqueuedAt;
    }

    WithdrawalRequest[] private _withdrawals;

    // -------------------------------------------------------------------------
    // Additional Storage
    // -------------------------------------------------------------------------

    /// @notice CollateralAttestation contract for CIF tracking
    address public collateralAttestation;

    /// @notice PolicyManager for ecosystem-wide pause enforcement
    address public policyManager;

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
    event AdminDelayConfigured(uint32 delaySeconds);
    event RecoverySinkSet(address indexed sink, bool allowed);
    event TokensRecovered(
        address indexed caller, address indexed token, address indexed to, uint256 amount
    );
    event CollateralAttestationSet(address indexed newCollateralAttestation);
    event CashInFlightTracked(uint256 amount);
    event CashInFlightTrackingFailed(uint256 amount);
    event PolicyManagerSet(address indexed newPolicyManager);

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address asset_, address liquidityWindow_, address treasurer_)
        public
        initializer
    {
        if (admin == address(0) || asset_ == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __Multicall_init();
        __UUPSUpgradeable_init();

        _grantRole(ADMIN_ROLE, admin);
        asset = IERC20(asset_);
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
    // Upgrade Authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Reverts if PolicyManager ecosystem pause is active
    modifier whenEcosystemNotPaused() {
        if (policyManager != address(0) && IPolicyManagerV2(policyManager).paused()) {
            revert EcosystemPaused();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    function setCollateralAttestation(address _collateralAttestation) external onlyRole(ADMIN_ROLE) {
        collateralAttestation = _collateralAttestation;
        emit CollateralAttestationSet(_collateralAttestation);
    }

    function setPolicyManager(address _policyManager) external onlyRole(ADMIN_ROLE) {
        policyManager = _policyManager;
        emit PolicyManagerSet(_policyManager);
    }

    function setLiquidityWindow(address newWindow) external onlyRole(ADMIN_ROLE) {
        if (newWindow == address(0)) revert InvalidAddress();

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

    function setTreasurer(address newTreasurer) external onlyRole(ADMIN_ROLE) {
        if (newTreasurer == address(0)) revert InvalidAddress();

        address oldTreasurer = treasurer;
        if (oldTreasurer != address(0)) {
            _revokeRole(TREASURER_ROLE, oldTreasurer);
            _revokeRole(DEPOSITOR_ROLE, oldTreasurer);
            isRecoverySink[oldTreasurer] = false;
            emit RecoverySinkSet(oldTreasurer, false);
        }

        treasurer = newTreasurer;
        _grantRole(TREASURER_ROLE, newTreasurer);
        _grantRole(DEPOSITOR_ROLE, newTreasurer);
        isRecoverySink[newTreasurer] = true;
        emit TreasurerSet(newTreasurer);
        emit RecoverySinkSet(newTreasurer, true);
    }

    function setAdminDelaySeconds(uint32 delaySeconds) external onlyRole(ADMIN_ROLE) {
        adminDelaySeconds = delaySeconds;
        emit AdminDelayConfigured(delaySeconds);
    }

    function setRecoverySink(address sink, bool allowed) external onlyRole(ADMIN_ROLE) {
        if (sink == address(0)) revert InvalidAddress();
        isRecoverySink[sink] = allowed;
        emit RecoverySinkSet(sink, allowed);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Deposit & Withdrawal Entrypoints
    // -------------------------------------------------------------------------

    function recordDeposit(uint256 amount) external {
        if (!hasRole(DEPOSITOR_ROLE, msg.sender)) revert NotAuthorized();
        if (amount == 0) revert InvalidAmount();

        if (msg.sender != liquidityWindow) {
            asset.safeTransferFrom(msg.sender, address(this), amount);
        }
        emit DepositRecorded(msg.sender, amount);
    }

    /// @notice Queues or executes a withdrawal, depending on the caller.
    function queueWithdrawal(address to, uint256 amount) external nonReentrant whenNotPaused whenEcosystemNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // LiquidityWindow refunds withdraw immediately and do not track cash in flight.
        if (msg.sender == liquidityWindow && to != treasurer) {
            _instantWithdrawal(to, amount, false);
            return;
        }

        // Treasurer withdrawals are immediate. Cash in flight is only tracked when funds go to treasury.
        if (hasRole(TREASURER_ROLE, msg.sender)) {
            _instantWithdrawal(to, amount, to == treasurer);
            return;
        }

        // Admin withdrawals are queued behind the configured delay.
        if (!hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        _enqueueWithdrawal(to, amount, msg.sender);
    }

    function executeWithdrawal(uint256 id)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
        whenEcosystemNotPaused
    {
        WithdrawalRequest storage request = _withdrawals[id];
        if (request.executed || request.cancelled) revert WithdrawalAlreadyProcessed();
        if (block.timestamp < request.releaseAt) revert WithdrawalNotReady(request.releaseAt);

        request.executed = true;

        asset.safeTransfer(request.to, request.amount);
        _trackCashInFlight(request.amount);

        emit WithdrawalExecuted(id, msg.sender);
    }

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

    function cancelWithdrawal(uint256 id) external onlyRole(ADMIN_ROLE) {
        WithdrawalRequest storage request = _withdrawals[id];
        if (request.executed || request.cancelled) revert WithdrawalAlreadyProcessed();

        request.cancelled = true;
        emit WithdrawalCancelled(id, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function totalLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function withdrawalCount() external view returns (uint256) {
        return _withdrawals.length;
    }

    function getWithdrawal(uint256 id) external view returns (WithdrawalRequest memory) {
        return _withdrawals[id];
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    /// @param trackCIF True when the withdrawal should add to cashInFlight.
    function _instantWithdrawal(address to, uint256 amount, bool trackCIF) internal {
        uint256 balance = asset.balanceOf(address(this));
        if (amount > balance) revert InsufficientLiquidity();

        asset.safeTransfer(to, amount);

        if (trackCIF) {
            _trackCashInFlight(amount);
        }

        emit InstantWithdrawal(msg.sender, to, amount);
    }

    /// @dev Withdrawals still succeed if cash-in-flight tracking fails.
    function _trackCashInFlight(uint256 amount) internal {
        if (collateralAttestation != address(0)) {
            try ICollateralAttestationV2(collateralAttestation).addCashInFlight(amount) {
                emit CashInFlightTracked(amount);
            } catch {
                emit CashInFlightTrackingFailed(amount);
            }
        }
    }

    function _enqueueWithdrawal(address to, uint256 amount, address requestedBy) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 releaseAt = nowTs + adminDelaySeconds;

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

        emit WithdrawalRequested(_withdrawals.length - 1, to, amount, releaseAt, requestedBy);
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    // Reserved for future upgrades.
    uint256[48] private __gap;
}
