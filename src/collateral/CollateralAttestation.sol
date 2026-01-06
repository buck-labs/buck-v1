// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// CollateralAttestation keeps the off-chain STRC valuation on-chain so everything else can reason about solvency.
// The attestor bot pushes measurements through here, while policy/liquidity contracts read from it.
// We aim for a small surface: roles, a couple knobs, and pure view math the rest of the system can trust.
contract CollateralAttestation is
    Initializable,
    AccessControlUpgradeable,
    MulticallUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Role constants
    // -------------------------------------------------------------------------

    // Multisig/admin gets this role to manage config and upgrades; matches OZ default for compatibility.
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    // Off-chain attestor service holds this role so only it can publish valuations.
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    // Shared 18-dec precision constant so our math lines up with the rest of the protocol.
    uint256 private constant PRECISION = 1e18;
    // Basis points helper for haircuts/thresholds when we need percentage math.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidHaircut();
    error AttestationStale();
    error InvalidStalenessThreshold();
    error InvalidReserveAssetDecimals();
    error StaleAttestationSubmission(
        uint256 measurementTime, uint256 submissionTime, uint256 maxAge
    );
    error TimestampNotMonotonic(uint256 newTimestamp, uint256 previousTimestamp);

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    // Latest brokerage mark in USD, scaled to 1e18 so all downstream math is easy and lossless.
    // This is the main input from the attestor service.
    uint256 public V;

    // Haircut lets us discount the raw valuation before counting it toward solvency.
    // Stored in 18 decimals (0.98e18 = 2% trim) and shared with every CR consumer.
    uint256 public HC;

    // Tracks when the attestation actually hit chain, useful when comparing to measurement time.
    // This doubles as the freshness reference downstream.
    uint256 public lastAttestationTime;

    // The timestamp reported by the attestor for when the valuation was observed off-chain.
    // Reject submissions that are already stale when they arrive.
    uint256 public attestationMeasurementTime;

    // Wiring to BUCK supply, on-chain reserve, and the reserve asset itself.
    // Allows us to query fresh balances without a keeper doing manual snapshots.
    address public buckToken;
    address public liquidityReserve;
    address public usdc;

    // Decimal precision of the reserve asset (e.g., 6 for USDC, 18 for DAI).
    // Set once during initialization; used to scale reserve balances to 18 decimals for CR math.
    uint8 public reserveAssetDecimals;

    // Max age we tolerate when the system is overcollateralized and life is good.
    // Defaults to ~daily cadence but can be tuned by governance.
    uint256 public healthyStaleness;

    // Short leash once CR dips below 1 so we force rapid attestation updates.
    // Keeps CAP pricing and policy logic responsive under stress.
    uint256 public stressedStaleness;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // Broadcasts valuation updates plus config changes so off-chain automation can stay in sync.
    event AttestationPublished(
        uint256 indexed V,
        uint256 indexed HC,
        uint256 measurementTime,
        uint256 submissionTime,
        uint256 collateralRatio
    );

    event ContractReferencesUpdated(
        address indexed buckToken, address indexed liquidityReserve, address indexed usdc
    );

    event StalenessThresholdsUpdated(uint256 healthyStaleness, uint256 stressedStaleness);

    event HaircutUpdated(uint256 HC);

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    // Implementation constructor just locks the initializer; real setup happens through the proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Boots the module with the right roles, external contract addresses, and staleness timers.
    // Designed to run exactly once through the proxy; all params must be present or we abort.
    // Drops in a default 2% haircut so CR math is conservative from day one.
    function initialize(
        address admin,
        address attestor,
        address _buckToken,
        address _liquidityReserve,
        address _usdc,
        uint8 _reserveAssetDecimals,
        uint256 _healthyStaleness,
        uint256 _stressedStaleness
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (attestor == address(0)) revert ZeroAddress();
        if (_buckToken == address(0)) revert ZeroAddress();
        if (_liquidityReserve == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_reserveAssetDecimals > 18) revert InvalidReserveAssetDecimals();
        if (_healthyStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness == 0) revert InvalidStalenessThreshold();

        __AccessControl_init();
        __Multicall_init();
        __UUPSUpgradeable_init();

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(ATTESTOR_ROLE, attestor);

        buckToken = _buckToken;
        liquidityReserve = _liquidityReserve;
        usdc = _usdc;
        reserveAssetDecimals = _reserveAssetDecimals;

        // Default thresholds
        healthyStaleness = _healthyStaleness;
        stressedStaleness = _stressedStaleness;

        // Default 2% haircut (98% of value)
        HC = 0.98e18;
    }

    // -------------------------------------------------------------------------
    // UUPS Upgrade Authorization
    // -------------------------------------------------------------------------

    // Standard UUPS gate: only the admin role can push a new implementation.
    // The address is unused; OZ validates it and the hook is required by UUPS.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // -------------------------------------------------------------------------
    // Attestor Functions
    // -------------------------------------------------------------------------

    // Attestor pushes fresh numbers here: raw valuation, haircut, and when the measurement happened.
    // We sanity-check the haircut bounds and make sure the measurement isn't already stale on arrival.
    // All writes happen atomically so readers see consistent V/HC/time in the same block.
    function publishAttestation(uint256 _V, uint256 _HC, uint256 _attestedTimestamp)
        external
        onlyRole(ATTESTOR_ROLE)
    {
        if (_HC > PRECISION) revert InvalidHaircut();
        if (_HC == 0) revert InvalidHaircut();

        // Enforce monotonic timestamps - new attestation must be newer than previous
        if (_attestedTimestamp <= attestationMeasurementTime) {
            revert TimestampNotMonotonic(_attestedTimestamp, attestationMeasurementTime);
        }

        // Calculate new CR from provided parameters before storing
        // Ensures staleness check uses the correct threshold (stressed vs healthy)
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
    // View Functions
    // -------------------------------------------------------------------------

    // Crunches CR using live supply, reserve balance, and the haircut valuation.
    // If there's no supply we treat it as infinitely collateralized so callers short-circuit safely.
    // Reserve asset gets scaled to 18 decimals dynamically based on configured decimals.
    //
    // Treasury USDC is NOT counted in CR - it's protocol profit, not user backing.
    // Only reserve USDC counts as collateral since that's what backs user refunds.
    function getCollateralRatio() public view returns (uint256) {
        uint256 L = IERC20(buckToken).totalSupply();
        if (L == 0) return type(uint256).max; // Infinite CR when no supply

        // Count ONLY reserve USDC as collateral (treasury is protocol profit)
        uint256 R = IERC20(usdc).balanceOf(liquidityReserve);

        // CR = (R + HC×V) / L
        // All in 18 decimals: R (scaled from reserveAssetDecimals), HC (18 decimals), V (18 decimals), L (18 decimals)
        uint256 scaledR = _scaleToEighteen(R, reserveAssetDecimals);
        uint256 haircutValue = Math.mulDiv(HC, V, PRECISION);
        uint256 numerator = scaledR + haircutValue;

        return Math.mulDiv(numerator, PRECISION, L);
    }

    // Lets policy/liquidity contracts know if this data is still trustworthy.
    // We default to true until the first attestation lands so everyone fails safe.
    // Healthy CR tolerates longer gaps, stressed CR tightens the leash immediately.
    function isAttestationStale() public view returns (bool) {
        if (attestationMeasurementTime == 0) return true; // Never attested

        uint256 cr = getCollateralRatio();
        uint256 maxStaleness = cr >= PRECISION ? healthyStaleness : stressedStaleness;

        return block.timestamp - attestationMeasurementTime > maxStaleness;
    }

    // Handy for dashboards: tells you how long it’s been since the broker valuation was observed.
    // We signal "never" by returning max uint so nobody mistakes a cold start for fresh data.
    // Otherwise it’s a straight timestamp diff using the recorded measurement time.
    function timeSinceLastAttestation() external view returns (uint256) {
        if (attestationMeasurementTime == 0) return type(uint256).max;
        return block.timestamp - attestationMeasurementTime;
    }

    // Shortcut for anyone who just needs to know if CR cleared the 1.0 bar.
    // Reuses getCollateralRatio under the hood so values stay consistent across the stack.
    function isHealthyCollateral() external view returns (bool) {
        return getCollateralRatio() >= PRECISION;
    }

    // Gives callers the individual pieces behind the CR calculation for transparency.
    // All outputs are scaled to 18 decimals so analytics don't have to special-case different assets.
    // Useful for understanding the composition of the collateral ratio.
    function getCollateralComponents()
        external
        view
        returns (uint256 R, uint256 V_, uint256 L, uint256 haircutValue)
    {
        L = IERC20(buckToken).totalSupply();
        // Count ONLY reserve USDC as collateral (treasury is protocol profit)
        R = _scaleToEighteen(IERC20(usdc).balanceOf(liquidityReserve), reserveAssetDecimals);
        V_ = V;
        haircutValue = Math.mulDiv(HC, V, PRECISION);
    }

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    // Swap in new token/reserve/usdc contracts after upgrades or migrations.
    // All pointers must be non-zero to avoid bricking collateral queries.
    function setContractReferences(address _buckToken, address _liquidityReserve, address _usdc)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_buckToken == address(0)) revert ZeroAddress();
        if (_liquidityReserve == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();

        buckToken = _buckToken;
        liquidityReserve = _liquidityReserve;
        usdc = _usdc;

        emit ContractReferencesUpdated(_buckToken, _liquidityReserve, _usdc);
    }

    // Adjust staleness thresholds for each CR regime.
    // Both values must stay non-zero to avoid trust issues.
    // Stressed threshold must be <= healthy threshold (fresher data required under stress).
    function setStalenessThresholds(uint256 _healthyStaleness, uint256 _stressedStaleness)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_healthyStaleness == 0) revert InvalidStalenessThreshold();
        if (_stressedStaleness == 0) revert InvalidStalenessThreshold();
        // Stressed mode requires fresher data, so threshold must be shorter
        if (_stressedStaleness > _healthyStaleness) revert InvalidStalenessThreshold();

        healthyStaleness = _healthyStaleness;
        stressedStaleness = _stressedStaleness;

        emit StalenessThresholdsUpdated(_healthyStaleness, _stressedStaleness);
    }

    // Update haircut coefficient for collateral valuation.
    // Haircut stays within (0, 1e18] for valid math.
    function setHaircut(uint256 _HC) external onlyRole(ADMIN_ROLE) {
        if (_HC > PRECISION) revert InvalidHaircut();
        if (_HC == 0) revert InvalidHaircut();

        HC = _HC;
        emit HaircutUpdated(_HC);
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    // Scales a value from arbitrary decimals to 18 decimals for consistent math.
    // Handles both scaling up (USDC 6→18) and scaling down (hypothetical 24→18).
    /// @param value The raw value to scale
    /// @param decimals The current decimal precision of the value
    /// @return The value scaled to 18 decimals
    function _scaleToEighteen(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) {
            return value * (10 ** (18 - decimals));
        } else {
            return value / (10 ** (decimals - 18));
        }
    }

    // Calculates CR from provided V and HC parameters without reading storage.
    // Used to determine staleness threshold BEFORE storing new attestation values.
    // Fixes TOCTOU vulnerability where OLD CR determined threshold for NEW values.
    /// @param _V Off-chain collateral value (18 decimals)
    /// @param _HC Haircut coefficient (18 decimals)
    /// @return Calculated collateral ratio (18 decimals)
    function _calculateCR(uint256 _V, uint256 _HC) internal view returns (uint256) {
        uint256 L = IERC20(buckToken).totalSupply();
        if (L == 0) return type(uint256).max; // Infinite CR when no supply

        // Count ONLY reserve USDC as collateral (treasury is protocol profit)
        uint256 R = IERC20(usdc).balanceOf(liquidityReserve);

        // CR = (R + HC×V) / L (all in 18 decimals)
        uint256 scaledR = _scaleToEighteen(R, reserveAssetDecimals);
        uint256 haircutValue = Math.mulDiv(_HC, _V, PRECISION);
        uint256 numerator = scaledR + haircutValue;

        return Math.mulDiv(numerator, PRECISION, L);
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    // Reserved slots for future upgrades so we can append fields without clobbering storage.
    // Don't touch unless you're managing a new version and understand the layout implications.
    uint256[50] private __gap;
}
