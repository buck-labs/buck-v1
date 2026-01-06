// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "test/utils/BaseTest.sol";
import {AccessRegistry} from "src/access/AccessRegistry.sol";
import {console} from "forge-std/Test.sol";

contract AccessRegistryGasTest is BaseTest {
    AccessRegistry internal registry;

    address internal constant TIMELOCK = address(0x1000);
    address internal constant ATTESTOR = address(0x2000);
    address internal constant USER = address(0x3000);

    function setUp() public {
        registry = new AccessRegistry(TIMELOCK, ATTESTOR);

        // Set up a merkle root
        // This simulates what would happen in production
        vm.prank(ATTESTOR);
        registry.setRoot(0x1234567890123456789012345678901234567890123456789012345678901234, 1);
    }

    function test_GasConsumption_RegisterWithProof_SingleProof() public {
        // Single proof element (like in the failed tx)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = 0x1b6649069777bae6ca3b653dd520472d9e69677614997179a51c20e42455af5b;

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        try registry.registerWithProof(proof) {
            // This will fail because the proof is invalid, but we can still measure gas
        } catch {
            // Expected to fail
        }

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for registerWithProof with 1 proof element:", gasUsed);
    }

    function test_GasBreakdown_RegisterWithProof() public view {
        // Test the gas cost of each operation
        uint256 totalGas = 0;

        // 1. Storage read of merkleRoot
        uint256 gas1 = gasleft();
        registry.merkleRoot();
        uint256 gasUsed = gas1 - gasleft();
        console.log("Gas for reading merkleRoot:", gasUsed);
        totalGas += gasUsed;

        // 2. Storage read of currentRootId
        gas1 = gasleft();
        registry.currentRootId();
        gasUsed = gas1 - gasleft();
        console.log("Gas for reading currentRootId:", gasUsed);
        totalGas += gasUsed;

        // 3. Storage read of isAllowed
        gas1 = gasleft();
        registry.isAllowed(USER);
        gasUsed = gas1 - gasleft();
        console.log("Gas for reading isAllowed:", gasUsed);
        totalGas += gasUsed;

        // 4. Keccak256 computation
        gas1 = gasleft();
        bytes32 leaf = keccak256(abi.encodePacked(USER));
        gasUsed = gas1 - gasleft();
        console.log("Gas for keccak256:", gasUsed);
        totalGas += gasUsed;

        // 5. Simulate MerkleProof verification (this is the expensive part)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = 0x1b6649069777bae6ca3b653dd520472d9e69677614997179a51c20e42455af5b;

        gas1 = gasleft();
        // We can't call MerkleProof directly but we can estimate
        // MerkleProof.verifyCalldata does: hash = keccak256(abi.encodePacked(a, b)) for each proof element
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            if (computedHash <= proof[i]) {
                computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
            } else {
                computedHash = keccak256(abi.encodePacked(proof[i], computedHash));
            }
        }
        gasUsed = gas1 - gasleft();
        console.log("Gas for Merkle verification (1 element):", gasUsed);
        totalGas += gasUsed;

        // Test with multiple proof elements
        bytes32[] memory longProof = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            longProof[i] = bytes32(uint256(i + 1));
        }

        gas1 = gasleft();
        computedHash = leaf;
        for (uint256 i = 0; i < longProof.length; i++) {
            if (computedHash <= longProof[i]) {
                computedHash = keccak256(abi.encodePacked(computedHash, longProof[i]));
            } else {
                computedHash = keccak256(abi.encodePacked(longProof[i], computedHash));
            }
        }
        gasUsed = gas1 - gasleft();
        console.log("Gas for Merkle verification (10 elements):", gasUsed);

        // 6. Storage write (SSTORE)
        console.log("SSTORE to new slot costs ~20,000 gas");
        totalGas += 20000;

        console.log("\n=== TOTAL ESTIMATED GAS ===");
        uint256 totalBase = 21000; // Base transaction cost
        uint256 calldataGas = 68 * 16 + 32 * 4; // Non-zero bytes * 16 + zero bytes * 4
        console.log("Base tx cost:", totalBase);
        console.log("Calldata cost:", calldataGas);
        console.log("Function execution:", totalGas);
        console.log("Total estimated:", totalBase + calldataGas + totalGas);
    }

    function test_MerkleProofGasScaling() public view {
        // Test how gas scales with proof size
        for (uint256 size = 1; size <= 32; size++) {
            bytes32[] memory proof = new bytes32[](size);
            for (uint256 i = 0; i < size; i++) {
                proof[i] = bytes32(uint256(i + 1));
            }

            uint256 gasBefore = gasleft();
            bytes32 computedHash = bytes32(0);
            for (uint256 i = 0; i < proof.length; i++) {
                if (computedHash <= proof[i]) {
                    computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
                } else {
                    computedHash = keccak256(abi.encodePacked(proof[i], computedHash));
                }
            }
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Proof size:", size, "Gas used:", gasUsed);
        }
    }
}
