//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝
//
// POLICY MANAGER V2
// CONFIGURATION HUB
//
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for Buck token queries
interface IBuckV2 {
    function totalSupply() external view returns (uint256);
    function currentYieldMultiplier() external view returns (uint256);
}

/// @notice Minimal interface for OracleAdapter
interface IOracleAdapter {
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}

/// @notice Minimal interface for CollateralAttestation
interface ICollateralAttestationV2 {
    function totalAssets() external view returns (uint256);
    function getCollateralRatio() external view returns (uint256);
    function isAttestationStale() external view returns (bool);
}

/**
 * @title PolicyManagerV2
 * @notice Pricing and risk configuration for BUCK.
 *
 * @dev Computes CAP price, fee parameters, refund capacity, and the
 * ecosystem pause state. Admins manage configuration, and the
 * LiquidityWindow uses OPERATOR_ROLE to record refund usage.
 */
contract PolicyManagerV2 is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // -------------------------------------------------------------------------
    // Role Constants
    // -------------------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Storage - Contract References
    // -------------------------------------------------------------------------

    address public buck;
    address public liquidityReserve;
    address public oracleAdapter;
    address public usdc;
    address public collateralAttestation;

    // -------------------------------------------------------------------------
    // Storage - Reserved
    // -------------------------------------------------------------------------

    /// @dev Reserved slots. Do not use.
    uint256[20] private __v1_deprecated_gap;

    // -------------------------------------------------------------------------
    // Storage - Fees and Daily Cap
    // -------------------------------------------------------------------------

    /// @notice LiquidityWindow address
    address public liquidityWindow;

    /// @notice Mint fee in basis points
    uint16 public mintFeeBps;

    /// @notice Refund fee in basis points
    uint16 public refundFeeBps;

    /// @notice Half-spread in basis points (e.g., 10 = 0.10% each direction)
    uint16 public halfSpreadBps;

    /// @notice DEX buy fee in basis points
    uint16 public buyFeeBps;

    /// @notice DEX sell fee in basis points
    uint16 public sellFeeBps;

    // -------------------------------------------------------------------------
    // Storage - Daily Cap (% of Liquidity Reserve)
    // -------------------------------------------------------------------------

    /// @notice Daily refund cap as percentage of liquidity reserve (0-100)
    /// @dev Set to 100 to allow full reserve redemption in one day
    uint8 public dailyCapPct;

    /// @notice USDC redeemed in current cap cycle
    uint256 public dailyUsedUsdc;

    /// @notice Frozen cap for current cycle (set at first refund of day)
    uint256 public dailyCapUsdc;

    /// @notice Current cap cycle ID (days since epoch, EST-aligned)
    uint64 public currentCapCycle;

    /// @notice Hours to add to UTC to align to EST midnight (19 = EST, 20 = EDT)
    uint8 public cycleOffsetHours;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ContractReferencesUpdated(
        address indexed buck,
        address indexed oracleAdapter,
        address indexed collateralAttestation,
        address liquidityReserve,
        address liquidityWindow,
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

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidFee();
    error InvalidCapPct();
    error InvalidCycleOffset();
    error ExceedsDailyCap(uint256 requested, uint256 remaining);
    error ContractsNotConfigured();
    error StaleCollateralAttestation();

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) public initializer {
        if (initialAdmin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(ADMIN_ROLE, initialAdmin);

        mintFeeBps = 19;
        refundFeeBps = 19;
        halfSpreadBps = 10;
        buyFeeBps = 29;
        sellFeeBps = 29;
        dailyCapPct = 66;
        cycleOffsetHours = 19;
    }

    /// @notice Reinitializer that sets fee defaults.
    function initializeV2() external reinitializer(2) onlyRole(ADMIN_ROLE) {
        mintFeeBps = 19;
        refundFeeBps = 19;
        halfSpreadBps = 10;
        buyFeeBps = 29;
        sellFeeBps = 29;
        dailyCapPct = 66;
        cycleOffsetHours = 19;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    function setContractReferences(
        address buck_,
        address oracleAdapter_,
        address collateralAttestation_,
        address liquidityReserve_,
        address liquidityWindow_,
        address usdc_
    ) external onlyRole(ADMIN_ROLE) {
        if (buck_ == address(0)) revert ZeroAddress();
        if (oracleAdapter_ == address(0)) revert ZeroAddress();
        if (collateralAttestation_ == address(0)) revert ZeroAddress();
        if (liquidityReserve_ == address(0)) revert ZeroAddress();
        if (liquidityWindow_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0)) revert ZeroAddress();

        buck = buck_;
        oracleAdapter = oracleAdapter_;
        collateralAttestation = collateralAttestation_;
        liquidityReserve = liquidityReserve_;
        liquidityWindow = liquidityWindow_;
        usdc = usdc_;

        emit ContractReferencesUpdated(
            buck_, oracleAdapter_, collateralAttestation_, liquidityReserve_, liquidityWindow_, usdc_
        );
    }

    function setFees(
        uint16 mintFeeBps_,
        uint16 refundFeeBps_,
        uint16 halfSpreadBps_,
        uint16 buyFeeBps_,
        uint16 sellFeeBps_
    ) external onlyRole(ADMIN_ROLE) {
        if (mintFeeBps_ > 1000) revert InvalidFee(); // Max 10%
        if (refundFeeBps_ > 1000) revert InvalidFee();
        if (halfSpreadBps_ > 500) revert InvalidFee(); // Max 5%
        if (buyFeeBps_ > 1000) revert InvalidFee();
        if (sellFeeBps_ > 1000) revert InvalidFee();

        mintFeeBps = mintFeeBps_;
        refundFeeBps = refundFeeBps_;
        halfSpreadBps = halfSpreadBps_;
        buyFeeBps = buyFeeBps_;
        sellFeeBps = sellFeeBps_;

        emit FeesUpdated(mintFeeBps_, refundFeeBps_, halfSpreadBps_, buyFeeBps_, sellFeeBps_);
    }

    /// @param pct Percentage of reserve (0-100)
    function setDailyCapPct(uint8 pct) external onlyRole(ADMIN_ROLE) {
        if (pct > 100) revert InvalidCapPct();

        uint8 oldPct = dailyCapPct;
        dailyCapPct = pct;

        emit DailyCapPctUpdated(oldPct, pct);
    }

    /// @dev 19 = EST (UTC-5), 20 = EDT (UTC-4)
    function setCycleOffsetHours(uint8 hours_) external onlyRole(ADMIN_ROLE) {
        if (hours_ > 23) revert InvalidCycleOffset();

        uint8 oldHours = cycleOffsetHours;
        cycleOffsetHours = hours_;

        emit CycleOffsetUpdated(oldHours, hours_);
    }

    // -------------------------------------------------------------------------
    // Pricing Functions
    // -------------------------------------------------------------------------

    /// @notice CAP price: (STRC/100) + yieldAccumulated, capped by CR (18 decimals)
    function getCAPPrice() external view returns (uint256 price) {
        return _computeCAPPrice();
    }

    function _computeCAPPrice() internal view returns (uint256 price) {
        if (buck == address(0) || oracleAdapter == address(0)) {
            revert ContractsNotConfigured();
        }

        // Reject stale attestations before using the collateral ratio.
        if (collateralAttestation != address(0) &&
            ICollateralAttestationV2(collateralAttestation).isAttestationStale()) {
            revert StaleCollateralAttestation();
        }

        (uint256 basePrice,) = IOracleAdapter(oracleAdapter).latestPrice();

        // Yield accrues on the $1 face value, not on the floating STRC price.
        uint256 multiplier = IBuckV2(buck).currentYieldMultiplier();
        uint256 yieldAccumulated = multiplier > 1e18 ? multiplier - 1e18 : 0;
        price = basePrice + yieldAccumulated;

        // Cap the price by the current collateral ratio.
        uint256 cr = getCollateralRatio();
        if (cr < price) {
            price = cr;
        }

        return price;
    }

    /// @notice Collateral ratio from CollateralAttestationV2 (18 decimals).
    function getCollateralRatio() public view returns (uint256 cr) {
        if (buck == address(0) || collateralAttestation == address(0)) {
            return 1e18; // Fall back to 100% when dependencies are not set.
        }

        uint256 supply = IBuckV2(buck).totalSupply();
        if (supply == 0) {
            return type(uint256).max; // No liabilities = infinite CR, let oracle price pass through.
        }

        return ICollateralAttestationV2(collateralAttestation).getCollateralRatio();
    }

    function totalAssets() external view returns (uint256) {
        if (collateralAttestation == address(0)) revert ContractsNotConfigured();
        return ICollateralAttestationV2(collateralAttestation).totalAssets();
    }

    // -------------------------------------------------------------------------
    // Fee Getters
    // -------------------------------------------------------------------------

    function getFees() external view returns (uint16 mintFee, uint16 refundFee) {
        return (mintFeeBps, refundFeeBps);
    }

    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee) {
        return (buyFeeBps, sellFeeBps);
    }

    function getHalfSpread() external view returns (uint16) {
        return halfSpreadBps;
    }

    function getAllFees()
        external
        view
        returns (
            uint16 mintFee_,
            uint16 refundFee_,
            uint16 halfSpread_,
            uint16 buyFee_,
            uint16 sellFee_
        )
    {
        return (mintFeeBps, refundFeeBps, halfSpreadBps, buyFeeBps, sellFeeBps);
    }

    // -------------------------------------------------------------------------
    // Batched Getters
    // -------------------------------------------------------------------------

    function getMintParams()
        external
        view
        returns (uint256 capPrice_, uint16 mintFee_, uint16 halfSpread_, bool isPaused_)
    {
        capPrice_ = _computeCAPPrice();
        return (capPrice_, mintFeeBps, halfSpreadBps, paused());
    }

    function getRefundParams()
        external
        view
        returns (
            uint256 capPrice_,
            uint16 refundFee_,
            uint16 halfSpread_,
            bool isPaused_
        )
    {
        capPrice_ = _computeCAPPrice();
        return (capPrice_, refundFeeBps, halfSpreadBps, paused());
    }

    /// @dev reserveDrain includes the user payout and any fee routed to treasury.
    function checkAndRecordRefund(uint256 reserveDrain) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _maybeResetCycle();

        if (dailyUsedUsdc + reserveDrain > dailyCapUsdc) {
            revert ExceedsDailyCap(reserveDrain, dailyCapUsdc - dailyUsedUsdc);
        }

        dailyUsedUsdc += reserveDrain;
        emit RefundRecorded(reserveDrain, dailyUsedUsdc, dailyCapUsdc);
    }

    // -------------------------------------------------------------------------
    // Daily Cap Functions
    // -------------------------------------------------------------------------

    /// @notice Checks whether a refund fits within the current cycle.
    /// @dev reserveDrain includes the user payout and any fee routed to treasury.
    function checkRefund(uint256 reserveDrain) external view returns (bool allowed, string memory reason) {
        if (paused()) {
            return (false, "paused");
        }

        uint64 cycle = _currentCapCycle();
        uint256 used = dailyUsedUsdc;
        uint256 cap = dailyCapUsdc;

        if (cycle != currentCapCycle || cap == 0) {
            used = 0;
            cap = _computeDailyCap();
        }

        if (used + reserveDrain > cap) {
            return (false, "exceeds_daily_cap");
        }

        return (true, "");
    }

    function getRemainingCapacity() external view returns (uint256 remaining) {
        uint64 cycle = _currentCapCycle();
        uint256 used = dailyUsedUsdc;
        uint256 cap = dailyCapUsdc;

        if (cycle != currentCapCycle || cap == 0) {
            used = 0;
            cap = _computeDailyCap();
        }

        return cap > used ? cap - used : 0;
    }

    function getDailyCap() external view returns (uint256 cap) {
        uint64 cycle = _currentCapCycle();
        uint256 storedCap = dailyCapUsdc;

        if (cycle != currentCapCycle || storedCap == 0) {
            return _computeDailyCap();
        }

        return storedCap;
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    function _computeDailyCap() internal view returns (uint256) {
        if (liquidityReserve == address(0) || usdc == address(0)) {
            return 0;
        }

        uint256 reserveBalance = IERC20(usdc).balanceOf(liquidityReserve);
        return (reserveBalance * dailyCapPct) / 100;
    }

    function _currentCapCycle() internal view returns (uint64) {
        return uint64((block.timestamp + uint256(cycleOffsetHours) * 1 hours) / 1 days);
    }

    function _maybeResetCycle() internal {
        uint64 cycle = _currentCapCycle();

        if (cycle != currentCapCycle || dailyCapUsdc == 0) {
            currentCapCycle = cycle;
            dailyUsedUsdc = 0;
            dailyCapUsdc = _computeDailyCap();

            emit DailyCapReset(cycle, dailyCapUsdc);
        }
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
