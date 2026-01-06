// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Buck, IAccessRegistry, IRewardsHook} from "src/token/Buck.sol";

contract MockRewardsHook is IRewardsHook {
    struct Call {
        address from;
        address to;
        uint256 amount;
    }

    Call[] internal _calls;

    function onBalanceChange(address from, address to, uint256 amount) external override {
        _calls.push(Call({from: from, to: to, amount: amount}));
    }

    function calls(uint256 index) external view returns (Call memory) {
        return _calls[index];
    }

    function count() external view returns (uint256) {
        return _calls.length;
    }

    function reset() external {
        delete _calls;
    }
}

contract MockAccessRegistry is IAccessRegistry {
    mapping(address => bool) public isAllowed;
    mapping(address => bool) public isDenylisted;

    function setAllowed(address account, bool allowed) external {
        isAllowed[account] = allowed;
    }

    function setDenylisted(address account, bool denied) external {
        isDenylisted[account] = denied;
    }
}

contract MockPolicyManagerTest {
    uint16 public buyFeeBps;
    uint16 public sellFeeBps;

    function getDexFees() external view returns (uint16, uint16) {
        return (buyFeeBps, sellFeeBps);
    }

    function setDexFees(uint16 _buyFee, uint16 _sellFee) external {
        buyFeeBps = _buyFee;
        sellFeeBps = _sellFee;
    }
}

