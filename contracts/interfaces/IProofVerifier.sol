// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProofVerifier — Interface for ZK proof verification
/// @notice Wraps different proving systems (UltraHonk for ZAseon, Halo2/SNARK wrapper for Lumora)
interface IProofVerifier {
    /// @notice Verify a transfer proof
    /// @param proof The serialized proof bytes
    /// @param publicInputs The public inputs to the circuit
    /// @return valid Whether the proof is valid
    function verifyTransferProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid);

    /// @notice Verify a withdrawal proof
    /// @param proof The serialized proof bytes
    /// @param publicInputs The public inputs to the circuit
    /// @return valid Whether the proof is valid
    function verifyWithdrawProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid);

    /// @notice Verify an aggregated proof (multiple transactions in one proof)
    /// @param proof The serialized aggregated proof bytes
    /// @param publicInputs The public inputs to the aggregation circuit
    /// @return valid Whether the proof is valid
    function verifyAggregatedProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid);

    /// @notice Get the proving system identifier
    /// @return system The proving system name (e.g., "UltraHonk", "Halo2-SNARK", "Groth16")
    function provingSystem() external pure returns (string memory system);
}
