// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Buck} from "src/token/Buck.sol";
import {LiquidityWindow} from "src/liquidity/LiquidityWindow.sol";
import {LiquidityReserve} from "src/liquidity/LiquidityReserve.sol";
import {PolicyManager} from "src/policy/PolicyManager.sol";
import {RewardsEngine} from "src/rewards/RewardsEngine.sol";
import {CollateralAttestation} from "src/collateral/CollateralAttestation.sol";

/// @notice Shared test base exposing forge-std cheatcodes and utilities.
contract BaseTest is Test {
    /// @notice Deploy BUCK with UUPS proxy pattern
    /// @param initialOwner The initial owner of the BUCK contract
    /// @return The BUCK instance (proxy)
    function deployBUCK(address initialOwner) internal returns (Buck) {
        // Deploy implementation
        Buck implementation = new Buck();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(implementation.initialize, (initialOwner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return Buck(address(proxy));
    }

    /// @notice Deploy LiquidityWindow with UUPS proxy pattern
    /// @param initialOwner The initial owner of the LiquidityWindow contract
    /// @param buck_ Address of the BUCK token
    /// @param liquidityReserve_ Address of the LiquidityReserve
    /// @param policyManager_ Address of the PolicyManager
    /// @return The LiquidityWindow instance (proxy)
    function deployLiquidityWindow(
        address initialOwner,
        address buck_,
        address liquidityReserve_,
        address policyManager_
    ) internal returns (LiquidityWindow) {
        // Deploy implementation
        LiquidityWindow implementation = new LiquidityWindow();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            implementation.initialize, (initialOwner, buck_, liquidityReserve_, policyManager_)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return LiquidityWindow(address(proxy));
    }

    /// @notice Deploy PolicyManager with UUPS proxy pattern
    /// @param admin The admin address (granted ADMIN_ROLE and OPERATOR_ROLE)
    /// @return The PolicyManager instance (proxy)
    function deployPolicyManager(address admin) internal returns (PolicyManager) {
        // Deploy implementation
        PolicyManager implementation = new PolicyManager();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(implementation.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return PolicyManager(address(proxy));
    }

    /// @notice Deploy RewardsEngine with UUPS proxy pattern
    /// @param admin The admin address (granted ADMIN_ROLE)
    /// @param distributor The distributor address (granted DISTRIBUTOR_ROLE)
    /// @param minClaimTokens_ Minimum tokens required to claim rewards
    /// @return The RewardsEngine instance (proxy)
    function deployRewardsEngine(
        address admin,
        address distributor,
        uint32 /*antiSnipeCutoffSeconds_*/,
        uint256 minClaimTokens_,
        bool /*claimOncePerEpoch_*/
    ) internal returns (RewardsEngine) {
        // Deploy implementation
        RewardsEngine implementation = new RewardsEngine();

        // Deploy proxy with initialization
        bytes memory initData =
            abi.encodeCall(implementation.initialize, (admin, distributor, minClaimTokens_));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return RewardsEngine(address(proxy));
    }

    /// @notice Deploy LiquidityReserve with UUPS proxy pattern
    /// @param admin The admin address (granted ADMIN_ROLE)
    /// @param asset_ Address of the asset token (USDC)
    /// @param liquidityWindow_ Address of the LiquidityWindow
    /// @param treasurer_ Address of the treasurer
    /// @return The LiquidityReserve instance (proxy)
    function deployLiquidityReserve(
        address admin,
        address asset_,
        address liquidityWindow_,
        address treasurer_
    ) internal returns (LiquidityReserve) {
        // Deploy implementation
        LiquidityReserve implementation = new LiquidityReserve();

        // Deploy proxy with initialization
        bytes memory initData =
            abi.encodeCall(implementation.initialize, (admin, asset_, liquidityWindow_, treasurer_));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return LiquidityReserve(address(proxy));
    }

    /// @notice Deploy CollateralAttestation with UUPS proxy pattern
    /// @param admin The admin address (granted ADMIN_ROLE)
    /// @param attestor The attestor address (granted ATTESTOR_ROLE)
    /// @param buckToken_ Address of the BUCK token
    /// @param liquidityReserve_ Address of the LiquidityReserve
    /// @param usdc_ Address of the USDC token
    /// @return The CollateralAttestation instance (proxy)
    function deployCollateralAttestation(
        address admin,
        address attestor,
        address buckToken_,
        address liquidityReserve_,
        address usdc_
    ) internal returns (CollateralAttestation) {
        // Deploy implementation
        CollateralAttestation implementation = new CollateralAttestation();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            implementation.initialize,
            (
                admin,
                attestor,
                buckToken_,
                liquidityReserve_,
                usdc_,
                6, // reserveAssetDecimals (USDC)
                72 hours, // healthyStaleness
                15 minutes // stressedStaleness
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Return wrapped proxy
        return CollateralAttestation(address(proxy));
    }
}
