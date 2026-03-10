// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IComplianceOracle — Interface for optional compliance hooks
/// @notice Allows selective transparency for regulatory requirements
///         while preserving privacy for non-regulated transactions.
interface IComplianceOracle {
    /// @notice Check if a transaction is compliant with current policy
    /// @param nullifiers The nullifiers being spent
    /// @param outputCommitments The new output commitments
    /// @param viewingKeyProof Optional proof of viewing key disclosure
    /// @return compliant Whether the transaction passes compliance checks
    function checkCompliance(
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        bytes calldata viewingKeyProof
    ) external view returns (bool compliant);

    /// @notice Check if an address is sanctioned/blocked
    /// @param account The address to check
    /// @return blocked Whether the address is blocked
    function isBlocked(address account) external view returns (bool blocked);
}
