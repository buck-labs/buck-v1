// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBuckV2
 * @notice Interface for the BUCK V2 token.
 *
 * BUCK tracks STRC/100 plus streamed yield through an additive pricing model.
 * Yield is embedded in price appreciation rather than a separate claim flow.
 */
interface IBuckV2 is IERC20 {
    // ============ Events ============

    /// @notice Emitted when a new yield stream is started
    event YieldStreamStarted(uint256 indexed yieldBps, uint256 vestDays, uint256 timestamp);

    /// @notice Emitted when yield stream is finalized early
    event YieldFinalized(uint256 finalMultiplier, uint256 timestamp);

    /// @notice Emitted when yield distributor is updated
    event YieldDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);

    // ============ Errors ============

    error NotYieldDistributor();
    error InvalidYieldBps();
    error InvalidVestDuration();
    error NoActiveStream();
    error StreamAlreadyActive();

    // ============ Yield Functions ============

    /// @notice Current yield multiplier including unvested portion
    /// @dev Streams yield linearly over currentVestDuration
    /// @return multiplier in 18 decimals (1e18 = 1.0)
    function currentYieldMultiplier() external view returns (uint256);

    /// @notice Set yield stream rate (decoupled from USDC deposits)
    /// @dev USDC deposits to liquidity reserve happen separately via direct transfers
    /// @dev If a stream is active, it will be finalized before starting the new one
    /// @param yieldBps Yield in basis points (e.g., 1000 = 10%)
    /// @param vestDays Number of days to stream this yield over (3-365)
    function setYieldStream(uint256 yieldBps, uint256 vestDays) external;

    /// @notice Finalize current yield stream early, locking in vested progress
    /// @dev Use this to stop a stream mid-way (e.g., if rate needs to change)
    /// @dev After calling, you can start a new stream with setYieldStream
    function finalizeYield() external;

    /// @notice Set the yield distributor address
    /// @param _yieldDistributor Address authorized to call setYieldStream()
    function setYieldDistributor(address _yieldDistributor) external;

    /// @notice Get current yield stream status for monitoring
    /// @return baseMultiplier The finalized base multiplier
    /// @return currentMultiplier Current multiplier including vested portion
    /// @return unvestedWad Total WAD being streamed
    /// @return vestedWad Amount vested so far (WAD)
    /// @return accruedWad Accrued yield from updateYieldRate() (non-compounded, WAD)
    /// @return timeRemaining Seconds until fully vested
    /// @return percentComplete Percentage of stream complete (0-100)
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
        );

    // ============ View Functions ============

    /// @notice Base yield multiplier (excluding unvested)
    function yieldMultiplier() external view returns (uint256);

    /// @notice Unvested yield in WAD (18 decimals)
    function unvestedYieldWad() external view returns (uint256);

    /// @notice Accrued yield in WAD (vested but not compounded into base)
    function accruedYieldWad() external view returns (uint256);

    /// @notice Timestamp of last yield distribution
    function lastYieldTime() external view returns (uint256);

    /// @notice Current vesting duration in seconds
    function currentVestDuration() external view returns (uint256);

    /// @notice Address authorized to call setYieldStream()
    function yieldDistributor() external view returns (address);
}
