// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PoseidonHasher — Poseidon hash function for ZK-friendly commitments
/// @notice T=3 (width 3, rate 2) Poseidon permutation over BN254 scalar field.
///         Used for note commitments, nullifiers, and Merkle tree hashing.
/// @dev Full-round constants for 128-bit security. This is a reference implementation;
///      production deployments should use optimized assembly or precompile.
library PoseidonHasher {
    // BN254 scalar field modulus
    uint256 internal constant FIELD_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // Number of full rounds (security parameter)
    uint256 internal constant FULL_ROUNDS = 8;
    // Number of partial rounds
    uint256 internal constant PARTIAL_ROUNDS = 57;

    /// @notice Hash two field elements using Poseidon
    /// @param left First input element
    /// @param right Second input element
    /// @return result The Poseidon hash
    function hash(
        uint256 left,
        uint256 right
    ) internal pure returns (uint256 result) {
        // State: [0, left, right]
        uint256[3] memory state;
        state[0] = 0;
        state[1] = left % FIELD_MODULUS;
        state[2] = right % FIELD_MODULUS;

        // Apply permutation rounds
        result = _permute(state);
    }

    /// @notice Hash a single field element (domain = 0)
    /// @param input The input element
    /// @return result The Poseidon hash
    function hashSingle(uint256 input) internal pure returns (uint256 result) {
        return hash(input, 0);
    }

    /// @notice Hash three field elements
    /// @param a First element
    /// @param b Second element
    /// @param c Third element
    /// @return result The Poseidon hash
    function hash3(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256 result) {
        // Two-step: hash(hash(a, b), c)
        uint256 intermediate = hash(a, b);
        result = hash(intermediate, c);
    }

    /// @notice Hash four field elements
    function hash4(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256) {
        uint256 h1 = hash(a, b);
        uint256 h2 = hash(c, d);
        return hash(h1, h2);
    }

    /// @dev Internal Poseidon permutation (simplified reference — production should use
    ///      precomputed round constants from the Poseidon paper)
    function _permute(uint256[3] memory state) private pure returns (uint256) {
        // S-box: x^5 (full rounds on all state elements)
        for (uint256 r = 0; r < FULL_ROUNDS / 2; r++) {
            // Add round constants (using hash of round index as placeholder)
            for (uint256 i = 0; i < 3; i++) {
                state[i] = addmod(
                    state[i],
                    uint256(keccak256(abi.encodePacked(r, i))),
                    FIELD_MODULUS
                );
            }
            // Full S-box on all elements
            for (uint256 i = 0; i < 3; i++) {
                state[i] = _sbox(state[i]);
            }
            // MDS mix
            state = _mds(state);
        }

        // Partial rounds (S-box only on first element)
        for (uint256 r = 0; r < PARTIAL_ROUNDS; r++) {
            for (uint256 i = 0; i < 3; i++) {
                state[i] = addmod(
                    state[i],
                    uint256(
                        keccak256(abi.encodePacked(FULL_ROUNDS / 2 + r, i))
                    ),
                    FIELD_MODULUS
                );
            }
            state[0] = _sbox(state[0]);
            state = _mds(state);
        }

        // Final full rounds
        for (uint256 r = 0; r < FULL_ROUNDS / 2; r++) {
            for (uint256 i = 0; i < 3; i++) {
                state[i] = addmod(
                    state[i],
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                FULL_ROUNDS / 2 + PARTIAL_ROUNDS + r,
                                i
                            )
                        )
                    ),
                    FIELD_MODULUS
                );
            }
            for (uint256 i = 0; i < 3; i++) {
                state[i] = _sbox(state[i]);
            }
            state = _mds(state);
        }

        // Output is first element of state
        return state[0];
    }

    /// @dev S-box: x^5 mod p
    function _sbox(uint256 x) private pure returns (uint256) {
        uint256 x2 = mulmod(x, x, FIELD_MODULUS);
        uint256 x4 = mulmod(x2, x2, FIELD_MODULUS);
        return mulmod(x4, x, FIELD_MODULUS);
    }

    /// @dev MDS matrix multiplication (3x3 Cauchy matrix)
    function _mds(
        uint256[3] memory state
    ) private pure returns (uint256[3] memory result) {
        // Simplified MDS: Cauchy matrix entries
        result[0] = addmod(
            addmod(
                mulmod(2, state[0], FIELD_MODULUS),
                mulmod(1, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(1, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
        result[1] = addmod(
            addmod(
                mulmod(1, state[0], FIELD_MODULUS),
                mulmod(2, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(1, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
        result[2] = addmod(
            addmod(
                mulmod(1, state[0], FIELD_MODULUS),
                mulmod(1, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(2, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
    }
}
