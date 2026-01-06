// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "src/token/Buck.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockAccessRegistryAccess is IAccessRegistry {
    mapping(address => bool) public isAllowed;
    mapping(address => bool) public isDenylisted;

    function setAllowed(address account, bool allowed) external {
        isAllowed[account] = allowed;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

contract MockRewardsHookAccess is IRewardsHook {
    function onBalanceChange(address, address, uint256) external {}
}

contract MockPolicyManagerAccess {
    uint16 public buyFeeBps = 100; // 1%
    uint16 public sellFeeBps = 200; // 2%

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }
}

contract BUCKAccessControlTest is BaseTest {
    Buck internal buck;
    MockAccessRegistryAccess internal accessRegistry;
    MockRewardsHookAccess internal rewardsHook;
    MockPolicyManagerAccess internal policyManager;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant LIQUIDITY_WINDOW = address(0xBEEF);
    address internal constant LIQUIDITY_RESERVE = address(0xCAFE);
    address internal constant TREASURY = address(0xFEE1);
    address internal constant REWARDS_HOOK = address(0xD00D);
    address internal constant USER = address(0x1234);
    address internal constant CALLER = address(0xABCD);
    address internal constant DEX_PAIR = address(0xDEAD);

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
        accessRegistry = new MockAccessRegistryAccess();
        rewardsHook = new MockRewardsHookAccess();
        policyManager = new MockPolicyManagerAccess();

        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );
        vm.prank(TIMELOCK);
        buck.addDexPair(DEX_PAIR);
    }

    function testConfigureModulesRestrictedToTimelock() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        buck.configureModules(
            address(0),
            address(0),
            address(0),
            address(0),
            address(accessRegistry),
            address(rewardsHook)
        );

        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );
    }

    function testSettersRestrictedToTimelock() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        buck.addDexPair(address(0x1111));

        // Note: setSwapFees() moved to PolicyManager - DEX fees now set there

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        buck.setFeeSplit(1234);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        buck.setFeeExempt(address(0x9999), true);
    }

    function testMintAuthorization() public {
        accessRegistry.setAllowed(USER, true);

        vm.expectRevert(Buck.NotAuthorizedMinter.selector);
        buck.mint(USER, 1 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);

        vm.prank(address(rewardsHook));
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 2 ether);
    }

    function testBurnAuthorization() public {
        accessRegistry.setAllowed(USER, true);
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 2 ether);

        vm.expectRevert(Buck.NotLiquidityWindow.selector);
        buck.burn(USER, 1 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.burn(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);
    }

    function testTransfersArePermissionless() public {
        // Transfers no longer require KYC - only mint/refund at LiquidityWindow do
        accessRegistry.setAllowed(USER, true);
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 5 ether);

        // CALLER has no KYC but can receive tokens
        vm.prank(USER);
        assertTrue(buck.transfer(CALLER, 1 ether));
        assertEq(buck.balanceOf(CALLER), 1 ether);

        // CALLER can transfer to TREASURY without KYC
        vm.prank(CALLER);
        assertTrue(buck.transfer(TREASURY, 0.5 ether));
        assertEq(buck.balanceOf(TREASURY), 0.5 ether);
    }

    function testDexFeesAppliedOnlyWhenPairInvolved() public {
        accessRegistry.setAllowed(USER, true);
        accessRegistry.setAllowed(CALLER, true);

        // Set DEX fees via PolicyManager
        policyManager.setDexFees(100, 200);
        vm.prank(TIMELOCK);
        buck.setFeeSplit(5000);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 100 ether);

        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 100 ether);

        vm.prank(USER);
        assertTrue(buck.transfer(DEX_PAIR, 50 ether));

        uint256 fee = (50 ether * 200) / 10_000;
        assertEq(buck.balanceOf(DEX_PAIR), 100 ether + 50 ether - fee);
        assertEq(buck.balanceOf(TREASURY), fee / 2);
        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), fee / 2);

        uint256 reserveBefore = buck.balanceOf(LIQUIDITY_RESERVE);
        uint256 treasuryBefore = buck.balanceOf(TREASURY);

        vm.prank(USER);
        assertTrue(buck.transfer(CALLER, 1 ether));

        assertEq(buck.balanceOf(LIQUIDITY_RESERVE), reserveBefore);
        assertEq(buck.balanceOf(TREASURY), treasuryBefore);
    }

    // =========================================================================
    // EDGE CASES FOR ACCESS CONTROL
    // =========================================================================

    function testModuleChangeRevokesOldAccess() public {
        accessRegistry.setAllowed(USER, true);

        // Original liquidity window can mint
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);

        // Change liquidity window
        address newLiquidityWindow = address(0x7777);
        vm.prank(TIMELOCK);
        buck.configureModules(
            newLiquidityWindow,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        // Old liquidity window can't mint anymore
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(Buck.NotAuthorizedMinter.selector);
        buck.mint(USER, 1 ether);

        // Old liquidity window can't burn anymore
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(Buck.NotLiquidityWindow.selector);
        buck.burn(USER, 1 ether);

        // New liquidity window can mint
        vm.prank(newLiquidityWindow);
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 2 ether);

        // New liquidity window can burn
        vm.prank(newLiquidityWindow);
        buck.burn(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);
    }

    function testRewardsHookChangeAffectsMintingRights() public {
        accessRegistry.setAllowed(USER, true);

        // Original rewards hook can mint
        vm.prank(address(rewardsHook));
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);

        // Change rewards hook
        MockRewardsHookAccess newRewardsHook = new MockRewardsHookAccess();
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(newRewardsHook)
        );

        // Old rewards hook can't mint anymore
        vm.prank(address(rewardsHook));
        vm.expectRevert(Buck.NotAuthorizedMinter.selector);
        buck.mint(USER, 1 ether);

        // New rewards hook can mint
        vm.prank(address(newRewardsHook));
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 2 ether);
    }

    function testZeroAddressModulesDisableFunctionality() public {
        accessRegistry.setAllowed(USER, true);
        accessRegistry.setAllowed(CALLER, true);

        // Set liquidity window to zero
        vm.prank(TIMELOCK);
        buck.configureModules(
            address(0), // no liquidity window
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        // Random address can't mint when liquidity window is zero
        vm.prank(address(0x5555));
        vm.expectRevert(Buck.NotAuthorizedMinter.selector);
        buck.mint(USER, 1 ether);

        // Rewards hook can still mint
        vm.prank(address(rewardsHook));
        buck.mint(USER, 1 ether);

        // Random address can't burn (liquidity window is zero)
        vm.prank(address(0x5555));
        vm.expectRevert(Buck.NotLiquidityWindow.selector);
        buck.burn(USER, 1 ether);
    }

    function testKycRegistryRemovalDisablesKycChecks() public {
        // Initially KYC is enforced
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(Buck.AccessCheckFailed.selector, USER));
        buck.mint(USER, 1 ether);

        // Remove KYC registry
        vm.prank(TIMELOCK);
        buck.configureModules(
            LIQUIDITY_WINDOW,
            LIQUIDITY_RESERVE,
            TREASURY,
            address(policyManager),
            address(0), // no KYC registry
            address(rewardsHook)
        );

        // Now can mint without KYC
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(USER, 1 ether);
        assertEq(buck.balanceOf(USER), 1 ether);

        // Can transfer without KYC
        vm.prank(USER);
        assertTrue(buck.transfer(CALLER, 1 ether));
        assertEq(buck.balanceOf(CALLER), 1 ether);
    }

    function testSystemAccountsAlwaysBypassKyc() public {
        // Don't set any KYC allowances

        // Liquidity window can receive without KYC
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(LIQUIDITY_WINDOW, 1 ether);

        // Treasury can receive without KYC
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(TREASURY, 1 ether);

        // Liquidity reserve can receive without KYC
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(LIQUIDITY_RESERVE, 1 ether);

        // DEX pair can receive without KYC
        vm.prank(LIQUIDITY_WINDOW);
        buck.mint(DEX_PAIR, 1 ether);

        // System accounts can transfer between each other without KYC
        vm.prank(TREASURY);
        assertTrue(buck.transfer(LIQUIDITY_RESERVE, 1 ether));
    }

    function testDexPairChangeUpdatesFeeExemption() public {
        accessRegistry.setAllowed(USER, true);

        // Initial DEX pair is fee exempt
        assertTrue(buck.isFeeExempt(DEX_PAIR));

        // Add second DEX pair (first stays active)
        address newDexPair = address(0x3333);
        vm.prank(TIMELOCK);
        buck.addDexPair(newDexPair);

        // Both DEX pairs are fee exempt (multi-pair support)
        assertTrue(buck.isFeeExempt(DEX_PAIR));
        assertTrue(buck.isFeeExempt(newDexPair));

        // Remove first DEX pair
        vm.prank(TIMELOCK);
        buck.removeDexPair(DEX_PAIR);

        // Now only new pair is exempt
        assertFalse(buck.isFeeExempt(DEX_PAIR));
        assertTrue(buck.isFeeExempt(newDexPair));
    }

    function testFeeExemptionPersistsThroughModuleChanges() public {
        // Set custom fee exemption
        address customExempt = address(0x9999);
        vm.prank(TIMELOCK);
        buck.setFeeExempt(customExempt, true);
        assertTrue(buck.isFeeExempt(customExempt));

        // Change modules
        vm.prank(TIMELOCK);
        buck.configureModules(
            address(0x8881),
            address(0x8882),
            address(0x8883),
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );

        // Custom exemption should persist
        assertTrue(buck.isFeeExempt(customExempt));

        // New system accounts should be exempt
        assertTrue(buck.isFeeExempt(address(0x8881))); // new liquidity window
        assertTrue(buck.isFeeExempt(address(0x8882))); // new liquidity reserve
        assertTrue(buck.isFeeExempt(address(0x8883))); // new treasury
    }

    function testCannotMintOrBurnZeroAddress() public {
        // Cannot mint to zero address
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(Buck.ZeroAddress.selector);
        buck.mint(address(0), 1 ether);

        // Cannot burn from zero address (OZ reverts with ERC20InvalidSender)
        vm.prank(LIQUIDITY_WINDOW);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidSender(address)", address(0)));
        buck.burn(address(0), 1 ether);
    }

    function testFeeValidationBoundaries() public {
        // Note: DEX fee validation (buyFeeBps/sellFeeBps) now happens in PolicyManager.setDexFees()
        // BUCK no longer has setSwapFees() or buyFeeBps/sellFeeBps storage

        // Cannot set fee split above 10000
        vm.prank(TIMELOCK);
        vm.expectRevert(Buck.InvalidFee.selector);
        buck.setFeeSplit(10001);

        // Can set exactly at boundary
        vm.prank(TIMELOCK);
        buck.setFeeSplit(10000);
        assertEq(buck.feeToReservePct(), 10000);
    }

    function testMultipleTimelockCallsInSameTx() public {
        // Timelock can make multiple config changes in same tx
        vm.startPrank(TIMELOCK);

        // Note: setSwapFees moved to PolicyManager
        buck.setFeeSplit(7500);
        buck.setFeeExempt(address(0x1111), true);
        buck.addDexPair(address(0x2222));

        vm.stopPrank();

        // Note: buyFeeBps/sellFeeBps no longer exist on BUCK - check PolicyManager instead
        assertEq(buck.feeToReservePct(), 7500);
        assertTrue(buck.isFeeExempt(address(0x1111)));
        assertTrue(buck.isDexPair(address(0x2222)));
    }
}
