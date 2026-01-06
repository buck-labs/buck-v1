// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {AccessRegistry} from "src/access/AccessRegistry.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract AccessRegistryTest is BaseTest {
    AccessRegistry internal registry;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant USER1 = address(0xBEEF);
    address internal constant USER2 = address(0xCAFE);

    function setUp() public {
        registry = new AccessRegistry(TIMELOCK, TIMELOCK);
    }

    function testSetRootOnlyTimelock() public {
        bytes32 root = _computeRoot(keccak256("leaf1"), keccak256("leaf2"));

        vm.expectRevert(bytes("AccessRegistry: unauthorized"));
        registry.setRoot(root, 1);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);
        assertEq(registry.merkleRoot(), root);
        assertEq(registry.currentRootId(), 1);
    }

    function testRegisterWithValidProofSucceeds() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 7);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));
    }

    function testRegisterFailsWithInvalidProof() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 7);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        vm.prank(USER1);
        registry.registerWithProof(proof);
    }

    function testRegisterFailsWhenRootNotSet() public {
        bytes32[] memory proof;
        vm.expectRevert(bytes("AccessRegistry: root not set"));
        vm.prank(USER1);
        registry.registerWithProof(proof);
    }

    function testRevokeOnlyTimelock() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 3);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);

        vm.expectRevert(bytes("AccessRegistry: unauthorized"));
        registry.revoke(USER1);

        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertFalse(registry.isAllowed(USER1));
    }

    function testRevokeBatchRequiresAuthorization() public {
        address[] memory targets = new address[](1);
        targets[0] = USER1;

        vm.expectRevert(bytes("AccessRegistry: unauthorized"));
        registry.revokeBatch(targets);
    }

    function testRevokeBatchRevokesMultipleAddresses() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 4);

        bytes32[] memory proofForUser1 = new bytes32[](1);
        proofForUser1[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proofForUser1);

        bytes32[] memory proofForUser2 = new bytes32[](1);
        proofForUser2[0] = leaf1;
        vm.prank(USER2);
        registry.registerWithProof(proofForUser2);

        address[] memory targets = new address[](2);
        targets[0] = USER1;
        targets[1] = USER2;

        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, false, 4);
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER2, false, 4);
        vm.prank(TIMELOCK);
        registry.revokeBatch(targets);

        assertFalse(registry.isAllowed(USER1));
        assertFalse(registry.isAllowed(USER2));
    }

    function testRevokeBatchSkipsAlreadyRevokedAddresses() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 6);

        bytes32[] memory proofForUser1 = new bytes32[](1);
        proofForUser1[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proofForUser1);

        // USER2 was never registered (remains false in mapping)
        address[] memory targets = new address[](2);
        targets[0] = USER1;
        targets[1] = USER2;

        vm.recordLogs();
        vm.prank(TIMELOCK);
        registry.revokeBatch(targets);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Now emits AccessUpdated for USER1 + Denylisted for both USER1 and USER2
        assertEq(logs.length, 3, "should emit AccessUpdated(USER1) + Denylisted(USER1) + Denylisted(USER2)");

        // Verify USER1 was revoked and USER2 remains unapproved
        assertFalse(registry.isAllowed(USER1));
        assertFalse(registry.isAllowed(USER2));

        // Both should be denylisted
        assertTrue(registry.isDenylisted(USER1));
        assertTrue(registry.isDenylisted(USER2));

        // Ensure the first emitted event is AccessUpdated for USER1
        bytes32 expectedTopic = keccak256("AccessUpdated(address,bool,uint64)");
        assertEq(logs[0].topics[0], expectedTopic);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), USER1);
    }

    function testPauseRegistrationBlocksRegister() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 5);

        vm.prank(TIMELOCK);
        registry.pauseRegistration();

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerWithProof(proof);

        vm.prank(TIMELOCK);
        registry.unpauseRegistration();

        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));
    }

    function testLifecycleSetRootRegisterAndRevoke() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 9);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, true, 9);
        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));

        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, false, 9);
        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertFalse(registry.isAllowed(USER1));
    }

    // -------------------------------------------------------------------------
    // Manual Override Tests (setAttestor, forceAllow)
    // -------------------------------------------------------------------------

    function testSetAttestorOnlyOwner() public {
        address newAttestor = address(0xDEAD);

        // Non-owner cannot set attestor
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this))
        );
        registry.setAttestor(newAttestor);

        // Owner can set attestor
        vm.expectEmit(true, false, false, false);
        emit AccessRegistry.AttestorUpdated(newAttestor);
        vm.prank(TIMELOCK);
        registry.setAttestor(newAttestor);

        assertEq(registry.attestor(), newAttestor);
    }

    function testSetAttestorRejectsZeroAddress() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(bytes("AccessRegistry: invalid attestor"));
        registry.setAttestor(address(0));
    }

    function testRotateAttestor() public {
        address firstAttestor = address(0xFEED);
        address secondAttestor = address(0xBEAD);

        // Set first attestor
        vm.prank(TIMELOCK);
        registry.setAttestor(firstAttestor);
        assertEq(registry.attestor(), firstAttestor);

        // First attestor can set root
        bytes32 root = keccak256("root1");
        vm.prank(firstAttestor);
        registry.setRoot(root, 1);
        assertEq(registry.merkleRoot(), root);

        // Rotate to second attestor
        vm.prank(TIMELOCK);
        registry.setAttestor(secondAttestor);
        assertEq(registry.attestor(), secondAttestor);

        // First attestor can no longer set root
        bytes32 root2 = keccak256("root2");
        vm.prank(firstAttestor);
        vm.expectRevert(bytes("AccessRegistry: unauthorized"));
        registry.setRoot(root2, 2);

        // Second attestor can set root
        vm.prank(secondAttestor);
        registry.setRoot(root2, 2);
        assertEq(registry.merkleRoot(), root2);
    }

    function testForceAllowOnlyOwner() public {
        // Non-owner cannot force allow
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this))
        );
        registry.forceAllow(USER1);

        // Owner can force allow
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, true, 0); // epoch is 0 initially
        vm.prank(TIMELOCK); // TIMELOCK is the owner
        registry.forceAllow(USER1);

        assertTrue(registry.isAllowed(USER1));
    }

    function testForceAllowEmitsEventOnlyOnce() public {
        // First forceAllow should emit event
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, true, 0);
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));

        // Second forceAllow should NOT emit event (already allowed)
        vm.recordLogs();
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit event when already allowed");
    }

    function testForceAllowBypassesPause() public {
        // Pause registration
        vm.prank(TIMELOCK);
        registry.pauseRegistration();

        // Regular registration should fail
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerWithProof(proof);

        // But forceAllow should still work
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));
    }

    function testForceAllowThenRevoke() public {
        // Force allow USER1
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));

        // Revoke USER1 (sets _allowed=false AND _denylisted=true)
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, false, 0);
        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertFalse(registry.isAllowed(USER1));
        assertTrue(registry.isDenylisted(USER1));

        // Must removeDeny + forceAllow to reinstate (separate operations)
        vm.prank(TIMELOCK);
        registry.removeDeny(USER1);
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));
    }

    function testOwnerCanAlsoUseAttestorFunctions() public {
        // Owner should be able to call attestor-only functions
        bytes32 root = keccak256("owner-root");

        vm.prank(TIMELOCK); // TIMELOCK is owner
        registry.setRoot(root, 1);
        assertEq(registry.merkleRoot(), root);

        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));

        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertFalse(registry.isAllowed(USER1));
    }

    function testForceAllowSystemAddresses() public {
        address liquidityWindow = address(0x1111);
        address liquidityReserve = address(0x2222);
        address treasury = address(0x3333);

        // Force allow system addresses without requiring Merkle proof
        vm.prank(TIMELOCK);
        registry.forceAllow(liquidityWindow);

        vm.prank(TIMELOCK);
        registry.forceAllow(liquidityReserve);

        vm.prank(TIMELOCK);
        registry.forceAllow(treasury);

        assertTrue(registry.isAllowed(liquidityWindow));
        assertTrue(registry.isAllowed(liquidityReserve));
        assertTrue(registry.isAllowed(treasury));
    }

    // -------------------------------------------------------------------------
    // Denylist Tests (FIND-007 remediation)
    // -------------------------------------------------------------------------

    function testRevokeAddsToDenylist() public {
        // Setup: register USER1
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));
        assertFalse(registry.isDenylisted(USER1));

        // Revoke should add to denylist
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, false, 1);
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.Denylisted(USER1, true);
        vm.prank(TIMELOCK);
        registry.revoke(USER1);

        assertFalse(registry.isAllowed(USER1));
        assertTrue(registry.isDenylisted(USER1));
    }

    function testDenylistedUserCannotReRegister() public {
        // Setup: register and revoke USER1
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);

        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertTrue(registry.isDenylisted(USER1));

        // Attempt to re-register with same proof should fail
        vm.prank(USER1);
        vm.expectRevert(bytes("AccessRegistry: denylisted"));
        registry.registerWithProof(proof);
    }

    function testDenylistedUserCannotReRegisterEvenWithNewRoot() public {
        // Setup: register and revoke USER1
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);

        vm.prank(TIMELOCK);
        registry.revoke(USER1);

        // Publish new root (same tree, new epoch)
        vm.prank(TIMELOCK);
        registry.setRoot(root, 2);

        // Still cannot re-register because denylisted
        vm.prank(USER1);
        vm.expectRevert(bytes("AccessRegistry: denylisted"));
        registry.registerWithProof(proof);
    }

    function testRemoveDenyAndForceAllowSeparateOperations() public {
        // Setup: register and revoke USER1
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);

        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertTrue(registry.isDenylisted(USER1));
        assertFalse(registry.isAllowed(USER1));

        // removeDeny clears denylist, forceAllow adds to allowlist (separate operations)
        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.Denylisted(USER1, false);
        vm.prank(TIMELOCK);
        registry.removeDeny(USER1);

        assertFalse(registry.isDenylisted(USER1));
        assertFalse(registry.isAllowed(USER1)); // Still not allowed, just not denied

        vm.expectEmit(true, true, true, true);
        emit AccessRegistry.AccessUpdated(USER1, true, 1);
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);

        assertFalse(registry.isDenylisted(USER1));
        assertTrue(registry.isAllowed(USER1));
    }

    function testRemoveDenyDoesNotAllowlist() public {
        // Setup: register and revoke USER1
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 leaf2 = keccak256(abi.encodePacked(USER2));
        bytes32 root = _computeRoot(leaf1, leaf2);

        vm.prank(TIMELOCK);
        registry.setRoot(root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.prank(USER1);
        registry.registerWithProof(proof);

        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertTrue(registry.isDenylisted(USER1));
        assertFalse(registry.isAllowed(USER1));

        // removeDeny only clears denylist, does NOT add to allowlist
        vm.prank(TIMELOCK);
        registry.removeDeny(USER1);

        assertFalse(registry.isDenylisted(USER1));
        assertFalse(registry.isAllowed(USER1)); // Still not allowed!

        // User must re-register via Merkle proof to become allowed
        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));
    }

    function testForceAllowDoesNotClearDenylist() public {
        // Revoke USER1 (adds to denylist)
        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertTrue(registry.isDenylisted(USER1));

        // forceAllow adds to allowlist but does NOT clear denylist
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);

        assertTrue(registry.isDenylisted(USER1)); // Still denylisted!
        // isAllowed returns false because denylist overrides allowlist
        assertFalse(registry.isAllowed(USER1));
    }

    function testDenylistBlocksIsAllowedEvenIfAllowedTrue() public {
        // Force allow USER1 first
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);
        assertTrue(registry.isAllowed(USER1));

        // Revoke - this sets _allowed=false AND _denylisted=true
        vm.prank(TIMELOCK);
        registry.revoke(USER1);
        assertFalse(registry.isAllowed(USER1));
        assertTrue(registry.isDenylisted(USER1));

        // Even if we somehow had _allowed=true and _denylisted=true,
        // isAllowed should return false (denylist overrides)
        // This is tested implicitly - after revoke, isAllowed is false
    }

    function testDenylistEmitsEvent() public {
        vm.prank(TIMELOCK);
        registry.forceAllow(USER1);

        vm.recordLogs();
        vm.prank(TIMELOCK);
        registry.revoke(USER1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2); // AccessUpdated + Denylisted

        bytes32 denylistTopic = keccak256("Denylisted(address,bool)");
        assertEq(logs[1].topics[0], denylistTopic);
        assertEq(address(uint160(uint256(logs[1].topics[1]))), USER1);
    }

    function testRevokeNeverAllowedUserStillDenylists() public {
        // USER1 was never registered
        assertFalse(registry.isAllowed(USER1));
        assertFalse(registry.isDenylisted(USER1));

        // Revoke should still add to denylist (proactive block)
        vm.prank(TIMELOCK);
        registry.revoke(USER1);

        assertFalse(registry.isAllowed(USER1));
        assertTrue(registry.isDenylisted(USER1));
    }

    function _computeRoot(bytes32 leafA, bytes32 leafB) internal pure returns (bytes32) {
        return leafA < leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));
    }
}
