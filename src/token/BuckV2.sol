//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardTransient} from "src/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";

/// @notice Minimal interface for access registry lookups.
interface IAccessRegistry {
    function isAllowed(address account) external view returns (bool);
    function isDenylisted(address account) external view returns (bool);
}

/// @notice Minimal interface for PolicyManager price queries.
interface IPolicyManager {
    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee);
}

/**
 * @title BuckV2
 * @notice Yield-bearing ERC20 token with streaming price appreciation
 *
 * @dev Architecture:
 * - Price Formula: BUCK_price = (STRC/100) + yieldAccumulated (additive on $1 face value)
 * - Yield streams linearly over configurable vesting periods (3-365 days)
 * - DEX fee collection on registered trading pairs (buy/sell fees)
 *
 * @dev Access Control:
 * - Owner: Module configuration, fee settings, pause, yield distributor assignment
 * - LiquidityWindow: Mint and burn operations
 * - YieldDistributor: Yield stream management (setYieldStream, finalizeYield)
 * - Allowlist: Checked on mint + burn only (gates entry). Transfers are unrestricted.
 * - Denylist: Checked on all transfers (frozen accounts cannot send or receive)
 *
 * @dev Fee Structure:
 * - DEX swaps: Configurable buy/sell fees (set via PolicyManager)
 * - Fees split between liquidity reserve and treasury (configurable ratio)
 * - System accounts and registered DEX pairs are auto-exempt
 */