contract BUCKTest is BaseTest {
    Buck internal buck;
    MockAccessRegistry internal accessRegistry;
    MockRewardsHook internal rewardsHook;
    MockPolicyManagerTest internal policyManager;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant ALICE = address(0xAA);
    address internal constant BOB = address(0xBB);
    address internal constant CAROL = address(0xCC);
    uint256 internal constant OWNER_PK = 0xBEEF;
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    bool internal modulesConfigured;

    function setUp() public {
        buck = deployBUCK(TIMELOCK);
        accessRegistry = new MockAccessRegistry();
        rewardsHook = new MockRewardsHook();
        policyManager = new MockPolicyManagerTest();
    }

    function testInitialMetadata() public view {
        assertEq(buck.name(), "Buck");
        assertEq(buck.symbol(), "BUCK");
        assertEq(buck.decimals(), 18);
    }

    function testInitialConfig() public view {
        assertEq(buck.owner(), TIMELOCK);
        // Note: buyFeeBps/sellFeeBps now on PolicyManager, not STRX
        assertEq(buck.feeToReservePct(), 0);
        assertFalse(buck.isDexPair(address(0x1))); // No DEX pairs registered initially
        assertEq(buck.liquidityWindow(), address(0));
        assertEq(buck.liquidityReserve(), address(0));
        assertEq(buck.treasury(), address(0));
    }

    function testApproveAndAllowance() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _mint(ALICE, 1e18);

        vm.prank(ALICE);
        assertTrue(buck.approve(BOB, 5 ether));
        assertEq(buck.allowance(ALICE, BOB), 5 ether);

        // Test changing allowance (replace increaseAllowance)
        vm.prank(ALICE);
        assertTrue(buck.approve(BOB, 6 ether));
        assertEq(buck.allowance(ALICE, BOB), 6 ether);

        // Test reducing allowance (replace decreaseAllowance)
        vm.prank(ALICE);
        assertTrue(buck.approve(BOB, 4 ether));
        assertEq(buck.allowance(ALICE, BOB), 4 ether);
    }

    function testTransferMovesBalance() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _mint(ALICE, 10 ether);

        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 4 ether));

        assertEq(buck.balanceOf(ALICE), 6 ether);
        assertEq(buck.balanceOf(BOB), 4 ether);
    }

    function testTransferInsufficientBalanceReverts() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _mint(ALICE, 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether
            )
        );
        buck.transfer(BOB, 2 ether);
    }

    function testTransferFromConsumesAllowance() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _setKyc(CAROL, true);
        _mint(ALICE, 5 ether);

        vm.prank(ALICE);
        buck.approve(BOB, 3 ether);

        vm.prank(BOB);
        assertTrue(buck.transferFrom(ALICE, CAROL, 2 ether));

        assertEq(buck.balanceOf(ALICE), 3 ether);
        assertEq(buck.balanceOf(CAROL), 2 ether);
        assertEq(buck.allowance(ALICE, BOB), 1 ether);
    }

    function testTransferFromMaxAllowanceNotDecremented() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _setKyc(CAROL, true);
        _mint(ALICE, 5 ether);

        vm.prank(ALICE);
        buck.approve(BOB, type(uint256).max);

        vm.prank(BOB);
        assertTrue(buck.transferFrom(ALICE, CAROL, 3 ether));

        assertEq(buck.allowance(ALICE, BOB), type(uint256).max);
    }

    function testTransferFromInsufficientAllowanceReverts() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _setKyc(CAROL, true);
        _mint(ALICE, 5 ether);

        vm.prank(ALICE);
        buck.approve(BOB, 1 ether);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 1 ether, 2 ether
            )
        );
        buck.transferFrom(ALICE, CAROL, 2 ether);
    }

    function testPermitSetsAllowance() public {
        _configureModules();
        address owner = vm.addr(OWNER_PK);
        address spender = BOB;
        _setKyc(owner, true);
        _setKyc(spender, true);
        _mint(owner, 5 ether);

        vm.warp(1_000_000);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 2 ether;
        uint256 nonce = buck.nonces(owner);

        bytes32 digest = _permitDigest(owner, spender, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        buck.permit(owner, spender, value, deadline, v, r, s);

        assertEq(buck.allowance(owner, spender), value);
        assertEq(buck.nonces(owner), nonce + 1);
    }

    function testPermitExpiredReverts() public {
        _configureModules();
        address owner = vm.addr(OWNER_PK);
        address spender = BOB;
        _setKyc(owner, true);
        _setKyc(spender, true);
        _mint(owner, 5 ether);

        vm.warp(1_000_000);
        uint256 deadline = block.timestamp - 1;
        uint256 value = 1 ether;
        uint256 nonce = buck.nonces(owner);

        bytes32 digest = _permitDigest(owner, spender, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline)
        );
        buck.permit(owner, spender, value, deadline, v, r, s);
        assertEq(buck.nonces(owner), nonce);
    }

    function testPermitInvalidSignatureReverts() public {
        _configureModules();
        address owner = vm.addr(OWNER_PK);
        address spender = BOB;
        _setKyc(owner, true);
        _setKyc(spender, true);
        _mint(owner, 5 ether);
        _setKyc(spender, true);

        vm.warp(1_000_000);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1 ether;
        uint256 nonce = buck.nonces(owner);

        // Sign with a different private key to force invalid signature.
        bytes32 digest = _permitDigest(owner, spender, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK + 1, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(OWNER_PK + 1), owner
            )
        );
        buck.permit(owner, spender, value, deadline, v, r, s);
        assertEq(buck.allowance(owner, spender), 0);
        assertEq(buck.nonces(owner), nonce);
    }

    function _mint(address to, uint256 amount) internal {
        buck.mint(to, amount);
    }

    function _configureModules() internal {
        if (modulesConfigured) return;
        modulesConfigured = true;

        vm.prank(TIMELOCK);
        buck.configureModules(
            address(this),
            address(0xBEEF),
            address(0xCAFE),
            address(policyManager),
            address(accessRegistry),
            address(rewardsHook)
        );
    }

    function testRewardsHookCapturesMintTransferBurn() public {
        _configureModules();
        rewardsHook.reset();

        _setKyc(ALICE, true);
        _setKyc(BOB, true);

        _mint(ALICE, 10 ether);

        MockRewardsHook.Call memory mintCall = rewardsHook.calls(0);
        assertEq(mintCall.from, address(0));
        assertEq(mintCall.to, ALICE);
        assertEq(mintCall.amount, 10 ether);

        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 3 ether));

        MockRewardsHook.Call memory transferCall = rewardsHook.calls(1);
        assertEq(transferCall.from, ALICE);
        assertEq(transferCall.to, BOB);
        assertEq(transferCall.amount, 3 ether);

        vm.prank(address(this));
        buck.burn(ALICE, 2 ether);

        MockRewardsHook.Call memory burnCall = rewardsHook.calls(2);
        assertEq(burnCall.from, ALICE);
        assertEq(burnCall.to, address(0));
        assertEq(burnCall.amount, 2 ether);
    }

    function testSellFeeRoutesToReserveAndTreasuryAndNotifiesRewards() public {
        _configureModules();
        rewardsHook.reset();

        _setKyc(ALICE, true);

        address dexPair = address(0xD3E);

        vm.startPrank(TIMELOCK);
        buck.addDexPair(dexPair);
        policyManager.setDexFees(0, 200); // 2% sell fee
        buck.setFeeSplit(6000); // 60% to reserve, 40% to treasury
        vm.stopPrank();

        _mint(ALICE, 100 ether);

        uint256 reserveBefore = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryBefore = buck.balanceOf(buck.treasury());

        vm.prank(ALICE);
        assertTrue(buck.transfer(dexPair, 100 ether));

        uint256 reserveAfter = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryAfter = buck.balanceOf(buck.treasury());
        uint256 pairBalance = buck.balanceOf(dexPair);

        assertEq(reserveAfter - reserveBefore, 1.2 ether); // 60% of 2 ether
        assertEq(treasuryAfter - treasuryBefore, 0.8 ether); // 40% of 2 ether
        assertEq(pairBalance, 98 ether);

        // rewards hook calls: mint, reserve fee, treasury fee, transfer
        assertEq(rewardsHook.count(), 4);

        MockRewardsHook.Call memory callData = rewardsHook.calls(0);
        assertEq(callData.from, address(0));
        assertEq(callData.to, ALICE);
        assertEq(callData.amount, 100 ether);

        callData = rewardsHook.calls(1);
        assertEq(callData.from, ALICE);
        assertEq(callData.to, buck.liquidityReserve());
        assertEq(callData.amount, 1.2 ether);

        callData = rewardsHook.calls(2);
        assertEq(callData.from, ALICE);
        assertEq(callData.to, buck.treasury());
        assertEq(callData.amount, 0.8 ether);

        callData = rewardsHook.calls(3);
        assertEq(callData.from, ALICE);
        assertEq(callData.to, dexPair);
        // FIXED: RewardsEngine receives NET amount (100 ether - 2 ether fee = 98 ether)
        // This prevents phantom balance attacks (DEX fee fix)
        assertEq(callData.amount, 98 ether);
    }

    function testBuyFeeRoutesToReserveAndTreasuryAndNotifiesRewards() public {
        _configureModules();
        rewardsHook.reset();

        _setKyc(ALICE, true);

        address dexPair = address(0xD3E);

        vm.startPrank(TIMELOCK);
        buck.addDexPair(dexPair);
        policyManager.setDexFees(150, 0); // 1.5% buy fee
        buck.setFeeSplit(2500); // 25% to reserve, 75% to treasury
        vm.stopPrank();

        // Seed the pair with STRC liquidity
        buck.mint(dexPair, 80 ether);

        uint256 reserveBefore = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryBefore = buck.balanceOf(buck.treasury());

        vm.prank(dexPair);
        assertTrue(buck.transfer(ALICE, 40 ether));

        uint256 reserveAfter = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryAfter = buck.balanceOf(buck.treasury());
        uint256 pairBalance = buck.balanceOf(dexPair);

        uint256 fee = (40 ether * 150) / 10_000; // 0.6 ether
        uint256 reserveShare = (fee * 2500) / 10_000; // 0.15 ether
        uint256 treasuryShare = fee - reserveShare; // 0.45 ether

        assertEq(buck.balanceOf(ALICE), 40 ether - fee);
        assertEq(reserveAfter - reserveBefore, reserveShare);
        assertEq(treasuryAfter - treasuryBefore, treasuryShare);
        assertEq(pairBalance, 80 ether - 40 ether);

        // rewards hook calls: mint to pair, reserve fee, treasury fee, user transfer
        assertEq(rewardsHook.count(), 4);

        MockRewardsHook.Call memory callData = rewardsHook.calls(0);
        assertEq(callData.from, address(0));
        assertEq(callData.to, dexPair);
        assertEq(callData.amount, 80 ether);

        callData = rewardsHook.calls(1);
        assertEq(callData.from, dexPair);
        assertEq(callData.to, buck.liquidityReserve());
        assertEq(callData.amount, reserveShare);

        callData = rewardsHook.calls(2);
        assertEq(callData.from, dexPair);
        assertEq(callData.to, buck.treasury());
        assertEq(callData.amount, treasuryShare);

        callData = rewardsHook.calls(3);
        assertEq(callData.from, dexPair);
        assertEq(callData.to, ALICE);
        // FIXED: RewardsEngine receives NET amount (40 ether - 0.6 fee = 39.4 ether)
        // This prevents phantom balance attacks (DEX fee fix)
        assertEq(callData.amount, 40 ether - fee);
    }

    function testWalletToWalletTransfersIgnoreFees() public {
        _configureModules();
        rewardsHook.reset();

        _setKyc(ALICE, true);
        _setKyc(BOB, true);

        vm.prank(TIMELOCK);
        policyManager.setDexFees(150, 150); // configure non-zero fees within bounds

        _mint(ALICE, 5 ether);

        uint256 reserveBefore = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryBefore = buck.balanceOf(buck.treasury());

        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 2 ether));

        assertEq(buck.balanceOf(BOB), 2 ether);
        assertEq(buck.balanceOf(buck.liquidityReserve()), reserveBefore);
        assertEq(buck.balanceOf(buck.treasury()), treasuryBefore);

        // Only mint and end-user transfer should trigger rewards notifications
        assertEq(rewardsHook.count(), 2);
        MockRewardsHook.Call memory callData = rewardsHook.calls(0);
        assertEq(callData.from, address(0));
        assertEq(callData.to, ALICE);
        assertEq(callData.amount, 5 ether);

        callData = rewardsHook.calls(1);
        assertEq(callData.from, ALICE);
        assertEq(callData.to, BOB);
        assertEq(callData.amount, 2 ether);
    }

    function testFeeExemptionSkipsFeeCollection() public {
        _configureModules();

        _setKyc(ALICE, true);

        address dexPair = address(0xD3E);

        vm.startPrank(TIMELOCK);
        buck.addDexPair(dexPair);
        policyManager.setDexFees(150, 150); // 1.5% both directions
        buck.setFeeSplit(6000); // any split should be ignored for exempt addresses
        buck.setFeeExempt(ALICE, true);
        vm.stopPrank();

        _mint(ALICE, 100 ether);
        vm.prank(address(this));
        buck.mint(dexPair, 50 ether);

        uint256 reserveBefore = buck.balanceOf(buck.liquidityReserve());
        uint256 treasuryBefore = buck.balanceOf(buck.treasury());

        vm.prank(ALICE);
        assertTrue(buck.transfer(dexPair, 20 ether));

        assertEq(buck.balanceOf(dexPair), 70 ether);
        assertEq(buck.balanceOf(ALICE), 80 ether);
        assertEq(buck.balanceOf(buck.liquidityReserve()), reserveBefore);
        assertEq(buck.balanceOf(buck.treasury()), treasuryBefore);

        vm.prank(dexPair);
        assertTrue(buck.transfer(ALICE, 10 ether));

        assertEq(buck.balanceOf(ALICE), 90 ether);
        assertEq(buck.balanceOf(buck.liquidityReserve()), reserveBefore);
        assertEq(buck.balanceOf(buck.treasury()), treasuryBefore);
    }

    function testZeroAmountTransfersAndMints() public {
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);

        vm.prank(address(this));
        buck.mint(ALICE, 0);
        assertEq(buck.balanceOf(ALICE), 0);
        assertEq(buck.totalSupply(), 0);

        vm.prank(address(this));
        buck.mint(ALICE, 5 ether);

        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 0));
        assertEq(buck.balanceOf(ALICE), 5 ether);
        assertEq(buck.balanceOf(BOB), 0);

        vm.prank(ALICE);
        assertTrue(buck.approve(BOB, 10 ether));
        vm.prank(BOB);
        assertTrue(buck.transferFrom(ALICE, BOB, 0));
        assertEq(buck.balanceOf(ALICE), 5 ether);
        assertEq(buck.balanceOf(BOB), 0);
        assertEq(buck.allowance(ALICE, BOB), 10 ether);
    }

    function testMintRequiresKyc() public {
        _configureModules();

        vm.expectRevert(abi.encodeWithSelector(Buck.AccessCheckFailed.selector, ALICE));
        _mint(ALICE, 1 ether);
    }

    function testMintSucceedsWhenKycApproved() public {
        _configureModules();
        _setKyc(ALICE, true);
        _mint(ALICE, 1 ether);
        assertEq(buck.balanceOf(ALICE), 1 ether);
    }

    function testMintRestrictedToAuthorizedCallers() public {
        _configureModules();
        _setKyc(ALICE, true);

        // Non-authorized caller cannot mint.
        vm.prank(ALICE);
        vm.expectRevert(Buck.NotAuthorizedMinter.selector);
        buck.mint(ALICE, 1 ether);

        // Rewards hook is allowed to mint.
        vm.prank(address(rewardsHook));
        buck.mint(ALICE, 1 ether);
        assertEq(buck.balanceOf(ALICE), 1 ether);

        // Liquidity window (address(this)) can mint as well.
        _setKyc(BOB, true);
        buck.mint(BOB, 2 ether);
        assertEq(buck.balanceOf(BOB), 2 ether);
    }

    function testBurnRestrictedToLiquidityWindow() public {
        _configureModules();
        _setKyc(ALICE, true);
        _mint(ALICE, 2 ether);

        // Non-liquidity-window caller cannot burn.
        vm.prank(ALICE);
        vm.expectRevert(Buck.NotLiquidityWindow.selector);
        buck.burn(ALICE, 1 ether);

        // Liquidity window (address(this)) succeeds.
        buck.burn(ALICE, 1 ether);
        assertEq(buck.balanceOf(ALICE), 1 ether);
    }

    function testTransferDoesNotRequireKyc() public {
        // Transfers are now permissionless - KYC only required at mint/refund
        _configureModules();
        _setKyc(ALICE, true);
        _mint(ALICE, 2 ether);

        // BOB has no KYC, but can still receive tokens
        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 1 ether));
        assertEq(buck.balanceOf(BOB), 1 ether);

        // BOB can also transfer without KYC
        vm.prank(BOB);
        assertTrue(buck.transfer(ALICE, 0.5 ether));
        assertEq(buck.balanceOf(ALICE), 1.5 ether);
    }

    function testTransferWorksEvenWhenSenderRevoked() public {
        // Transfers are now permissionless - KYC revocation doesn't block transfers
        _configureModules();
        _setKyc(ALICE, true);
        _setKyc(BOB, true);
        _mint(ALICE, 2 ether);

        _setKyc(ALICE, false);

        // ALICE can still transfer even with revoked KYC
        vm.prank(ALICE);
        assertTrue(buck.transfer(BOB, 1 ether));
        assertEq(buck.balanceOf(BOB), 1 ether);
    }

    function testSystemAccountsBypassKyc() public {
        _configureModules();
        _setKyc(ALICE, true);
        _mint(ALICE, 2 ether);

        address liquidityReserve = buck.liquidityReserve();
        _setKyc(liquidityReserve, false);

        vm.prank(ALICE);
        assertTrue(buck.transfer(liquidityReserve, 1 ether));
        assertEq(buck.balanceOf(liquidityReserve), 1 ether);

        // Liquidity reserve can send back despite not being marked allowed.
        _setKyc(ALICE, true);
        vm.prank(liquidityReserve);
        assertTrue(buck.transfer(ALICE, 1 ether));
    }

    function _permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", buck.DOMAIN_SEPARATOR(), structHash));
    }

    function _setKyc(address account, bool allowed) internal {
        accessRegistry.setAllowed(account, allowed);
    }
}
