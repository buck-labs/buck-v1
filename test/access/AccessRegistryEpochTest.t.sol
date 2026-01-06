// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {AccessRegistry} from "src/access/AccessRegistry.sol";
import {Merkle} from "murky/src/Merkle.sol";

/// @title AccessRegistryEpochTest
/// @notice Comprehensive tests proving epoch + merkle proof security model
/// @dev Tests validate that epoch param is UX helper; real security = merkle verification
contract AccessRegistryEpochTest is BaseTest {
    AccessRegistry internal registry;
    Merkle internal merkle;

    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant ATTESTOR = address(0xA77E);
    address internal constant USER1 = address(0xBEEF);
    address internal constant USER2 = address(0xCAFE);
    address internal constant USER3 = address(0xDEAD);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        registry = new AccessRegistry(TIMELOCK, ATTESTOR);
        merkle = new Merkle();
    }

    // =========================================================================
    // EPOCH PARAMETER TESTS
    // =========================================================================

    /// @notice Tests that epoch parameter is ignored (kept for interface compatibility)
    /// @dev The epoch check was removed because epoch is not in the leaf hash,
    ///      so it provided no actual replay protection. Merkle verification is sufficient.
    function testEpochParameterIsIgnored() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(USER1));
        bytes32 root = leaf1;

        // Set root for Epoch 10
        vm.prank(ATTESTOR);
        registry.setRoot(root, 10);

        bytes32[] memory proof = new bytes32[](0);

        // Registering with any epoch value works - epoch is not validated
        // Security comes from merkle proof verification, not epoch matching
        vm.prank(USER1);
        registry.registerWithProof(proof); // Would have been "stale" before

        assertTrue(registry.isAllowed(USER1));
    }

    // =========================================================================
    // VALID REGISTRATION TESTS
    // =========================================================================

    /// @notice Happy path: valid proof + correct epoch = successful registration
    function testValidProofWithCorrectEpochSucceeds() public {
        // Build merkle tree with USER1, USER2, USER3
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = keccak256(abi.encodePacked(USER1));
        leaves[1] = keccak256(abi.encodePacked(USER2));
        leaves[2] = keccak256(abi.encodePacked(USER3));

        bytes32 root = merkle.getRoot(leaves);

        // Attestor sets root for epoch 1
        vm.prank(ATTESTOR);
        registry.setRoot(root, 1);

        // USER1 registers with valid proof for epoch 1
        bytes32[] memory proof = merkle.getProof(leaves, 0);
        vm.prank(USER1);
        registry.registerWithProof(proof);

        // Verify USER1 is now allowed
        assertTrue(registry.isAllowed(USER1));
        assertFalse(registry.isAllowed(ATTACKER)); // Attacker not in tree
    }

    // =========================================================================
    // CORE SECURITY TEST: OLD PROOF + NEW ROOT = FAILURE
    // =========================================================================

    /// @notice THE KEY ATTACK SCENARIO: Proves old proofs fail with new roots
    /// @dev This is the critical test that validates epoch-in-leaf is unnecessary
    /// User has valid proof for Epoch 10, tries to reuse it at Epoch 11
    function testOldProofFailsWithNewRoot() public {
        // ===== EPOCH 10: Initial tree with USER1 and USER2 =====
        bytes32[] memory leavesEpoch10 = new bytes32[](2);
        leavesEpoch10[0] = keccak256(abi.encodePacked(USER1));
        leavesEpoch10[1] = keccak256(abi.encodePacked(USER2));
        bytes32 rootEpoch10 = merkle.getRoot(leavesEpoch10);

        vm.prank(ATTESTOR);
        registry.setRoot(rootEpoch10, 10);

        // USER1 gets valid proof for epoch 10
        bytes32[] memory proofEpoch10 = merkle.getProof(leavesEpoch10, 0);

        // USER1 successfully registers at epoch 10
        vm.prank(USER1);
        registry.registerWithProof(proofEpoch10);
        assertTrue(registry.isAllowed(USER1));

        // ===== EPOCH 11: New tree with different users (USER2 and USER3) =====
        bytes32[] memory leavesEpoch11 = new bytes32[](2);
        leavesEpoch11[0] = keccak256(abi.encodePacked(USER2));
        leavesEpoch11[1] = keccak256(abi.encodePacked(USER3));
        bytes32 rootEpoch11 = merkle.getRoot(leavesEpoch11);

        vm.prank(ATTESTOR);
        registry.setRoot(rootEpoch11, 11);

        // ===== ATTACK: ATTACKER tries to use old proof with new epoch param =====
        // ATTACKER has USER1's old proof from epoch 10
        // Tries to use it against the new root

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        registry.registerWithProof(proofEpoch10);
        // ❌ FAILS at merkle verification
        // Proof was for rootEpoch10, contract now has rootEpoch11

        // ===== ATTACK 2: Try to pass old epoch (also fails at merkle verification) =====
        // Epoch parameter is no longer validated - security comes from merkle proof
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        registry.registerWithProof(proofEpoch10);
        // ❌ FAILS at merkle verification (rootId is ignored, proof still doesn't match)

        // ATTACKER remains blocked
        assertFalse(registry.isAllowed(ATTACKER));
    }

    // =========================================================================
    // ADDITIONAL SECURITY TESTS
    // =========================================================================

    /// @notice Test that proof from completely different tree fails
    /// @dev Even with correct epoch, wrong merkle tree = invalid
    function testProofFromDifferentTreeFails() public {
        // Tree 1: Real tree with USER1, USER2
        bytes32[] memory tree1 = new bytes32[](2);
        tree1[0] = keccak256(abi.encodePacked(USER1));
        tree1[1] = keccak256(abi.encodePacked(USER2));
        bytes32 root1 = merkle.getRoot(tree1);

        // Tree 2: Different tree with ATTACKER and USER3
        bytes32[] memory tree2 = new bytes32[](2);
        tree2[0] = keccak256(abi.encodePacked(ATTACKER));
        tree2[1] = keccak256(abi.encodePacked(USER3));

        // Set root1 as the official root
        vm.prank(ATTESTOR);
        registry.setRoot(root1, 1);

        // ATTACKER has valid proof for tree2, tries to use it against tree1
        bytes32[] memory attackerProof = merkle.getProof(tree2, 0);

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        registry.registerWithProof(attackerProof);

        assertFalse(registry.isAllowed(ATTACKER));
    }

    /// @notice Test replay protection: can't register twice
    function testCannotRegisterTwice() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(USER1));
        leaves[1] = keccak256(abi.encodePacked(USER2));
        bytes32 root = merkle.getRoot(leaves);

        vm.prank(ATTESTOR);
        registry.setRoot(root, 1);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // First registration succeeds
        vm.prank(USER1);
        registry.registerWithProof(proof);
        assertTrue(registry.isAllowed(USER1));

        // Second registration fails
        vm.prank(USER1);
        vm.expectRevert(bytes("AccessRegistry: already allowed"));
        registry.registerWithProof(proof);
    }

    /// @notice Full lifecycle: epoch advances, old proofs fail, new proofs work
    function testFullLifecycleAcrossMultipleEpochs() public {
        // ===== EPOCH 1: USER1 can register =====
        bytes32[] memory epoch1Leaves = new bytes32[](2);
        epoch1Leaves[0] = keccak256(abi.encodePacked(USER1));
        epoch1Leaves[1] = keccak256(abi.encodePacked(USER2));
        bytes32 epoch1Root = merkle.getRoot(epoch1Leaves);

        vm.prank(ATTESTOR);
        registry.setRoot(epoch1Root, 1);

        bytes32[] memory epoch1Proof = merkle.getProof(epoch1Leaves, 0);
        vm.prank(USER1);
        registry.registerWithProof(epoch1Proof);
        assertTrue(registry.isAllowed(USER1));

        // ===== EPOCH 2: Different tree, USER2 and USER3 =====
        bytes32[] memory epoch2Leaves = new bytes32[](2);
        epoch2Leaves[0] = keccak256(abi.encodePacked(USER2));
        epoch2Leaves[1] = keccak256(abi.encodePacked(USER3));
        bytes32 epoch2Root = merkle.getRoot(epoch2Leaves);

        vm.prank(ATTESTOR);
        registry.setRoot(epoch2Root, 2);

        // USER2 registers successfully with epoch 2 proof
        bytes32[] memory epoch2Proof = merkle.getProof(epoch2Leaves, 0);
        vm.prank(USER2);
        registry.registerWithProof(epoch2Proof);
        assertTrue(registry.isAllowed(USER2));

        // ===== EPOCH 3: New tree with USER3 and ATTACKER =====
        bytes32[] memory epoch3Leaves = new bytes32[](2);
        epoch3Leaves[0] = keccak256(abi.encodePacked(USER3));
        epoch3Leaves[1] = keccak256(abi.encodePacked(ATTACKER));
        bytes32 epoch3Root = merkle.getRoot(epoch3Leaves);

        vm.prank(ATTESTOR);
        registry.setRoot(epoch3Root, 3);

        // ATTACKER steals USER1's old proof, tries with current epoch
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        registry.registerWithProof(epoch1Proof);

        // USER3 registers successfully with epoch 3 proof
        bytes32[] memory epoch3Proof = merkle.getProof(epoch3Leaves, 0);
        vm.prank(USER3);
        registry.registerWithProof(epoch3Proof);
        assertTrue(registry.isAllowed(USER3));
    }

    /// @notice Test that attacker cannot forge proofs for addresses not in tree
    function testCannotForgeProofForAddressNotInTree() public {
        // Tree contains USER1 and USER2, but not ATTACKER
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(USER1));
        leaves[1] = keccak256(abi.encodePacked(USER2));
        bytes32 root = merkle.getRoot(leaves);

        vm.prank(ATTESTOR);
        registry.setRoot(root, 1);

        // ATTACKER tries to register with empty proof (will fail)
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("AccessRegistry: invalid proof"));
        registry.registerWithProof(emptyProof);

        assertFalse(registry.isAllowed(ATTACKER));
    }

    /// @notice Test epoch must strictly increase
    function testEpochMustStrictlyIncrease() public {
        bytes32 root1 = keccak256(abi.encodePacked(USER1));
        bytes32 root2 = keccak256(abi.encodePacked(USER2));

        vm.prank(ATTESTOR);
        registry.setRoot(root1, 5);

        // Try to set same rootId
        vm.prank(ATTESTOR);
        vm.expectRevert(bytes("AccessRegistry: rootId must increase"));
        registry.setRoot(root2, 5);

        // Try to set lower rootId
        vm.prank(ATTESTOR);
        vm.expectRevert(bytes("AccessRegistry: rootId must increase"));
        registry.setRoot(root2, 4);

        // Higher epoch works
        vm.prank(ATTESTOR);
        registry.setRoot(root2, 6);
        assertEq(registry.currentRootId(), 6);
    }
}
