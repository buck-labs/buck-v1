// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/**
 * @title IOracleAdapterV5
 * @notice Interface for OracleAdapterV5 - Simplified oracle with three-tier fallback
 *
 * Oracle Priority:
 * 1. Redstone (push, Chainlink-compatible)
 * 2. Internal (manual, fresh within 25 hours)
 * 3. lastGoodPrice (within maxAge, default 7 days)
 * 4. revert PriceUnavailable()
 */
interface IOracleAdapterV5 {
    // ============ Events ============

    event RedstoneConfigured(address indexed feed, uint256 staleAfter);
    event InternalPriceUpdated(uint256 price, uint256 updatedAt);
    event PriceUpdaterUpdated(address indexed priceUpdater);
    event LastGoodPriceUpdated(uint256 price, uint256 updatedAt, string source);
    event LastGoodPriceMaxAgeUpdated(uint256 maxAge);

    // ============ Errors ============

    error ZeroAddress();
    error UnauthorizedPriceUpdate();
    error RenounceOwnershipDisabled();
    error InvalidPrice();
    error PriceUnavailable();

    // ============ Configuration ============

    function configureRedstone(address feed, uint256 staleAfter) external;
    function setPriceUpdater(address _priceUpdater) external;
    function setInternalPrice(uint256 price) external;
    function setLastGoodPriceMaxAge(uint256 maxAge) external;

    // ============ Price Functions ============

    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
    function refreshPrice() external returns (uint256 price, uint256 updatedAt);

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
        );

    // ============ View Functions ============

    function redstoneFeed() external view returns (address);
    function redstoneFeedDecimals() external view returns (uint8);
    function redstoneTimeout() external view returns (uint256);
    function priceUpdater() external view returns (address);
    function lastGoodPrice() external view returns (uint256);
    function lastGoodPriceTime() external view returns (uint256);
    function lastGoodPriceMaxAge() external view returns (uint256);
    function STRC_DIVISOR() external view returns (uint256);
}
