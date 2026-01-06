//  ██████╗ ██╗   ██╗ ██████╗██╗  ██╗
//  ██╔══██╗██║   ██║██╔════╝██║ ██╔╝
//  ██████╔╝██║   ██║██║     █████╔╝ 
//  ██╔══██╗██║   ██║██║     ██╔═██╗ 
//  ██████╔╝╚██████╔╝╚██████╗██║  ██╗
//  ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝
                                
                      
// SPDX-License-Identifier: Unlicensed
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

/// @notice Minimal interface for rewards hook callbacks.
interface IRewardsHook {
    function onBalanceChange(address from, address to, uint256 amount) external;
}

/// @notice Minimal interface for PolicyManager.
interface IPolicyManager {
    function getDexFees() external view returns (uint16 buyFee, uint16 sellFee);
}

// Buck is the primary market token: mints via LiquidityWindow, enforces access control, and routes fees to treasury.
// RewardsEngine hooks into balance changes, while PolicyManager drives swap-fee spreads and module wiring.
// We keep modifiers tight so only whitelisted modules can mint/burn, and production mode locks critical deps.
contract Buck is
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

    // -------------------------------------------------------------------------
    // Storage - module wiring & policy
    // -------------------------------------------------------------------------

    // Convenience bundle used when wiring modules atomically.
    struct ModuleConfig {
        address liquidityWindow;
        address liquidityReserve;
        address treasury;
        address policyManager;
        address accessRegistry;
        address rewardsHook;
    }

    // Core modules we talk to: primary market, reserve, treasury, policy, access, rewards.
    address public liquidityWindow;
    address public liquidityReserve;
    address public treasury;
    address public policyManager;
    address public accessRegistry;
    address public rewardsHook;

    // DEX pairs/pools that trigger buy/sell fees on swaps.
    mapping(address => bool) public isDexPair;

    // Fee split for DEX trades: percentage of collected fees sent to reserve vs treasury.
    uint16 public feeToReservePct;

    // LP bots, treasury, etc. can be marked fee-exempt to bypass swap tolls.
    mapping(address => bool) public isFeeExempt;

    // Production readiness flag - once set, critical addresses cannot be zero
    bool public productionMode;

    // -------------------------------------------------------------------------
    // Events - Enhanced with old → new values
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
        address newAccessRegistry,
        address oldRewardsHook,
        address newRewardsHook
    );
    event DexPairAdded(address indexed pair);
    event DexPairRemoved(address indexed pair);
    event FeeSplitUpdated(uint16 oldFeeToReservePct, uint16 newFeeToReservePct);
    event FeeExemptSet(address indexed account, bool isExempt);
    event ProductionModeEnabled(uint256 timestamp);
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
    error NotAuthorizedMinter();
    error CriticalAddressCannotBeZero(string module);
    error ProductionModeAlreadyEnabled();
    error ProductionModeRequiresCriticalAddresses();
    error RenounceOwnershipDisabled();
    error AlreadyDexPair();
    error NotDexPair();

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BUCK token (replaces constructor for proxy pattern)
    /// @param initialOwner The initial owner of the contract
    /// @dev Can only be called once during proxy deployment
    // Proxy initializer: wires OZ parents and sets the initial owner.
    function initialize(address initialOwner) public initializer {
        if (initialOwner == address(0)) revert InvalidConfig();

        // Initialize all parent contracts
        __ERC20_init("Buck", "BUCK");
        __ERC20Permit_init("Buck");
        // ReentrancyGuardTransient uses transient storage - no init needed
        __Pausable_init();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyLiquidityWindow() {
        if (msg.sender != liquidityWindow) revert NotLiquidityWindow();
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != liquidityWindow && msg.sender != rewardsHook) {
            revert NotAuthorizedMinter();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // ERC-20 basic mutators
    // -------------------------------------------------------------------------

    // Standard transfer with access + rewards hook plumbing layered in.
    // Non-reentrant wrapper keeps primary-market handlers from griefing.
    function transfer(address to, uint256 amount)
        public
        override
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        return super.transfer(to, amount);
    }

    // Same as transfer but honors allowance; still runs hook logic on both legs.
    // Maintains the same pause + reentrancy guarantees as direct transfers.
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
    // Mint / burn (LiquidityWindow controlled)
    // -------------------------------------------------------------------------

    // Mint entry; only LiquidityWindow or RewardsEngine may call it.
    // Runs an access check on the recipient before minting.
    function mint(address to, uint256 amount) external nonReentrant onlyMinter whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        _enforceAccess(to);
        _mint(to, amount);
    }

    // Burn entry restricted to LiquidityWindow refunds.
    // Users never call this directly; refunds pipe burned supply through the window.
    function burn(address from, uint256 amount)
        external
        nonReentrant
        onlyLiquidityWindow
        whenNotPaused
    {
        _burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // Configuration (timelock only)
    // -------------------------------------------------------------------------

    // Atomically update all core module addresses; honors production-mode guardrails.
    // Keeps prior values for event breadcrumbs so governance can audit changes.
    function configureModules(
        address liquidityWindow_,
        address liquidityReserve_,
        address treasury_,
        address policyManager_,
        address accessRegistry_,
        address rewardsHook_
    ) external onlyOwner {
        // Store old config
        ModuleConfig memory oldConfig = ModuleConfig({
            liquidityWindow: liquidityWindow,
            liquidityReserve: liquidityReserve,
            treasury: treasury,
            policyManager: policyManager,
            accessRegistry: accessRegistry,
            rewardsHook: rewardsHook
        });

        // In production mode, enforce critical addresses
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
        }

        // Update storage
        liquidityWindow = liquidityWindow_;
        liquidityReserve = liquidityReserve_;
        treasury = treasury_;
        policyManager = policyManager_;
        accessRegistry = accessRegistry_;
        rewardsHook = rewardsHook_;

        // Revoke fee exemptions from old module addresses that are no longer in use
        if (oldConfig.liquidityWindow != address(0) && oldConfig.liquidityWindow != liquidityWindow_) {
            _setFeeExemptInternal(oldConfig.liquidityWindow, false);
        }
        if (oldConfig.liquidityReserve != address(0)
            && oldConfig.liquidityReserve != liquidityReserve_
        ) {
            _setFeeExemptInternal(oldConfig.liquidityReserve, false);
        }
        if (oldConfig.treasury != address(0) && oldConfig.treasury != treasury_) {
            _setFeeExemptInternal(oldConfig.treasury, false);
        }

        _syncSystemFeeExemptions();

        // Emit comprehensive event with old and new values
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
            accessRegistry_,
            oldConfig.rewardsHook,
            rewardsHook_
        );
    }

    // Register a DEX pair/pool for fee collection.
    // Automatically marks the pair as fee-exempt so it doesn't pay fees on its own transfers.
    function addDexPair(address pair) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        if (isDexPair[pair]) revert AlreadyDexPair();

        isDexPair[pair] = true;
        _setFeeExemptInternal(pair, true);

        emit DexPairAdded(pair);
    }

    // Unregister a DEX pair/pool from fee collection.
    // Removes fee exemption so the address is treated as a normal account.
    function removeDexPair(address pair) external onlyOwner {
        if (!isDexPair[pair]) revert NotDexPair();

        isDexPair[pair] = false;
        _setFeeExemptInternal(pair, false);

        emit DexPairRemoved(pair);
    }

    // Adjust how primary-market fees split between reserve and treasury.
    // Value is basis points; validation ensures we never exceed 100%.
    function setFeeSplit(uint16 newFeeToReservePct) external onlyOwner {
        if (newFeeToReservePct > BPS_DENOMINATOR) revert InvalidFee();

        uint16 oldFeeToReservePct = feeToReservePct;
        feeToReservePct = newFeeToReservePct;

        emit FeeSplitUpdated(oldFeeToReservePct, newFeeToReservePct);
    }

    // Manually mark/unmark addresses as exempt from protocol fees.
    // Useful for privileged actors (treasury, bots) beyond the auto-sync list.
    function setFeeExempt(address account, bool isExempt) external onlyOwner {
        _setFeeExemptInternal(account, isExempt);
    }

    /// @notice Enable production mode - one way switch
    /// @dev Once enabled, critical addresses must be non-zero
    // One-way switch that locks critical modules to non-zero addresses.
    // Prevents future configureModules calls from blanking vital dependencies.
    function enableProductionMode() external onlyOwner {
        if (productionMode) revert ProductionModeAlreadyEnabled();

        // Verify critical addresses are set
        if (
            liquidityWindow == address(0) || liquidityReserve == address(0)
                || treasury == address(0)
        ) {
            revert ProductionModeRequiresCriticalAddresses();
        }

        productionMode = true;
        emit ProductionModeEnabled(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Pausability functions
    // -------------------------------------------------------------------------

    /// @notice Pause all token transfers, mints, and burns
    /// @dev Only callable by owner for emergency situations
    // Emergency pause halts transfers/mints/burns.
    // Owner-only guard to stop primary market operations during incidents.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause token operations
    /// @dev Only callable by owner after emergency is resolved
    // Clears the pause flag so transfers resume without touching other state.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // UUPS Upgrade Authorization
    // -------------------------------------------------------------------------

    /// @notice Authorize contract upgrade
    /// @dev Required by UUPSUpgradeable. Only owner can authorize upgrades.
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Ownership renunciation is disabled to prevent accidental lockout
    /// @dev BUCK requires ongoing governance for pause, upgrades, and module configuration
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    // Public helper to preview swap fees given current PolicyManager config.
    // Returns 0 if policy manager isn't configured yet.
    function calculateSwapFee(uint256 amount, bool isBuy) external view returns (uint256) {
        if (policyManager == address(0)) return 0; // No fees if no PolicyManager configured

        // Query PolicyManager for current DEX fees
        (uint16 buyFee, uint16 sellFee) = IPolicyManager(policyManager).getDexFees();
        uint16 feeBps = isBuy ? buyFee : sellFee;
        return (amount * feeBps) / BPS_DENOMINATOR;
    }

    // -------------------------------------------------------------------------
    // Determines the applicable fee for a transfer based on DEX direction and fee exemptions.
    // Returns zero if policy manager isn't configured or if parties are exempt.
    // Checks isDexPair mapping for any registered DEX pair/pool.
    function _calculateFee(address from, address to, uint256 amount)
        internal
        view
        returns (uint256)
    {
        // Early exit if neither party is a DEX pair (most common case)
        bool isBuy = isDexPair[from];
        bool isSell = isDexPair[to];
        if (!isBuy && !isSell) return 0;

        if (policyManager == address(0)) return 0;

        // Query PolicyManager for current DEX fees (only if we have a DEX trade)
        (uint16 buyFee, uint16 sellFee) = IPolicyManager(policyManager).getDexFees();

        // BUY: tokens coming FROM a registered DEX pair
        if (isBuy) {
            if (_isFeeExempt(to)) return 0;
            return (amount * buyFee) / BPS_DENOMINATOR;
        }
        // SELL: tokens going TO a registered DEX pair
        if (isSell) {
            if (_isFeeExempt(from)) return 0;
            return (amount * sellFee) / BPS_DENOMINATOR;
        }
        return 0;
    }

    /// @notice Distributes collected fees between reserve and treasury
    /// @dev CEI pattern: All state updates before external calls to prevent reentrancy
    ///      Even though public entry points have nonReentrant guards, this provides defense-in-depth
    /// @param source The address fees are collected from
    /// @param feeAmount Total fee amount to distribute
    function _distributeFees(address source, uint256 feeAmount) internal {
        // CHECKS: Calculate distribution and validate addresses upfront
        uint256 toReserve = (feeAmount * feeToReservePct) / BPS_DENOMINATOR;
        uint256 toTreasury = feeAmount - toReserve;

        // Validate addresses BEFORE any state changes
        if (toReserve > 0 && liquidityReserve == address(0)) revert InvalidAddress();
        if (toTreasury > 0 && treasury == address(0)) revert InvalidAddress();

        // EFFECTS: All balance updates together (atomic state changes)
        // Both transfers complete before any external calls
        if (toReserve > 0) {
            super._update(source, liquidityReserve, toReserve);
        }
        if (toTreasury > 0) {
            super._update(source, treasury, toTreasury);
        }

        // INTERACTIONS: All external calls after state is finalized
        // Even if RewardsHook reenters here, all balances are already updated
        if (toReserve > 0) {
            _notifyRewards(source, liquidityReserve, toReserve);
        }
        if (toTreasury > 0) {
            _notifyRewards(source, treasury, toTreasury);
        }
    }

    // Forward balance delta to RewardsEngine if configured.
    // Reward hook is optional so tests can run without wiring the full system.
    function _notifyRewards(address from, address to, uint256 amount) internal {
        if (rewardsHook == address(0)) return;
        IRewardsHook(rewardsHook).onBalanceChange(from, to, amount);
    }

    // Enforces access checks on accounts we care about (skips internal/system addresses).
    // Mint call handles the actual enforcement before tokens hit the recipient.
    function _enforceAccess(address account) internal view {
        if (account == address(0)) return;
        if (_isSystemAccount(account)) return;
        if (accessRegistry == address(0)) return;
        if (!IAccessRegistry(accessRegistry).isAllowed(account)) revert AccessCheckFailed(account);
    }

    // Keeps protocol-owned accounts from accidentally incurring fees.
    // Called whenever module addresses change so state stays aligned.
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

    // Low-level setter used by admin + system sync.
    // Emits consistently so indexers can track exemption state over time.
    function _setFeeExemptInternal(address account, bool isExempt) internal {
        isFeeExempt[account] = isExempt;
        emit FeeExemptSet(account, isExempt);
    }

    // Wrapper for checking fee exemptions (future custom logic can drop in here).
    // Keeps a single touchpoint if we ever add dynamic exemption logic.
    function _isFeeExempt(address account) internal view returns (bool) {
        return isFeeExempt[account];
    }

    // Identifies protocol/system accounts that should skip access logic.
    // DEX pairs bypass access checks since they're pool contracts that hold tokens.
    function _isSystemAccount(address account) internal view returns (bool) {
        return account == liquidityWindow || account == liquidityReserve || account == treasury
            || isDexPair[account];
    }

    // Overrides OZ hook to apply fees and notify RewardsEngine on every state change.
    // Handles mint/burn branches explicitly before falling back to transfer logic.
    // Denylisted addresses are frozen: cannot send or receive (USDC/USDT style).
    function _update(address from, address to, uint256 value) internal override {
        // Freeze check: denylisted addresses cannot send or receive
        if (accessRegistry != address(0)) {
            if (from != address(0) && IAccessRegistry(accessRegistry).isDenylisted(from)) revert Frozen(from);
            if (to != address(0) && IAccessRegistry(accessRegistry).isDenylisted(to)) revert Frozen(to);
        }

        if (from == address(0) || to == address(0)) {
            // mint or burn - access is enforced in LiquidityWindow before minting
            super._update(from, to, value);
            _notifyRewards(from, to, value);
            return;
        }

        uint256 feeAmount = _calculateFee(from, to, value);
        if (feeAmount > 0) {
            uint256 netAmount = value - feeAmount;
            super._update(from, to, netAmount);
            _distributeFees(from, feeAmount);
            // Notify RewardsEngine with net amount actually transferred
            _notifyRewards(from, to, netAmount);
        } else {
            super._update(from, to, value);
            _notifyRewards(from, to, value);
        }
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    // Reserved padding so future upgrades can safely append storage fields.
    // Trim this array slot-by-slot when new storage variables are introduced.
    uint256[50] private __gap;
}
