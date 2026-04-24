// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity ^0.8.26;

/**
 * @title ILiquidityWindowV2
 * @notice Interface for LiquidityWindow V2 - Primary market interface for BUCK
 *
 * V2 Features:
 * - EIP-2612 permit support for single-tx minting
 * - Daily refund cap (via PolicyManager)
 * - Configurable fee split between Reserve and Treasury
 * - Optional per-tx caps as safety rails
 * - Fee exemption mapping for market makers
 */
interface ILiquidityWindowV2 {
    // ============ Events ============

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

    // ============ Errors ============

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
    error CannotRecoverCoreAsset();

    // ============ Mint Functions ============

    /// @notice Mint BUCK with USDC
    /// @param recipient Address to receive BUCK
    /// @param usdcAmount Amount of USDC to spend (6 decimals)
    /// @param minBuckOut Minimum BUCK to receive (slippage protection)
    /// @param maxEffectivePrice Maximum price to pay (18 decimals)
    /// @return buckOut Amount of BUCK minted
    /// @return feeUsdc Fee paid in USDC
    function requestMint(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice
    ) external returns (uint256 buckOut, uint256 feeUsdc);

    /// @notice Mint BUCK with USDC using EIP-2612 permit (single tx)
    /// @param recipient Address to receive BUCK
    /// @param usdcAmount Amount of USDC to spend (6 decimals)
    /// @param minBuckOut Minimum BUCK to receive (slippage protection)
    /// @param maxEffectivePrice Maximum price to pay (18 decimals)
    /// @param deadline Permit deadline timestamp
    /// @param v Signature v component
    /// @param r Signature r component
    /// @param s Signature s component
    /// @return buckOut Amount of BUCK minted
    /// @return feeUsdc Fee paid in USDC
    function requestMintWithPermit(
        address recipient,
        uint256 usdcAmount,
        uint256 minBuckOut,
        uint256 maxEffectivePrice,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 buckOut, uint256 feeUsdc);

    // ============ Refund Functions ============

    /// @notice Refund BUCK for USDC
    /// @param recipient Address to receive USDC
    /// @param buckAmount Amount of BUCK to refund (18 decimals)
    /// @param minUsdcOut Minimum USDC to receive (slippage protection)
    /// @param minEffectivePrice Minimum price to receive (18 decimals)
    /// @return usdcOut Amount of USDC received
    /// @return feeUsdc Fee paid in USDC
    function requestRefund(
        address recipient,
        uint256 buckAmount,
        uint256 minUsdcOut,
        uint256 minEffectivePrice
    ) external returns (uint256 usdcOut, uint256 feeUsdc);

    // ============ View Functions ============

    /// @notice Buck token address
    function buck() external view returns (address);

    /// @notice PolicyManager address
    function policyManager() external view returns (address);

    /// @notice LiquidityReserve address
    function liquidityReserve() external view returns (address);

    /// @notice AccessRegistry address (address(0) if disabled)
    function accessRegistry() external view returns (address);

    /// @notice USDC token address
    function usdc() external view returns (address);

    /// @notice Treasury address for fee routing
    function treasury() external view returns (address);

    /// @notice Percentage of fees routed to reserve (0-10000 bps)
    function feeToReservePct() external view returns (uint16);

    /// @notice Check if account is fee-exempt
    function isFeeExempt(address account) external view returns (bool);

    /// @notice Maximum USDC per mint transaction (type(uint256).max = no limit)
    function maxMintPerTxUsdc() external view returns (uint256);

    /// @notice Maximum USDC output per refund transaction (type(uint256).max = no limit)
    function maxRefundPerTxUsdc() external view returns (uint256);

    /// @notice Mint fee in basis points (delegates to PolicyManager)
    function mintFeeBps() external view returns (uint16);

    /// @notice Refund fee in basis points (delegates to PolicyManager)
    function refundFeeBps() external view returns (uint16);

    /// @notice Daily refund cap (delegates to PolicyManager)
    function dailyRefundCap() external view returns (uint256);

    /// @notice Daily refund amount used (delegates to PolicyManager)
    function dailyRefundUsed() external view returns (uint256);
}
