// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IComplianceOracle.sol";

/// @title ComplianceOracle — Configurable compliance layer for privacy pools
/// @notice Implements selective disclosure: users prove compliance without
///         revealing transaction details. Supports blocklist, viewing-key based
///         auditing, and configurable compliance policies.
///
/// @dev This oracle is queried by PrivacyPool during transfers/withdrawals.
///      The design preserves privacy by default: compliance checks validate
///      ZK proofs rather than inspecting plaintext values.
contract ComplianceOracle is IComplianceOracle {
    // ── Storage ────────────────────────────────────────

    address public governance;

    /// @notice Blocked addresses (e.g., sanctioned entities).
    mapping(address => bool) private _blocked;

    /// @notice Blocked commitment hashes (e.g., tainted notes).
    mapping(bytes32 => bool) private _blockedCommitments;

    /// @notice Authorized auditors who can submit viewing-key proofs.
    mapping(address => bool) public authorizedAuditors;

    /// @notice Compliance policy version — incremented on policy changes.
    uint256 public policyVersion;

    /// @notice Whether compliance checking is enabled (can be disabled for testnets).
    bool public complianceEnabled;

    /// @notice Maximum transaction value before enhanced due diligence (0 = no limit).
    uint256 public enhancedDueDiligenceThreshold;

    /// @notice ZK verifier for viewing-key disclosure proofs (address(0) = accept non-empty proofs).
    address public viewingKeyVerifier;

    // ── Events ─────────────────────────────────────────

    event AddressBlocked(address indexed account, string reason);
    event AddressUnblocked(address indexed account);
    event CommitmentBlocked(bytes32 indexed commitment, string reason);
    event AuditorAdded(address indexed auditor);
    event AuditorRemoved(address indexed auditor);
    event PolicyUpdated(uint256 newVersion);
    event ComplianceToggled(bool enabled);
    event ViewingKeyVerifierUpdated(address indexed verifier);

    // ── Modifiers ──────────────────────────────────────

    modifier onlyGovernance() {
        require(msg.sender == governance, "ComplianceOracle: not governance");
        _;
    }

    modifier onlyAuditor() {
        require(
            authorizedAuditors[msg.sender],
            "ComplianceOracle: not auditor"
        );
        _;
    }

    // ── Constructor ────────────────────────────────────

    constructor() {
        governance = msg.sender;
        complianceEnabled = true;
        policyVersion = 1;
    }

    // ── IComplianceOracle Implementation ───────────────

    /// @inheritdoc IComplianceOracle
    function checkCompliance(
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        bytes calldata viewingKeyProof
    ) external view override returns (bool compliant) {
        // If compliance is disabled, everything passes.
        if (!complianceEnabled) {
            return true;
        }

        // Check nullifiers are not from blocked commitments.
        for (uint256 i = 0; i < 2; i++) {
            if (_blockedCommitments[nullifiers[i]]) {
                return false;
            }
        }

        // Check output commitments are not blocked.
        for (uint256 i = 0; i < 2; i++) {
            if (_blockedCommitments[outputCommitments[i]]) {
                return false;
            }
        }

        // If a viewing-key proof is provided, verify it.
        if (viewingKeyProof.length > 0) {
            if (viewingKeyVerifier != address(0)) {
                // Proof structure: [32 bytes auditorPubKeyHash][remainder = zkProof]
                // The ZK proof demonstrates that an authorized auditor can decrypt
                // the note details (value, recipient) without revealing them on-chain.
                // The verifier checks:
                //   1. auditorPubKeyHash matches a registered auditor
                //   2. The SNARK/STARK proof is valid for the public inputs
                //      (nullifiers, outputCommitments, auditorPubKeyHash)
                require(
                    viewingKeyProof.length >= 33,
                    "ComplianceOracle: proof too short"
                );

                bytes32 auditorKeyHash = bytes32(viewingKeyProof[:32]);
                bytes memory zkProof = viewingKeyProof[32:];

                // Build public inputs: [nullifiers[0], nullifiers[1], outputs[0], outputs[1], auditorKeyHash]
                bytes memory publicInputs = abi.encodePacked(
                    nullifiers[0],
                    nullifiers[1],
                    outputCommitments[0],
                    outputCommitments[1],
                    auditorKeyHash
                );

                // Call the viewing-key verifier: verify(bytes proof, bytes publicInputs) -> bool
                (bool success, bytes memory result) = viewingKeyVerifier
                    .staticcall(
                        abi.encodeWithSignature(
                            "verify(bytes,bytes)",
                            zkProof,
                            publicInputs
                        )
                    );

                if (!success || result.length < 32) {
                    return false;
                }

                bool verified = abi.decode(result, (bool));
                return verified;
            }

            // No verifier set — accept non-empty proof (testnet/development mode).
            return true;
        }

        // Default: compliant if no blocking conditions met.
        return true;
    }

    /// @inheritdoc IComplianceOracle
    function isBlocked(
        address account
    ) external view override returns (bool blocked) {
        return _blocked[account];
    }

    // ── Governance: Blocklist Management ───────────────

    /// @notice Block an address (e.g., sanctioned entity).
    function blockAddress(
        address account,
        string calldata reason
    ) external onlyGovernance {
        _blocked[account] = true;
        emit AddressBlocked(account, reason);
    }

    /// @notice Unblock an address.
    function unblockAddress(address account) external onlyGovernance {
        _blocked[account] = false;
        emit AddressUnblocked(account);
    }

    /// @notice Block a commitment hash (tainted note).
    function blockCommitment(
        bytes32 commitment,
        string calldata reason
    ) external onlyGovernance {
        _blockedCommitments[commitment] = true;
        emit CommitmentBlocked(commitment, reason);
    }

    /// @notice Check if a commitment is blocked.
    function isCommitmentBlocked(
        bytes32 commitment
    ) external view returns (bool) {
        return _blockedCommitments[commitment];
    }

    // ── Governance: Auditor Management ─────────────────

    /// @notice Add an authorized auditor.
    function addAuditor(address auditor) external onlyGovernance {
        authorizedAuditors[auditor] = true;
        emit AuditorAdded(auditor);
    }

    /// @notice Remove an auditor.
    function removeAuditor(address auditor) external onlyGovernance {
        authorizedAuditors[auditor] = false;
        emit AuditorRemoved(auditor);
    }

    // ── Governance: Policy ─────────────────────────────

    /// @notice Toggle compliance checking on/off.
    function setComplianceEnabled(bool enabled) external onlyGovernance {
        complianceEnabled = enabled;
        emit ComplianceToggled(enabled);
    }

    /// @notice Set the enhanced due diligence threshold.
    function setEDDThreshold(uint256 threshold) external onlyGovernance {
        enhancedDueDiligenceThreshold = threshold;
    }

    /// @notice Bump the policy version (forces clients to re-check).
    function updatePolicy() external onlyGovernance {
        policyVersion++;
        emit PolicyUpdated(policyVersion);
    }

    /// @notice Transfer governance.
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "ComplianceOracle: zero address");
        governance = newGovernance;
    }

    /// @notice Set the viewing-key ZK proof verifier contract.
    /// @param verifier The verifier address (address(0) disables ZK verification).
    function setViewingKeyVerifier(address verifier) external onlyGovernance {
        viewingKeyVerifier = verifier;
        emit ViewingKeyVerifierUpdated(verifier);
    }
}