contract BuckV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    MulticallUpgradeable
{
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MIN_VEST_DURATION = 3 days;
    uint256 internal constant MAX_VEST_DURATION = 365 days;
    uint256 internal constant YIELD_PRECISION = 1e18;
    uint256 internal constant MAX_YIELD_WAD = 0.5e18;
    uint256 internal constant BPS_TO_WAD = 1e14;

    // -------------------------------------------------------------------------
    // Storage - Module Wiring
    // -------------------------------------------------------------------------

    /// @notice Convenience bundle used when wiring modules atomically.
    struct ModuleConfig {
        address liquidityWindow;
        address liquidityReserve;
        address treasury;
        address policyManager;
        address accessRegistry;
    }

    // Core modules: primary market, reserve, treasury, policy, access
    address public liquidityWindow;
    address public liquidityReserve;
    address public treasury;
    address public policyManager;
    address public accessRegistry;

    /// @dev Reserved slot. Do not use.
    address private __deprecated_rewardsHook;

    // DEX pairs/pools that trigger buy/sell fees on swaps.
    mapping(address => bool) public isDexPair;

    // Fee split for DEX trades: percentage of collected fees sent to reserve vs treasury.
    uint16 public feeToReservePct;

    // LP bots, treasury, etc. can be marked fee-exempt to bypass DEX trading fees.
    mapping(address => bool) public isFeeExempt;

    // Production readiness flag - once set, critical addresses cannot be zero
    bool public productionMode;

    // -------------------------------------------------------------------------
    // Storage - Yield Streaming
    // -------------------------------------------------------------------------

    /// @notice Base yield multiplier (18 decimals, starts at 1e18 = 1.0)
    uint256 public yieldMultiplier;

    /// @notice Unvested yield in WAD 
    uint256 public unvestedYieldWad;

    /// @notice Timestamp when current yield distribution started
    uint256 public lastYieldTime;

    /// @notice Current vesting duration in seconds
    uint256 public currentVestDuration;

    /// @notice Address authorized to call yield distribution functions
    address public yieldDistributor;

    /// @dev Reserved slot. Do not use.
    address private __deprecated_usdc;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ModulesUpdated(
        address indexed oldLiquidityWindow,
        address indexed newLiquidityWindow,
        address oldLiquidityReserve,
        address newLiquidityReserve,
        address oldTreasury,
        address newTreasury,
        address oldPolicyManager,
        address newPolicyManager,
        address oldAccessRegistry,
        address newAccessRegistry
    );
    event DexPairAdded(address indexed pair);
    event DexPairRemoved(address indexed pair);
    event FeeSplitUpdated(uint16 oldFeeToReservePct, uint16 newFeeToReservePct);
    event FeeExemptSet(address indexed account, bool isExempt);
    event ProductionModeEnabled(uint256 timestamp);

    // Yield events
    event YieldStreamStarted(uint256 indexed yieldBps, uint256 vestDays, uint256 timestamp);
    event YieldFinalized(uint256 finalMultiplier, uint256 timestamp);
    event YieldDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event YieldRateUpdated(uint256 indexed newYieldBps, uint256 newVestDays, uint256 accruedWad, uint256 timestamp);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotLiquidityWindow();
    error InvalidConfig();
    error InvalidFee();
    error InvalidAddress();
    error AccessCheckFailed(address account);
    error Frozen(address account);
    error ZeroAddress();
    error CriticalAddressCannotBeZero(string module);
    error ProductionModeAlreadyEnabled();
    error ProductionModeRequiresCriticalAddresses();
    error RenounceOwnershipDisabled();
    error AlreadyDexPair();
    error NotDexPair();
    error NotYieldDistributor();
    error InvalidYieldBps();
    error InvalidVestDuration();
    error NoActiveStream();
    error StreamAlreadyActive();
    error AccruedYieldExceedsCap();

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        if (initialOwner == address(0)) revert InvalidConfig();

        __ERC20_init("Buck", "BUCK");
        __ERC20Permit_init("Buck");
        __Pausable_init();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        yieldMultiplier = 1e18;
    }

    /// @notice One-time reinitializer for new storage slots.
    function migrateFromV1() external onlyOwner reinitializer(2) {
        if (yieldMultiplier == 0) {
            yieldMultiplier = 1e18;
        }
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyLiquidityWindow() {
        if (msg.sender != liquidityWindow) revert NotLiquidityWindow();
        _;
    }

    modifier onlyYieldDistributor() {
        if (msg.sender != yieldDistributor && msg.sender != owner()) {
            revert NotYieldDistributor();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // ERC-20 Basic Mutators
    // -------------------------------------------------------------------------

    function transfer(address to, uint256 amount)
        public
        override
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }

    // -------------------------------------------------------------------------
    // Mint / Burn (LiquidityWindow only)
    // -------------------------------------------------------------------------

    function mint(address to, uint256 amount) external nonReentrant onlyLiquidityWindow whenNotPaused {
        _enforceAccess(to);
        _mint(to, amount);
    }

    function burn(address from, uint256 amount)
        external
        nonReentrant
        onlyLiquidityWindow
        whenNotPaused
    {
        _burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // Yield Functions
    // -------------------------------------------------------------------------

    /// @notice Current yield multiplier: base + accrued + linearly-vested portion
    /// @return Multiplier in 18 decimals (1e18 = 1.0)
    function currentYieldMultiplier() public view returns (uint256) {
        uint256 result = yieldMultiplier;

        if (accruedYieldWad > 0) {
            result += (yieldMultiplier * accruedYieldWad) / YIELD_PRECISION;
        }

        if (unvestedYieldWad > 0 && currentVestDuration > 0) {
            uint256 elapsed = block.timestamp - lastYieldTime;
            uint256 vestedWad;

            if (elapsed >= currentVestDuration) {
                vestedWad = unvestedYieldWad;
            } else {
                vestedWad = (unvestedYieldWad * elapsed) / currentVestDuration;
            }

            result += (yieldMultiplier * vestedWad) / YIELD_PRECISION;
        }

        return result;
    }

    /// @notice Start a new yield stream. Reverts if actively vesting — use updateYieldRate() instead.
    /// @dev Auto-finalizes (compounds) a fully-vested prior stream.
    /// @param yieldBps Yield in basis points (converted to WAD internally)
    /// @param vestDays Vesting duration in days (3-365)
    function setYieldStream(uint256 yieldBps, uint256 vestDays) external onlyYieldDistributor {
        if (unvestedYieldWad > 0 || accruedYieldWad > 0) {
            if (block.timestamp < lastYieldTime + currentVestDuration) {
                revert StreamAlreadyActive();
            }
            // Auto-finalize fully-vested stream
            yieldMultiplier = currentYieldMultiplier();
            accruedYieldWad = 0;
        }

        if (yieldBps == 0 || yieldBps > MAX_YIELD_WAD / BPS_TO_WAD) revert InvalidYieldBps();

        uint256 vestDuration = vestDays * 1 days;
        if (vestDuration < MIN_VEST_DURATION || vestDuration > MAX_VEST_DURATION) {
            revert InvalidVestDuration();
        }

        unvestedYieldWad = yieldBps * BPS_TO_WAD;
        currentVestDuration = vestDuration;
        lastYieldTime = block.timestamp;

        emit YieldStreamStarted(yieldBps, vestDays, block.timestamp);
    }

    /// @notice Finalize current stream early — compounds vested progress into base multiplier.
    function finalizeYield() external onlyYieldDistributor {
        if (unvestedYieldWad == 0) revert NoActiveStream();

        yieldMultiplier = currentYieldMultiplier();
        unvestedYieldWad = 0;
        accruedYieldWad = 0;
        currentVestDuration = 0;
        lastYieldTime = block.timestamp;

        emit YieldFinalized(yieldMultiplier, block.timestamp);
    }

    /// @notice Update yield rate mid-stream without compounding.
    /// @dev Vested progress moves to accruedYieldWad (not base) to prevent compound interest.
    /// @param newYieldBps New yield rate in basis points
    /// @param newVestDays New vesting duration in days (3-365)
    function updateYieldRate(uint256 newYieldBps, uint256 newVestDays) external onlyYieldDistributor {
        if (newYieldBps == 0 || newYieldBps > MAX_YIELD_WAD / BPS_TO_WAD) revert InvalidYieldBps();

        uint256 newVestDuration = newVestDays * 1 days;
        if (newVestDuration < MIN_VEST_DURATION || newVestDuration > MAX_VEST_DURATION) {
            revert InvalidVestDuration();
        }

        uint256 vestedFromStream = 0;
        if (unvestedYieldWad > 0 && currentVestDuration > 0) {
            uint256 elapsed = block.timestamp - lastYieldTime;
            if (elapsed >= currentVestDuration) {
                vestedFromStream = unvestedYieldWad;
            } else {
                vestedFromStream = (unvestedYieldWad * elapsed) / currentVestDuration;
            }
        }

        accruedYieldWad += vestedFromStream;
        if (accruedYieldWad > MAX_YIELD_WAD) revert AccruedYieldExceedsCap();

        unvestedYieldWad = newYieldBps * BPS_TO_WAD;
        currentVestDuration = newVestDuration;
        lastYieldTime = block.timestamp;

        emit YieldRateUpdated(newYieldBps, newVestDays, accruedYieldWad, block.timestamp);
    }

    function getStreamStatus()
        external
        view
        returns (
            uint256 baseMultiplier,
            uint256 currentMultiplier,
            uint256 unvestedWad,
            uint256 vestedWad,
            uint256 accruedWad,
            uint256 timeRemaining,
            uint256 percentComplete
        )
    {
        baseMultiplier = yieldMultiplier;
        currentMultiplier = currentYieldMultiplier();
        unvestedWad = unvestedYieldWad;
        accruedWad = accruedYieldWad;

        if (currentVestDuration == 0 || unvestedYieldWad == 0) {
            return (baseMultiplier, currentMultiplier, 0, 0, accruedWad, 0, 100);
        }

        uint256 elapsed = block.timestamp - lastYieldTime;

        if (elapsed >= currentVestDuration) {
            vestedWad = unvestedYieldWad;
            timeRemaining = 0;
            percentComplete = 100;
        } else {
            vestedWad = (unvestedYieldWad * elapsed) / currentVestDuration;
            timeRemaining = currentVestDuration - elapsed;
            percentComplete = (elapsed * 100) / currentVestDuration;
        }
    }

    function setYieldDistributor(address _yieldDistributor) external onlyOwner {
        if (_yieldDistributor == address(0)) revert ZeroAddress();
        address oldDistributor = yieldDistributor;
        yieldDistributor = _yieldDistributor;
        emit YieldDistributorUpdated(oldDistributor, _yieldDistributor);
    }

    // -------------------------------------------------------------------------
    // Configuration (Owner only)
    // -------------------------------------------------------------------------

    function configureModules(
        address liquidityWindow_,
        address liquidityReserve_,
        address treasury_,
        address policyManager_,
        address accessRegistry_
    ) external onlyOwner {
        ModuleConfig memory oldConfig = ModuleConfig({
            liquidityWindow: liquidityWindow,
            liquidityReserve: liquidityReserve,
            treasury: treasury,
            policyManager: policyManager,
            accessRegistry: accessRegistry
        });

        if (productionMode) {
            if (liquidityWindow_ == address(0)) {
                revert CriticalAddressCannotBeZero("liquidityWindow");
            }
            if (liquidityReserve_ == address(0)) {
                revert CriticalAddressCannotBeZero("liquidityReserve");
            }
            if (treasury_ == address(0)) {
                revert CriticalAddressCannotBeZero("treasury");
            }
            if (policyManager_ == address(0)) {
                revert CriticalAddressCannotBeZero("policyManager");
            }
        }

        liquidityWindow = liquidityWindow_;
        liquidityReserve = liquidityReserve_;
        treasury = treasury_;
        policyManager = policyManager_;
        accessRegistry = accessRegistry_;

        if (oldConfig.liquidityWindow != address(0) && oldConfig.liquidityWindow != liquidityWindow_) {
            _setFeeExemptInternal(oldConfig.liquidityWindow, false);
        }
        if (oldConfig.liquidityReserve != address(0) && oldConfig.liquidityReserve != liquidityReserve_) {
            _setFeeExemptInternal(oldConfig.liquidityReserve, false);
        }
        if (oldConfig.treasury != address(0) && oldConfig.treasury != treasury_) {
            _setFeeExemptInternal(oldConfig.treasury, false);
        }

        _syncSystemFeeExemptions();

        emit ModulesUpdated(
            oldConfig.liquidityWindow,
            liquidityWindow_,
            oldConfig.liquidityReserve,
            liquidityReserve_,
            oldConfig.treasury,
            treasury_,
            oldConfig.policyManager,
            policyManager_,
            oldConfig.accessRegistry,
            accessRegistry_
        );
    }

    /// @dev Pairs are not auto-exempted, so pair-to-pair hops still pay fees.
    function addDexPair(address pair) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        if (isDexPair[pair]) revert AlreadyDexPair();
        isDexPair[pair] = true;
        emit DexPairAdded(pair);
    }

    function removeDexPair(address pair) external onlyOwner {
        if (!isDexPair[pair]) revert NotDexPair();

        isDexPair[pair] = false;

        emit DexPairRemoved(pair);
    }

    function setFeeSplit(uint16 newFeeToReservePct) external onlyOwner {
        if (newFeeToReservePct > BPS_DENOMINATOR) revert InvalidFee();

        uint16 oldFeeToReservePct = feeToReservePct;
        feeToReservePct = newFeeToReservePct;

        emit FeeSplitUpdated(oldFeeToReservePct, newFeeToReservePct);
    }

    /// @dev Only affects DEX swap fees, not LiquidityWindow mint and refund fees.
    function setDexFeeExempt(address account, bool isExempt) external onlyOwner {
        _setFeeExemptInternal(account, isExempt);
    }

    function enableProductionMode() external onlyOwner {
        if (productionMode) revert ProductionModeAlreadyEnabled();

        if (
            liquidityWindow == address(0) || liquidityReserve == address(0)
                || treasury == address(0) || policyManager == address(0)
        ) {
            revert ProductionModeRequiresCriticalAddresses();
        }

        productionMode = true;
        emit ProductionModeEnabled(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Pausability
    // -------------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // UUPS Upgrade Authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    function _calculateFee(address from, address to, uint256 amount)
        internal
        view
        returns (uint256)
    {
        bool isBuy = isDexPair[from];
        bool isSell = isDexPair[to];
        if (!isBuy && !isSell) return 0;

        if (policyManager == address(0)) return 0;

        (uint16 buyFee, uint16 sellFee) = IPolicyManager(policyManager).getDexFees();

        // Ceil division that rounds up in favor of the protocol.
        if (isBuy) {
            if (_isFeeExempt(to)) return 0;
            uint256 numerator = amount * buyFee;
            return (numerator + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        }
        if (isSell) {
            if (_isFeeExempt(from)) return 0;
            uint256 numerator = amount * sellFee;
            return (numerator + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        }
        return 0;
    }

    function _distributeFees(address source, uint256 feeAmount) internal {
        uint256 toReserve = (feeAmount * feeToReservePct) / BPS_DENOMINATOR;
        uint256 toTreasury = feeAmount - toReserve;

        if (toReserve > 0 && liquidityReserve == address(0)) revert InvalidAddress();
        if (toTreasury > 0 && treasury == address(0)) revert InvalidAddress();

        if (toReserve > 0) {
            super._update(source, liquidityReserve, toReserve);
        }
        if (toTreasury > 0) {
            super._update(source, treasury, toTreasury);
        }
    }

    function _enforceAccess(address account) internal view {
        if (account == address(0)) return;
        if (_isSystemAccount(account)) return;
        if (accessRegistry == address(0)) return;
        if (!IAccessRegistry(accessRegistry).isAllowed(account)) revert AccessCheckFailed(account);
    }

    function _syncSystemFeeExemptions() internal {
        if (liquidityWindow != address(0)) {
            _setFeeExemptInternal(liquidityWindow, true);
        }
        if (liquidityReserve != address(0)) {
            _setFeeExemptInternal(liquidityReserve, true);
        }
        if (treasury != address(0)) {
            _setFeeExemptInternal(treasury, true);
        }
    }

    function _setFeeExemptInternal(address account, bool isExempt) internal {
        isFeeExempt[account] = isExempt;
        emit FeeExemptSet(account, isExempt);
    }

    function _isFeeExempt(address account) internal view returns (bool) {
        return isFeeExempt[account];
    }

    function _isSystemAccount(address account) internal view returns (bool) {
        return account == liquidityWindow || account == liquidityReserve || account == treasury
            || isDexPair[account];
    }

    /// @dev Applies denylist checks and DEX fees on transfers.
    function _update(address from, address to, uint256 value) internal override {
        if (accessRegistry != address(0)) {
            if (from != address(0) && IAccessRegistry(accessRegistry).isDenylisted(from)) revert Frozen(from);
            if (to != address(0) && IAccessRegistry(accessRegistry).isDenylisted(to)) revert Frozen(to);
        }

        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 feeAmount = _calculateFee(from, to, value);
        if (feeAmount > 0) {
            uint256 netAmount = value - feeAmount;
            super._update(from, to, netAmount);
            _distributeFees(from, feeAmount);
        } else {
            super._update(from, to, value);
        }
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Accrued yield in WAD — vested but not yet compounded into base multiplier
    uint256 public accruedYieldWad;

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    uint256[43] private __gap;
}
