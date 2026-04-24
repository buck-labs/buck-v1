//  ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗
//  ██╔══██╗ ██║   ██║ ██╔════╝ ██║ ██╔╝
//  ██████╔╝ ██║   ██║ ██║      █████╔╝
//  ██╔══██╗ ██║   ██║ ██║      ██╔═██╗
//  ██████╔╝ ╚██████╔╝ ╚██████╗ ██║  ██╗
//  ╚═════╝   ╚═════╝   ╚═════╝ ╚═╝  ╚═╝
//
// ORACLE ADAPTER V5
//
//
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

/// @notice Minimal AggregatorV3 interface used by Redstone feeds.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/**
 * @title OracleAdapterV5
 * @notice Simplified oracle with three-tier fallback chain
 *
 * Fallback Chain:
 * 1. Redstone fresh → return price
 * 2. Internal fresh (within 25h) → return price
 * 3. lastGoodPrice within maxAge (default 7 days) → return price
 * 4. revert PriceUnavailable()
 */
contract OracleAdapterV5 is Ownable2Step, Multicall {
    // ============ Errors ============

    error ZeroAddress();
    error UnauthorizedPriceUpdate();
    error RenounceOwnershipDisabled();
    error InvalidPrice();
    error PriceUnavailable();

    // ============ Events ============

    event RedstoneConfigured(address indexed feed, uint256 staleAfter);
    event InternalPriceUpdated(uint256 price, uint256 updatedAt);
    event PriceUpdaterUpdated(address indexed priceUpdater);
    event LastGoodPriceUpdated(uint256 price, uint256 updatedAt, string source);
    event LastGoodPriceMaxAgeUpdated(uint256 maxAge);

    // ============ Constants ============

    /// @notice STRC to BUCK conversion divisor (BUCK = STRC / 100)
    uint256 public constant STRC_DIVISOR = 100;

    uint256 private constant TARGET_DECIMALS = 18;
    uint256 private constant INTERNAL_TIMEOUT = 90_000; // 25 hours

    // ============ State Variables ============

    address public redstoneFeed;

    /// @notice Cached feed decimals.
    uint8 public redstoneFeedDecimals;

    /// @notice Staleness threshold for Redstone prices.
    uint256 public redstoneTimeout;

    uint256 private _internalPrice;
    uint256 private _internalUpdatedAt;
    address public priceUpdater;

    /// @notice Seeded at construction.
    uint256 public lastGoodPrice;
    uint256 public lastGoodPriceTime;

    /// @notice Set to 0 to disable the lastGoodPrice fallback.
    uint256 public lastGoodPriceMaxAge;

    // ============ Constructor ============

    /// @param seedPrice Initial BUCK price in 18 decimals (e.g., 1e18 = $1.00)
    constructor(address initialOwner, uint256 seedPrice) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (seedPrice == 0) revert InvalidPrice();

        lastGoodPrice = seedPrice;
        lastGoodPriceTime = block.timestamp;
        redstoneTimeout = 90_000; // 25 hours
        lastGoodPriceMaxAge = 7 days;
    }

    // ============ Configuration ============

    function configureRedstone(address feed, uint256 staleAfter) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        redstoneFeed = feed;
        redstoneFeedDecimals = AggregatorV3Interface(feed).decimals();
        redstoneTimeout = staleAfter;
        emit RedstoneConfigured(feed, staleAfter);
    }

    function setPriceUpdater(address _priceUpdater) external onlyOwner {
        priceUpdater = _priceUpdater;
        emit PriceUpdaterUpdated(_priceUpdater);
    }

    /// @param price BUCK price in 18 decimals (not STRC)
    function setInternalPrice(uint256 price) external {
        if (msg.sender != owner() && msg.sender != priceUpdater) {
            revert UnauthorizedPriceUpdate();
        }
        if (price == 0) revert InvalidPrice();

        _internalPrice = price;
        _internalUpdatedAt = block.timestamp;
        emit InternalPriceUpdated(price, block.timestamp);
    }

    function setLastGoodPriceMaxAge(uint256 maxAge) external onlyOwner {
        lastGoodPriceMaxAge = maxAge;
        emit LastGoodPriceMaxAgeUpdated(maxAge);
    }

    // ============ Price Functions ============

    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt,) = _getBestPrice();
    }

    /// @notice Refreshes the active price and updates lastGoodPrice when a live source is used.
    function refreshPrice() external returns (uint256 price, uint256 updatedAt) {
        string memory source;
        (price, updatedAt, source) = _getBestPrice();

        // Only promote live sources.
        bytes32 sourceHash = keccak256(bytes(source));
        if (
            sourceHash == keccak256(bytes("REDSTONE")) || sourceHash == keccak256(bytes("INTERNAL"))
        ) {
            _updateLastGoodPrice(price, updatedAt, source);
        }
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ============ Diagnostics ============

    function getOracleStatus()
        external
        view
        returns (
            uint256 currentPrice,
            uint256 currentPriceUpdatedAt,
            string memory activeSource,
            uint256 redstonePrice,
            uint256 redstoneUpdatedAt,
            bool redstoneFresh,
            uint256 internalPrice,
            uint256 internalUpdatedAt,
            bool internalFresh,
            uint256 lastGoodPrice_,
            uint256 lastGoodPriceTime_,
            bool lastGoodPriceValid
        )
    {
        (redstonePrice, redstoneUpdatedAt, redstoneFresh) = _tryRedstone();

        internalPrice = _internalPrice;
        internalUpdatedAt = _internalUpdatedAt;
        internalFresh =
            _internalPrice != 0 && block.timestamp <= _internalUpdatedAt + INTERNAL_TIMEOUT;

        lastGoodPrice_ = lastGoodPrice;
        lastGoodPriceTime_ = lastGoodPriceTime;
        lastGoodPriceValid = lastGoodPriceMaxAge == 0
            ? false
            : block.timestamp <= lastGoodPriceTime + lastGoodPriceMaxAge;

        if (redstoneFresh) {
            currentPrice = redstonePrice;
            currentPriceUpdatedAt = redstoneUpdatedAt;
            activeSource = "REDSTONE";
        } else if (internalFresh) {
            currentPrice = internalPrice;
            currentPriceUpdatedAt = internalUpdatedAt;
            activeSource = "INTERNAL";
        } else if (lastGoodPriceValid) {
            currentPrice = lastGoodPrice_;
            currentPriceUpdatedAt = lastGoodPriceTime_;
            activeSource = "LAST_GOOD";
        } else {
            activeSource = "";
        }
    }

    // ============ Internal: Core Logic ============

    /// @notice Fallback chain: Redstone → Internal → lastGoodPrice → revert
    function _getBestPrice()
        internal
        view
        returns (uint256 price, uint256 updatedAt, string memory source)
    {
        // Tier 1: Redstone
        bool fresh;
        (price, updatedAt, fresh) = _tryRedstone();
        if (fresh) return (price, updatedAt, "REDSTONE");

        // Tier 2: Internal (within 25 hours)
        if (_internalPrice != 0 && block.timestamp <= _internalUpdatedAt + INTERNAL_TIMEOUT) {
            return (_internalPrice, _internalUpdatedAt, "INTERNAL");
        }

        // Tier 3: lastGoodPrice within maxAge
        if (lastGoodPriceMaxAge != 0 && block.timestamp <= lastGoodPriceTime + lastGoodPriceMaxAge)
        {
            return (lastGoodPrice, lastGoodPriceTime, "LAST_GOOD");
        }

        // All sources exhausted
        revert PriceUnavailable();
    }

    // ============ Internal: Oracle Reader ============

    function _tryRedstone() internal view returns (uint256 price, uint256 updatedAt, bool fresh) {
        if (redstoneFeed == address(0)) return (0, 0, false);

        try AggregatorV3Interface(redstoneFeed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 _updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (0, 0, false);
            if (_updatedAt == 0) return (0, 0, false);
            if (answeredInRound < roundId) return (0, 0, false);

            bool isFresh = redstoneTimeout == 0 || block.timestamp <= _updatedAt + redstoneTimeout;

            uint256 raw = uint256(answer);
            if (redstoneFeedDecimals < TARGET_DECIMALS) {
                uint256 factor = 10 ** (TARGET_DECIMALS - uint256(redstoneFeedDecimals));
                if (raw > type(uint256).max / factor) return (0, 0, false);
            } else if (redstoneFeedDecimals > TARGET_DECIMALS) {
                uint256 exp = uint256(redstoneFeedDecimals) - TARGET_DECIMALS;
                if (exp > 77) return (0, 0, false);
            }

            uint256 scaledPrice = _scalePrice(raw, redstoneFeedDecimals);
            uint256 buckPrice = scaledPrice / STRC_DIVISOR;

            return (buckPrice, _updatedAt, isFresh);
        } catch {
            return (0, 0, false);
        }
    }

    // ============ Internal: Helpers ============

    function _scalePrice(uint256 price, uint8 fromDecimals) internal pure returns (uint256) {
        if (fromDecimals < TARGET_DECIMALS) {
            return price * 10 ** (TARGET_DECIMALS - fromDecimals);
        } else if (fromDecimals > TARGET_DECIMALS) {
            return price / 10 ** (fromDecimals - TARGET_DECIMALS);
        }
        return price;
    }

    /// @dev Uses source timestamp, not block.timestamp
    function _updateLastGoodPrice(uint256 price, uint256 priceTimestamp, string memory source)
        internal
    {
        if (price == 0) return;
        lastGoodPrice = price;
        lastGoodPriceTime = priceTimestamp;
        emit LastGoodPriceUpdated(price, priceTimestamp, source);
    }
}
