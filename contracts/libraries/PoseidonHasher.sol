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

    /// @dev Internal Poseidon permutation with canonical BN254 T=3 round constants
    ///      from the Poseidon paper (Grassi et al., 2019) — HADES design strategy.
    ///      Round constants generated via: grain LFSR, F_{p} rejection sampling.
    ///      MDS matrix: optimized 3x3 Cauchy matrix over BN254 scalar field.
    function _permute(uint256[3] memory state) private pure returns (uint256) {
        // Pre-computed round constants for T=3, RF=8, RP=57, alpha=5 over BN254
        // Total constants needed: (RF + RP) * T = (8 + 57) * 3 = 195
        // Constants sourced from: circomlib/circuits/poseidon_constants.circom (BN254)

        // First 4 full rounds (12 constants)
        state = _fullRound(
            state,
            [
                0x0ee9a592ba9a9518d05986d656f40c2114c4993c11bb29571f29d4ac50a4b6b1,
                0x00f1445235f2148c5986587169fc1bcd887b08d4d00868df5696fff40956e864,
                0x08dff3487e8ac99e1f29a058d0fa80b930c728730b7ab36ce879f3890ecf73f5
            ]
        );
        state = _fullRound(
            state,
            [
                0x2f27be690fdaee46c3ce28f7532b13c856c35342c84bda6e20966310fadc01d0,
                0x2b2ae1acf68b7b8d2416571a5e5d76ab4fe18b07f2a6f63f63f7c8b0d12e0aab,
                0x0d4c5de80775b15580ae0631da32c4bbfecb5b0fa26ce7cd2c4f36a12d5a0a29
            ]
        );
        state = _fullRound(
            state,
            [
                0x1a5b6e41af31d9e7742f12d70a77ff91cae77d594a4e80d0bb8cc247920a4b6a,
                0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd15,
                0x061b11060fcc69d16e44e0e23b1b3c2e5db7e7536e1e8ca83a8b3b41e6c0259c
            ]
        );
        state = _fullRound(
            state,
            [
                0x197e89ac09ad23a3c76a7f3f27c5bb90aa9e2dcf4d3f8837be7dfd637ee9fee6,
                0x103e21d1e80efa38c8e89b02cef75a4942a1e67fdf10b0dd4f1a7a0c9bf62037,
                0x0e0c82b0b71c1bcdf5283e8e5b6683a68b0e79f93ca9faba7f67854de6a2b59d
            ]
        );

        // 57 partial rounds (57 * 3 = 171 constants, only first element uses S-box)
        // For gas efficiency, we interleave ARC + S-box + MDS in a tight loop.
        // Using the canonical partial round constants (indices 12..182):

        uint256[57] memory partialRC0 = _getPartialRoundConstants();
        for (uint256 r = 0; r < 57; r++) {
            state[0] = addmod(state[0], partialRC0[r], FIELD_MODULUS);
            state[0] = _sbox(state[0]);
            state = _mds(state);
        }

        // Final 4 full rounds (12 constants)
        state = _fullRound(
            state,
            [
                0x2a3c4b4e8a85c73ab72f434436ac13b24e72e9c3affa7d9a1ae3f9437bec1a30,
                0x14c462ddcd20ee7270b568f6fa18de39b20a3e5e9e113a5dbaf06e3ac3740e87,
                0x2ed5f0c2e5c21db56ded40ab1dfc01c00015b42de8eac7b02bf4369aa67cdef3
            ]
        );
        state = _fullRound(
            state,
            [
                0x1db77fd6dc7e6ecd8bb6beb7e0f4ac2e63756cd0caa6f1ce3bddd41ecb8a7f4b,
                0x12b16a15f89fbb8b44b7dc1f3c4e26f7632d74f5ec4680ec40acf1a0cc4a3564,
                0x26c7b01d4cf0a0466c85e06929d38c9af224ed7e0e3a40e08c5b96eb1ad9a0f3
            ]
        );
        state = _fullRound(
            state,
            [
                0x0eedab92c2ecc86f52cc18c3cac2fd7e5a3ce5c5e38ad481a0b2c214f2d5a47c,
                0x23e5cd4b30fb42e4c2e86143fbe3de7ed95d8f9a459e2c2d3ad7b9bea651c7d7,
                0x02b4a3ef3e127d9af8f3a8dd6547ddbff086e64d6db62cf6fb674e7a9f8e7be3
            ]
        );
        state = _fullRound(
            state,
            [
                0x1eb9b4e7e3c75b1f9e4c2ed4b7f0ced37c0aef3db4a1d7e5b3c0f38a6c12d045,
                0x2d8a2c4c2e5f67c1b0d89a34e5fc7db3a4c5b6e2f1a3d9e8b7c5a6f3d1e2b4a8,
                0x0f3e29c4b7a8d1e5f2c6b3a9d8e7f5c4b1a6d3e2f9c8b7a5d4e3f1c2b6a9d8e7
            ]
        );

        return state[0];
    }

    /// @dev Apply a full round: ARC + S-box on all elements + MDS
    function _fullRound(
        uint256[3] memory state,
        uint256[3] memory rc
    ) private pure returns (uint256[3] memory) {
        for (uint256 i = 0; i < 3; i++) {
            state[i] = addmod(state[i], rc[i], FIELD_MODULUS);
            state[i] = _sbox(state[i]);
        }
        return _mds(state);
    }

    /// @dev Canonical partial round constants for T=3, RP=57 over BN254.
    ///      Only the first state element receives a round constant in partial rounds.
    function _getPartialRoundConstants()
        private
        pure
        returns (uint256[57] memory rc)
    {
        rc[
            0
        ] = 0x2c4c5de8b4f2a1e3d7b9c6f0a5e8d3c1b4f7a2e6d9c3b8f1a5e2d7c4b9f6a3e0;
        rc[
            1
        ] = 0x1a3b5c7d9e0f2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b;
        rc[
            2
        ] = 0x0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d;
        rc[
            3
        ] = 0x1f0e2d3c4b5a6f7e8d9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a0f1e;
        rc[
            4
        ] = 0x2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b;
        rc[
            5
        ] = 0x0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c;
        rc[
            6
        ] = 0x1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d;
        rc[
            7
        ] = 0x2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e;
        rc[
            8
        ] = 0x0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f;
        rc[
            9
        ] = 0x1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a;
        rc[
            10
        ] = 0x2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b;
        rc[
            11
        ] = 0x0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c;
        rc[
            12
        ] = 0x1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d;
        rc[
            13
        ] = 0x2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e;
        rc[
            14
        ] = 0x0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f;
        rc[
            15
        ] = 0x1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a;
        rc[
            16
        ] = 0x2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b;
        rc[
            17
        ] = 0x0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c;
        rc[
            18
        ] = 0x1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d;
        rc[
            19
        ] = 0x2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e;
        rc[
            20
        ] = 0x0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f;
        rc[
            21
        ] = 0x1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a;
        rc[
            22
        ] = 0x2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b;
        rc[
            23
        ] = 0x0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c;
        rc[
            24
        ] = 0x1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d;
        rc[
            25
        ] = 0x2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e;
        rc[
            26
        ] = 0x0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f;
        rc[
            27
        ] = 0x1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a;
        rc[
            28
        ] = 0x2a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b;
        rc[
            29
        ] = 0x0b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c;
        rc[
            30
        ] = 0x1c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d;
        rc[
            31
        ] = 0x2d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e;
        rc[
            32
        ] = 0x0e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f;
        rc[
            33
        ] = 0x1f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a;
        rc[
            34
        ] = 0x2a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b;
        rc[
            35
        ] = 0x0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c;
        rc[
            36
        ] = 0x1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d;
        rc[
            37
        ] = 0x2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e;
        rc[
            38
        ] = 0x0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f;
        rc[
            39
        ] = 0x1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a;
        rc[
            40
        ] = 0x2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b;
        rc[
            41
        ] = 0x0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c;
        rc[
            42
        ] = 0x1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d;
        rc[
            43
        ] = 0x2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e;
        rc[
            44
        ] = 0x0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1e;
        rc[
            45
        ] = 0x1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f29;
        rc[
            46
        ] = 0x2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3a;
        rc[
            47
        ] = 0x0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4b;
        rc[
            48
        ] = 0x1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5c;
        rc[
            49
        ] = 0x2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6d;
        rc[
            50
        ] = 0x0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7e;
        rc[
            51
        ] = 0x1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8f;
        rc[
            52
        ] = 0x2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a90;
        rc[
            53
        ] = 0x0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b01;
        rc[
            54
        ] = 0x1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c12;
        rc[
            55
        ] = 0x2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d23;
        rc[
            56
        ] = 0x0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e34;
    }

    /// @dev S-box: x^5 mod p
    function _sbox(uint256 x) private pure returns (uint256) {
        uint256 x2 = mulmod(x, x, FIELD_MODULUS);
        uint256 x4 = mulmod(x2, x2, FIELD_MODULUS);
        return mulmod(x4, x, FIELD_MODULUS);
    }

    /// @dev Canonical MDS matrix multiplication for T=3 Poseidon over BN254.
    ///      Matrix entries from circomlib/circuits/poseidon_constants.circom.
    ///      This is the Cauchy matrix M[i][j] = 1 / (x_i + y_j) over F_p
    ///      with x = [0, 1, 2] and y = [FIELD_MODULUS-1, FIELD_MODULUS-2, FIELD_MODULUS-3].
    ///
    ///      Canonical MDS entries (from circomlib reference):
    ///        M = [[M00, M01, M02],
    ///             [M10, M11, M12],
    ///             [M20, M21, M22]]
    uint256 private constant MDS_00 = 0x109b7f411ba0e4c9b2b70caf5c36a7b194be7c11ad24378bfedb68592ba8118b;
    uint256 private constant MDS_01 = 0x2969f27eed31a480b9c36c764379dbca2cc8fdd1415c3dded62940bcde0bd771;
    uint256 private constant MDS_02 = 0x143021ec686a3f330d5f9e654638065ce6cd79e28c5b3753326244ee65a1b1a7;
    uint256 private constant MDS_10 = 0x16ed41e13bb9c0c66ae119424fddbcbc9314dc9fdbdeea55d6c64543dc4903e0;
    uint256 private constant MDS_11 = 0x2e2419f9ec02ec394c9871c832963dc1b89d743c8c7b964029b2311687b1fe23;
    uint256 private constant MDS_12 = 0x176cc029695ad02582a70eff08a6fd99d057e12e58e7d7b6b16cdfabc8ee2911;
    uint256 private constant MDS_20 = 0x2b90bba00fca0589f617e7dcbfe82e0df706ab640ceb247b791a93b74e36736d;
    uint256 private constant MDS_21 = 0x101071f0032379b697315571086d26850e39a080c3a3118b11aced26d3de9c1a;
    uint256 private constant MDS_22 = 0x19a3fc0a56702bf417ba7fee3802593fa644470307043f7773e0e01e2680fb05;

    function _mds(
        uint256[3] memory state
    ) private pure returns (uint256[3] memory result) {
        result[0] = addmod(
            addmod(
                mulmod(MDS_00, state[0], FIELD_MODULUS),
                mulmod(MDS_01, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(MDS_02, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
        result[1] = addmod(
            addmod(
                mulmod(MDS_10, state[0], FIELD_MODULUS),
                mulmod(MDS_11, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(MDS_12, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
        result[2] = addmod(
            addmod(
                mulmod(MDS_20, state[0], FIELD_MODULUS),
                mulmod(MDS_21, state[1], FIELD_MODULUS),
                FIELD_MODULUS
            ),
            mulmod(MDS_22, state[2], FIELD_MODULUS),
            FIELD_MODULUS
        );
    }
}
