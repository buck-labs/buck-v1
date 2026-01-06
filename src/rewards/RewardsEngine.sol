// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IRewardsMintable {
    function mint(address to, uint256 amount) external;
}

interface IPolicyDistributionConfig {
    function getDistributionSkimBps() external view returns (uint16);
    function getCAPPrice() external view returns (uint256);
}

// Minimal interface to read CollateralAttestation pointer from PolicyManager
interface IPolicyAttestationRef {
    function collateralAttestation() external view returns (address);
}

// Minimal interface for CollateralAttestation to fetch current CR (18 decimals)
interface ICollateralAttestationView {
    function getCollateralRatio() external view returns (uint256);
    function isAttestationStale() external view returns (bool);
}
// Minimal interface to refresh PolicyManager's band before reading band-dependent config
interface IPolicyBandRefresh {
    function refreshBand() external returns (uint8);
}

interface ILiquidityReserve {
    function withdrawDistributionSkim(address to, uint256 amount) external;
}

// RewardsEngine tracks balance-time units, routes USDC coupons into BUCK mints, and enforces late-entry rules.
// LiquidityWindow tops up reserve; this contract mirrors inflows into token rewards with band-aware haircuts.
// Goal is to keep distribution math transparent: all accounting in 18-dec, explicit epochs, rich telemetry.
contract RewardsEngine is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    MulticallUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    using Math for uint256;

    // -------------------------------------------------------------------------
    // Role constants
    // -------------------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant ACC_PRECISION = 1e18;
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant USDC_TO_18 = 1e12;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotToken();
    error InvalidConfig();
    error BalanceUnderflow();
    error NothingToDistribute();
    error ClaimTooSmall(uint256 claimable, uint256 minRequired);
    error NoRewardsDeclared();
    error InvalidRecipient();
    error InvalidRecoverySink(address account);
    error UnsupportedRecoveryAsset(address token);
    error ZeroAddress();
    error InvalidAmount();
    error InvalidOraclePrice();
    error MaxTokensPerEpochExceeded(uint256 requested, uint256 maxAllowed);
    error InvalidMaxTokensPerEpoch();
    error AlreadyDistributed();
    error EpochNotConfigured();
    error DistributionTooEarly();
    error DistributionBlockedDuringDepeg(uint256 capPrice);
    error MustDistributeBeforeNewEpoch();
    error MaxClaimPerTxExceeded(uint256 requested, uint256 maxAllowed);
    error ClaimExceedsHeadroom(uint256 requested, uint256 headroom);
    error StaleAttestationForClaim();

    // -------------------------------------------------------------------------
    // Storage - account tracking
    // -------------------------------------------------------------------------

    // Per-account ledger storing balances, accrued units, and gating metadata.
    struct AccountState {
        uint256 balance;           // Current BUCK balance observed via hook
        uint64 lastClaimedEpoch;   // Last epoch user claimed rewards for
        uint64 lastAccrualTime;    // Timestamp of last unit accrual (for current epoch)
        uint64 lastAccruedEpoch;   // Epoch id for which unitsAccrued applies (rolls forward lazily)
        uint64 lastInflow;         // Timestamp when balance last increased
        uint256 unitsAccrued;      // Time-weighted units accrued in the CURRENT epoch (balance * seconds)
        uint256 pendingRewards;    // Rewards credited from PRIOR epochs, waiting to be claimed (in BUCK)
        uint256 rewardDebt;        // Baseline of accRewardPerUnit applied to accrued units (for O(1) claims)
        bool excluded;             // True when account is excluded from earning
        bool eligible;             // False if any outflow before checkpoint end
        uint256 lateInflow;        // Tokens received after checkpointStart (don't earn until next epoch)
        uint64 lateInflowEpoch;    // Epoch when lateInflow was recorded (for lazy reset)
    }

    mapping(address => AccountState) private _accounts;

    // -------------------------------------------------------------------------
    // Storage - admin wiring & config
    // -------------------------------------------------------------------------

    address public token; // BUCK token expected to call onBalanceChange / mint rewards
    address public policyManager; // Required for CAP pricing and distribution skim
    address public treasury; // Treasury to receive skim fees (also receives breakage)
    address public liquidityReserve; // LiquidityReserve to pull USDC from
    address public reserveUSDC; // USDC token address for reserve balance checks

    uint256 public minClaimTokens;

    // -------------------------------------------------------------------------
    // Storage - epoch configuration
    // -------------------------------------------------------------------------

    uint64 public currentEpochId;
    uint64 public epochStart;
    uint64 public epochEnd;
    uint64 public checkpointStart;    // Start of checkpoint window (must hold through)
    uint64 public checkpointEnd;      // End of checkpoint window

    // -------------------------------------------------------------------------
    // Storage - global integrator (per-epoch)
    // -------------------------------------------------------------------------

    uint256 public globalEligibleUnits;      // Integral of eligible supply THIS epoch
    uint256 public currentEligibleSupply;    // Sum of eligible account balances
    uint64 public lastGlobalUpdateTime;      // Last time global integrator was updated
    uint256 public treasuryUnitsThisEpoch;   // Pre-checkpoint breakage accumulator
    uint256 public futureBreakageUnits;      // Post-checkpoint breakage (remaining days → DAO)
    uint256 public totalBreakageAllTime;     // Lifetime breakage counter
    uint256 public totalExcludedSupply;      // Sum of excluded account balances
    bool public distributedThisEpoch;        // Enforce one distribution per epoch
    bool public blockDistributeOnDepeg;      // Block distributions when CAP < $1 (default: true)

    // -------------------------------------------------------------------------
    // Storage - per-epoch distribution data & reporting (GLOBAL)
    // -------------------------------------------------------------------------

    // Global cumulative reward index (incremented each distribution)
    uint256 public accRewardPerUnit; // scaled by ACC_PRECISION

    // Per-epoch timing (used for epoch-boundary finalization in _settleAccount)
    mapping(uint64 => uint64) public epochStartTime;    // Start timestamp for each epoch
    mapping(uint64 => uint64) public epochEndTime;      // End timestamp for each epoch

    // Lightweight per-epoch report for analytics (no per-user snapshots)
    struct EpochReport {
        uint64 distributionTime;      // Timestamp when distribute() executed for this epoch
        uint256 denominatorUnits;     // Denominator used for deltaIndex (eligible + sink units)
        uint256 deltaIndex;           // tokensAllocated / denominatorUnits (scaled by ACC_PRECISION)
        uint256 tokensAllocated;      // Tokens allocated (minus dust carry)
        uint256 dustCarry;            // Dust carried to next distribution
    }
    mapping(uint64 => EpochReport) public epochReport;

    // -------------------------------------------------------------------------
    // Storage - reward accounting
    // -------------------------------------------------------------------------

    uint64 public lastDistributedEpochId;
    uint256 public lastDistributionCAPPrice; // CAP price used for distribution (18 decimals)

    uint256 public totalRewardsDeclared;
    uint256 public totalRewardsClaimed;
    uint256 public dust; // Leftover BUCK from division rounding, carried into next distribution

    mapping(address => bool) public isRecoverySink;

    uint256 public maxTokensToMintPerEpoch; // Maximum BUCK tokens that can be minted in one epoch
    uint256 public currentEpochTokensMinted; // Tracks tokens minted in current epoch
    uint64 public lastMintEpochId; // Tracks which epoch we last minted in (for reset logic)

    // Breakage sink receives forfeited units (pre- and post-checkpoint). Always excluded from accrual.
    address public breakageSink;

    // Claim-time controls
    bool public enforceCROnClaim; // When true, revert claims that would push CR below 1.0
    uint256 public maxClaimTokensPerTx; // Optional per-transaction cap for claims (0 = unlimited)

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // Epoch & Checkpoint
    event EpochConfigured(
        uint64 indexed epochId,
        uint64 epochStart,
        uint64 epochEnd,
        uint64 checkpointStart,
        uint64 checkpointEnd
    );

    // Distribution
    event DistributionPriced(
        uint64 indexed epochId, uint256 couponUsdc, uint256 capPrice, uint256 tokensFromCoupon
    );
    event DistributionSkimCollected(
        uint64 indexed epochId, uint256 skimUsdc, uint16 skimBps, address indexed treasury
    );
    event DistributionDeclared(
        uint64 indexed epochId,
        uint256 tokensAllocated,
        uint256 denominatorUnits,
        uint256 globalEligibleUnits,
        uint256 treasuryBreakage,
        uint256 futureBreakage,
        uint256 deltaIndex,
        uint256 dustCarry,
        uint256 grossAPYBps,
        uint256 netAPYBps
    );

    // Claims
    event RewardClaimed(
        address indexed account,
        address indexed recipient,
        uint256 amount,
        uint64 fromEpoch,
        uint64 toEpoch
    );

    // Breakage
    event ProportionalBreakage(
        address indexed account,
        uint256 amountSold,
        uint256 unitsForfeit,
        uint64 indexed epochId
    );
    event FutureBreakage(
        address indexed account,
        uint256 amountSold,
        uint256 futureUnits,
        uint256 remainingSeconds,
        uint64 indexed epochId
    );

    // Admin
    event MinClaimUpdated(uint256 minClaimTokens);
    event TokenHookUpdated(address indexed token);
    event TreasuryUpdated(address indexed treasury);
    event PolicyManagerUpdated(address indexed policyManager);
    event AccountExcluded(address indexed account, bool isExcluded);
    event MaxTokensPerEpochUpdated(uint256 maxTokens);
    event DepegGuardUpdated(bool blocked);
    event RecoverySinkSet(address indexed sink, bool allowed);
    event TokensRecovered(
        address indexed caller, address indexed token, address indexed to, uint256 amount
    );
    event BreakageSinkUpdated(address indexed oldSink, address indexed newSink);
    event CROnClaimEnforcementUpdated(bool enabled);
    event MaxClaimPerTxUpdated(uint256 maxTokens);

    // -------------------------------------------------------------------------
    // Constructor & Initializer
    // -------------------------------------------------------------------------

    // Implementation constructor locks initialization; actual setup comes via proxy initializer.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Wire admin + distributor roles and baseline earning parameters.
    // Called once post deploy; recover sinks start with admin to keep rescue paths simple.
    function initialize(
        address admin,
        address distributor,
        uint256 minClaimTokens_
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __Multicall_init();
        __UUPSUpgradeable_init();

        if (admin == address(0)) revert InvalidConfig();
        if (distributor == address(0)) revert InvalidConfig();
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(DISTRIBUTOR_ROLE, distributor);

        minClaimTokens = minClaimTokens_;
        isRecoverySink[admin] = true;
        blockDistributeOnDepeg = true; // Default: block distributions during depeg for safety
    }

    // -------------------------------------------------------------------------
    // UUPS Upgrade Authorization
    // -------------------------------------------------------------------------

    // Only the admin role can approve new logic for this UUPS contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyToken() {
        if (msg.sender != token) revert NotToken();
        _;
    }

    // -------------------------------------------------------------------------
    // Admin configuration
    // -------------------------------------------------------------------------

    // Connect reserve + USDC token so we can validate distributions and pull skims.
    // Both addresses must be set before distribute() enforcement kicks in.
    function setReserveAddresses(address liquidityReserve_, address reserveUSDC_)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (liquidityReserve_ == address(0) || reserveUSDC_ == address(0)) revert ZeroAddress();
        liquidityReserve = liquidityReserve_;
        reserveUSDC = reserveUSDC_;
    }

    // Cap BUCK minted per epoch to throttle emissions if policy wants a hard ceiling.
    // Resets automatically when a new epoch id is configured.
    function setMaxTokensToMintPerEpoch(uint256 maxTokens) external onlyRole(ADMIN_ROLE) {
        if (maxTokens == 0) revert InvalidMaxTokensPerEpoch();
        maxTokensToMintPerEpoch = maxTokens;
        emit MaxTokensPerEpochUpdated(maxTokens);
    }

    // Adjust dust filter so tiny claims don't clog gas or event logs.
    // Can be tuned up or down without touching accrued units.
    function setMinClaimTokens(uint256 minClaimTokens_) external onlyRole(ADMIN_ROLE) {
        minClaimTokens = minClaimTokens_;
        emit MinClaimUpdated(minClaimTokens_);
    }

    // Toggle CR guard for claims (prevents CR dropping below 1 after mint)
    function setEnforceCROnClaim(bool enabled) external onlyRole(ADMIN_ROLE) {
        enforceCROnClaim = enabled;
        emit CROnClaimEnforcementUpdated(enabled);
    }

    // Configure a maximum claim size per transaction (0 disables the cap)
    function setMaxClaimTokensPerTx(uint256 maxTokens) external onlyRole(ADMIN_ROLE) {
        maxClaimTokensPerTx = maxTokens;
        emit MaxClaimPerTxUpdated(maxTokens);
    }

    // Whitelist addresses that may receive recovered tokens (treasury multisig, etc.).
    // Ensures rescue flows terminate in known good destinations only.
    function setRecoverySink(address sink, bool allowed) external onlyRole(ADMIN_ROLE) {
        if (sink == address(0)) revert ZeroAddress();
        isRecoverySink[sink] = allowed;
        emit RecoverySinkSet(sink, allowed);
    }

    // BUCK token registers here so only it can call onBalanceChange/mint.
    // Protects hooks from rogue contracts trying to spoof balance updates.
    function setToken(address token_) external onlyRole(ADMIN_ROLE) {
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;
        emit TokenHookUpdated(token_);
    }

    // Treasury receives coupon skim and can be rotated as governance matures.
    // Required for distribute() to successfully push skim via LiquidityReserve.
    function setTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Set the breakage sink address (always excluded from accrual)
    /// @dev Excludes the new sink in-place and adjusts eligible/excluded supply counters
    function setBreakageSink(address sink) external onlyRole(ADMIN_ROLE) {
        if (sink == address(0)) revert ZeroAddress();

        _accrueGlobal();
        // Ensure sink is settled before changing flags
        _settleAccount(sink);

        AccountState storage s = _accounts[sink];
        if (!s.excluded) {
            if (s.eligible && s.balance > 0) {
                if (currentEligibleSupply >= s.balance) {
                    currentEligibleSupply -= s.balance;
                } else {
                    currentEligibleSupply = 0;
                }
            }
            totalExcludedSupply += s.balance;
            s.excluded = true;
            s.eligible = false;
            // Reset units and rewardDebt to keep accounting invariant intact.
            s.unitsAccrued = 0;
            s.rewardDebt = 0;
            s.lastAccrualTime = _cappedTimestamp();
        }

        address old = breakageSink;
        breakageSink = sink;
        emit BreakageSinkUpdated(old, sink);
    }

    // Hard stop on new distributions during incidents.
    // Keeps coupons safely in reserve until the pause is lifted.
    function pauseDistribute() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    // Resume distributions after remediation.
    // Emits no event; rely on `pause()` logs for incident history.
    function unpauseDistribute() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Wire PolicyManager so we can read band/fees/haircuts in real time.
    // Safe to set to zero when testing since distribute() guards against null policy.
    function setPolicyManager(address policyManager_) external onlyRole(ADMIN_ROLE) {
        policyManager = policyManager_;
        emit PolicyManagerUpdated(policyManager_);
    }

    // Toggle depeg guard: when true, distribute() reverts if CAP price < $1.
    // Default is true for safety; governance can disable if needed during stress.
    function setBlockDistributeOnDepeg(bool blocked) external onlyRole(ADMIN_ROLE) {
        blockDistributeOnDepeg = blocked;
        emit DepegGuardUpdated(blocked);
    }

    // Configures a new epoch with checkpoint window for eligibility verification.
    // Checkpoint window (e.g., days 12-16): holders must NOT sell during this period to earn.
    // Late entries (after checkpointStart) are ineligible for this epoch.
    function configureEpoch(
        uint64 epochId,
        uint64 epochStart_,
        uint64 epochEnd_,
        uint64 checkpointStart_,
        uint64 checkpointEnd_
    ) external onlyRole(ADMIN_ROLE) {
        _configureEpochInternal(epochId, epochStart_, epochEnd_, checkpointStart_, checkpointEnd_);
    }

    function _configureEpochInternal(
        uint64 epochId,
        uint64 epochStart_,
        uint64 epochEnd_,
        uint64 checkpointStart_,
        uint64 checkpointEnd_
    ) internal {
        if (epochEnd_ <= epochStart_) revert InvalidConfig();
        if (epochId <= currentEpochId) revert InvalidConfig();
        if (checkpointStart_ <= epochStart_) revert InvalidConfig();
        if (checkpointEnd_ >= epochEnd_) revert InvalidConfig();
        if (checkpointEnd_ <= checkpointStart_) revert InvalidConfig();

        // Prevent configuring new epoch before distributing the current one
        // This ensures distribute() always applies to the intended epoch
        if (currentEpochId > 0 && !distributedThisEpoch) revert MustDistributeBeforeNewEpoch();

        currentEpochId = epochId;
        epochStart = epochStart_;
        epochEnd = epochEnd_;
        checkpointStart = checkpointStart_;
        checkpointEnd = checkpointEnd_;

        // Store epoch timing for settlement/analytics
        epochStartTime[epochId] = epochStart_;
        epochEndTime[epochId] = epochEnd_;

        // Reset global state for new epoch
        lastGlobalUpdateTime = epochStart_;
        globalEligibleUnits = 0;
        treasuryUnitsThisEpoch = 0;
        futureBreakageUnits = 0;
        distributedThisEpoch = false;

        // Eligible supply = total supply MINUS excluded accounts
        address token_ = token;
        if (token_ != address(0)) {
            currentEligibleSupply = IERC20(token_).totalSupply() - totalExcludedSupply;
        }

        emit EpochConfigured(epochId, epochStart_, epochEnd_, checkpointStart_, checkpointEnd_);
    }

    // Admin can exclude system wallets from earning (or re-include).
    // Updates eligible supply tracking to maintain global integrator accuracy.
    function setAccountExcluded(address account, bool isExcluded) external onlyRole(ADMIN_ROLE) {
        AccountState storage s = _accounts[account];

        // No change needed
        if (s.excluded == isExcluded) return;

        // Accrue global units before changing eligible supply
        _accrueGlobal();

        // Settle account's current units
        _settleAccount(account);

        if (isExcluded) {
            // Excluding: remove from eligible supply, add to excluded supply
            if (s.balance > 0 && s.eligible) {
                if (currentEligibleSupply >= s.balance) {
                    currentEligibleSupply -= s.balance;
                } else {
                    currentEligibleSupply = 0;
                }
            }
            totalExcludedSupply += s.balance;

            // Reset their units for this epoch (they don't earn when excluded)
            // Also reset rewardDebt to keep accounting invariant intact.
            s.unitsAccrued = 0;
            s.rewardDebt = 0;
            s.eligible = false;
        } else {
            // Re-including: remove from excluded supply
            if (totalExcludedSupply >= s.balance) {
                totalExcludedSupply -= s.balance;
            } else {
                totalExcludedSupply = 0;
            }

            // Apply late-entry rule: re-inclusions after checkpointStart don't earn this epoch
            uint64 now_ = _cappedTimestamp();
            bool isLateEntry = (checkpointStart > 0 && now_ >= checkpointStart && now_ < epochEnd);

            if (isLateEntry) {
                // Late re-inclusion: ineligible for current epoch, don't add to eligible supply
                s.eligible = false;
                s.lastAccrualTime = now_;
            } else if (s.balance > 0) {
                // Normal re-inclusion: add to eligible supply
                currentEligibleSupply += s.balance;
                s.eligible = true;
            }
        }

        s.excluded = isExcluded;
        s.lastAccrualTime = _cappedTimestamp();

        emit AccountExcluded(account, isExcluded);
    }

    // -------------------------------------------------------------------------
    // Token hook entrypoint
    // -------------------------------------------------------------------------

    // Token hook: BUCK calls this on transfer to keep balance-time units synced.
    // Handles mint/burn/transfer with minimal assumptions about caller.
    function onBalanceChange(address from, address to, uint256 amount) external onlyToken {
        // Skip self-transfers - no economic change, prevents breakage inflation griefing
        if (from == to) return;

        // Do not accrue for the RewardsEngine contract itself, but still process the counterparty
        if (from != address(0) && from != address(this)) {
            _handleOutflow(from, amount);
        }

        if (to != address(0) && to != address(this)) {
            _handleInflow(to, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Reward distribution
    // -------------------------------------------------------------------------

    // Core coupon handler: validates reserve deposits, applies skim, calculates reward per unit.
    // ONE distribution per epoch - stores epochReport with deltaIndex for claim logic.
    function distribute(uint256 couponUsdcAmount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        whenNotPaused
        returns (uint256 allocated, uint256 newDust)
    {
        // Ensure band-dependent config (e.g., distributionSkimBps) is current
        if (policyManager != address(0)) {
            IPolicyBandRefresh(policyManager).refreshBand();

            // Depeg guard: block distributions when CAP < $1 to prevent solvency degradation
            // Can be toggled off by admin if governance needs to distribute during stress
            if (blockDistributeOnDepeg) {
                uint256 depegCheckPrice = IPolicyDistributionConfig(policyManager).getCAPPrice();
                if (depegCheckPrice < 1e18) revert DistributionBlockedDuringDepeg(depegCheckPrice);
            }
        }
        // Enforce one distribution per epoch
        if (distributedThisEpoch) revert AlreadyDistributed();

        // Ensure epoch is configured before distributing
        if (epochEnd == 0) revert EpochNotConfigured();

        // Ensure we're at or past epoch end (prevents mid-epoch distribution)
        if (block.timestamp < epochEnd) revert DistributionTooEarly();

        // Security: Pull USDC directly from distributor to prove funds deposited
        if (liquidityReserve == address(0) || reserveUSDC == address(0)) {
            revert InvalidConfig();
        }

        // Transfer coupon USDC from caller to reserve
        IERC20(reserveUSDC).safeTransferFrom(msg.sender, liquidityReserve, couponUsdcAmount);

        // Apply distribution skim fee before calculating BUCK allocation
        uint256 netCouponUsdc = couponUsdcAmount;
        uint256 skimUsdc = 0;
        uint16 skimBps = 0;
        {
            address policy = policyManager;
            if (policy != address(0)) {
                IPolicyDistributionConfig config = IPolicyDistributionConfig(policy);
                skimBps = config.getDistributionSkimBps();

                if (skimBps > 0 && treasury != address(0) && liquidityReserve != address(0)) {
                    skimUsdc = Math.mulDiv(couponUsdcAmount, skimBps, BPS_DENOMINATOR);
                    netCouponUsdc = couponUsdcAmount - skimUsdc;
                }
            }
        }

        // Finalize global units up to epoch end (or now if mid-epoch)
        _accrueGlobal();

        // CAP pricing: $1 when CR ≥ 1, else max(oracle, CR)
        uint256 tokensFromCoupon;
        uint256 capPrice;
        {
            address policy = policyManager;
            if (policy == address(0)) revert InvalidConfig();
            IPolicyDistributionConfig config = IPolicyDistributionConfig(policy);

            // Withdraw skim BEFORE getCAPPrice so CR calculation sees correct reserve balance
            if (skimUsdc > 0) {
                ILiquidityReserve(liquidityReserve).withdrawDistributionSkim(treasury, skimUsdc);
                emit DistributionSkimCollected(currentEpochId, skimUsdc, skimBps, treasury);
            }

            capPrice = config.getCAPPrice();
            if (capPrice == 0) revert InvalidOraclePrice();

            if (netCouponUsdc > type(uint256).max / USDC_TO_18) revert InvalidAmount();
            uint256 scaledCoupon = netCouponUsdc * USDC_TO_18;
            tokensFromCoupon = Math.mulDiv(scaledCoupon, PRICE_SCALE, capPrice);

            emit DistributionPriced(currentEpochId, couponUsdcAmount, capPrice, tokensFromCoupon);
            lastDistributionCAPPrice = capPrice;
        }

        // Check if we need to reset epoch counter (new epoch)
        if (lastMintEpochId != currentEpochId) {
            currentEpochTokensMinted = 0;
            lastMintEpochId = currentEpochId;
        }

        // Enforce max tokens per epoch if configured
        uint256 totalReward = tokensFromCoupon + dust;
        if (maxTokensToMintPerEpoch > 0) {
            if (currentEpochTokensMinted + totalReward > maxTokensToMintPerEpoch) {
                revert MaxTokensPerEpochExceeded(
                    currentEpochTokensMinted + totalReward, maxTokensToMintPerEpoch
                );
            }
        }

        if (totalReward == 0) revert NothingToDistribute();

        // Calculate total units: eligible holders + treasury breakage + future breakage
        uint256 totalUnits = globalEligibleUnits + treasuryUnitsThisEpoch + futureBreakageUnits;

        // Calculate APY metrics for event emission
        uint256 grossAPYBps = 0;
        uint256 netAPYBps = 0;
        {
            uint256 totalSupply = IERC20(token).totalSupply();
            if (totalSupply > 0 && capPrice > 0 && couponUsdcAmount > 0) {
                uint256 epochDurationSeconds = epochEnd > epochStart ? epochEnd - epochStart : 30 days;
                if (epochDurationSeconds < 1 days) epochDurationSeconds = 30 days;

                uint256 totalSupplyValueUSD = Math.mulDiv(totalSupply, capPrice, PRICE_SCALE);
                if (totalSupplyValueUSD > 0) {
                    // Calculate APY in single step to preserve precision
                    // Old approach lost precision: returnBps truncates (e.g., 1.9 → 1), then *365 = 365 instead of ~700
                    // New approach: (coupon * BPS * 365days) / (supplyValue * epochDuration) preserves precision
                    uint256 denominatorScaled = totalSupplyValueUSD * epochDurationSeconds;

                    uint256 grossCouponScaled = couponUsdcAmount * USDC_TO_18;
                    grossAPYBps = Math.mulDiv(grossCouponScaled * 365 days, BPS_DENOMINATOR, denominatorScaled);

                    uint256 netCouponScaled = netCouponUsdc * USDC_TO_18;
                    netAPYBps = Math.mulDiv(netCouponScaled * 365 days, BPS_DENOMINATOR, denominatorScaled);
                }
            }
        }

    // Calculate reward per unit and store epoch report for settlement/analytics
    uint256 rewardPerUnitStored;
    if (totalUnits > 0) {
        rewardPerUnitStored = Math.mulDiv(totalReward, ACC_PRECISION, totalUnits);
        allocated = Math.mulDiv(totalUnits, rewardPerUnitStored, ACC_PRECISION);
        newDust = totalReward - allocated;
    } else {
        // No eligible units - carry forward as dust
        rewardPerUnitStored = 0;
        allocated = 0;
        newDust = totalReward;
    }

        // Auto-mint protocol breakage share to the breakage sink (always excluded from accrual)
        if (rewardPerUnitStored > 0) {
            uint256 sinkUnits = treasuryUnitsThisEpoch + futureBreakageUnits;
            if (sinkUnits > 0) {
                uint256 sinkShare = Math.mulDiv(sinkUnits, rewardPerUnitStored, ACC_PRECISION);
                address sinkAddr = breakageSink != address(0) ? breakageSink : treasury;
                if (sinkAddr != address(0) && sinkShare > 0) {
                    _mintRewards(sinkAddr, sinkShare);
                    totalRewardsClaimed += sinkShare;
                    emit RewardClaimed(sinkAddr, sinkAddr, sinkShare, currentEpochId, currentEpochId);
                }
            }
        }

    // Update global cumulative index used for O(1) claims.
    accRewardPerUnit += rewardPerUnitStored;

    // Store epoch report for analytics and epoch-boundary finalization
    // Use capped timestamp so late distributions still cap accrual at epochEnd
    epochReport[currentEpochId] = EpochReport({
        distributionTime: _cappedTimestamp(),
        denominatorUnits: totalUnits,
        deltaIndex: rewardPerUnitStored,
        tokensAllocated: allocated,
        dustCarry: newDust
    });

        // Update state
        dust = newDust;
        totalRewardsDeclared += allocated;
        distributedThisEpoch = true;

        // Update epoch minting counter
        if (maxTokensToMintPerEpoch > 0) {
            currentEpochTokensMinted += allocated;
        }

        lastDistributedEpochId = currentEpochId;

        emit DistributionDeclared(
            currentEpochId,
            allocated,
            totalUnits,
            globalEligibleUnits,
            treasuryUnitsThisEpoch,
            futureBreakageUnits,
            rewardPerUnitStored,
            newDust,
            grossAPYBps,
            netAPYBps
        );

        // Reset current-epoch integrators after distribution.
        // The values have been captured in epochReport and emitted; reset for cleanliness
        // (configureEpoch will also reset when the next epoch starts)
        globalEligibleUnits = 0;
        treasuryUnitsThisEpoch = 0;
        futureBreakageUnits = 0;

        return (allocated, newDust);
    }

    // Users claim rewards using O(1) logic:
    // - Prior epoch rewards are lazily credited to pendingRewards during settlement across epoch boundaries
    // - Current epoch accrual is converted via accRewardPerUnit index minus rewardDebt baseline
    // Claim = pendingRewards + (unitsAccrued * accIndex - rewardDebt).
    function claim(address recipient) external returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidRecipient();

        AccountState storage s = _accounts[msg.sender];

        // Settle first to:
        // - Accrue current-epoch units to now (capped)
        // - Lazily credit prior epoch rewards into pendingRewards when crossing epoch boundary
        _settleAccount(msg.sender);

        uint64 endEpoch = lastDistributedEpochId;
        if (endEpoch == 0) revert NoRewardsDeclared();

        // Compute total claimable amount.
        // pendingRewards = finalized prior epochs (credited at epoch boundaries)
        // Current epoch contribution = unitsAccrued * accRewardPerUnit - rewardDebt
        amount = s.pendingRewards;
        if (s.unitsAccrued > 0 && accRewardPerUnit > 0) {
            uint256 currentEpochReward = Math.mulDiv(s.unitsAccrued, accRewardPerUnit, ACC_PRECISION);
            if (currentEpochReward > s.rewardDebt) {
                amount += currentEpochReward - s.rewardDebt;
            }
        }

        if (amount < minClaimTokens) revert ClaimTooSmall(amount, minClaimTokens);

        // Optional per-transaction cap
        if (maxClaimTokensPerTx > 0 && amount > maxClaimTokensPerTx) {
            revert MaxClaimPerTxExceeded(amount, maxClaimTokensPerTx);
        }

        // Optional CR headroom guard
        if (enforceCROnClaim) {
            address pm = policyManager;
            if (pm == address(0)) revert InvalidConfig();
            address att = IPolicyAttestationRef(pm).collateralAttestation();
            if (att == address(0)) revert InvalidConfig();

            // Require fresh attestation data for solvency decisions
            if (ICollateralAttestationView(att).isAttestationStale()) revert StaleAttestationForClaim();

            uint256 cr = ICollateralAttestationView(att).getCollateralRatio(); // 18 decimals
            uint256 L = IERC20(token).totalSupply();
            // capSupply = floor(L * cr / 1e18)
            uint256 capSupply = Math.mulDiv(L, cr, ACC_PRECISION);
            uint256 headroom = capSupply > L ? capSupply - L : 0;
            if (amount > headroom) {
                revert ClaimExceedsHeadroom(amount, headroom);
            }
        }

        // Update state - reset all accumulators
        uint64 fromEpoch = s.lastClaimedEpoch + 1;
        s.lastClaimedEpoch = endEpoch;
        s.pendingRewards = 0;
        s.unitsAccrued = 0;
        s.rewardDebt = 0;

        totalRewardsClaimed += amount;

        _mintRewards(recipient, amount);
        emit RewardClaimed(msg.sender, recipient, amount, fromEpoch, endEpoch);
    }

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    /// @notice Calculate pending rewards for an account
    /// @dev O(1): Simulates settle to now and computes pendingRewards + (unitsAccrued * accIndex - rewardDebt)
    /// Full formula includes both finalized prior epochs and current epoch accrual.
    function pendingRewards(address account) external view returns (uint256 reward) {
        AccountState storage s = _accounts[account];
        if (s.excluded) return 0;

        // Start with already-finalized prior epoch rewards
        reward = s.pendingRewards;

        // Simulate epoch-boundary finalization if needed
        uint256 simulatedUnits = s.unitsAccrued;
        uint256 simulatedDebt = s.rewardDebt;
        uint64 simulatedEpoch = s.lastAccruedEpoch;
        uint64 simulatedLastAccrualTime = s.lastAccrualTime;

        // If crossing epoch boundary, simulate finalization
        if (simulatedEpoch > 0 && simulatedEpoch < currentEpochId) {
            EpochReport storage report = epochReport[simulatedEpoch];

            // Calculate earning balance for the prior epoch being finalized
            uint256 priorEpochEarning = s.balance;
            if (s.lateInflowEpoch == simulatedEpoch && s.lateInflow > 0) {
                priorEpochEarning = priorEpochEarning > s.lateInflow ? priorEpochEarning - s.lateInflow : 0;
            }

            // Accrue remaining time in prior epoch up to distribution time (not epoch end)
            if (s.eligible && priorEpochEarning > 0 && report.distributionTime > 0) {
                if (simulatedLastAccrualTime < report.distributionTime) {
                    uint256 remainingElapsed = uint256(report.distributionTime - simulatedLastAccrualTime);
                    simulatedUnits += priorEpochEarning * remainingElapsed;
                }
            }

            // Finalize prior epoch
            if (report.deltaIndex > 0 && simulatedUnits > 0) {
                reward += Math.mulDiv(simulatedUnits, report.deltaIndex, ACC_PRECISION);
            }

            // Handle multi-epoch gaps (use distributionTime - epochStart, not full duration)
            uint64 nextEpoch = simulatedEpoch + 1;
            while (nextEpoch < currentEpochId) {
                EpochReport storage gapReport = epochReport[nextEpoch];
                // Calculate earning balance for this gap epoch
                uint256 gapEarning = s.balance;
                if (s.lateInflowEpoch == nextEpoch && s.lateInflow > 0) {
                    gapEarning = gapEarning > s.lateInflow ? gapEarning - s.lateInflow : 0;
                }
                if (gapReport.deltaIndex > 0 && gapEarning > 0 && gapReport.distributionTime > 0) {
                    uint64 gapStart = epochStartTime[nextEpoch];
                    if (gapReport.distributionTime > gapStart) {
                        uint256 gapUnits = gapEarning * uint256(gapReport.distributionTime - gapStart);
                        reward += Math.mulDiv(gapUnits, gapReport.deltaIndex, ACC_PRECISION);
                    }
                }
                nextEpoch++;
            }

            // Reset simulated accumulators for current epoch
            simulatedUnits = 0;
            simulatedDebt = 0;
            simulatedLastAccrualTime = epochStartTime[currentEpochId];
            // After epoch boundary, simulate from current epoch start
            simulatedEpoch = currentEpochId;
        }

        // Calculate earning balance for current epoch
        // Late inflows don't earn until the next checkpoint
        uint256 currentEarning = s.balance;
        if (s.lateInflowEpoch == currentEpochId && s.lateInflow > 0) {
            currentEarning = currentEarning > s.lateInflow ? currentEarning - s.lateInflow : 0;
        }

        // Simulate current-epoch accrual to now
        // After epoch rollover, start from the appropriate point
        uint64 now_ = _cappedTimestamp();
        uint64 accrualStart = simulatedLastAccrualTime;

        // After epoch boundary crossing, eligibility resets (fresh each epoch)
        // Also handle the case where user crossed boundary
        bool simulatedEligible = s.eligible;
        if (s.lastAccruedEpoch > 0 && s.lastAccruedEpoch < currentEpochId && !s.excluded) {
            simulatedEligible = true; // Fresh eligibility each epoch
            uint64 epochStartCurrent = epochStartTime[currentEpochId];
            if (epochStartCurrent > accrualStart) {
                accrualStart = epochStartCurrent;
            }
        }

        // If distribution happened since accrualStart, split the simulation.
        if (distributedThisEpoch && simulatedEligible && currentEarning > 0 && now_ > accrualStart) {
            EpochReport storage currentReport = epochReport[currentEpochId];
            if (currentReport.distributionTime > 0 && accrualStart < currentReport.distributionTime) {
                // Simulate pre-distribution accrual (finalized at deltaIndex)
                uint256 preDistElapsed = uint256(currentReport.distributionTime - accrualStart);
                uint256 preDistUnits = currentEarning * preDistElapsed;
                if (preDistUnits > 0 && currentReport.deltaIndex > 0) {
                    reward += Math.mulDiv(preDistUnits, currentReport.deltaIndex, ACC_PRECISION);
                }

                // Simulate post-distribution accrual
                if (now_ > currentReport.distributionTime) {
                    uint256 postDistElapsed = uint256(now_ - currentReport.distributionTime);
                    uint256 postDistUnits = currentEarning * postDistElapsed;
                    simulatedUnits += postDistUnits;
                    simulatedDebt += Math.mulDiv(postDistUnits, accRewardPerUnit, ACC_PRECISION);
                }
            } else if (now_ > accrualStart) {
                // No distribution crossing, normal accrual
                uint256 elapsed = uint256(now_ - accrualStart);
                uint256 deltaUnits = currentEarning * elapsed;
                simulatedUnits += deltaUnits;
                simulatedDebt += Math.mulDiv(deltaUnits, accRewardPerUnit, ACC_PRECISION);
            }
        } else if (now_ > accrualStart && simulatedEligible && currentEarning > 0) {
            uint256 elapsed = uint256(now_ - accrualStart);
            uint256 deltaUnits = currentEarning * elapsed;
            simulatedUnits += deltaUnits;
            simulatedDebt += Math.mulDiv(deltaUnits, accRewardPerUnit, ACC_PRECISION);
        }

        // Add current epoch contribution: unitsAccrued * accIndex - rewardDebt
        if (simulatedUnits > 0 && accRewardPerUnit > 0) {
            uint256 currentEpochReward = Math.mulDiv(simulatedUnits, accRewardPerUnit, ACC_PRECISION);
            if (currentEpochReward > simulatedDebt) {
                reward += currentEpochReward - simulatedDebt;
            }
        }
    }

    /// @notice Get accrued units for current epoch (before distribution)
    /// @dev Useful to see time-weighted participation before rewards are calculated
    function accruedUnitsThisEpoch(address account) external view returns (uint256 units) {
        AccountState storage s = _accounts[account];
        if (s.excluded || !s.eligible) return 0;

        units = s.unitsAccrued;

        // Calculate earning balance (exclude late inflows)
        uint256 earningBalance = s.balance;
        if (s.lateInflowEpoch == currentEpochId && s.lateInflow > 0) {
            earningBalance = earningBalance > s.lateInflow ? earningBalance - s.lateInflow : 0;
        }

        // Simulate accrual to current time
        uint64 now_ = _cappedTimestamp();
        if (now_ > s.lastAccrualTime && earningBalance > 0) {
            units += earningBalance * uint256(now_ - s.lastAccrualTime);
        }
    }

    /// @notice Get full account state for UI/debugging
    function getAccountFullState(address account)
        external
        view
        returns (
            uint256 balance,
            uint64 lastClaimedEpoch,
            uint64 lastAccrualTime,
            uint64 lastInflow,
            uint256 unitsAccrued,
            bool excluded,
            bool eligible
        )
    {
        AccountState storage s = _accounts[account];
        return (
            s.balance,
            s.lastClaimedEpoch,
            s.lastAccrualTime,
            s.lastInflow,
            s.unitsAccrued,
            s.excluded,
            s.eligible
        );
    }

    /// @notice Get checkpoint eligibility status for an account
    function getEligibilityStatus(address account)
        external
        view
        returns (
            bool isEligible,
            bool isExcluded,
            bool isLateEntry,
            uint64 checkpointStart_,
            uint64 checkpointEnd_
        )
    {
        AccountState storage s = _accounts[account];
        isEligible = s.eligible && !s.excluded;
        isExcluded = s.excluded;
        // Late entry if lastInflow is after checkpoint start
        isLateEntry = s.lastInflow >= checkpointStart && checkpointStart > 0;
        checkpointStart_ = checkpointStart;
        checkpointEnd_ = checkpointEnd;
    }

    /// @notice Compact checkpoint status for an account
    /// @dev hasFailedThisEpoch reflects late entry (ineligible due to buying after checkpointStart).
    ///      Pre-checkpoint partial sells do not mark failure in the proportional-breakage model.
    function getCheckpointStatus(address account)
        external
        view
        returns (
            bool isEligible_,
            bool hasFailedThisEpoch,
            bool canEarnThisEpoch
        )
    {
        AccountState storage s = _accounts[account];
        uint64 now_ = _cappedTimestamp();
        bool withinEpoch = (epochEnd == 0 ? false : now_ < epochEnd);
        isEligible_ = s.eligible && !s.excluded;
        bool lateWindow = (checkpointStart > 0 && now_ >= checkpointStart && now_ < epochEnd);
        // Failure here represents late entry only (not pre-checkpoint sells in proportional model)
        hasFailedThisEpoch = (!s.eligible && lateWindow);
        canEarnThisEpoch = isEligible_ && withinEpoch;
    }

    /// @notice Get current epoch info
    function getEpochInfo()
        external
        view
        returns (
            uint64 epochId,
            uint64 start,
            uint64 end,
            uint64 checkpointStart_,
            uint64 checkpointEnd_,
            bool distributed
        )
    {
        return (
            currentEpochId,
            epochStart,
            epochEnd,
            checkpointStart,
            checkpointEnd,
            distributedThisEpoch
        );
    }

    /// @notice Get the active checkpoint window for the current epoch
    function getCheckpointWindow()
        external
        view
        returns (uint64 start, uint64 end, uint64 epochId)
    {
        return (checkpointStart, checkpointEnd, currentEpochId);
    }

    /// @notice Get global integrator state for debugging
    function getGlobalState()
        external
        view
        returns (
            uint256 eligibleUnits,
            uint256 eligibleSupply,
            uint256 treasuryBreakage,
            uint256 futureBreakage,
            uint256 totalBreakage,
            uint64 lastUpdateTime
        )
    {
        return (
            globalEligibleUnits,
            currentEligibleSupply,
            treasuryUnitsThisEpoch,
            futureBreakageUnits,
            totalBreakageAllTime,
            lastGlobalUpdateTime
        );
    }

    /// @notice Get epoch report for analytics
    /// @param epochId The epoch to query
    /// @return distributionTime Timestamp when distribute() was called
    /// @return denominatorUnits Total units used as denominator (eligible + breakage)
    /// @return deltaIndex Reward per unit for this epoch (scaled by ACC_PRECISION)
    /// @return tokensAllocated Total tokens allocated this epoch
    /// @return dustCarry Dust carried forward from this distribution
    function getEpochReport(uint64 epochId)
        external
        view
        returns (
            uint64 distributionTime,
            uint256 denominatorUnits,
            uint256 deltaIndex,
            uint256 tokensAllocated,
            uint256 dustCarry
        )
    {
        EpochReport storage report = epochReport[epochId];
        return (
            report.distributionTime,
            report.denominatorUnits,
            report.deltaIndex,
            report.tokensAllocated,
            report.dustCarry
        );
    }

    // -------------------------------------------------------------------------
    // Internal logic
    // -------------------------------------------------------------------------

    /// @notice Returns current timestamp capped to epoch boundaries
    /// @dev Ensures accrual calculations stay within epoch bounds
    function _cappedTimestamp() internal view returns (uint64) {
        uint64 now_ = uint64(block.timestamp);

        // No epoch configured - return current time
        if (epochEnd == 0) {
            return now_;
        }

        // Before epoch start - return epoch start
        if (now_ < epochStart) {
            return epochStart;
        }

        // After epoch end - return epoch end
        if (now_ > epochEnd) {
            return epochEnd;
        }

        return now_;
    }

    /// @notice Accrues global eligible units up to current (capped) time
    /// @dev Must be called before any operation that changes eligible supply
    function _accrueGlobal() internal {
        uint64 now_ = _cappedTimestamp();

        // Skip if no time has elapsed or epoch not started
        if (now_ <= lastGlobalUpdateTime || lastGlobalUpdateTime == 0) {
            return;
        }

        uint256 elapsed = uint256(now_ - lastGlobalUpdateTime);

        // Accumulate: eligible supply * seconds elapsed
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }

        lastGlobalUpdateTime = now_;
    }

    // Processes balance decreases (transfers out/redemptions) after settling accrual.
    // Keeps units accurate even when balances bounce rapidly within a block.
    function _handleOutflow(address account, uint256 amount) internal {
        if (amount == 0) return;

        // Accrue global units first (order matters!)
        _accrueGlobal();

        // Settle account's units up to now
        _settleAccount(account);

        AccountState storage s = _accounts[account];

        uint256 balance = s.balance;
        if (balance < amount) revert BalanceUnderflow();

        // Calculate how much comes from late inflow vs earning balance
        // Sell non-earning tokens (lateInflow) first to preserve earning balance
        uint256 fromLateInflow = 0;
        if (s.lateInflowEpoch == currentEpochId && s.lateInflow > 0) {
            fromLateInflow = amount > s.lateInflow ? s.lateInflow : amount;
            s.lateInflow -= fromLateInflow;
        }
        uint256 fromEarning = amount - fromLateInflow;

        // Update eligible supply only for the earning portion
        // (lateInflow was never added to eligibleSupply, so don't double-subtract)
        if (fromEarning > 0 && !s.excluded && s.eligible) {
            if (currentEligibleSupply >= fromEarning) {
                currentEligibleSupply -= fromEarning;
            } else {
                currentEligibleSupply = 0; // Safety check
            }
        }

        // Update totalExcludedSupply for excluded accounts
        // Keeps excluded supply in sync with actual excluded balances
        if (s.excluded) {
            if (totalExcludedSupply >= amount) {
                totalExcludedSupply -= amount;
            } else {
                totalExcludedSupply = 0;
            }
        }

        // Breakage logic (only applies to earning portion).
        // - Pre-checkpoint: forfeit (fromEarning/earningBalance) of CURRENT-EPOCH accrued units to treasury
        // - Post-checkpoint: capture remaining days as future breakage (fromEarning * (epochEnd - now))
        {
            uint64 now_ = _cappedTimestamp();
            // Calculate earning balance for breakage denominator
            uint256 earningBalance = balance;
            if (s.lateInflowEpoch == currentEpochId) {
                // Note: lateInflow was already reduced above, so add fromLateInflow back for accurate calculation
                uint256 originalLateInflow = s.lateInflow + fromLateInflow;
                earningBalance = earningBalance > originalLateInflow ? earningBalance - originalLateInflow : 0;
            }

            if (
                now_ >= epochStart && now_ < checkpointEnd && s.eligible && !s.excluded && earningBalance > 0 && fromEarning > 0
            ) {
                // Proportional forfeit of current-epoch units based on earning portion sold
                uint256 forfeitedUnits = Math.mulDiv(s.unitsAccrued, fromEarning, earningBalance);
                if (forfeitedUnits > 0) {
                    if (forfeitedUnits > s.unitsAccrued) {
                        forfeitedUnits = s.unitsAccrued; // safety cap
                    }
                    s.unitsAccrued -= forfeitedUnits;
                    treasuryUnitsThisEpoch += forfeitedUnits;
                    totalBreakageAllTime += forfeitedUnits;

                    // Scale rewardDebt proportionally to removed units.
                    // This maintains the invariant: pending = unitsAccrued * accIndex - rewardDebt
                    uint256 forfeitedDebt = Math.mulDiv(s.rewardDebt, fromEarning, earningBalance);
                    if (forfeitedDebt > s.rewardDebt) {
                        forfeitedDebt = s.rewardDebt; // safety cap
                    }
                    s.rewardDebt -= forfeitedDebt;

                    emit ProportionalBreakage(account, fromEarning, forfeitedUnits, currentEpochId);
                }
            } else if (now_ >= checkpointEnd && now_ < epochEnd && s.eligible && !s.excluded && fromEarning > 0) {
                // Future breakage: DAO captures remaining days for the earning portion sold
                uint256 remainingSeconds = uint256(epochEnd - now_);
                if (remainingSeconds > 0) {
                    uint256 futureUnits = fromEarning * remainingSeconds;
                    futureBreakageUnits += futureUnits;
                    totalBreakageAllTime += futureUnits;
                    emit FutureBreakage(account, fromEarning, futureUnits, remainingSeconds, currentEpochId);
                }
            }
        }

        s.balance = balance - amount;
    }

    // Processes balance increases (transfers in/mints) after settling accrual.
    // Records a fresh inflow timestamp for telemetry (not used for eligibility).
    function _handleInflow(address account, uint256 amount) internal {
        if (amount == 0) return;

        // Accrue global units first (order matters!)
        _accrueGlobal();

        // Settle account's units up to now
        _settleAccount(account);

        AccountState storage s = _accounts[account];

        // Track inflow timing for telemetry ("when did this account last receive tokens")
        // Note: Eligibility is determined by block.timestamp at inflow, not this stored value
        s.lastInflow = uint64(block.timestamp);

        uint64 now_ = _cappedTimestamp();

        // Late entry rule: inflows at/after checkpointStart do not earn this epoch
        bool isLateEntry = (checkpointStart > 0 && now_ >= checkpointStart && now_ < epochEnd);

        // Update balance
        s.balance += amount;

        if (isLateEntry) {
            // Track late inflows instead of disqualifying
            // These tokens don't earn until the next checkpoint
            // Lazy reset: if this is a new epoch, reset lateInflow
            if (s.lateInflowEpoch != currentEpochId) {
                s.lateInflow = 0;
                s.lateInflowEpoch = currentEpochId;
            }
            s.lateInflow += amount;
            // Do NOT add to currentEligibleSupply - these tokens can't earn this epoch
            // But still mark eligible so they can earn on their pre-checkpoint balance
            if (!s.excluded && !s.eligible) {
                s.eligible = true;
            }
        } else {
            // Normal inflow before checkpoint - add to eligible supply
            if (!s.excluded) {
                s.eligible = true;
                currentEligibleSupply += amount;
            }
        }

        // Update totalExcludedSupply for excluded accounts
        // Keeps excluded supply in sync with actual excluded balances
        if (s.excluded) {
            totalExcludedSupply += amount;
        }
    }

    /// @notice Settles an account's accrued units up to current (capped) time
    /// @dev Called before any balance change to ensure accurate unit tracking
    /// @dev Uses epoch-boundary finalization instead of per-epoch reconstruction.
    ///      - At epoch boundary: credit unitsAccrued * deltaIndex to pendingRewards, reset accumulators
    ///      - This ensures units are finalized at the exact values tracked during the epoch
    function _settleAccount(address account) internal {
        AccountState storage s = _accounts[account];
        uint64 now_ = _cappedTimestamp();

        // Excluded accounts don't accrue
        if (s.excluded) {
            s.lastAccrualTime = now_;
            return;
        }

        // Initialize epoch tracking on first touch
        if (s.lastAccruedEpoch == 0 && currentEpochId > 0) {
            s.lastAccruedEpoch = currentEpochId;
            if (s.lastAccrualTime == 0) {
                s.lastAccrualTime = epochStart > 0 ? epochStart : now_;
            }
            s.eligible = true;
        }

        // Epoch-boundary finalization.
        // If crossing into a new epoch, finalize prior epoch(s) using epochReport.deltaIndex
        if (s.lastAccruedEpoch > 0 && s.lastAccruedEpoch < currentEpochId) {
            EpochReport storage report = epochReport[s.lastAccruedEpoch];

            // Calculate earning balance for the epoch being finalized
            // Late inflows don't earn until the next checkpoint
            uint256 priorEpochEarning = s.balance;
            if (s.lateInflowEpoch == s.lastAccruedEpoch && s.lateInflow > 0) {
                priorEpochEarning = priorEpochEarning > s.lateInflow ? priorEpochEarning - s.lateInflow : 0;
            }

            // Accrue remaining time in prior epoch up to distribution time (not epoch end)
            // Post-distribution time in the prior epoch earns nothing (only one distribution per epoch)
            if (s.eligible && priorEpochEarning > 0 && report.distributionTime > 0) {
                if (s.lastAccrualTime < report.distributionTime) {
                    // User has time before distribution - accrue up to distribution
                    uint256 remainingElapsed = uint256(report.distributionTime - s.lastAccrualTime);
                    s.unitsAccrued += priorEpochEarning * remainingElapsed;
                }
                // Time after distribution in the prior epoch earns nothing
            }

            // Finalize the prior epoch: credit unitsAccrued at that epoch's deltaIndex
            if (report.deltaIndex > 0 && s.unitsAccrued > 0) {
                s.pendingRewards += Math.mulDiv(s.unitsAccrued, report.deltaIndex, ACC_PRECISION);
            }

            // Handle multi-epoch gaps (rare: user inactive for multiple epochs)
            // For completely missed epochs, use earning balance * (distributionTime - epochStart)
            uint64 nextEpoch = s.lastAccruedEpoch + 1;
            while (nextEpoch < currentEpochId) {
                EpochReport storage gapReport = epochReport[nextEpoch];
                // Calculate earning balance for this gap epoch
                uint256 gapEarning = s.balance;
                if (s.lateInflowEpoch == nextEpoch && s.lateInflow > 0) {
                    gapEarning = gapEarning > s.lateInflow ? gapEarning - s.lateInflow : 0;
                }
                if (gapReport.deltaIndex > 0 && gapEarning > 0 && gapReport.distributionTime > 0) {
                    uint64 gapStart = epochStartTime[nextEpoch];
                    // Only count time up to distribution (post-distribution earns nothing)
                    if (gapReport.distributionTime > gapStart) {
                        uint256 gapUnits = gapEarning * uint256(gapReport.distributionTime - gapStart);
                        s.pendingRewards += Math.mulDiv(gapUnits, gapReport.deltaIndex, ACC_PRECISION);
                    }
                }
                nextEpoch++;
            }

            // Reset accumulators for the new epoch
            s.unitsAccrued = 0;
            s.rewardDebt = 0;
            s.lastAccruedEpoch = currentEpochId;
            s.lastAccrualTime = epochStart > 0 ? epochStart : now_;
            s.eligible = true;  // Fresh eligibility each epoch
        }

        // Calculate elapsed time since last accrual
        if (now_ <= s.lastAccrualTime) {
            return;  // No time elapsed
        }

        // Calculate earning balance for current epoch
        // Late inflows don't earn until the next checkpoint
        uint256 currentEarning = s.balance;
        if (s.lateInflowEpoch == currentEpochId && s.lateInflow > 0) {
            currentEarning = currentEarning > s.lateInflow ? currentEarning - s.lateInflow : 0;
        }

        // If distribution happened since lastAccrualTime, split the accrual.
        // Pre-distribution units get finalized at deltaIndex; post-distribution units use rewardDebt
        if (distributedThisEpoch && s.eligible && currentEarning > 0) {
            EpochReport storage currentReport = epochReport[currentEpochId];
            if (currentReport.distributionTime > 0 && s.lastAccrualTime < currentReport.distributionTime) {
                // Accrue units from lastAccrualTime to distributionTime
                uint256 preDistElapsed = uint256(currentReport.distributionTime - s.lastAccrualTime);
                uint256 preDistUnits = currentEarning * preDistElapsed;

                // Finalize pre-distribution units at deltaIndex (no rewardDebt - index was 0)
                if (preDistUnits > 0 && currentReport.deltaIndex > 0) {
                    s.pendingRewards += Math.mulDiv(preDistUnits, currentReport.deltaIndex, ACC_PRECISION);
                }

                // Now accrue post-distribution units (from distributionTime to now)
                if (now_ > currentReport.distributionTime) {
                    uint256 postDistElapsed = uint256(now_ - currentReport.distributionTime);
                    uint256 postDistUnits = currentEarning * postDistElapsed;
                    s.unitsAccrued += postDistUnits;
                    s.rewardDebt += Math.mulDiv(postDistUnits, accRewardPerUnit, ACC_PRECISION);
                }

                s.lastAccrualTime = now_;
                return;
            }
        }

        uint256 elapsed = uint256(now_ - s.lastAccrualTime);

        // Accrue current-epoch units: earning balance * elapsed time (only if eligible)
        if (elapsed > 0 && s.eligible && currentEarning > 0) {
            uint256 deltaUnits = currentEarning * elapsed;
            s.unitsAccrued += deltaUnits;
            // Baseline rewardDebt at current accRewardPerUnit.
            s.rewardDebt += Math.mulDiv(deltaUnits, accRewardPerUnit, ACC_PRECISION);
        }

        s.lastAccrualTime = now_;
    }

    // Simple wrapper so we can swap reward token interface in the future.
    // Skips work when amount is zero to avoid extra hook calls downstream.
    // Note: Token.mint() has access enforcement built-in.
    function _mintRewards(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        address token_ = token;
        if (token_ == address(0)) revert InvalidConfig();
        IRewardsMintable(token_).mint(recipient, amount);
    }

    // Admin escape hatch—recover foreign tokens without risking BUCK drain.
    // Only whitelisted sinks can receive rescued assets and BUCK is explicitly blocked.
    function recoverERC20(address token_, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (token_ == address(0) || to == address(0)) revert ZeroAddress();
        if (!isRecoverySink[to]) revert InvalidRecoverySink(to);
        if (amount == 0) revert InvalidAmount();
        address canonical = token;
        if (canonical != address(0) && token_ == canonical) {
            revert UnsupportedRecoveryAsset(token_);
        }
        IERC20(token_).safeTransfer(to, amount);
        emit TokensRecovered(msg.sender, token_, to, amount);
    }

    // -------------------------------------------------------------------------
    // Storage Gap
    // -------------------------------------------------------------------------

    // Reserved storage space to allow for layout changes in the future.
    // Trim the gap if future revisions append new state variables.
    uint256[50] private __gap;
}
