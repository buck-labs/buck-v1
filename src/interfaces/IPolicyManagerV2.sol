// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity ^0.8.26;

/**
 * @title IPolicyManagerV2
 * @notice Interface for PolicyManagerV2 - Simplified policy engine for BUCK V2
 *
 * V2 Design:
 * - Single daily cap: % of liquidity reserve (EST-aligned reset)
 * - Flat fees: mintFeeBps, refundFeeBps, halfSpreadBps, buyFeeBps, sellFeeBps
 * - getCAPPrice(): (STRC/100) + yieldAccumulated, capped by CR (additive on face value)
 * - Ecosystem pause: One pause stops everything
 */
interface IPolicyManagerV2 {
    // ============ Events ============

    event ContractReferencesUpdated(
        address indexed buck,
        address indexed oracleAdapter,
        address indexed collateralAttestation,
        address liquidityReserve,
        address usdc
    );
    event FeesUpdated(
        uint16 mintFeeBps,
        uint16 refundFeeBps,
        uint16 halfSpreadBps,
        uint16 buyFeeBps,
        uint16 sellFeeBps
    );
    event DailyCapPctUpdated(uint8 oldPct, uint8 newPct);
    event CycleOffsetUpdated(uint8 oldHours, uint8 newHours);
    event DailyCapReset(uint64 cycle, uint256 capUsdc);
    event RefundRecorded(uint256 reserveDrain, uint256 dailyUsedUsdc, uint256 dailyCapUsdc);

    // ============ Errors ============

    error ZeroAddress();
    error InvalidFee();
    error InvalidCapPct();
    error InvalidCycleOffset();
    error ExceedsDailyCap(uint256 requested, uint256 remaining);
    error ContractsNotConfigured();

    // ============ Pricing Functions ============

    /// @notice Get CAP price: (STRC/100) + yieldAccumulated, capped by CR
    /// @dev Additive model: yield is on $1 face value, not floating STRC price
    /// @return price Price in 18 decimals (1e18 = $1.00)
    function getCAPPrice() external view returns (uint256 price);

    /// @notice Get collateral ratio: totalAssets / totalSupply
    /// @return cr Collateral ratio in 18 decimals (1e18 = 100%)
    function getCollateralRatio() external view returns (uint256 cr);

    /// @notice Get total assets backing BUCK
    /// @return Total asset value in USDC (6 decimals)
    function totalAssets() external view returns (uint256);

    // ============ Fee Functions ============

    /// @notice Get primary market fees
    function getFees() external view returns (uint16 mintFee, uint16 refundFee);

    /// @notice Get DEX fees (for Buck token)
    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee);

    /// @notice Get half-spread for mint/refund pricing
    function getHalfSpread() external view returns (uint16);

    // ============ Batched Getters (Gas Optimization) ============

    /// @notice Get all parameters needed for a mint in one call
    /// @return capPrice CAP price (18 decimals)
    /// @return mintFee Mint fee in basis points
    /// @return halfSpread Half-spread in basis points
    /// @return isPaused Whether ecosystem is paused
    function getMintParams()
        external
        view
        returns (uint256 capPrice, uint16 mintFee, uint16 halfSpread, bool isPaused);

    /// @notice Get all parameters needed for a refund in one call
    /// @return capPrice CAP price (18 decimals)
    /// @return refundFee Refund fee in basis points
    /// @return halfSpread Half-spread in basis points
    /// @return paused Whether ecosystem is paused
    function getRefundParams()
        external
        view
        returns (uint256 capPrice, uint16 refundFee, uint16 halfSpread, bool paused);

    // ============ Daily Cap Functions ============

    /// @notice Check if a refund is allowed (view for UI preview)
    /// @dev Returns status instead of reverting - use for UI checks
    /// @dev IMPORTANT: Pass net reserve drain (usdcOut + feeToTreasury), not just user payout
    /// @dev Use LiquidityWindowV2.previewRefundCapUsage() to compute the correct value
    /// @param reserveDrain Net USDC that would leave the reserve (usdcOut + feeToTreasury, 6 decimals)
    /// @return allowed True if refund would be allowed
    /// @return reason Failure reason if not allowed (empty if allowed)
    function checkRefund(uint256 reserveDrain) external view returns (bool allowed, string memory reason);

    /// @notice Check and record a refund in one call (Gas Optimization)
    /// @dev The only way to record refunds - requires OPERATOR_ROLE
    /// @dev LiquidityWindow passes net reserve drain (usdcOut + feeToTreasury), not just user payout
    /// @param reserveDrain Net USDC leaving the reserve (usdcOut + feeToTreasury, 6 decimals)
    function checkAndRecordRefund(uint256 reserveDrain) external;

    // ============ Role Functions ============

    /// @notice OPERATOR_ROLE constant (grant to LiquidityWindow)
    function OPERATOR_ROLE() external view returns (bytes32);

    /// @notice Get remaining daily refund capacity
    /// @return remaining USDC that can still be redeemed today (6 decimals)
    function getRemainingCapacity() external view returns (uint256 remaining);

    /// @notice Get current daily cap in USDC
    /// @return cap Current daily cap (6 decimals)
    function getDailyCap() external view returns (uint256 cap);

    // ============ Pause Functions ============

    /// @notice Check if ecosystem is paused (from PausableUpgradeable)
    function paused() external view returns (bool);

    // ============ View Functions ============

    /// @notice Daily refund cap as percentage of liquidity reserve (0-100)
    function dailyCapPct() external view returns (uint8);

    /// @notice USDC redeemed in current cap cycle
    function dailyUsedUsdc() external view returns (uint256);

    /// @notice Frozen cap for current cycle
    function dailyCapUsdc() external view returns (uint256);

    /// @notice Hours to add to UTC to align to EST midnight
    function cycleOffsetHours() external view returns (uint8);

    /// @notice Mint fee in basis points
    function mintFeeBps() external view returns (uint16);

    /// @notice Refund fee in basis points
    function refundFeeBps() external view returns (uint16);

    /// @notice Half-spread in basis points
    function halfSpreadBps() external view returns (uint16);

    /// @notice DEX buy fee in basis points
    function buyFeeBps() external view returns (uint16);

    /// @notice DEX sell fee in basis points
    function sellFeeBps() external view returns (uint16);

    /// @notice LiquidityWindow contract address (authorized to call recordRefund)
    function liquidityWindow() external view returns (address);
}
