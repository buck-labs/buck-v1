//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝
//
// LIQUIDITY WINDOW V2
// PRIMARY MARKET
//
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal interface for BuckV2
interface IBuckV2 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @notice Minimal interface for PolicyManagerV2
interface IPolicyManagerV2 {
    function getCAPPrice() external view returns (uint256);
    function getFees() external view returns (uint16 mintFee, uint16 refundFee);
    function getHalfSpread() external view returns (uint16);
    function checkRefund(uint256 reserveDrain) external view returns (bool allowed, string memory reason);
    function paused() external view returns (bool);
    function getDailyCap() external view returns (uint256);
    function dailyUsedUsdc() external view returns (uint256);

    function getMintParams() external view returns (uint256 capPrice, uint16 mintFee, uint16 halfSpread, bool isPaused);
    function getRefundParams() external view returns (uint256 capPrice, uint16 refundFee, uint16 halfSpread, bool isPaused);
    function checkAndRecordRefund(uint256 reserveDrain) external;
}

/// @notice Minimal interface for LiquidityReserve
interface ILiquidityReserve {
    function queueWithdrawal(address to, uint256 amount) external;
}

/// @notice Minimal interface for AccessRegistry
interface IAccessRegistry {
    function isAllowed(address account) external view returns (bool);
}

/**
 * @title LiquidityWindowV2
 * @notice Primary market interface for BUCK.
 *
 * @dev Handles mints and refunds, supports permit-based minting,
 * fee routing, optional per-transaction caps, and refund-cap
 * enforcement via PolicyManager.
 */
