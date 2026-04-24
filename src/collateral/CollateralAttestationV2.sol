//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝
//
// COLLATERAL ATTESTATION V2
// OFF-CHAIN COLLATERAL VALUATION
//
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CollateralAttestationV2
 * @notice Tracks off-chain STRC value and cash in flight for collateral ratio calculations.
 *
 * @dev Collateral ratio is computed as (R + HC x V + CIF) / L.
 */
contract CollateralAttestationV2 is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Role Constants
    // -------------------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_CIF_AGE = 14 days;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidHaircut();
    error InvalidStalenessThreshold();
    error InvalidReserveAssetDecimals();
    error StaleAttestationSubmission(uint256 measurementTime, uint256 submissionTime, uint256 maxAge);
    error TimestampNotMonotonic(uint256 newTimestamp, uint256 previousTimestamp);
    error Unauthorized();
    error CashInFlightMismatch(uint256 actual, uint256 expected);
    error UseClearCashInFlight();

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Attested brokerage holdings value (18 decimals)
    uint256 public V;

    /// @notice Haircut coefficient (18 decimals), e.g., 0.98e18 = 98%
    uint256 public HC;

    /// @notice When the attestation was submitted on-chain
    uint256 public lastAttestationTime;

    /// @notice When the off-chain measurement was taken
    uint256 public attestationMeasurementTime;

    /// @notice BUCK token address
    address public buckToken;

    /// @notice Liquidity reserve address (holds on-chain USDC backing)
    address public liquidityReserve;

    /// @notice USDC token address
    address public usdc;

    /// @notice Reserve asset decimals (6 for USDC)
    uint8 public reserveAssetDecimals;

    /// @notice Staleness threshold when CR >= 100%
    uint256 public healthyStaleness;

    /// @notice Staleness threshold when CR < 100%
    uint256 public stressedStaleness;

    // -------------------------------------------------------------------------
    // Cash-in-Flight
    // -------------------------------------------------------------------------

    /// @notice Cash-in-Flight: USDC in transit (both directions) not yet at destination (18 decimals)
    uint256 public cashInFlight;

    /// @notice Timestamp of last CIF update (for expiry check)
    uint256 public lastCIFUpdate;

    /// @notice Attestor service address
    address public attestor;

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialAdmin,
        address initialAttestor,
        address _buckToken,
        address _liquidityReserve,
        address _usdc,
        uint8 _reserveAssetDecimals,
        uint256 _healthyStaleness,
        uint256 _stressedStaleness
    ) external initializer {
        if (initialAdmin == address(0)) revert ZeroAddress();
        if (initialAttestor == address(0)) revert ZeroAddress();
        if (_buckToken == address(0)) revert ZeroAddress();
        if (_liquidityReserve == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_reserveAssetDecimals > 18) revert InvalidReserveAssetDecimals();
        if (_healthyStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness > _healthyStaleness) revert InvalidStalenessThreshold();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(ATTESTOR_ROLE, initialAttestor);

        attestor = initialAttestor;
        buckToken = _buckToken;
        liquidityReserve = _liquidityReserve;
        usdc = _usdc;
        reserveAssetDecimals = _reserveAssetDecimals;
        healthyStaleness = _healthyStaleness;
        stressedStaleness = _stressedStaleness;

        HC = PRECISION;

        emit AttestorUpdated(initialAttestor);
    }

    // -------------------------------------------------------------------------
    // Attestor Functions
    // -------------------------------------------------------------------------

    /// @notice Publish new attestation from off-chain valuation
    /// @param _V New brokerage value (18 decimals)
    /// @param _HC Haircut coefficient (18 decimals)
    /// @param _attestedTimestamp When the measurement was taken off-chain
    function publishAttestation(uint256 _V, uint256 _HC, uint256 _attestedTimestamp)
        external
        onlyRole(ATTESTOR_ROLE)
    {
        if (_HC > PRECISION) revert InvalidHaircut();
        if (_HC == 0) revert InvalidHaircut();

        if (_attestedTimestamp <= attestationMeasurementTime) {
            revert TimestampNotMonotonic(_attestedTimestamp, attestationMeasurementTime);
        }

        uint256 newCR = _calculateCR(_V, _HC);
        uint256 maxStaleness = newCR >= PRECISION ? healthyStaleness : stressedStaleness;

        if (block.timestamp - _attestedTimestamp > maxStaleness) {
            revert StaleAttestationSubmission(_attestedTimestamp, block.timestamp, maxStaleness);
        }

        V = _V;
        HC = _HC;
        lastAttestationTime = block.timestamp;
        attestationMeasurementTime = _attestedTimestamp;

        emit AttestationPublished(_V, _HC, _attestedTimestamp, block.timestamp, newCR);
    }

    // -------------------------------------------------------------------------
    // Cash-in-Flight Functions
    // -------------------------------------------------------------------------

    /// @notice Adds cash in flight.
    /// @dev Callable by LiquidityReserve or an admin.
    /// @param amount USDC amount in transit (in reserve decimals, e.g., 6 for USDC)
    function addCashInFlight(uint256 amount) external {
        if (msg.sender != liquidityReserve && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        uint256 scaledAmount = _scaleToEighteen(amount, reserveAssetDecimals);
        cashInFlight += scaledAmount;
        lastCIFUpdate = block.timestamp;
        emit CashInFlightAdded(scaledAmount, cashInFlight);
    }

    /// @notice Sets cash in flight to a non-zero amount.
    /// @param amount USDC amount in transit, in reserve decimals.
    function setCashInFlight(uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert UseClearCashInFlight();
        uint256 scaledAmount = _scaleToEighteen(amount, reserveAssetDecimals);
        cashInFlight = scaledAmount;
        lastCIFUpdate = block.timestamp;
        emit CashInFlightSet(scaledAmount);
    }

    /// @notice Clears cash in flight if it matches the expected amount.
    /// @param expectedAmount The expected current CIF value (18 decimals)
    function clearCashInFlight(uint256 expectedAmount) external onlyRole(ADMIN_ROLE) {
        if (cashInFlight != expectedAmount) {
            revert CashInFlightMismatch(cashInFlight, expectedAmount);
        }
        cashInFlight = 0;
        lastCIFUpdate = block.timestamp;
        emit CashInFlightSet(0);
    }

    /// @notice Returns effective cash in flight.
    /// @return Current cash-in-flight amount (18 decimals), or 0 if expired
    function getEffectiveCIF() external view returns (uint256) {
        return _getEffectiveCIF();
    }

    /// @dev Returns 0 once cashInFlight has expired.
    function _getEffectiveCIF() internal view returns (uint256) {
        if (cashInFlight == 0) return 0;
        if (block.timestamp > lastCIFUpdate + MAX_CIF_AGE) return 0;
        return cashInFlight;
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    /// @notice Calculate collateral ratio: CR = (R + HC×V + CIF) / L
    /// @return CR in 18 decimals (1e18 = 100%)
    function getCollateralRatio() public view returns (uint256) {
        uint256 L = IERC20(buckToken).totalSupply();
        if (L == 0) return type(uint256).max; // Infinite CR when no supply

        uint256 R = IERC20(usdc).balanceOf(liquidityReserve);
        uint256 scaledR = _scaleToEighteen(R, reserveAssetDecimals);
        uint256 haircutValue = Math.mulDiv(HC, V, PRECISION);

        uint256 numerator = scaledR + haircutValue + _getEffectiveCIF();

        return Math.mulDiv(numerator, PRECISION, L);
    }

    /// @notice Check if attestation is stale
    /// @return True if attestation exceeds staleness threshold
    function isAttestationStale() public view returns (bool) {
        if (attestationMeasurementTime == 0) return true; // Never attested

        uint256 cr = getCollateralRatio();
        uint256 maxStaleness = cr >= PRECISION ? healthyStaleness : stressedStaleness;

        return block.timestamp - attestationMeasurementTime > maxStaleness;
    }

    /// @return Seconds since measurement, or max uint256 if never attested
    function timeSinceLastAttestation() external view returns (uint256) {
        if (attestationMeasurementTime == 0) return type(uint256).max;
        return block.timestamp - attestationMeasurementTime;
    }

    function isHealthyCollateral() external view returns (bool) {
        return getCollateralRatio() >= PRECISION;
    }

    /// @notice Get collateral components for transparency
    /// @return R On-chain reserve (18 decimals)
    /// @return V_ Off-chain attested value (18 decimals)
    /// @return CIF Cash-in-flight (18 decimals)
    /// @return L Total BUCK supply (18 decimals)
    /// @return haircutValue HC x V (18 decimals)
    function getCollateralComponents()
        external
        view
        returns (uint256 R, uint256 V_, uint256 CIF, uint256 L, uint256 haircutValue)
    {
        L = IERC20(buckToken).totalSupply();
        R = _scaleToEighteen(IERC20(usdc).balanceOf(liquidityReserve), reserveAssetDecimals);
        V_ = V;
        CIF = _getEffectiveCIF();
        haircutValue = Math.mulDiv(HC, V, PRECISION);
    }

    function totalCollateralValue() external view returns (uint256) {
        uint256 R = _scaleToEighteen(IERC20(usdc).balanceOf(liquidityReserve), reserveAssetDecimals);
        uint256 haircutValue = Math.mulDiv(HC, V, PRECISION);
        return R + haircutValue + _getEffectiveCIF();
    }

    /// @notice Total assets backing BUCK, in reserve decimals.
    /// @return Total in reserve decimals (6 for USDC)
    function totalAssets() external view returns (uint256) {
        uint256 R = IERC20(usdc).balanceOf(liquidityReserve); // Raw reserve-decimal value.
        // Scale 18-decimal values down to reserve decimals.
        uint256 haircutValue = Math.mulDiv(HC, V, PRECISION); // 18 decimals.
        uint256 scaledHaircut = haircutValue / (10 ** (18 - reserveAssetDecimals));
        uint256 scaledCIF = _getEffectiveCIF() / (10 ** (18 - reserveAssetDecimals));
        return R + scaledHaircut + scaledCIF;
    }

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    function setAttestor(address newAttestor) external onlyRole(ADMIN_ROLE) {
        if (newAttestor == address(0)) revert ZeroAddress();

        if (attestor != address(0)) {
            _revokeRole(ATTESTOR_ROLE, attestor);
        }
        _grantRole(ATTESTOR_ROLE, newAttestor);

        attestor = newAttestor;
        emit AttestorUpdated(newAttestor);
    }

    function setLiquidityReserve(address newLiquidityReserve) external onlyRole(ADMIN_ROLE) {
        if (newLiquidityReserve == address(0)) revert ZeroAddress();
        liquidityReserve = newLiquidityReserve;
        emit LiquidityReserveUpdated(newLiquidityReserve);
    }

    function setContractReferences(address _buckToken, address _usdc) external onlyRole(ADMIN_ROLE) {
        if (_buckToken == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();

        buckToken = _buckToken;
        usdc = _usdc;

        emit ContractReferencesUpdated(_buckToken, _usdc);
    }

    function setStalenessThresholds(uint256 _healthyStaleness, uint256 _stressedStaleness)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_healthyStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness > _healthyStaleness) revert InvalidStalenessThreshold();

        healthyStaleness = _healthyStaleness;
        stressedStaleness = _stressedStaleness;

        emit StalenessThresholdsUpdated(_healthyStaleness, _stressedStaleness);
    }

    function setHaircut(uint256 _HC) external onlyRole(ADMIN_ROLE) {
        if (_HC > PRECISION) revert InvalidHaircut();
        if (_HC == 0) revert InvalidHaircut();

        HC = _HC;
        emit HaircutUpdated(_HC);
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    function _scaleToEighteen(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) {
            return value * (10 ** (18 - decimals));
        } else {
            return value / (10 ** (decimals - 18));
        }
    }

    /// @dev Calculates collateral ratio using the provided attestation values.
    function _calculateCR(uint256 _V, uint256 _HC) internal view returns (uint256) {
        uint256 L = IERC20(buckToken).totalSupply();
        if (L == 0) return type(uint256).max;

        uint256 R = IERC20(usdc).balanceOf(liquidityReserve);
        uint256 scaledR = _scaleToEighteen(R, reserveAssetDecimals);
        uint256 haircutValue = Math.mulDiv(_HC, _V, PRECISION);

        uint256 numerator = scaledR + haircutValue + _getEffectiveCIF();

        return Math.mulDiv(numerator, PRECISION, L);
    }

    // -------------------------------------------------------------------------
    // UUPS Authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    uint256[48] private __gap;
}
