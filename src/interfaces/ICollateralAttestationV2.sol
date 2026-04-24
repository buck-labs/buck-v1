// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity ^0.8.26;

/**
 * @title ICollateralAttestationV2
 * @notice Interface for CollateralAttestation V2 with Cash-in-Flight tracking
 *
 * V2 Changes:
 * - Added Cash-in-Flight (CIF) tracking for cash in transit
 * - CR formula: (R + HC×V + CIF) / L
 * - No CIF expiry - admin manually clears after cash arrives at destination
 *
 * CIF Flow (works for BOTH directions):
 * - Outgoing (Reserve → Alpaca): LiquidityReserve calls addCashInFlight() on withdrawal
 * - Incoming (Alpaca → Reserve): Admin calls addCashInFlight() when dividend wire initiated
 * - Admin clears CIF via clearCashInFlight(expectedAmount) when cash arrives at destination
 */
interface ICollateralAttestationV2 {
    // ============ Events ============

    event AttestationPublished(
        uint256 indexed V,
        uint256 indexed HC,
        uint256 measurementTime,
        uint256 submissionTime,
        uint256 collateralRatio
    );
    event AttestorUpdated(address indexed newAttestor);
    event LiquidityReserveUpdated(address indexed newLiquidityReserve);
    event ContractReferencesUpdated(address indexed buckToken, address indexed usdc);
    event StalenessThresholdsUpdated(uint256 healthyStaleness, uint256 stressedStaleness);
    event HaircutUpdated(uint256 HC);
    event CashInFlightAdded(uint256 amount, uint256 newTotal);
    event CashInFlightSet(uint256 amount);

    // ============ Errors ============

    error ZeroAddress();
    error InvalidHaircut();
    error InvalidStalenessThreshold();
    error InvalidReserveAssetDecimals();
    error StaleAttestationSubmission(uint256 measurementTime, uint256 submissionTime, uint256 maxAge);
    error TimestampNotMonotonic(uint256 newTimestamp, uint256 previousTimestamp);
    error Unauthorized();
    error CashInFlightMismatch(uint256 actual, uint256 expected);
    error UseClearCashInFlight();

    // ============ Attestor Functions ============

    /// @notice Publish new attestation from off-chain valuation
    /// @param _V New brokerage value (18 decimals)
    /// @param _HC Haircut coefficient (18 decimals)
    /// @param _attestedTimestamp When the measurement was taken off-chain
    function publishAttestation(uint256 _V, uint256 _HC, uint256 _attestedTimestamp) external;

    // ============ Cash-in-Flight Functions ============

    /// @notice Add to cash-in-flight (callable by LiquidityReserve OR Admin)
    /// @dev LiquidityReserve calls on outgoing (withdrawal to Alpaca)
    /// @dev Admin calls on incoming (dividend wire from Alpaca)
    /// @param amount USDC amount in transit (in reserve decimals, e.g., 6 for USDC)
    function addCashInFlight(uint256 amount) external;

    /// @notice Set cash-in-flight to a non-zero amount (admin correction)
    /// @param amount New CIF amount (in reserve decimals) - must be non-zero
    /// @dev To clear CIF, use clearCashInFlight() which guards against tx reordering
    function setCashInFlight(uint256 amount) external;

    /// @notice Clear cash-in-flight only if it matches the expected amount
    /// @dev Prevents silent CIF corruption from transaction reordering
    /// @param expectedAmount The expected current CIF value (18 decimals)
    function clearCashInFlight(uint256 expectedAmount) external;

    /// @notice Get effective CIF (no expiry in V2)
    /// @return Current cash-in-flight amount (18 decimals)
    function getEffectiveCIF() external view returns (uint256);

    // ============ View Functions ============

    /// @notice Attested brokerage holdings value (18 decimals)
    function V() external view returns (uint256);

    /// @notice Haircut coefficient (18 decimals), e.g., 0.98e18 = 98%
    function HC() external view returns (uint256);

    /// @notice Cash-in-flight amount (18 decimals)
    function cashInFlight() external view returns (uint256);

    /// @notice When the attestation was submitted on-chain
    function lastAttestationTime() external view returns (uint256);

    /// @notice When the off-chain measurement was taken
    function attestationMeasurementTime() external view returns (uint256);

    /// @notice BUCK token address
    function buckToken() external view returns (address);

    /// @notice Liquidity reserve address
    function liquidityReserve() external view returns (address);

    /// @notice USDC token address
    function usdc() external view returns (address);

    /// @notice Reserve asset decimals
    function reserveAssetDecimals() external view returns (uint8);

    /// @notice Staleness threshold when CR >= 100%
    function healthyStaleness() external view returns (uint256);

    /// @notice Staleness threshold when CR < 100%
    function stressedStaleness() external view returns (uint256);

    /// @notice Attestor service address
    function attestor() external view returns (address);

    /// @notice Calculate collateral ratio: CR = (R + HC×V + CIF) / L
    /// @return CR in 18 decimals (1e18 = 100%)
    function getCollateralRatio() external view returns (uint256);

    /// @notice Check if attestation is stale
    function isAttestationStale() external view returns (bool);

    /// @notice Time since last attestation measurement
    function timeSinceLastAttestation() external view returns (uint256);

    /// @notice Check if CR is healthy (>= 100%)
    function isHealthyCollateral() external view returns (bool);

    /// @notice Get collateral components for transparency
    /// @return R On-chain reserve (18 decimals)
    /// @return V_ Off-chain attested value (18 decimals)
    /// @return CIF Cash-in-flight (18 decimals)
    /// @return L Total BUCK supply (18 decimals)
    /// @return haircutValue HC x V (18 decimals)
    function getCollateralComponents()
        external
        view
        returns (uint256 R, uint256 V_, uint256 CIF, uint256 L, uint256 haircutValue);

    /// @notice Total collateral value (R + HC×V + CIF)
    function totalCollateralValue() external view returns (uint256);

    /// @notice Total assets backing BUCK (PolicyManagerV2 compatible)
    /// @return Total in reserve decimals (6 for USDC)
    function totalAssets() external view returns (uint256);

    // ============ Admin Functions ============

    /// @notice Update attestor address
    function setAttestor(address newAttestor) external;

    /// @notice Update liquidity reserve address
    function setLiquidityReserve(address newLiquidityReserve) external;

    /// @notice Update contract references
    function setContractReferences(address _buckToken, address _usdc) external;

    /// @notice Update staleness thresholds
    function setStalenessThresholds(uint256 _healthyStaleness, uint256 _stressedStaleness) external;

    /// @notice Update haircut coefficient
    function setHaircut(uint256 _HC) external;
}