contract LiquidityWindowV2 is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant USDC_DECIMALS = 6;
    uint256 internal constant BUCK_DECIMALS = 18;
    uint256 internal constant DECIMAL_ADJUSTMENT = 10 ** (BUCK_DECIMALS - USDC_DECIMALS); // 1e12

    // -------------------------------------------------------------------------
    // Storage - Contract References
    // -------------------------------------------------------------------------

    address public buck;
    address public policyManager;
    /// @dev Reserved slot. Do not use.
    address public oracleAdapter;
    address public liquidityReserve;
    address public accessRegistry;
    address public usdc;
    address public treasury;

    // -------------------------------------------------------------------------
    // Storage - Fee Configuration
    // -------------------------------------------------------------------------

    /// @notice Percentage of fees routed to reserve (0-10000 bps)
    /// @dev The remainder is routed to treasury.
    uint16 public feeToReservePct;

    /// @notice Fee exemption mapping (e.g., for market makers)
    mapping(address => bool) public isFeeExempt;

    // -------------------------------------------------------------------------
    // Storage - Optional Per-TX Caps
    // -------------------------------------------------------------------------

    /// @notice Max USDC per mint transaction (type(uint256).max = no limit)
    uint256 public maxMintPerTxUsdc;

    /// @notice Max USDC output per refund transaction (type(uint256).max = no limit)
    uint256 public maxRefundPerTxUsdc;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Mint(
        address indexed caller,
        address indexed recipient,
        uint256 usdcIn,
        uint256 buckOut,
        uint256 feeUsdc,
        uint256 effectivePrice
    );

    event Refund(
        address indexed caller,
        address indexed recipient,
        uint256 buckIn,
        uint256 usdcOut,
        uint256 feeUsdc,
        uint256 effectivePrice
    );

    event ContractReferencesUpdated(
        address indexed buck,
        address indexed policyManager,
        address oracleAdapter,
        address liquidityReserve,
        address accessRegistry,
        address usdc,
        address treasury
    );

    event FeeToReservePctUpdated(uint16 oldPct, uint16 newPct);
    event MaxMintPerTxUpdated(uint256 oldMax, uint256 newMax);
    event MaxRefundPerTxUpdated(uint256 oldMax, uint256 newMax);
    event FeeExemptUpdated(address indexed account, bool exempt);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ContractsNotConfigured();
    error EcosystemPaused();
    error AccessDenied(address account);
    error PriceTooHigh(uint256 effectivePrice, uint256 maxPrice);
    error PriceTooLow(uint256 effectivePrice, uint256 minPrice);
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error ExceedsMaxMintPerTx(uint256 amount, uint256 max);
    error ExceedsMaxRefundPerTx(uint256 amount, uint256 max);
    error InvalidFeeToReservePct();
    error RenounceOwnershipDisabled();
    error CannotRecoverCoreAsset();

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        feeToReservePct = 5000;
        maxMintPerTxUsdc = type(uint256).max;
        maxRefundPerTxUsdc = type(uint256).max;
    }

    /// @notice One-time reinitializer for contract references.
    function migrateFromV1(
        address buck_,
        address policyManager_,
        address oracleAdapter_,
        address liquidityReserve_,
        address accessRegistry_,
        address usdc_,
        address treasury_
    ) external onlyOwner reinitializer(2) {
        if (buck_ == address(0)) revert ZeroAddress();
        if (policyManager_ == address(0)) revert ZeroAddress();
        if (liquidityReserve_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        buck = buck_;
        policyManager = policyManager_;
        oracleAdapter = oracleAdapter_;
        liquidityReserve = liquidityReserve_;
        accessRegistry = accessRegistry_;
        usdc = usdc_;
        treasury = treasury_;

        feeToReservePct = 5000;
        maxMintPerTxUsdc = type(uint256).max;
        maxRefundPerTxUsdc = type(uint256).max;

        emit ContractReferencesUpdated(buck_, policyManager_, oracleAdapter_, liquidityReserve_, accessRegistry_, usdc_, treasury_);
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    function setContractReferences(
        address buck_,
        address policyManager_,
        address oracleAdapter_,
        address liquidityReserve_,
        address accessRegistry_,
        address usdc_,
        address treasury_
    ) external onlyOwner {
        if (buck_ == address(0)) revert ZeroAddress();
        if (policyManager_ == address(0)) revert ZeroAddress();
        if (liquidityReserve_ == address(0)) revert ZeroAddress();
        // Pricing comes from PolicyManager, so oracleAdapter may be zero.
        // accessRegistry may be zero to disable access checks.
        if (usdc_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        buck = buck_;
        policyManager = policyManager_;
        oracleAdapter = oracleAdapter_;
        liquidityReserve = liquidityReserve_;
        accessRegistry = accessRegistry_;
        usdc = usdc_;
        treasury = treasury_;

        emit ContractReferencesUpdated(buck_, policyManager_, oracleAdapter_, liquidityReserve_, accessRegistry_, usdc_, treasury_);
    }

    function setFeeToReservePct(uint16 pct) external onlyOwner {
        if (pct > BPS_DENOMINATOR) revert InvalidFeeToReservePct();

        uint16 oldPct = feeToReservePct;
        feeToReservePct = pct;

        emit FeeToReservePctUpdated(oldPct, pct);
    }

    function setMaxMintPerTx(uint256 maxUsdc) external onlyOwner {
        uint256 oldMax = maxMintPerTxUsdc;
        maxMintPerTxUsdc = maxUsdc;

        emit MaxMintPerTxUpdated(oldMax, maxUsdc);
    }

    function setMaxRefundPerTx(uint256 maxUsdc) external onlyOwner {
        uint256 oldMax = maxRefundPerTxUsdc;
        maxRefundPerTxUsdc = maxUsdc;

        emit MaxRefundPerTxUpdated(oldMax, maxUsdc);
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();

        isFeeExempt[account] = exempt;

        emit FeeExemptUpdated(account, exempt);
    }

    // -------------------------------------------------------------------------
    // Mint Functions
    // -------------------------------------------------------------------------

    function requestMint(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice
    ) external nonReentrant returns (uint256 buckOut, uint256 feeUsdc) {
        return _executeMint(recipient, usdcAmount, minBuckOut, maxEffectivePrice);
    }

    /// @notice requestMint with EIP-2612 permit for single-tx approval + mint.
    function requestMintWithPermit(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 buckOut, uint256 feeUsdc) {
        // Try permit — if front-run, the allowance is already set so we continue
        try IERC20Permit(usdc).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s) {} catch {}

        return _executeMint(recipient, usdcAmount, minBuckOut, maxEffectivePrice);
    }

    // -------------------------------------------------------------------------
    // Refund Functions
    // -------------------------------------------------------------------------

    function requestRefund(
        address recipient,
        uint256 buckAmount,
        uint256 minUsdcOut,
        uint256 minEffectivePrice
    ) external nonReentrant whenNotPaused returns (uint256 usdcOut, uint256 feeUsdc) {
        _checkConfigured();
        if (recipient == address(0)) revert ZeroAddress();
        if (buckAmount == 0) revert ZeroAmount();
        _enforceAccess(msg.sender);
        _enforceAccess(recipient);

        (uint256 capPrice, uint16 refundFee, uint16 halfSpreadBps, bool paused) =
            IPolicyManagerV2(policyManager).getRefundParams();
        if (paused) revert EcosystemPaused();

        uint256 effectivePrice = _applySpread(capPrice, false, halfSpreadBps);
        if (effectivePrice < minEffectivePrice) {
            revert PriceTooLow(effectivePrice, minEffectivePrice);
        }

        uint256 grossUsdc = (buckAmount * effectivePrice) / 1e18 / DECIMAL_ADJUSTMENT;
        feeUsdc = _calculateFee(grossUsdc, refundFee);
        usdcOut = grossUsdc - feeUsdc;

        if (usdcOut < minUsdcOut) {
            revert SlippageExceeded(usdcOut, minUsdcOut);
        }
        if (maxRefundPerTxUsdc != type(uint256).max && usdcOut > maxRefundPerTxUsdc) {
            revert ExceedsMaxRefundPerTx(usdcOut, maxRefundPerTxUsdc);
        }

        // netReserveDrain excludes feeToReserve (comes back to reserve)
        uint256 feeToReserve = (feeUsdc * feeToReservePct) / BPS_DENOMINATOR;
        uint256 feeToTreasury = feeUsdc - feeToReserve;
        uint256 netReserveDrain = usdcOut + feeToTreasury;

        IPolicyManagerV2(policyManager).checkAndRecordRefund(netReserveDrain);

        IBuckV2(buck).burn(msg.sender, buckAmount);
        ILiquidityReserve(liquidityReserve).queueWithdrawal(address(this), grossUsdc);

        if (feeToTreasury > 0) {
            IERC20(usdc).safeTransfer(treasury, feeToTreasury);
        }
        if (feeToReserve > 0) {
            IERC20(usdc).safeTransfer(liquidityReserve, feeToReserve);
        }
        IERC20(usdc).safeTransfer(recipient, usdcOut);

        emit Refund(msg.sender, recipient, buckAmount, usdcOut, feeUsdc, effectivePrice);

        return (usdcOut, feeUsdc);
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    function mintFeeBps() external view returns (uint16) {
        if (policyManager == address(0)) return 0;
        (uint16 mintFee,) = IPolicyManagerV2(policyManager).getFees();
        return mintFee;
    }

    function refundFeeBps() external view returns (uint16) {
        if (policyManager == address(0)) return 0;
        (, uint16 refundFee) = IPolicyManagerV2(policyManager).getFees();
        return refundFee;
    }

    function dailyRefundCap() external view returns (uint256) {
        if (policyManager == address(0)) return 0;
        return IPolicyManagerV2(policyManager).getDailyCap();
    }

    function dailyRefundUsed() external view returns (uint256) {
        if (policyManager == address(0)) return 0;
        return IPolicyManagerV2(policyManager).dailyUsedUsdc();
    }

    /// @dev Preview assuming the caller is not fee-exempt.
    /// @dev Fee-exempt callers only drain usdcOut from the reserve.
    function previewRefundCapUsage(uint256 buckAmount)
        external
        view
        returns (uint256 reserveDrain, uint256 usdcOut, uint256 feeUsdc)
    {
        if (policyManager == address(0)) return (0, 0, 0);

        (uint256 capPrice,, uint16 halfSpreadBps,) = IPolicyManagerV2(policyManager).getRefundParams();
        (, uint16 refundFee) = IPolicyManagerV2(policyManager).getFees();

        uint256 effectivePrice = (capPrice * (BPS_DENOMINATOR - halfSpreadBps)) / BPS_DENOMINATOR;
        uint256 grossUsdc = (buckAmount * effectivePrice) / 1e18 / DECIMAL_ADJUSTMENT;

        feeUsdc = (grossUsdc * refundFee + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        usdcOut = grossUsdc - feeUsdc;

        uint256 feeToReserve = (feeUsdc * feeToReservePct) / BPS_DENOMINATOR;
        uint256 feeToTreasury = feeUsdc - feeToReserve;
        reserveDrain = usdcOut + feeToTreasury;

        return (reserveDrain, usdcOut, feeUsdc);
    }

    // -------------------------------------------------------------------------
    // Pause Functions
    // -------------------------------------------------------------------------

    /// @dev Local pause is separate from the ecosystem pause in PolicyManager.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Recovery Functions
    // -------------------------------------------------------------------------

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == usdc || token == buck) revert CannotRecoverCoreAsset();
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);

        emit TokensRecovered(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    function _executeMint(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice
    ) internal whenNotPaused returns (uint256 buckOut, uint256 feeUsdc) {
        _checkConfigured();
        if (recipient == address(0)) revert ZeroAddress();
        if (usdcAmount == 0) revert ZeroAmount();
        _enforceAccess(msg.sender);
        _enforceAccess(recipient);

        if (maxMintPerTxUsdc != type(uint256).max && usdcAmount > maxMintPerTxUsdc) {
            revert ExceedsMaxMintPerTx(usdcAmount, maxMintPerTxUsdc);
        }

        (
            uint256 capPrice,
            uint16 mintFeeBps_,
            uint16 halfSpreadBps,
            bool isPaused
        ) = IPolicyManagerV2(policyManager).getMintParams();
        if (isPaused) revert EcosystemPaused();

        uint256 effectivePrice = _applySpread(capPrice, true, halfSpreadBps);
        if (effectivePrice > maxEffectivePrice) {
            revert PriceTooHigh(effectivePrice, maxEffectivePrice);
        }

        feeUsdc = _calculateFee(usdcAmount, mintFeeBps_);
        uint256 netUsdc = usdcAmount - feeUsdc;
        buckOut = (netUsdc * DECIMAL_ADJUSTMENT * 1e18) / effectivePrice;

        if (buckOut < minBuckOut) {
            revert SlippageExceeded(buckOut, minBuckOut);
        }

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 feeToReserve = _routeFees(feeUsdc);
        uint256 toReserve = netUsdc + feeToReserve;
        IERC20(usdc).safeTransfer(liquidityReserve, toReserve);

        IBuckV2(buck).mint(recipient, buckOut);

        emit Mint(msg.sender, recipient, usdcAmount, buckOut, feeUsdc, effectivePrice);

        return (buckOut, feeUsdc);
    }

    function _applySpread(
        uint256 capPrice,
        bool isMint,
        uint16 halfSpreadBps
    ) internal pure returns (uint256 effectivePrice) {
        if (isMint) {
            // Mint: price goes UP (user pays more) - round UP to favor protocol
            uint256 numerator = capPrice * (BPS_DENOMINATOR + halfSpreadBps);
            effectivePrice = (numerator + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        } else {
            // Refund: price goes DOWN (user gets less) - round DOWN to favor protocol
            effectivePrice = (capPrice * (BPS_DENOMINATOR - halfSpreadBps)) / BPS_DENOMINATOR;
        }
    }

    /// @dev Ceil division that rounds up in favor of the protocol. Returns 0 if the caller is fee-exempt.
    function _calculateFee(uint256 amount, uint16 feeBps) internal view returns (uint256 fee) {
        if (isFeeExempt[msg.sender]) {
            return 0;
        }
        uint256 numerator = amount * feeBps;
        return (numerator + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    }

    /// @dev Transfers the treasury portion and returns the reserve portion.
    function _routeFees(uint256 feeUsdc) internal returns (uint256 feeToReserve) {
        if (feeUsdc == 0) return 0;

        feeToReserve = (feeUsdc * feeToReservePct) / BPS_DENOMINATOR;
        uint256 feeToTreasury = feeUsdc - feeToReserve;

        if (feeToTreasury > 0) {
            IERC20(usdc).safeTransfer(treasury, feeToTreasury);
        }

        return feeToReserve;
    }

    function _enforceAccess(address account) internal view {
        if (accessRegistry == address(0)) return;

        if (!IAccessRegistry(accessRegistry).isAllowed(account)) {
            revert AccessDenied(account);
        }
    }

    function _checkConfigured() internal view {
        if (buck == address(0) || policyManager == address(0) || liquidityReserve == address(0) || usdc == address(0) || treasury == address(0)) {
            revert ContractsNotConfigured();
        }
    }

    // -------------------------------------------------------------------------
    // UUPS & Ownership
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    uint256[42] private __gap;
}
