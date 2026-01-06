// SPDX-License-Identifier: Unlicensed
// Copyright (c) 2026 Buck Labs

pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// AccessRegistry tracks which wallets cleared compliance by verifying a Merkle proof from the attestor.
// Off-chain ops keeps the tree fresh and publishes roots, while users self-register via proofs.
// Goal: minimal surface area, clear audit trail of who toggled what, and fast reads for the rest of the stack.
contract AccessRegistry is Pausable, Ownable2Step {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // Root updates are our audit log: new tree hash + monotonically increasing root ID + who updated.
    event RootUpdated(bytes32 indexed newRoot, uint64 indexed rootId, address indexed updatedBy);
    // Tracks who the attestor service is for ops visibility.
    event AttestorUpdated(address indexed newAttestor);
    // Fired anytime an address flips in or out of the allowlist.
    event AccessUpdated(address indexed account, bool allowed, uint64 indexed rootId);
    // Fired when an address is added to or removed from the denylist.
    event Denylisted(address indexed account, bool isDenylisted);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error RenounceOwnershipDisabled();

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    // Latest tree hash from the attestor; proofs must target this or we reject them.
    bytes32 public merkleRoot;

    // Simple increasing counter so we know which vintage of the tree users are proving against.
    uint64 public currentRootId;

    // Tracks who has already proven and is currently allowed to interact.
    mapping(address => bool) private _allowed;

    // Persistent denylist: revoked addresses cannot re-register until explicitly cleared.
    mapping(address => bool) private _denylisted;

    // Attestor service (or owner) can publish new roots; we keep the pointer explicit here.
    address public attestor;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    // One-time setup: wire owner (timelock/multisig) and the attestor service.
    // Both must be non-zero or we bail so deployment scripts catch the mistake immediately.
    constructor(address initialOwner, address initialAttestor) Ownable(initialOwner) {
        require(initialAttestor != address(0), "AccessRegistry: invalid attestor");
        attestor = initialAttestor;
        emit AttestorUpdated(initialAttestor);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    // Attestor (or owner) gets to publish roots and revoke users; we reuse this everywhere.
    modifier onlyAttestor() {
        require(msg.sender == attestor || msg.sender == owner(), "AccessRegistry: unauthorized");
        _;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Update the address authorised to publish new roots.
    // Governance can rotate the attestor signer if we change providers or keys.
    // Zero address is disallowed so we never soft-brick proof verification.
    function setAttestor(address newAttestor) external onlyOwner {
        require(newAttestor != address(0), "AccessRegistry: invalid attestor");
        attestor = newAttestor;
        emit AttestorUpdated(newAttestor);
    }

    // Hard stop for new registrations during audits or emergencies; existing allows remain intact.
    function pauseRegistration() external onlyOwner {
        _pause();
    }

    // Flip registrations back on once the incident review clears.
    function unpauseRegistration() external onlyOwner {
        _unpause();
    }

    // Attestor posts the latest tree hash + rootId after TRM clears a batch.
    // RootId must strictly increase to version tree updates.
    function setRoot(bytes32 newRoot, uint64 rootId) external onlyAttestor {
        require(newRoot != bytes32(0), "AccessRegistry: invalid root");
        require(rootId > currentRootId, "AccessRegistry: rootId must increase");
        merkleRoot = newRoot;
        currentRootId = rootId;
        emit RootUpdated(newRoot, rootId, msg.sender);
    }

    // Attestor can yank an address if compliance flags it; no-op when already removed.
    function revoke(address account) external onlyAttestor {
        _revoke(account);
    }

    // Bulk version for when compliance hands us a whole batch; keep an eye on gas limits when calling.
    // Uses calldata iteration so the attestor can pass tight-packed arrays from off-chain tooling.
    function revokeBatch(address[] calldata accounts) external onlyAttestor {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            _revoke(accounts[i]);
        }
    }

    /// @notice Remove an account from the denylist without adding to allowlist.
    /// @dev Use when undoing a mistaken deny - account must still register via Merkle proof.
    // Lets governance undo a deny without bypassing the normal compliance verification flow.
    function removeDeny(address account) external onlyOwner {
        if (_denylisted[account]) {
            _denylisted[account] = false;
            emit Denylisted(account, false);
        }
    }

    /// @notice Emergency allowlist bypass (e.g., institutional accounts, manual remediation).
    /// @dev Owner-only access to prevent unilateral bypass of access verification.
    /// @dev Does NOT clear denylist - call removeDeny() first if account is denied.
    // Owner-only escape hatch when we need to manually allow someone without a Merkle proof.
    function forceAllow(address account) external onlyOwner {
        if (!_allowed[account]) {
            _allowed[account] = true;
            emit AccessUpdated(account, true, currentRootId);
        }
    }

    // Shared helper so single/batch revokes share the same event logic and guardrails.
    // Also adds to denylist to prevent immediate re-registration with same proof.
    function _revoke(address account) internal {
        if (_allowed[account]) {
            _allowed[account] = false;
            emit AccessUpdated(account, false, currentRootId);
        }
        if (!_denylisted[account]) {
            _denylisted[account] = true;
            emit Denylisted(account, true);
        }
    }

    // -------------------------------------------------------------------------
    // User flow
    // -------------------------------------------------------------------------

    /// @notice First-time registration. Users fetch the proof bundle from the
    ///         attestor service and submit it here.
    /// @param proof Array of sibling hashes leading to the root.
    // Main entry point for users: prove membership against the latest Merkle root and get marked allowed.
    // Rejects double registrations, denylisted users, and invalid proofs to keep the set tight.
    function registerWithProof(bytes32[] calldata proof) external whenNotPaused {
        require(!_denylisted[msg.sender], "AccessRegistry: denylisted");
        require(merkleRoot != bytes32(0), "AccessRegistry: root not set");
        require(!_allowed[msg.sender], "AccessRegistry: already allowed");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verifyCalldata(proof, merkleRoot, leaf), "AccessRegistry: invalid proof");

        _allowed[msg.sender] = true;
        emit AccessUpdated(msg.sender, true, currentRootId);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    // Simple view helper so other contracts can check access eligibility cheaply.
    // Denylisted accounts are never allowed, even if _allowed is true.
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account] && !_denylisted[account];
    }

    // Check if an account is on the denylist.
    function isDenylisted(address account) external view returns (bool) {
        return _denylisted[account];
    }

    // -------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------

    /// @notice Ownership renunciation is disabled to prevent accidental lockout
    /// @dev AccessRegistry requires ongoing governance for attestor management and access control
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
