// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "src/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MulticallUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IBuckToken {
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface IPolicyManager {
    enum Band {
        Green,
        Yellow,
        Red
    }

    /// @notice Gas optimization: Batched parameters for mint/refund operations
    /// @dev Reduces external calls from 4 to 1, saving ~15-20k gas per transaction
    struct MintParameters {
        uint256 capPrice; // CAP price in 18 decimals
        uint16 halfSpreadBps; // Half-spread in basis points
        uint16 mintFeeBps; // Mint fee in basis points
        uint16 refundFeeBps; // Refund fee in basis points
        bool mintCapPassed; // Whether user is under mint cap
        Band currentBand; // Current band status
    }

    function checkMintCap(uint256 amountTokens) external view returns (bool);
    function recordMint(uint256 amountTokens) external;
    function checkRefundCap(uint256 amountTokens) external view returns (bool);
    function recordRefund(uint256 amountTokens) external;
    function getFees() external view returns (uint16 mintFeeBps, uint16 refundFeeBps);
    function getHalfSpread() external view returns (uint16 halfSpreadBps);
    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee);
    function getCAPPrice() external view returns (uint256 price);
    function currentBand() external view returns (Band);
    function refreshBand() external returns (Band);
    /// @notice Dedicated getter for floor to avoid ABI struct mismatch
    function getBandFloorBps(Band band) external view returns (uint16);
    function getMintParameters(uint256 amountTokens)
        external
        view
        returns (MintParameters memory);
    function getRefundParameters(uint256 amountTokens)
        external
        view
        returns (MintParameters memory);
}

interface ILiquidityReserve {
    function recordDeposit(uint256 amount) external;
    function queueWithdrawal(address to, uint256 amount) external;
}

interface IAccessRegistry {
    function isAllowed(address account) external view returns (bool);
}

