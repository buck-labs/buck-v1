// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Minimal interfaces for autonomous state queries
interface IBuckToken {
    function totalSupply() external view returns (uint256);
}

interface IOracleAdapter {
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
    function isHealthy(uint256 maxStale) external view returns (bool);
    // Allows PolicyManager to toggle strict mode based on CR for on-chain automation
    function setStrictMode(bool enabled) external;
}

interface ICollateralAttestation {
    function getCollateralRatio() external view returns (uint256);
    function isAttestationStale() external view returns (bool);
    function timeSinceLastAttestation() external view returns (uint256);
    function healthyStaleness() external view returns (uint256);
    function stressedStaleness() external view returns (uint256);
}

/// @title PolicyManager
/// @notice Band state machine + policy surface for the primary market and reward flows.
// PolicyManager is the protocol's control plane: it tracks solvency, flips bands, and surfaces limits.
// Downstream contracts read these parameters autonomously; roles here are strictly configuration + telemetry.
// No funds live in this contract—just signals that keep LiquidityWindow, RewardsEngine, and oracles synced.
contract PolicyManager is
    Initializable,
    AccessControlUpgradeable,
    MulticallUpgradeable,
    UUPSUpgradeable
{
    // Role constants
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // Oracle staleness windows for CAP pricing
    // Healthy mode (CR >= 1.0): Oracle optional, relaxed staleness acceptable
    // Stressed mode (CR < 1.0): Oracle required for max(oracle, CR), must be fresh
    uint256 public constant HEALTHY_ORACLE_STALENESS = 72 hours; // CR >= 1.0: Oracle optional
    uint256 public constant STRESSED_ORACLE_STALENESS = 15 minutes; // CR < 1.0: Oracle critical

    enum Band { Green, Yellow, Red }

    enum CapType {
        MintAggregate,
        RefundAggregate
    }

    // Daily cap settings expressed in basis points of total supply.
    struct CapSettings {
        uint16 mintAggregateBps;
        uint16 refundAggregateBps;
    }

    // Band-specific configuration: spreads, fees, oracle thresholds, distribution haircut/skim, caps.
    struct BandConfig {
        uint16 halfSpreadBps;
        uint16 mintFeeBps;
        uint16 refundFeeBps;
        uint32 oracleStaleSeconds;
        uint16 deviationThresholdBps;
        uint16 alphaBps;
        uint16 floorBps;
        uint16 distributionSkimBps; // Skim fee on coupon USDC before distribution (routes to Treasury/Reserve)
        CapSettings caps;
    }

    // Cached aggregate caps computed from system snapshot + band config.
    struct DerivedCaps {
        uint256 mintAggregateBps;
        uint256 refundAggregateBps;
        uint64 computedAt;
    }

    // Reserve ratio thresholds that control band transitions and emergency triggers.
    struct ReserveThresholds {
        uint16 warnBps; // 5% - YELLOW threshold (R/L < warnBps triggers YELLOW)
        uint16 floorBps; // 2.5% - RED threshold (R/L < floorBps triggers RED)
        uint16 emergencyBps; // 1% - EMERGENCY threshold (R/L <= emergencyBps triggers EMERGENCY)
    }

    /// @notice Gas optimization: Batched parameters for mint operations
    /// @dev Reduces external calls from 4 to 1, saving ~15-20k gas per mint
    struct MintParameters {
        uint256 capPrice; // CAP price in 18 decimals
        uint16 halfSpreadBps; // Half-spread in basis points
        uint16 mintFeeBps; // Mint fee in basis points
        uint16 refundFeeBps; // Refund fee in basis points
        bool mintCapPassed; // Whether user is under mint cap
        Band currentBand; // Current band status
    }

    // Rolling counters used for daily cap enforcement.
    // Tracks actual token amounts (not BPS) for precise cap accounting without rounding issues.
    struct RollingCounter {
        uint64 capCycle;      // daily cap cycle id (resets at EST midnight)
        uint256 amountTokens; // tokens consumed this cycle
        uint256 capTokens;    // frozen token cap for this cycle
    }

    // Snapshot of on-chain health metrics used for autonomous decision making.
    struct SystemSnapshot {
        uint16 reserveRatioBps;
        uint16 equityBufferBps;
        uint32 oracleStaleSeconds;
        uint256 totalSupply;
        uint256 navPerToken;
        uint256 reserveBalance;
        uint256 collateralRatio; // CR from CollateralAttestation (18 decimals)
    }

    // Contract references for autonomous state queries
    // These are the live addresses we read when computing bands/caps.
    address public buckToken;
    address public liquidityReserve;
    address public oracleAdapter;
    address public usdc;
    address public collateralAttestation;

    // Emergency override mechanism
    // Lets governance freeze in a manual snapshot when sensors misbehave.
    bool private _snapshotOverrideActive;
    uint256 private _lastOverrideTimestamp;

    // Core band + configuration state.
    Band private _band;
    ReserveThresholds private _reserveThresholds;
    mapping(Band => BandConfig) private _bandConfigs;

    // Rolling cap trackers keyed by daily cap cycle.
    RollingCounter private _mintAggregate;
    RollingCounter private _refundAggregate;

    uint64 public lastBandEvaluation;
    SystemSnapshot private _lastSnapshot;
    DerivedCaps private _derivedCaps;

    // DEX swap fees (static, governance-adjustable)
    uint16 public buyFeeBps;
    uint16 public sellFeeBps;

    // Per-transaction size limit (percentage of remaining capacity)
    // Prevents single large transaction from draining all liquidity
    // Default: 50% of remaining capacity, range: 1-100%
    uint16 public maxSingleTransactionPct;

    // Collateral deficit tracking for monitoring events
    bool private _isInDeficit;

    // Hours to add to UTC to align cap cycle reset to local midnight (19 = EST, 20 = EDT)
    uint32 public cycleOffsetHours;

    event BandChanged(Band indexed previousBand, Band indexed newBand, string reason);
    event BandConfigUpdated(
        Band indexed band,
        uint16 halfSpreadBps,
        uint16 mintFeeBps,
        uint16 refundFeeBps,
        uint32 oracleStaleSeconds,
        uint16 deviationThresholdBps,
        uint16 alphaBps,
        uint16 floorBps,
        uint16 distributionSkimBps,
        uint16 mintAggregateBps,
        uint16 refundAggregateBps,
        uint64 eta
    );
    event ReserveThresholdsUpdated(
        uint16 targetBps, uint16 warnBps, uint16 floorBps, uint16 emergencyBps, uint64 eta
    );
    event DexFeesUpdated(
        uint16 oldBuyFeeBps,
        uint16 newBuyFeeBps,
        uint16 oldSellFeeBps,
        uint16 newSellFeeBps,
        uint64 eta
    );
    event MaxSingleTransactionPctUpdated(uint16 oldPct, uint16 newPct);
    event CycleOffsetUpdated(uint32 oldHours, uint32 newHours);
    event CapWindowReset(address indexed user, CapType capType);
    event DailyLimitRecorded(CapType capType, uint256 newAmountTokens);
    event SnapshotRecorded(
        uint16 reserveRatioBps,
        uint16 equityBufferBps,
        uint16 oracleDeviationBps,
        uint32 oracleStaleSeconds,
        uint256 totalSupply,
        uint256 navPerToken,
        uint256 reserveBalance,
        uint16 activeLiquidityStewards,
        uint64 timestamp
    );
    event DerivedCapsUpdated(
        uint256 mintAggregateBps, uint256 refundAggregateBps, uint64 timestamp
    );
    event ContractReferencesUpdated(
        address indexed buckToken,
        address indexed liquidityReserve,
        address indexed oracleAdapter,
        address usdc
    );
    event CollateralAttestationUpdated(address indexed collateralAttestation);
    event SnapshotOverrideActivated(
        uint16 reserveRatioBps,
        uint256 totalSupply,
        uint256 navPerToken,
        uint256 reserveBalance,
        uint256 timestamp
    );
    event SnapshotOverrideCleared(uint256 timestamp);
    event CollateralDeficit(uint256 collateralRatio, uint256 deficit);
    event RecollateralizationComplete(uint256 collateralRatio);
    event StrictModeChangeRequired(bool shouldBeStrict, uint256 collateralRatio, string reason);

    error InvalidConfig();
    /// @notice Cap enforcement reverted because requested amount exceeds remaining capacity (token units).
    error CapExceeded(CapType capType, uint256 requestedTokens, uint256 remainingTokens);
    /// @notice Per-transaction size limit exceeded (token units).
    error TransactionTooLarge(uint256 requestedTokens, uint256 maxAllowedTokens);
    error OverrideCooldownActive(uint256 remainingTime);
    error StaleCollateralAttestation(uint256 timeSinceUpdate, uint256 maxStaleness);
    error InvalidCycleOffset();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Bootstraps default band configs, thresholds, and grants admin/operator roles.
    // Called once via proxy; downstream modules query these values immediately after deployment.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidConfig();

        // Initialize parent contracts
        __AccessControl_init();
        __Multicall_init();
        __UUPSUpgradeable_init();

        // Grant roles
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        // Initialize PolicyManager state (band defaults to Green as first enum value)
        CapSettings memory greenCaps = CapSettings({
            mintAggregateBps: 0, // UNLIMITED - mints improve reserve ratio
            refundAggregateBps: 500 // 5.0% daily refund cap
        });
        CapSettings memory yellowCaps = CapSettings({
            mintAggregateBps: 0, // UNLIMITED - mints improve reserve ratio
            refundAggregateBps: 250 // 2.5% daily refund cap
        });
        CapSettings memory redCaps = CapSettings({
            mintAggregateBps: 0, // UNLIMITED - mints improve reserve ratio
            refundAggregateBps: 100 // 1.0% daily refund cap (protective)
        });

        _bandConfigs[Band.Green] = BandConfig({
            halfSpreadBps: 10, // 0.1% spread in each direction
            mintFeeBps: 5, // 0.05% mint fee
            refundFeeBps: 10, // 0.1% refund fee
            oracleStaleSeconds: 600,
            deviationThresholdBps: 25,
            alphaBps: 500, // 5.0% daily refund cap (refunds only, mints unlimited)
            floorBps: 100, // 1% emergency floor across all bands
            distributionSkimBps: 1000, // 10% skim
            caps: greenCaps
        });

        _bandConfigs[Band.Yellow] = BandConfig({
            halfSpreadBps: 15, // 0.15% spread in each direction
            mintFeeBps: 10, // 0.1% mint fee
            refundFeeBps: 15, // 0.15% refund fee
            oracleStaleSeconds: 900,
            deviationThresholdBps: 50,
            alphaBps: 250, // 2.5% daily refund cap (refunds only, mints unlimited)
            floorBps: 100, // 1% emergency floor across all bands
            distributionSkimBps: 1000, // 10% skim
            caps: yellowCaps
        });

        _bandConfigs[Band.Red] = BandConfig({
            halfSpreadBps: 20, // 0.2% spread in each direction
            mintFeeBps: 15, // 0.15% mint fee
            refundFeeBps: 20, // 0.2% refund fee
            oracleStaleSeconds: 1_800,
            deviationThresholdBps: 100,
            alphaBps: 100, // 1.0% daily refund cap (refunds only, mints unlimited)
            floorBps: 100, // 1% emergency floor across all bands
            distributionSkimBps: 1000, // 10% skim
            caps: redCaps
        });
        _reserveThresholds = ReserveThresholds({
            warnBps: 500, // 5% - GREEN/YELLOW boundary (R/L < 5% → YELLOW)
            floorBps: 250, // 2.5% - YELLOW/RED boundary (R/L < 2.5% → RED)
            emergencyBps: 100 // 1% - RED/EMERGENCY boundary (R/L <= 1% → EMERGENCY)
        });

        // Default per-transaction size limit: 50% of remaining capacity
        // Prevents single whale from draining all daily liquidity in one transaction
        maxSingleTransactionPct = 50;

        // Default cap cycle alignment to EST (UTC-5 = add 19 hours)
        cycleOffsetHours = 19;
    }

    // ========= Access control =========
    // Uses OpenZeppelin AccessControl with ADMIN_ROLE and OPERATOR_ROLE

    // ========= Configuration =========

    // Update spreads/fees/caps for a specific band.
    function setBandConfig(Band band, BandConfig calldata config) external onlyRole(ADMIN_ROLE) {
        _validateBandConfig(config);
        _bandConfigs[band] = config;
        emit BandConfigUpdated(
            band,
            config.halfSpreadBps,
            config.mintFeeBps,
            config.refundFeeBps,
            config.oracleStaleSeconds,
            config.deviationThresholdBps,
            config.alphaBps,
            config.floorBps,
            config.distributionSkimBps,
            config.caps.mintAggregateBps,
            config.caps.refundAggregateBps,
            uint64(block.timestamp)
        );
    }

    // Adjust reserve ratio thresholds that drive band transitions.
    function setReserveThresholds(ReserveThresholds calldata thresholds)
        external
        onlyRole(ADMIN_ROLE)
    {
        _validateReserveThresholds(thresholds);
        _reserveThresholds = thresholds;
        emit ReserveThresholdsUpdated(
            thresholds.warnBps,  // Use warnBps as the first parameter for compatibility
            thresholds.warnBps,
            thresholds.floorBps,
            thresholds.emergencyBps,
            uint64(block.timestamp)
        );
    }

    /// @notice Configure contract references for autonomous state queries
    /// @dev These addresses enable PolicyManager to read on-chain state directly
    // Wires contract references so PolicyManager can read balances/ratios without keepers.
    function setContractReferences(
        address buckToken_,
        address liquidityReserve_,
        address oracleAdapter_,
        address usdc_
    ) external onlyRole(ADMIN_ROLE) {
        if (
            buckToken_ == address(0) || liquidityReserve_ == address(0)
                || oracleAdapter_ == address(0) || usdc_ == address(0)
        ) {
            revert InvalidConfig();
        }
        buckToken = buckToken_;
        liquidityReserve = liquidityReserve_;
        oracleAdapter = oracleAdapter_;
        usdc = usdc_;
        emit ContractReferencesUpdated(buckToken_, liquidityReserve_, oracleAdapter_, usdc_);
    }

    /// @notice Set CollateralAttestation contract reference
    /// @dev Enables PolicyManager to read Collateral Ratio for CAP pricing
    // Enables CAP pricing + band health checks using the attested collateral ratio.
    function setCollateralAttestation(address collateralAttestation_)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (collateralAttestation_ == address(0)) revert InvalidConfig();
        collateralAttestation = collateralAttestation_;
        emit CollateralAttestationUpdated(collateralAttestation_);
    }

    /// @notice Emergency override: manually set system snapshot (disables autonomous queries)
    /// @dev Use only in emergencies (oracle failure, contract bugs, etc.)
    /// @dev Enforces 72-hour cooldown between overrides to prevent abuse
    /// @param snapshot Manual snapshot to use instead of querying on-chain state
    // Emergency manual snapshot when sensors fail; rate-limited to prevent abuse.
    function overrideSystemSnapshot(SystemSnapshot calldata snapshot)
        external
        onlyRole(ADMIN_ROLE)
    {
        // Enforce cooldown to prevent rapid manipulation
        uint256 cooldown = 72 hours;
        if (block.timestamp < _lastOverrideTimestamp + cooldown) {
            revert OverrideCooldownActive((_lastOverrideTimestamp + cooldown) - block.timestamp);
        }

        _validateSnapshot(snapshot);
        _lastSnapshot = snapshot;
        _snapshotOverrideActive = true;
        _lastOverrideTimestamp = block.timestamp;

        emit SnapshotOverrideActivated(
            snapshot.reserveRatioBps,
            snapshot.totalSupply,
            snapshot.navPerToken,
            snapshot.reserveBalance,
            block.timestamp
        );
    }

    /// @notice Clear emergency override and return to autonomous operation
    /// @dev Restores normal behavior where PolicyManager queries on-chain state
    // Restores autonomous operation after an emergency snapshot.
    function clearSnapshotOverride() external onlyRole(ADMIN_ROLE) {
        _snapshotOverrideActive = false;
        emit SnapshotOverrideCleared(block.timestamp);
    }

    // Update static DEX buy/sell fees emitted to BUCK token for swap calculations.
    function setDexFees(uint16 newBuyFeeBps, uint16 newSellFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newBuyFeeBps > BPS_DENOMINATOR || newSellFeeBps > BPS_DENOMINATOR) {
            revert InvalidConfig();
        }
        uint16 oldBuyFeeBps = buyFeeBps;
        uint16 oldSellFeeBps = sellFeeBps;
        buyFeeBps = newBuyFeeBps;
        sellFeeBps = newSellFeeBps;
        emit DexFeesUpdated(
            oldBuyFeeBps, newBuyFeeBps, oldSellFeeBps, newSellFeeBps, uint64(block.timestamp)
        );
    }

    // Set maximum single transaction size as percentage of remaining daily capacity.
    // Prevents whale from draining all liquidity in one transaction.
    // Range: 1-100 (1% to 100% of remaining capacity)
    function setMaxSingleTransactionPct(uint16 newPct) external onlyRole(ADMIN_ROLE) {
        if (newPct == 0 || newPct > 100) {
            revert InvalidConfig();
        }
        uint16 oldPct = maxSingleTransactionPct;
        maxSingleTransactionPct = newPct;
        emit MaxSingleTransactionPctUpdated(oldPct, newPct);
    }

    /// @notice Update cycle offset hours to align cap cycles to local midnight (handles DST)
    /// @dev 19 = EST (UTC-5), 20 = EDT (UTC-4); call twice a year to toggle
    function setCycleOffsetHours(uint32 hours_) external onlyRole(ADMIN_ROLE) {
        if (hours_ > 23) {
            revert InvalidCycleOffset();
        }
        uint32 oldHours = cycleOffsetHours;
        cycleOffsetHours = hours_;
        emit CycleOffsetUpdated(oldHours, hours_);
    }

    // Helper for frontends/keepers to check if an address holds OPERATOR_ROLE.
    function isOperator(address operator) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, operator);
    }

    // ========= Band evaluation =========

    // Returns the currently active liquidity band.
    function currentBand() external view returns (Band) {
        return _band;
    }

    /// @notice Autonomous band refresh - recalculates band from live on-chain state
    /// @dev Call this at the start of each transaction for accurate, gas-efficient band updates
    /// @dev Uses cached _band for subsequent reads within the same transaction
    /// @return newBand The updated band (GREEN/YELLOW/RED/EMERGENCY)
    function refreshBand() external returns (Band newBand) {
        // Query live on-chain state (totalSupply, reserve balance, oracle price)
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();

        // Skip band evaluation if system is uninitialized (zero supply = no liabilities yet)
        // Keep current band during bootstrap
        if (snapshot.totalSupply == 0) {
            return _band;
        }

        // Evaluate band from current reserve ratio
        (Band evaluated, string memory reason) = _evaluateBand(snapshot);

        // Update cached band if it changed
        if (evaluated != _band) {
            Band previous = _band;
            _band = evaluated;
            lastBandEvaluation = uint64(block.timestamp);
            emit BandChanged(previous, evaluated, reason);
        }

        // Refresh derived caps so view functions return current values
        _refreshDerivedCaps(snapshot);

        return _band;
    }

    // Expose stored config for a band (used by dashboards + tests).
    function getBandConfig(Band band) external view returns (BandConfig memory) {
        return _bandConfigs[band];
    }

    /// @notice Get the floor basis points for a specific band
    /// @dev Dedicated getter to avoid ABI struct mismatch with external callers
    /// @param band The band to query (Green, Yellow, Red)
    /// @return floorBps Floor in basis points for reserve protection
    function getBandFloorBps(Band band) external view returns (uint16) {
        return _bandConfigs[band].floorBps;
    }

    // Convenience getter for reserve thresholds.
    function getReserveThresholds() external view returns (ReserveThresholds memory) {
        return _reserveThresholds;
    }

    // Fetches mint/refund fees from the active band config.
    function getFees() external view returns (uint16 mintFeeBps, uint16 refundFeeBps) {
        BandConfig memory config = _resolveActiveConfig();
        return (config.mintFeeBps, config.refundFeeBps);
    }

    // Returns the global DEX fee settings.
    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee) {
        return (buyFeeBps, sellFeeBps);
    }

    // Grab the half-spread BPS for the active band.
    function getHalfSpread() external view returns (uint16) {
        BandConfig memory config = _resolveActiveConfig();
        return config.halfSpreadBps;
    }

    // Distribution skim BPS (coupon skim to treasury/reserve).
    function getDistributionSkimBps() external view returns (uint16) {
        BandConfig memory config = _resolveActiveConfig();
        return config.distributionSkimBps;
    }

    // Raw cap settings for the current band.
    function getCapsBps() external view returns (CapSettings memory) {
        BandConfig memory config = _resolveActiveConfig();
        return config.caps;
    }

    // Cached caps derived from latest snapshot (aggregate BPS limits).
    function getDerivedCaps() external view returns (DerivedCaps memory) {
        return _derivedCaps;
    }

    /// @notice Get CAP (Collateral-Aware Peg) price for BUCK
    /// @dev CAP pricing: BUCK = $1.00 when CR ≥ 1, else max(oraclePrice, CR)
    /// @return price BUCK price in USD (18 decimals)
    // Collateral-aware price: $1 when healthy, else max(oracle price, collateral ratio).
    // Falls back to oracle-only when attestation isn't configured yet.
    function getCAPPrice() external view returns (uint256 price) {
        // If collateralAttestation not configured, fall back to oracle price (backward compatibility)
        // This ensures existing tests continue to work during the transition period
        if (collateralAttestation == address(0)) {
            // Try to use oracle price for backward compatibility with existing tests
            if (oracleAdapter != address(0)) {
                (uint256 fallbackPrice,) = IOracleAdapter(oracleAdapter).latestPrice();
                return fallbackPrice; // Return oracle price directly (pre-CAP behavior)
            }
            return 1e18; // $1.00 - ultimate fallback if neither is configured
        }

        // BOOTSTRAP MODE: Check if any attestation has been published yet
        // timeSinceLastAttestation() returns max uint when attestationMeasurementTime == 0
        // This allows initial mint operations before the first attestation is published
        uint256 timeSinceUpdate =
            ICollateralAttestation(collateralAttestation).timeSinceLastAttestation();

        if (timeSinceUpdate == type(uint256).max) {
            // No attestation published yet - assume CR = 1.0 for bootstrap
            // This is safe because:
            // 1. Fresh deployment has no users (no exploit surface)
            // 2. Only admin can mint initially (access check required)
            // 3. Conservative assumption (assumes healthy until proven otherwise)
            // 4. Automatically transitions to normal checks after first attestation
            return 1e18; // $1.00 - bootstrap default
        }

        // NORMAL MODE: Validate attestation freshness before using CR for pricing
        // Per architecture doc: "validate attestation freshness before critical operations"
        // Prevents users from trading at incorrect prices based on stale collateral data
        if (ICollateralAttestation(collateralAttestation).isAttestationStale()) {
            // Gather diagnostic info for error message
            uint256 currentCR = ICollateralAttestation(collateralAttestation).getCollateralRatio();
            // Determine max staleness based on CR (healthy: 72hr, stressed: 15min)
            uint256 maxStaleness = currentCR >= 1e18
                ? ICollateralAttestation(collateralAttestation).healthyStaleness()
                : ICollateralAttestation(collateralAttestation).stressedStaleness();
            revert StaleCollateralAttestation(timeSinceUpdate, maxStaleness);
        }

        // Get Collateral Ratio from CollateralAttestation
        uint256 cr = ICollateralAttestation(collateralAttestation).getCollateralRatio();

        // If CR ≥ 1.0, BUCK maintains $1.00 peg
        if (cr >= 1e18) {
            return 1e18; // $1.00
        }

        // If CR < 1.0, BUCK = max(oraclePrice, CR), but capped below $1.00
        // Oracle price is already in 18 decimals (1e18 = $1.00)
        // Use the higher value to give users the better price when undercollateralized
        // But must ensure CAP < $1.00 when CR < 1.0 (invariant)

        // Pass staleness window to oracle health check based on CR state
        // Stressed mode (CR < 1.0): require 15min freshness
        // Healthy mode (CR >= 1.0): allow 72hr staleness
        uint256 rawCAP = cr; // Default to CR

        if (oracleAdapter != address(0)) {
            // Get oracle price and timestamp directly
            // Don't rely on isHealthy() which can return true when strictMode is off
            (uint256 oraclePrice, uint256 updatedAt) = IOracleAdapter(oracleAdapter).latestPrice();

            // At this point cr < 1e18 (we returned early above if cr >= 1e18)
            // Stressed mode: enforce freshness DIRECTLY, independent of strictMode
            // This prevents stale oracle prices from being used during undercollateralization
            bool isFresh = updatedAt != 0 && block.timestamp <= updatedAt + STRESSED_ORACLE_STALENESS;
            if (isFresh && oraclePrice > 0) {
                rawCAP = Math.max(oraclePrice, cr);
            }
            // else: stale oracle, use CR only (already set above)
        }

        // If oracle or CR somehow >= $1.00, cap at $0.999999... (1e18 - 1)
        // This maintains the invariant: CAP < $1.00 when CR < 1.0
        return rawCAP >= 1e18 ? 1e18 - 1 : rawCAP;
    }

    /// @notice Check if collateral attestation is stale
    /// @dev Returns false if collateralAttestation is not configured (no staleness check)
    /// @return stale True if attestation is stale and should not be trusted
    // Indicates whether the collateral attestation data is stale.
    // Returns false when attestation isn't wired yet for backwards compatibility.
    function isAttestationStale() external view returns (bool stale) {
        if (collateralAttestation == address(0)) {
            return false; // No attestation configured, no staleness
        }
        return ICollateralAttestation(collateralAttestation).isAttestationStale();
    }

    /// @notice Sync oracle strict mode with current CR state
    /// @dev Automatically toggles oracle between strict/relaxed mode based on CR:
    /// @dev - CR ≥ 1.0: Oracle disabled (strict mode OFF) - not needed for CAP pricing
    /// @dev - CR < 1.0: Oracle enabled (strict mode ON) - required for CAP pricing formula
    /// @dev Can be called by anyone (keeper bot, DAO, or manual)
    /// @dev Emits CollateralDeficit when entering undercollateralization (CR crosses below 1.0)
    /// @dev Emits RecollateralizationComplete when exiting undercollateralization (CR crosses above 1.0)
    // Permissionless helper that toggles oracle strict mode based on CR >=/< 1.
    // Keeps OracleAdapter freshness enforcement in sync with solvency state.
    function syncOracleStrictMode() external {
        // Skip if collateralAttestation or oracle not configured
        if (collateralAttestation == address(0) || oracleAdapter == address(0)) {
            return;
        }

        // Bootstrap guard: if no attestation has been published yet, skip syncing
        // timeSinceLastAttestation returns max uint when attestationMeasurementTime == 0
        uint256 timeSinceUpdate =
            ICollateralAttestation(collateralAttestation).timeSinceLastAttestation();
        if (timeSinceUpdate == type(uint256).max) {
            return;
        }

        // Oracle guard: if oracle has no usable price yet, skip syncing
        (uint256 probePrice, uint256 probeUpdatedAt) = IOracleAdapter(oracleAdapter).latestPrice();
        if (probePrice == 0 || probeUpdatedAt == 0) {
            return;
        }

        // Get current CR from CollateralAttestation
        uint256 cr = ICollateralAttestation(collateralAttestation).getCollateralRatio();

        // Determine if oracle strict mode should be enabled based on CR threshold
        // CR >= 1.0 (1e18): Healthy, oracle not needed → strict mode OFF
        // CR < 1.0: Stressed, oracle needed for pricing → strict mode ON
        bool shouldBeStrict = cr < 1e18;

        // Toggle strict mode on-chain for immediate effect
        // Ensures oracle freshness enforcement happens instantly when CR crosses 1.0
        IOracleAdapter(oracleAdapter).setStrictMode(shouldBeStrict);

        // Still emit event for monitoring/logging
        emit StrictModeChangeRequired(
            shouldBeStrict,
            cr,
            shouldBeStrict ? "CR < 1.0: Strict mode enabled" : "CR >= 1.0: Strict mode disabled"
        );

        // Emit monitoring events when CR crosses 1.0 threshold
        if (shouldBeStrict && !_isInDeficit) {
            // Entering undercollateralization: CR just crossed below 1.0
            uint256 deficit = 1e18 - cr; // How much below 1.0 we are
            emit CollateralDeficit(cr, deficit);
            _isInDeficit = true;
        } else if (!shouldBeStrict && _isInDeficit) {
            // Exiting undercollateralization: CR just crossed back above 1.0
            emit RecollateralizationComplete(cr);
            _isInDeficit = false;
        } else if (shouldBeStrict) {
            // Already in deficit, emit continuous monitoring event
            uint256 deficit = 1e18 - cr;
            emit CollateralDeficit(cr, deficit);
        }
    }

    // Signals when reserve ratio has fallen into emergency territory (for UI/governance).
    // Use the current on-chain snapshot (or override when active) instead of the cached value.
    function requiresGovernanceVote() external view returns (bool) {
        SystemSnapshot memory snap = _computeCurrentSnapshot();
        return snap.reserveRatioBps <= _reserveThresholds.emergencyBps;
    }

    /// @notice LEGACY: Manual snapshot reporting (deprecated - use autonomous mode instead)
    /// @dev This function is kept for backward compatibility with existing tests and deployments
    /// @dev NEW DEPLOYMENTS: Configure contract references with setContractReferences() instead
    /// @dev PolicyManager will then query on-chain state automatically (no keeper needed)
    /// @dev Only use this function if:
    ///      1. Contract references are not yet configured (gradual migration)
    ///      2. You need to test legacy behavior
    ///      3. Emergency override is active (use overrideSystemSnapshot instead)
    /// @param snapshot System state to record (will be stored and used if autonomous mode disabled)
    /// @return newBand The current band after evaluation
    // Legacy manual snapshot entry, retained for backwards compatibility/testing.
    function reportSystemSnapshot(SystemSnapshot calldata snapshot)
        external
        onlyRole(ADMIN_ROLE)
        returns (Band newBand)
    {
        _validateSnapshot(snapshot);

        _lastSnapshot = snapshot;
        lastBandEvaluation = uint64(block.timestamp);
        emit SnapshotRecorded(
            snapshot.reserveRatioBps,
            snapshot.equityBufferBps,
            0,  // oracleDeviationBps placeholder for event compatibility
            snapshot.oracleStaleSeconds,
            snapshot.totalSupply,
            snapshot.navPerToken,
            snapshot.reserveBalance,
            0,  // activeLiquidityStewards placeholder for event compatibility
            lastBandEvaluation
        );

        // Instant band transitions - no hysteresis, pure R/L logic
        (Band evaluated, string memory reason) = _evaluateBand(snapshot);

        if (evaluated != _band) {
            Band previous = _band;
            _band = evaluated;
            emit BandChanged(previous, evaluated, reason);
        }
        _refreshDerivedCaps(snapshot);
        return _band;
    }

    // Returns whatever snapshot the system is currently using (override or computed).
    function getLastSnapshot() external view returns (SystemSnapshot memory) {
        return _lastSnapshot;
    }

    /// @notice Compute current system state by querying on-chain contracts
    /// @dev This is the KEY function that enables autonomous operation
    /// @return snapshot Current system state derived from on-chain data
    // Pulls live balances, supply, and oracle data; falls back to override when active.
    function _computeCurrentSnapshot() internal view returns (SystemSnapshot memory snapshot) {
        // If emergency override is active, use manual snapshot
        if (_snapshotOverrideActive) {
            return _lastSnapshot;
        }

        // If contract references aren't configured yet, fall back to last snapshot
        // This allows gradual migration and backward compatibility with tests
        if (
            buckToken == address(0) || liquidityReserve == address(0) || oracleAdapter == address(0)
                || usdc == address(0)
        ) {
            return _lastSnapshot;
        }

        // Query on-chain state directly (NO TRUST REQUIRED)
        uint256 totalSupply = IBuckToken(buckToken).totalSupply();
        // Scale USDC balance from 6 decimals to 18 decimals for compatibility with L (liabilities)
        // This ensures accurate reserve ratio and floor calculations
        uint256 reserveBalance = IERC20(usdc).balanceOf(liquidityReserve) * 1e12;
        (uint256 navPerToken, uint256 oracleUpdatedAt) = IOracleAdapter(oracleAdapter).latestPrice();

        // Calculate L (total liability at $1 notional per token)
        // Bands/caps use $1 assumption for conservative risk management during depegs
        // CAP pricing (via CollateralAttestation) handles actual token valuation separately
        uint256 L = totalSupply;

        // Calculate R/L (reserve ratio)
        uint256 reserveRatioCalc = L == 0 ? 0 : Math.mulDiv(reserveBalance, BPS_DENOMINATOR, L);
        if (reserveRatioCalc > BPS_DENOMINATOR) {
            reserveRatioCalc = BPS_DENOMINATOR; // clamp to 100% to avoid uint16 wrap
        }
        uint16 reserveRatioBps = uint16(reserveRatioCalc);

        // Calculate B/L (equity buffer above floor)
        uint256 floorAmount = Math.mulDiv(L, _reserveThresholds.floorBps, BPS_DENOMINATOR);
        uint256 buffer = reserveBalance > floorAmount ? reserveBalance - floorAmount : 0;
        uint256 equityBufferCalc = L == 0 ? 0 : Math.mulDiv(buffer, BPS_DENOMINATOR, L);
        if (equityBufferCalc > BPS_DENOMINATOR) {
            equityBufferCalc = BPS_DENOMINATOR; // clamp to 100% to avoid uint16 wrap
        }
        uint16 equityBufferBps = uint16(equityBufferCalc);

        // Calculate oracle staleness using actual timestamp (more accurate than block estimation)
        uint32 oracleStaleSeconds = oracleUpdatedAt == 0 ? 0 : uint32(block.timestamp - oracleUpdatedAt);

        // Query Collateral Ratio from CollateralAttestation (if configured)
        uint256 collateralRatio = 0;
        if (collateralAttestation != address(0)) {
            collateralRatio = ICollateralAttestation(collateralAttestation).getCollateralRatio();
        }

        return SystemSnapshot({
            reserveRatioBps: reserveRatioBps,
            equityBufferBps: equityBufferBps,
            oracleStaleSeconds: oracleStaleSeconds,
            totalSupply: totalSupply,
            navPerToken: navPerToken,
            reserveBalance: reserveBalance,
            collateralRatio: collateralRatio
        });
    }

    /// @notice Compute refund cap from current snapshot (view-only, no storage writes)
    /// @dev Used by checkRefundCap() for real-time cap evaluation
    // Calculates aggregate refund capacity using the same approach as mint cap.
    function _computeRefundCap(SystemSnapshot memory snapshot) internal view returns (uint256) {
        BandConfig memory config = _resolveActiveConfig();
        return _deriveCaps(snapshot, config, false);
    }

    // ========= Cap bookkeeping =========

    // External view used by LiquidityWindow to ensure a mint won't exceed caps.
    // Now accepts actual token amounts (not BPS) for precise cap tracking without rounding issues.
    function checkMintCap(uint256 amountTokens) external view returns (bool) {
        // AUTONOMOUS OPERATION: Compute caps from CURRENT on-chain state
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        BandConfig memory config = _resolveActiveConfig();

        // Bootstrap: when supply is zero, allow mints (cap is undefined but safe as no liabilities yet)
        if (snapshot.totalSupply == 0) {
            return true;
        }

        // UNLIMITED MINTS: Production config has mintAggregateBps = 0 (unlimited)
        // Skip all cap checks for unlimited mints to allow 10x+ market cap growth in a day
        if (config.caps.mintAggregateBps == 0) {
            return true;
        }

        // Convert configured BPS cap to absolute token cap using current supply
        // capTokens = totalSupply * mintAggregateBps / BPS_DENOMINATOR
        uint256 mintCapTokens = Math.mulDiv(snapshot.totalSupply, config.caps.mintAggregateBps, BPS_DENOMINATOR);

        uint64 capCycle = _currentCapCycle();
        uint256 remainingTokens = _remainingCapacityTokens(mintCapTokens, _mintAggregate, capCycle);

        if (amountTokens > remainingTokens) {
            revert CapExceeded(CapType.MintAggregate, amountTokens, remainingTokens);
        }

        return true;
    }

    // Same as checkMintCap but for refunds.
    // Now accepts actual token amounts (not BPS) for precise cap tracking without rounding issues.
    function checkRefundCap(uint256 amountTokens) external view returns (bool) {
        // AUTONOMOUS OPERATION: Compute caps from CURRENT on-chain state
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        // Bootstrap: when supply is zero, allow refunds (nothing to cap)
        if (snapshot.totalSupply == 0) {
            return true;
        }
        uint256 refundAggregateBps = _computeRefundCap(snapshot);

        // Convert BPS cap to absolute token cap using current supply
        uint256 refundCapTokens = Math.mulDiv(snapshot.totalSupply, refundAggregateBps, BPS_DENOMINATOR);

        if (refundCapTokens == 0) {
            revert CapExceeded(CapType.RefundAggregate, amountTokens, 0);
        }

        uint64 capCycle = _currentCapCycle();

        uint256 remainingTokens = _remainingCapacityTokens(refundCapTokens, _refundAggregate, capCycle);
        if (amountTokens > remainingTokens) {
            revert CapExceeded(CapType.RefundAggregate, amountTokens, remainingTokens);
        }

        // Enforce per-transaction size limit (% of remaining capacity)
        // Prevents whale from draining all daily liquidity in single transaction
        uint256 maxSingleTxTokens = (remainingTokens * maxSingleTransactionPct) / 100;
        if (amountTokens > maxSingleTxTokens) {
            revert TransactionTooLarge(amountTokens, maxSingleTxTokens);
        }

        return true;
    }

    // Called by LiquidityWindow after a mint to update aggregate counters.
    // Now records actual token amounts for precise cap tracking.
    function recordMint(uint256 amountTokens) external onlyRole(OPERATOR_ROLE) {
        uint64 capCycle = _currentCapCycle();
        // Initialize frozen cap at first record in a new cycle (if capped)
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        BandConfig memory config = _resolveActiveConfig();

        if (_mintAggregate.capCycle != capCycle) {
            _mintAggregate.capCycle = capCycle;
            _mintAggregate.amountTokens = 0;
            if (config.caps.mintAggregateBps == 0) {
                _mintAggregate.capTokens = type(uint256).max; // unlimited
            } else {
                _mintAggregate.capTokens = Math.mulDiv(
                    snapshot.totalSupply, config.caps.mintAggregateBps, BPS_DENOMINATOR
                );
            }
            emit CapWindowReset(address(0), CapType.MintAggregate);
        }

        // Tally usage (enforcement happens in checkMintCap)
        uint256 newAmount = _mintAggregate.amountTokens + amountTokens;
        _mintAggregate.amountTokens = newAmount;
        emit DailyLimitRecorded(CapType.MintAggregate, newAmount);
    }

    // Mirror of recordMint for refunds.
    // Now records actual token amounts for precise cap tracking.
    function recordRefund(uint256 amountTokens) external onlyRole(OPERATOR_ROLE) {
        uint64 capCycle = _currentCapCycle();
        // Initialize frozen cap at first record in a new cycle (if capped)
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        BandConfig memory config = _resolveActiveConfig();

        if (_refundAggregate.capCycle != capCycle) {
            _refundAggregate.capCycle = capCycle;
            _refundAggregate.amountTokens = 0;
            uint256 refundAggregateBps = _deriveCaps(snapshot, config, false);
            if (refundAggregateBps == 0) {
                _refundAggregate.capTokens = type(uint256).max; // unlimited
            } else {
                _refundAggregate.capTokens = Math.mulDiv(
                    snapshot.totalSupply, refundAggregateBps, BPS_DENOMINATOR
                );
            }
            emit CapWindowReset(address(0), CapType.RefundAggregate);
        }

        uint256 newAmount = _refundAggregate.amountTokens + amountTokens;
        _refundAggregate.amountTokens = newAmount;
        emit DailyLimitRecorded(CapType.RefundAggregate, newAmount);
    }

    // Returns remaining aggregate mint/refund capacity in TOKENS (not BPS).
    // Computes token caps from current supply for precise tracking.
    function getAggregateRemainingCapacity()
        external
        view
        returns (uint256 mintAggregateRemainingTokens, uint256 refundAggregateRemainingTokens)
    {
        uint64 capCycle = _currentCapCycle();
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        BandConfig memory config = _resolveActiveConfig();

        // Mint: 0 BPS means unlimited, return max sentinel
        if (config.caps.mintAggregateBps == 0) {
            mintAggregateRemainingTokens = type(uint256).max;
        } else {
            uint256 mintCapTokens = Math.mulDiv(snapshot.totalSupply, config.caps.mintAggregateBps, BPS_DENOMINATOR);
            mintAggregateRemainingTokens = _remainingCapacityTokens(mintCapTokens, _mintAggregate, capCycle);
        }

        // Refund: use _computeRefundCap to match enforcement logic (includes floor/alpha)
        uint256 refundAggregateBps = _computeRefundCap(snapshot);
        uint256 refundCapTokens = Math.mulDiv(snapshot.totalSupply, refundAggregateBps, BPS_DENOMINATOR);
        refundAggregateRemainingTokens = _remainingCapacityTokens(refundCapTokens, _refundAggregate, capCycle);
    }

    /// @notice Gas optimization: Get all mint parameters in a single call
    /// @dev Batches getCAPPrice(), getHalfSpread(), getFees(), and checkMintCap()
    /// @dev Saves ~15-20k gas per mint by eliminating duplicate SLOADs
    /// @param amountTokens Amount in actual tokens (not BPS) for precise cap tracking
    /// @return params Struct containing all mint parameters
    function getMintParameters(uint256 amountTokens)
        external
        view
        returns (MintParameters memory params)
    {
        params.capPrice = this.getCAPPrice();
        params.currentBand = _band;
        BandConfig memory config = _bandConfigs[params.currentBand];

        params.halfSpreadBps = config.halfSpreadBps;
        params.mintFeeBps = config.mintFeeBps;
        params.refundFeeBps = config.refundFeeBps;

        // If amountTokens is 0, caller will check cap separately with actual amount
        // This allows batching price/fee queries without knowing final amount yet
        if (amountTokens == 0) {
            params.mintCapPassed = true; // Signal that cap check was skipped
            return params;
        }

        // UNLIMITED MINTS: Production config has mintAggregateBps = 0 (unlimited)
        // Skip all cap checks for unlimited mints
        if (config.caps.mintAggregateBps == 0) {
            params.mintCapPassed = true;
            return params;
        }

        // AUTONOMOUS OPERATION: Compute caps from CURRENT on-chain state
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();

        // Convert BPS cap to absolute token cap using current supply
        uint256 mintCapTokens = Math.mulDiv(snapshot.totalSupply, config.caps.mintAggregateBps, BPS_DENOMINATOR);

        uint64 capCycle = _currentCapCycle();
        uint256 remainingTokens = _remainingCapacityTokens(mintCapTokens, _mintAggregate, capCycle);

        // Check aggregate cap in tokens
        if (amountTokens > remainingTokens) {
            params.mintCapPassed = false;
            return params;
        }

        params.mintCapPassed = true;
    }

    /// @notice Gas optimization: Get all refund parameters in a single call
    /// @dev Batches getCAPPrice(), getHalfSpread(), getFees(), and checkRefundCap()
    /// @dev Saves ~15-20k gas per refund by eliminating duplicate SLOADs
    /// @dev Note: mintCapPassed field is reused for refundCapPassed (maintains struct compatibility)
    /// @param amountTokens Amount in actual tokens (not BPS) for precise cap tracking
    /// @return params Struct containing all refund parameters
    function getRefundParameters(uint256 amountTokens)
        external
        view
        returns (MintParameters memory params)
    {
        params.capPrice = this.getCAPPrice();
        params.currentBand = _band;
        BandConfig memory config = _bandConfigs[params.currentBand];

        params.halfSpreadBps = config.halfSpreadBps;
        params.mintFeeBps = config.mintFeeBps;
        params.refundFeeBps = config.refundFeeBps;

        // If amountTokens is 0, caller will check cap separately with actual amount
        // This allows batching price/fee queries without knowing final amount yet
        if (amountTokens == 0) {
            params.mintCapPassed = true; // Signal that cap check was skipped
            return params;
        }

        // AUTONOMOUS OPERATION: Compute caps from CURRENT on-chain state
        SystemSnapshot memory snapshot = _computeCurrentSnapshot();
        uint256 refundAggregateBps = _computeRefundCap(snapshot);

        // Convert BPS cap to absolute token cap using current supply
        uint256 refundCapTokens = Math.mulDiv(snapshot.totalSupply, refundAggregateBps, BPS_DENOMINATOR);

        if (refundCapTokens == 0) {
            params.mintCapPassed = false; // Reused for refundCapPassed
            return params;
        }

        uint64 capCycle = _currentCapCycle();
        uint256 remainingTokens = _remainingCapacityTokens(refundCapTokens, _refundAggregate, capCycle);

        // Check aggregate cap in tokens
        if (amountTokens > remainingTokens) {
            params.mintCapPassed = false; // Reused for refundCapPassed
            return params;
        }

        // Check per-transaction size limit in tokens
        uint256 maxSingleTxTokens = (remainingTokens * maxSingleTransactionPct) / 100;
        params.mintCapPassed = amountTokens <= maxSingleTxTokens; // Reused for refundCapPassed
    }

    // ========= Internal helpers =========

    // Sanity-check band config so spreads/fees stay within reasonable bounds.
    function _validateBandConfig(BandConfig calldata config) internal pure {
        if (config.halfSpreadBps > 5000) revert InvalidConfig();
        if (config.mintFeeBps > 1000 || config.refundFeeBps > 1000) revert InvalidConfig();
        if (config.alphaBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (config.floorBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (config.distributionSkimBps > 1000) revert InvalidConfig(); // Max 10% skim
        if (
            config.caps.mintAggregateBps > BPS_DENOMINATOR
                || config.caps.refundAggregateBps > BPS_DENOMINATOR
        ) revert InvalidConfig();
    }

    // Ensure thresholds are ordered from highest to lowest.
    function _validateReserveThresholds(ReserveThresholds calldata thresholds) internal pure {
        if (thresholds.emergencyBps > thresholds.floorBps) revert InvalidConfig();
        if (thresholds.floorBps > thresholds.warnBps) revert InvalidConfig();
        if (thresholds.warnBps > BPS_DENOMINATOR) revert InvalidConfig();
    }

    // Prevent obviously invalid manual snapshots from being accepted.
    function _validateSnapshot(SystemSnapshot calldata snapshot) internal pure {
        if (snapshot.reserveRatioBps > 10_000) revert InvalidConfig(); // Allow up to 100%
        if (snapshot.equityBufferBps > 5_000) revert InvalidConfig(); // Allow up to 50%
    }

    // Convenience helper to grab the current band's config struct.
    function _resolveActiveConfig() internal view returns (BandConfig memory active) {
        active = _bandConfigs[_band];
        return active;
    }

    // Core band evaluation: compare reserve ratio to thresholds and suggest a band.
    /// @notice Pure liquidity-based band evaluation - 24/7 operation, no oracle dependency
    /// @dev Simplified to R/L ratio only - instant transitions based on reserve thresholds
    function _evaluateBand(SystemSnapshot memory snapshot)
        internal
        view
        returns (Band, string memory)
    {
        // Band determination is pure R/L (reserve-to-liability ratio)
        // No market hours, no oracle health, no hysteresis - cyberpunk 24/7 markets

        // EMERGENCY threshold retained as governance signal via requiresGovernanceVote().
        // Operationally, treat <= emergency threshold as RED.
        if (snapshot.reserveRatioBps <= _reserveThresholds.emergencyBps) {
            return (Band.Red, "reserve-below-1-percent");
        }

        // RED: R/L < 2.5% - distributions blocked, highest fees
        if (snapshot.reserveRatioBps < _reserveThresholds.floorBps) {
            return (Band.Red, "reserve-below-2.5-percent");
        }

        // YELLOW: R/L < 5% - distributions allowed, elevated fees
        if (snapshot.reserveRatioBps < _reserveThresholds.warnBps) {
            return (Band.Yellow, "reserve-below-5-percent");
        }

        // GREEN: R/L >= 5% - healthy operation, standard fees
        return (Band.Green, "healthy");
    }

    // Recomputes derived caps anytime band or snapshot changes.
    function _refreshDerivedCaps(SystemSnapshot memory snapshot) internal {
        BandConfig memory config = _resolveActiveConfig();

        uint256 mintAggregateBps = _deriveCaps(snapshot, config, true);
        uint256 refundAggregateBps = _deriveCaps(snapshot, config, false);

        DerivedCaps memory caps = DerivedCaps({
            mintAggregateBps: mintAggregateBps,
            refundAggregateBps: refundAggregateBps,
            computedAt: uint64(block.timestamp)
        });

        _derivedCaps = caps;
        emit DerivedCapsUpdated(caps.mintAggregateBps, caps.refundAggregateBps, caps.computedAt);
    }

    // Derives aggregate mint/refund caps in dollars (BPS) based on band settings + snapshot.
    function _deriveCaps(SystemSnapshot memory snapshot, BandConfig memory config, bool isMint)
        internal
        pure
        returns (uint256 aggregateBps)
    {
        uint16 baseAggregate =
            isMint ? config.caps.mintAggregateBps : config.caps.refundAggregateBps;
        uint256 reserveBalance = snapshot.reserveBalance;
        uint256 navPerToken = snapshot.navPerToken;
        uint256 totalSupply = snapshot.totalSupply;

        uint256 L =
            totalSupply == 0 || navPerToken == 0 ? 0 : Math.mulDiv(totalSupply, navPerToken, 1e18);

        if (L == 0) {
            aggregateBps = baseAggregate != 0 ? baseAggregate : BPS_DENOMINATOR;
            if (aggregateBps > BPS_DENOMINATOR) {
                aggregateBps = BPS_DENOMINATOR;
            }
            return aggregateBps;
        }

        uint256 capAmount = 0;
        // Only apply alphaBps-based cap for REFUNDS, not mints (per architecture doc)
        if (!isMint) {
            // reserveBalance is already scaled to 18 decimals in _computeCurrentSnapshot()
            // L is also in 18 decimals (totalSupply * navPerToken / 1e18)
            uint256 floorAmount = Math.mulDiv(config.floorBps, L, BPS_DENOMINATOR);
            if (reserveBalance > floorAmount) {
                uint256 alphaAmount = Math.mulDiv(config.alphaBps, L, BPS_DENOMINATOR);
                uint256 available = reserveBalance - floorAmount;
                capAmount = alphaAmount < available ? alphaAmount : available;
            } else {
                // Hard stop refunds when reserves at/below floor
                // Don't allow baseAggregate fallback to override this protection
                return 0;
            }
        }

        if (capAmount != 0) {
            aggregateBps = Math.mulDiv(capAmount, BPS_DENOMINATOR, L);
        } else {
            aggregateBps = 0;
        }

        if (baseAggregate != 0) {
            // If baseAggregate is set, use the minimum of baseAggregate and aggregateBps
            if (aggregateBps == 0 || baseAggregate < aggregateBps) {
                aggregateBps = baseAggregate;
            }
        } else if (aggregateBps == 0) {
            // Both baseAggregate and aggregateBps are 0 = unlimited (for mints with no caps)
            aggregateBps = BPS_DENOMINATOR;
        }

        if (aggregateBps > BPS_DENOMINATOR) {
            aggregateBps = BPS_DENOMINATOR;
        }

        return aggregateBps;
    }

    // Returns remaining capacity in tokens for a rolling counter.
    // Now works with absolute token amounts instead of BPS for precise tracking.
    function _remainingCapacityTokens(uint256 capTokens, RollingCounter storage counter, uint64 cycle)
        internal
        view
        returns (uint256)
    {
        bool sameCycle = counter.capCycle == cycle;
        // Prefer frozen cap only when initialized this cycle (capTokens set)
        uint256 effectiveCap = sameCycle && counter.capTokens != 0 ? counter.capTokens : capTokens;
        if (effectiveCap == 0) return 0; // fail safe: no capacity when cap is zero
        uint256 used = sameCycle ? counter.amountTokens : 0;
        if (used >= effectiveCap) return 0;
        return effectiveCap - used;
    }

    // Daily cap cycle aligned to local midnight (19h = EST, 20h = EDT).
    // Adding hours shifts the day boundary from UTC midnight to local midnight.
    function _currentCapCycle() internal view returns (uint64) {
        return uint64((block.timestamp + uint256(cycleOffsetHours) * 1 hours) / 1 days);
    }

    // ========= UUPS Upgrade Authorization =========

    // UUPS upgrade gate—admin role only.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // ========= Storage Gap =========
    // Reserve storage slots for future upgrades
    uint256[52] private __gap;
}
