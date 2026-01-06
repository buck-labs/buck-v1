// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint64 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

// OracleAdapter wraps Pyth with an internal price feed so PolicyManager has a simple price source.
// Tries Pyth first, then uses internal price if Pyth is unavailable.
// Strict mode lets PolicyManager enforce freshness only when collateral ratio actually needs it.
contract OracleAdapter is Ownable2Step, Multicall {
    error ZeroAddress();
    error UnauthorizedStrictModeAccess();
    error UnauthorizedPriceUpdate();
    error RenounceOwnershipDisabled();

    event PythConfigured(
        address indexed contractAddress,
        bytes32 indexed priceId,
        uint256 staleAfter,
        uint256 maxConf
    );
    event InternalPriceUpdated(uint256 price, uint256 updatedAt);
    event StrictModeUpdated(bool strictMode);
    event PolicyManagerUpdated(address indexed policyManager);
    event PriceUpdaterUpdated(address indexed priceUpdater);

    // Strict mode toggles freshness enforcement; off when CR ≥ 1 so prices are optional.
    bool public strictMode;

    // PolicyManager address that can automatically toggle strict mode based on CR
    address public policyManager;

    // Hot wallet that can update internal price quickly during stress (CR < 1)
    address public priceUpdater;

    // Primary oracle (Pyth) plus config for staleness + acceptable confidence interval.
    address public pythContract;
    bytes32 public pythPriceId;
    uint256 public pythStaleAfter;
    uint256 public pythMaxConf;

    // Internal price if Pyth feed fails, plus bookkeeping for update timing.
    uint256 private _internalPrice;
    uint256 private _internalUpdatedAt;

    // Deployment wires in the owner (typically the multisig) so it can configure feeds.
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // Configure the Pyth feed for primary oracle price source.
    function configurePyth(address pyth, bytes32 priceId, uint256 staleAfter, uint256 maxConf)
        external
        onlyOwner
    {
        if (pyth == address(0) || priceId == bytes32(0)) revert ZeroAddress();
        pythContract = pyth;
        pythPriceId = priceId;
        pythStaleAfter = staleAfter;
        pythMaxConf = maxConf;
        emit PythConfigured(pyth, priceId, staleAfter, maxConf);
    }

    // Set hot wallet that can update internal price quickly during stress periods
    function setPriceUpdater(address _priceUpdater) external onlyOwner {
        priceUpdater = _priceUpdater;
        emit PriceUpdaterUpdated(_priceUpdater);
    }

    // Internal price used when Pyth feed fails. Owner or priceUpdater can update.
    function setInternalPrice(uint256 price) external {
        if (msg.sender != owner() && msg.sender != priceUpdater) {
            revert UnauthorizedPriceUpdate();
        }
        _internalPrice = price;
        _internalUpdatedAt = block.timestamp;
        emit InternalPriceUpdated(price, block.timestamp);
    }

    // Set PolicyManager address that can automatically toggle strict mode
    function setPolicyManager(address _policyManager) external onlyOwner {
        if (_policyManager == address(0)) revert ZeroAddress();
        policyManager = _policyManager;
        emit PolicyManagerUpdated(_policyManager);
    }

    // Allow PolicyManager to automatically toggle strict mode on-chain based on CR.
    // Only owner or PolicyManager can call this to prevent manipulation.
    function setStrictMode(bool enabled) external {
        if (msg.sender != owner() && msg.sender != policyManager) {
            revert UnauthorizedStrictModeAccess();
        }
        // Only update and emit if value changes to avoid unnecessary events
        if (strictMode != enabled) {
            strictMode = enabled;
            emit StrictModeUpdated(enabled);
        }
    }

    // Returns the freshest price we can find, trying Pyth → internal in order.
    // Always scales to 18 decimals so downstream math is consistent.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        return _latestPrice();
    }

    // Internal helper for price lookup (avoids external self-call overhead)
    function _latestPrice() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = _tryPyth();
        if (price != 0) return (price, updatedAt);
        return (_internalPrice, _internalUpdatedAt);
    }

    // PolicyManager calls this before trusting CAP pricing; enforces freshness only in strict mode.
    // Returns true in healthy mode so the oracle can go stale without blocking normal operations.
    function isHealthy(uint256 maxStale) external view returns (bool) {
        // When not in strict mode (CR ≥ 1.0), oracle health doesn't matter
        // CAP price = $1.00 regardless of oracle state
        if (!strictMode) {
            return true;
        }

        // In strict mode (CR < 1.0), oracle MUST be fresh for CAP pricing
        (uint256 price, uint256 updatedAt) = _latestPrice();
        if (price == 0 || updatedAt == 0) return false;
        return block.timestamp <= updatedAt + maxStale;
    }

    // Internal helper: read Pyth, enforce publish window + confidence bound, scale to 18 decimals.
    function _tryPyth() internal view returns (uint256 price, uint256 updatedAt) {
        if (pythContract == address(0) || pythPriceId == bytes32(0)) return (0, 0);

        IPyth.Price memory p = IPyth(pythContract).getPriceUnsafe(pythPriceId);
        if (p.price <= 0) return (0, 0);
        if (pythStaleAfter != 0 && block.timestamp > p.publishTime + pythStaleAfter) {
            return (0, 0);
        }
        if (pythMaxConf != 0 && p.conf > 0) {
            uint256 scaledConf = _scalePythConfidence(p);
            // Accept extremely small confidence that scales to zero; only reject when above max
            if (scaledConf > pythMaxConf) {
                return (0, 0);
            }
        }

        uint256 scaled = _scalePythPrice(p);
        if (scaled == 0) return (0, 0);
        return (scaled, p.publishTime);
    }

    // Scale Pyth’s signed price into a plain uint in 18-decimal format.
    function _scalePythPrice(IPyth.Price memory p) private pure returns (uint256) {
        int256 signed = int256(p.price);
        if (signed <= 0) return 0;

        uint256 value = uint256(signed);
        return _scalePythValue(value, p.expo);
    }

    // Same deal for Pyth confidence interval values.
    function _scalePythConfidence(IPyth.Price memory p) private pure returns (uint256) {
        if (p.conf == 0) return 0;
        return _scalePythValue(uint256(p.conf), p.expo);
    }

    // Generic scaler for Pyth numbers, guarding against wild exponents and overflow.
    function _scalePythValue(uint256 value, int32 expo) private pure returns (uint256) {
        int256 exp = int256(expo) + 18;
        // Mirror canonical Pyth SDK bounds (+/- 58)
        if (exp > 58 || exp < -58) return 0;

        if (exp >= 0) {
            uint256 pow = 10 ** uint256(exp);
            return value * pow;
        } else {
            uint256 pow = 10 ** uint256(-exp);
            return value / pow;
        }
    }

    /// @notice Ownership renunciation is disabled to prevent accidental lockout
    /// @dev OracleAdapter requires ongoing governance for price feed configuration
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