// LiquidityWindow sits between approved stewards and the reserve: handles mint/refund pricing, fees, caps.
// PolicyManager feeds parameters, CollateralAttestation drives pricing, and Reserve moves the USDC.
// Intent is to keep primary market logic in one place with explicit admin controls and settlement hooks.
contract LiquidityWindow is
    Initializable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    MulticallUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant USDC_DECIMALS = 6;
    uint256 private constant USDC_SCALE_FACTOR = 10 ** (18 - USDC_DECIMALS); // 1e12 to convert USDC to 18 decimals

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    // Core contract pointers we call into for mint/burn, reserve flows, and policy queries.
    address public buck;
    address public liquidityReserve;
    address public policyManager;
    address public usdc; // The USDC token address

    // Access registry for sanctions/compliance checks
    address public accessRegistry;

    // Liquidity Steward role - fee-exempt addresses
    mapping(address => bool) public isLiquiditySteward;

    uint16 public feeToReservePct; // remainder to treasury
    address public treasury;

    // Recovery sinks allow admin to rescue stray tokens safely.
    mapping(address => bool) public isRecoverySink;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event FeeSplitConfigured(uint16 feeToReservePct, address treasury);
    event MintExecuted(
        address indexed steward,
        address indexed recipient,
        uint256 usdcIn,
        uint256 buckOut,
        uint256 usdcFees
    );
    event RefundExecuted(
        address indexed steward,
        address indexed recipient,
        uint256 buckIn,
        uint256 usdcOut,
        uint256 usdcFees
    );
    event RecoverySinkSet(address indexed sink, bool allowed);
    event TokensRecovered(
        address indexed caller, address indexed token, address indexed to, uint256 amount
    );
    event AccessRegistrySet(address indexed newRegistry);
    event LiquidityStewardSet(address indexed account, bool isSteward);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error PriceTooHigh(uint256 effectivePrice, uint256 maxPrice);
    error PriceTooLow(uint256 effectivePrice, uint256 minPrice);
    error CapCheckFailed();
    error MinAmountNotMet();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InvalidRecoverySink(address account);
    error UnsupportedRecoveryAsset(address token);
    error InvalidAmount();
    error AccessCheckFailed(address account);
    error RenounceOwnershipDisabled();

    // ---------------------------------------------------------------------
    // Constructor & Initializer
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Wire core contract references, default treasury split, and guard rails.
    // Called once through proxy; everything else is owner-configurable afterwards.
    function initialize(
        address initialOwner,
        address buck_,
        address liquidityReserve_,
        address policyManager_
    ) external initializer {
        if (
            initialOwner == address(0) || buck_ == address(0) || liquidityReserve_ == address(0)
                || policyManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        // Initialize parent contracts
        // ReentrancyGuardTransient uses transient storage - no init needed
        __Pausable_init();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        // Initialize LiquidityWindow state
        buck = buck_;
        liquidityReserve = liquidityReserve_;
        policyManager = policyManager_;
        treasury = liquidityReserve_;
        feeToReservePct = uint16(BPS_DENOMINATOR);
        isRecoverySink[liquidityReserve_] = true;
    }

    // ---------------------------------------------------------------------
    // Admin configuration
    // ---------------------------------------------------------------------

    // Adjusts how much of collected fees stay with the reserve vs route to treasury ops.
    function configureFeeSplit(uint16 feeToReservePct_, address treasury_) external onlyOwner {
        if (feeToReservePct_ > BPS_DENOMINATOR) revert("split-bounds");
        if (treasury_ == address(0)) revert ZeroAddress();
        feeToReservePct = feeToReservePct_;
        treasury = treasury_;
        isRecoverySink[treasury_] = true;
        emit RecoverySinkSet(treasury_, true);
        emit FeeSplitConfigured(feeToReservePct_, treasury_);
    }

    // Emergency stop for primary market operations; does not touch instant refunds already queued.
    function pauseLiquidityWindow() external onlyOwner {
        _pause();
    }

    // Resume flow once incident response is done.
    function unpauseLiquidityWindow() external onlyOwner {
        _unpause();
    }

    // Additional safe addresses allowed to receive rescued tokens.
    function setRecoverySink(address sink, bool allowed) external onlyOwner {
        if (sink == address(0)) revert ZeroAddress();
        isRecoverySink[sink] = allowed;
        emit RecoverySinkSet(sink, allowed);
    }

    // Swap access registry if we refresh the Merkle tree contract or toggle compliance requirements.
    // Setting to address(0) disables access enforcement entirely.
    function setAccessRegistry(address registry) external onlyOwner {
        accessRegistry = registry;
        emit AccessRegistrySet(registry);
    }

    // Steward addresses bypass trading fees and represent official liquidity ops.
    function setLiquiditySteward(address account, bool isSteward) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isLiquiditySteward[account] = isSteward;
        emit LiquidityStewardSet(account, isSteward);
    }

    // One-time pointer to the USDC token; guard so we don't accidentally swap assets mid-flight.
    function setUSDC(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Invalid USDC");
        require(usdc == address(0), "USDC already set");
        usdc = _usdc;
    }

    // Governance escape hatch for tokens accidentally sent here; never touches BUCK/USDC.
    function recoverERC20(address token_, address to, uint256 amount) external onlyOwner {
        if (token_ == address(0) || to == address(0)) revert ZeroAddress();
        if (!isRecoverySink[to]) revert InvalidRecoverySink(to);
        if (amount == 0) revert InvalidAmount();
        if (token_ == buck || (usdc != address(0) && token_ == usdc)) {
            revert UnsupportedRecoveryAsset(token_);
        }
        IERC20(token_).safeTransfer(to, amount);
        emit TokensRecovered(msg.sender, token_, to, amount);
    }

    // ---------------------------------------------------------------------
    // Mint / Refund entrypoints
    // ---------------------------------------------------------------------

    // Main primary-market entry: take USDC, mint BUCK at CAP price with spreads/fees applied.
    function requestMint(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 buckOut, uint256 feeUsdc)
    {
        // Autonomous band refresh - updates band based on current reserve ratio
        // Cached reads for rest of transaction (4-5x cheaper than recalculating)
        if (policyManager != address(0)) {
            IPolicyManager(policyManager).refreshBand();
        }

        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        // Enforce access for both caller and recipient
        _enforceAccess(msg.sender);
        _enforceAccess(recipient);

        // Gas optimization: Batch all PolicyManager queries in one call
        // This eliminates 3 external calls, saving ~15-20k gas per mint
        // For cap checking, we pass 0 which will skip cap validation in batch
        // We'll check actual cap after calculating buckOut
        IPolicyManager.MintParameters memory params =
            IPolicyManager(policyManager).getMintParameters(0);

        uint256 effectivePrice = _applySpread(params.capPrice, true, params.halfSpreadBps);
        // Invariant: When CAP < $1 (CR < 1), ensure final mint price remains < $1 even after spread
        if (params.capPrice < PRICE_SCALE && effectivePrice >= PRICE_SCALE) {
            effectivePrice = PRICE_SCALE - 1;
        }
        if (maxEffectivePrice != 0 && effectivePrice > maxEffectivePrice) {
            revert PriceTooHigh(effectivePrice, maxEffectivePrice);
        }

        // Calculate fee first, then mint based on net amount after fees
        // Ensures BUCK supply equals actual USDC backing (excluding protocol fees)
        feeUsdc = _calculateFeeAmount(usdcAmount, params.mintFeeBps);
        uint256 netAmount = usdcAmount - feeUsdc;
        uint256 netAmount18 = netAmount * USDC_SCALE_FACTOR;
        buckOut = (netAmount18 * PRICE_SCALE) / effectivePrice;

        if (buckOut < minBuckOut) {
            revert MinAmountNotMet();
        }

        // Check mint cap with actual buckOut amount (tokens, not BPS)
        // Pass buckOut directly for precise cap tracking without rounding issues
        // Enforce cap: map PolicyManager revert/bool to local CapCheckFailed for compatibility
        try IPolicyManager(policyManager).checkMintCap(buckOut) returns (bool ok) {
            if (!ok) revert CapCheckFailed();
        } catch {
            revert CapCheckFailed();
        }

        // Transfer USDC from user
        require(usdc != address(0), "USDC not configured");
        // Transfer USDC to this contract first
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Send the non-fee portion directly to reserve
        if (netAmount > 0) {
            IERC20(usdc).safeTransfer(liquidityReserve, netAmount);
        }

        // Record mint against aggregate cap before changing supply so epoch cap freezes on pre-mint supply
        IPolicyManager(policyManager).recordMint(buckOut);
        IBuckToken(buck).mint(recipient, buckOut);

        // Route fees (now the contract has the fee USDC) and aggregate reserve portion
        uint256 reserveFeeDeposited = _routeFees(feeUsdc, false);

        // Record a single combined deposit for net + reserve fee portion
        ILiquidityReserve(liquidityReserve).recordDeposit(netAmount + reserveFeeDeposited);

        // Note: cap was recorded before mint; no second record needed

        emit MintExecuted(msg.sender, recipient, usdcAmount, buckOut, feeUsdc);
        return (buckOut, feeUsdc);
    }

    // Reverse flow: burn BUCK, pull USDC from reserve, respect spreads, caps, and slippage checks.
    function requestRefund(
        address recipient,
        uint256 buckAmount,
        uint256 minUsdcOut,
        uint256 minEffectivePrice
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut, uint256 feeUsdc)
    {
        // Autonomous band refresh - updates band based on current reserve ratio
        // Cached reads for rest of transaction (4-5x cheaper than recalculating)
        if (policyManager != address(0)) {
            IPolicyManager(policyManager).refreshBand();
        }

        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        require(usdc != address(0), "USDC not configured");

        // Enforce access for both caller and recipient
        _enforceAccess(msg.sender);
        _enforceAccess(recipient);

        // Gas optimization: Batch all PolicyManager queries in one call
        // This eliminates 3 external calls, saving ~15-20k gas per refund
        // For cap checking, we pass 0 which will skip cap validation in batch
        // We'll check actual cap after calculating usdcOut
        IPolicyManager.MintParameters memory params =
            IPolicyManager(policyManager).getRefundParameters(0);

        uint256 effectivePrice = _applySpread(params.capPrice, false, params.halfSpreadBps);
        if (minEffectivePrice != 0 && effectivePrice < minEffectivePrice) {
            revert PriceTooLow(effectivePrice, minEffectivePrice);
        }

        // Calculate USDC amount in 18 decimals, then scale down to 6
        uint256 grossUsdc18 = (buckAmount * effectivePrice) / PRICE_SCALE;
        uint256 grossUsdc = grossUsdc18 / USDC_SCALE_FACTOR;
        if (grossUsdc == 0) revert InvalidAmount();
        feeUsdc = _calculateFeeAmount(grossUsdc, params.refundFeeBps);
        usdcOut = grossUsdc - feeUsdc;
        if (usdcOut < minUsdcOut) {
            revert MinAmountNotMet();
        }

        // Check liquidity availability before burning BUCK
        // Available liquidity = reserve balance - floor (band-dependent protection)
        uint256 reserveBalance = IERC20(usdc).balanceOf(liquidityReserve);
        uint16 floorBps = IPolicyManager(policyManager).getBandFloorBps(params.currentBand);
        uint256 floor = _calculateFloor(floorBps);
        uint256 availableLiquidity = reserveBalance > floor ? reserveBalance - floor : 0;

        if (grossUsdc > availableLiquidity) {
            revert InsufficientLiquidity(grossUsdc, availableLiquidity);
        }

        // Check refund cap with actual buckAmount (tokens, not BPS)
        // Pass buckAmount directly for precise cap tracking without rounding issues
        try IPolicyManager(policyManager).checkRefundCap(buckAmount) returns (bool ok) {
            if (!ok) revert CapCheckFailed();
        } catch {
            revert CapCheckFailed();
        }

        // Record refund before burning so epoch cap freezes on pre-burn supply
        IPolicyManager(policyManager).recordRefund(buckAmount);
        IBuckToken(buck).burn(msg.sender, buckAmount);

        // Step 1: Get GROSS amount from Reserve (includes fee portion)
        ILiquidityReserve(liquidityReserve).queueWithdrawal(address(this), grossUsdc);

        // Step 2: Now contract has USDC, route fees properly to Reserve/Treasury split
        _routeFees(feeUsdc, true);

        // Step 3: Send net amount to recipient
        IERC20(usdc).safeTransfer(recipient, usdcOut);

        // Note: cap was recorded before burn; no second record needed

        emit RefundExecuted(msg.sender, recipient, buckAmount, usdcOut, feeUsdc);
        return (usdcOut, feeUsdc);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @notice Calculate reserve floor based on floor basis points
    /// @dev Floor protects minimum operational liquidity (GREEN/YELLOW: 5%, RED: 1%)
    /// @param floorBps Floor in basis points from PolicyManager
    /// @return floorUsdc Reserve floor in USDC (6 decimals)
    function _calculateFloor(uint16 floorBps)
        internal
        view
        returns (uint256 floorUsdc)
    {
        // Calculate floor = (totalSupply * floorBps) / 10000
        // Total supply is in 18 decimals, we need USDC in 6 decimals
        uint256 totalSupply = IBuckToken(buck).totalSupply();
        uint256 floorAmount18 = (totalSupply * floorBps) / BPS_DENOMINATOR;

        // Convert from 18 decimals to 6 decimals for USDC
        floorUsdc = floorAmount18 / USDC_SCALE_FACTOR;

        return floorUsdc;
    }

    // Gate mints/refunds behind access checks unless registry is not configured.
    function _enforceAccess(address account) internal view {
        // Skip if no access registry configured
        if (accessRegistry == address(0)) {
            return;
        }
        if (!IAccessRegistry(accessRegistry).isAllowed(account)) {
            revert AccessCheckFailed(account);
        }
    }

    // Applies BPS fees unless the caller is whitelisted as a protocol steward.
    function _calculateFeeAmount(uint256 amount, uint16 feeBps) internal view returns (uint256) {
        // Liquidity Stewards are fee-exempt
        if (isLiquiditySteward[msg.sender]) {
            return 0;
        }
        return (amount * feeBps) / BPS_DENOMINATOR;
    }

    // Applies half-spread around CAP price so mints pay more and refunds receive less.
    function _applySpread(uint256 price, bool forMint, uint16 spreadBps)
        internal
        pure
        returns (uint256 effectivePrice)
    {
        // Apply only the base half-spread (no additional haircut stacking)
        if (spreadBps == 0) {
            return price;
        }

        if (forMint) {
            // For mints, make token MORE expensive (user pays more)
            // Round UP to be conservative so minted BUCK is not over-allocated due to flooring
            uint256 num = price * (BPS_DENOMINATOR + spreadBps);
            effectivePrice = (num + (BPS_DENOMINATOR - 1)) / BPS_DENOMINATOR;
        } else {
            require(spreadBps <= BPS_DENOMINATOR, "spread-bounds");
            // For refunds, make token LESS valuable (user receives less)
            effectivePrice = (price * (BPS_DENOMINATOR - spreadBps)) / BPS_DENOMINATOR;
        }

        return effectivePrice;
    }

    // Splits collected fees between reserve and treasury based on the configured percentage.
    // Optionally records the reserve portion as a LiquidityReserve deposit.
    // Returns the amount sent to reserve so callers can aggregate recordDeposit calls when desired.
    function _routeFees(uint256 feeUsdc, bool recordReserveDeposit) internal returns (uint256 toReserve) {
        if (feeUsdc == 0) return 0;
        if (usdc == address(0)) return 0; // Skip if USDC not configured

        // Split fees between Reserve and Treasury according to feeToReservePct
        toReserve = (feeUsdc * feeToReservePct) / BPS_DENOMINATOR;
        uint256 toTreasury = feeUsdc - toReserve;

        // Verify contract has sufficient USDC balance
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance >= feeUsdc, "Insufficient USDC for fee routing");

        // Send Reserve portion to Reserve
        if (toReserve > 0) {
            IERC20(usdc).safeTransfer(liquidityReserve, toReserve);
            if (recordReserveDeposit) {
                ILiquidityReserve(liquidityReserve).recordDeposit(toReserve);
            }
        }

        // Send Treasury portion directly to Treasury
        if (toTreasury > 0) {
            IERC20(usdc).safeTransfer(treasury, toTreasury);
        }
    }

    // ---------------------------------------------------------------------
    // UUPS Upgrade Authorization
    // ---------------------------------------------------------------------

    // Owner-only gate for UUPS upgrades so a single signer can't hot swap logic unexpectedly.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Ownership renunciation is disabled to prevent accidental lockout
    /// @dev LiquidityWindow requires ongoing governance for pause, upgrades, and configuration
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ---------------------------------------------------------------------
    // Storage Gap
    // ---------------------------------------------------------------------

    // Reserved slots so future revisions can append state without breaking storage layout.
    uint256[50] private __gap;
}
