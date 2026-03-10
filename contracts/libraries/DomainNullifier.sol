// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoseidonHasher} from "./PoseidonHasher.sol";

/// @title DomainNullifier — Domain-separated nullifier algebra for cross-chain privacy
/// @notice Implements V1 (simple) and V2 (domain-separated) nullifier schemes.
///         V2 nullifiers include chain_id and app_id to prevent cross-chain replay
///         while allowing the same spending key to be used across chains.
library DomainNullifier {
    /// @notice Compute a V1 nullifier: Poseidon(spending_key, commitment)
    /// @param spendingKey The owner's spending key
    /// @param commitment The note commitment
    /// @return nullifier The V1 nullifier
    function computeV1(
        uint256 spendingKey,
        uint256 commitment
    ) internal pure returns (uint256) {
        return PoseidonHasher.hash(spendingKey, commitment);
    }

    /// @notice Compute a V2 domain-separated nullifier:
    ///         Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))
    /// @param spendingKey The owner's spending key
    /// @param commitment The note commitment
    /// @param chainId The chain ID for domain separation
    /// @param appId The application ID for domain separation
    /// @return nullifier The V2 domain-separated nullifier
    function computeV2(
        uint256 spendingKey,
        uint256 commitment,
        uint256 chainId,
        uint256 appId
    ) internal pure returns (uint256) {
        uint256 inner = PoseidonHasher.hash(spendingKey, commitment);
        uint256 domain = PoseidonHasher.hash(chainId, appId);
        return PoseidonHasher.hash(inner, domain);
    }

    /// @notice Compute a domain tag from chain/app identifiers
    /// @param chainId The chain ID (e.g., Polkadot paraId, Avalanche subnetId)
    /// @param appId The application/protocol ID
    /// @return tag The domain separation tag
    function computeDomainTag(
        uint256 chainId,
        uint256 appId
    ) internal pure returns (uint256) {
        return PoseidonHasher.hash(chainId, appId);
    }

    /// @notice Verify that a nullifier matches expected V2 computation
    ///         (used in proof public input validation)
    function verifyV2(
        uint256 nullifier,
        uint256 spendingKey,
        uint256 commitment,
        uint256 chainId,
        uint256 appId
    ) internal pure returns (bool) {
        return nullifier == computeV2(spendingKey, commitment, chainId, appId);
    }
}
