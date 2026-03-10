// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "../interfaces/IProofVerifier.sol";

/// @title Halo2SnarkVerifier — On-chain verification of Halo2 proofs via SNARK wrapper
/// @notice Lumora generates Halo2 (IPA) proofs off-chain. Direct IPA verification on
///         EVM costs ~2M+ gas. Instead, we wrap the Halo2 proof in a Groth16 proof
///         that attests "I verified a valid Halo2 proof with these public inputs."
///         Groth16 verification on EVM costs ~250K gas — an 8x improvement.
///
/// @dev Architecture:
///      1. Lumora node generates Halo2 proof off-chain (lumora-prover)
///      2. SNARK wrapper circuit verifies Halo2 proof and produces Groth16 proof
///      3. This contract verifies the Groth16 wrapper proof on-chain
///
///      The wrapper circuit's public inputs are:
///        - Original Halo2 public inputs (merkle root, nullifiers, commitments, etc.)
///        - Halo2 verification key hash (binds to specific circuit)
///
///      Verification key points (BN254 G1/G2) are set at deployment.
contract Halo2SnarkVerifier is IProofVerifier {
    // ── BN254 Curve Constants ──────────────────────────────────────────

    uint256 internal constant PRIME_Q =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // ── Verification Key (set at deployment) ───────────────────────────

    struct VerifyingKey {
        // G1 points
        uint256 alpha_x;
        uint256 alpha_y;
        // G2 points (4 coordinates for BN254 G2)
        uint256[2] beta_x;
        uint256[2] beta_y;
        uint256[2] gamma_x;
        uint256[2] gamma_y;
        uint256[2] delta_x;
        uint256[2] delta_y;
        // IC points (input commitment, length = public_inputs + 1)
        uint256[][] ic;
    }

    /// @notice Transfer circuit verification key
    VerifyingKey private _transferVK;

    /// @notice Withdraw circuit verification key
    VerifyingKey private _withdrawVK;

    /// @notice Aggregation circuit verification key
    VerifyingKey private _aggregationVK;

    /// @notice Whether VKs have been initialized
    bool public transferVKReady;
    bool public withdrawVKReady;
    bool public aggregationVKReady;

    /// @notice Hash of the original Halo2 circuit VK (for binding)
    bytes32 public immutable halo2TransferVKHash;
    bytes32 public immutable halo2WithdrawVKHash;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error VKNotInitialized();
    error InvalidProofLength();
    error PairingFailed();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(bytes32 _halo2TransferVKHash, bytes32 _halo2WithdrawVKHash) {
        halo2TransferVKHash = _halo2TransferVKHash;
        halo2WithdrawVKHash = _halo2WithdrawVKHash;
        governance = msg.sender;
    }

    // ── IProofVerifier ─────────────────────────────────────────────────

    /// @inheritdoc IProofVerifier
    function verifyTransferProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool) {
        if (!transferVKReady) revert VKNotInitialized();
        return _verifyGroth16(proof, publicInputs, _transferVK);
    }

    /// @inheritdoc IProofVerifier
    function verifyWithdrawProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool) {
        if (!withdrawVKReady) revert VKNotInitialized();
        return _verifyGroth16(proof, publicInputs, _withdrawVK);
    }

    /// @inheritdoc IProofVerifier
    function verifyAggregatedProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool) {
        if (!aggregationVKReady) revert VKNotInitialized();
        return _verifyGroth16(proof, publicInputs, _aggregationVK);
    }

    /// @inheritdoc IProofVerifier
    function provingSystem() external pure returns (string memory) {
        return "Halo2-SNARK-Wrapper";
    }

    // ── VK Initialization ──────────────────────────────────────────────

    /// @notice Initialize the transfer circuit verification key
    /// @dev Called once after deployment with VK data from trusted setup
    function initTransferVK(
        uint256 alpha_x,
        uint256 alpha_y,
        uint256[2] calldata beta_x,
        uint256[2] calldata beta_y,
        uint256[2] calldata gamma_x,
        uint256[2] calldata gamma_y,
        uint256[2] calldata delta_x,
        uint256[2] calldata delta_y,
        uint256[][] calldata ic
    ) external onlyGovernance {
        _transferVK = VerifyingKey({
            alpha_x: alpha_x,
            alpha_y: alpha_y,
            beta_x: beta_x,
            beta_y: beta_y,
            gamma_x: gamma_x,
            gamma_y: gamma_y,
            delta_x: delta_x,
            delta_y: delta_y,
            ic: ic
        });
        transferVKReady = true;
    }

    /// @notice Initialize the withdraw circuit verification key
    function initWithdrawVK(
        uint256 alpha_x,
        uint256 alpha_y,
        uint256[2] calldata beta_x,
        uint256[2] calldata beta_y,
        uint256[2] calldata gamma_x,
        uint256[2] calldata gamma_y,
        uint256[2] calldata delta_x,
        uint256[2] calldata delta_y,
        uint256[][] calldata ic
    ) external onlyGovernance {
        _withdrawVK = VerifyingKey({
            alpha_x: alpha_x,
            alpha_y: alpha_y,
            beta_x: beta_x,
            beta_y: beta_y,
            gamma_x: gamma_x,
            gamma_y: gamma_y,
            delta_x: delta_x,
            delta_y: delta_y,
            ic: ic
        });
        withdrawVKReady = true;
    }

    /// @notice Initialize the aggregation circuit verification key
    function initAggregationVK(
        uint256 alpha_x,
        uint256 alpha_y,
        uint256[2] calldata beta_x,
        uint256[2] calldata beta_y,
        uint256[2] calldata gamma_x,
        uint256[2] calldata gamma_y,
        uint256[2] calldata delta_x,
        uint256[2] calldata delta_y,
        uint256[][] calldata ic
    ) external onlyGovernance {
        _aggregationVK = VerifyingKey({
            alpha_x: alpha_x,
            alpha_y: alpha_y,
            beta_x: beta_x,
            beta_y: beta_y,
            gamma_x: gamma_x,
            gamma_y: gamma_y,
            delta_x: delta_x,
            delta_y: delta_y,
            ic: ic
        });
        aggregationVKReady = true;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    // ── Internal: Groth16 Verification ─────────────────────────────────

    /// @dev Verify a Groth16 proof against given public inputs and VK
    ///      Uses the BN254 pairing precompile (address 0x08)
    function _verifyGroth16(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        VerifyingKey storage vk
    ) private view returns (bool) {
        // Proof format: [a_x, a_y, b_x1, b_x2, b_y1, b_y2, c_x, c_y] (256 bytes)
        if (proof.length != 256) revert InvalidProofLength();

        // Decode proof points
        (
            uint256 a_x,
            uint256 a_y,
            uint256[2] memory b_x,
            uint256[2] memory b_y,
            uint256 c_x,
            uint256 c_y
        ) = _decodeProof(proof);

        // Compute vk_x = IC[0] + sum(IC[i+1] * publicInputs[i])
        uint256 vk_x_x = vk.ic[0][0];
        uint256 vk_x_y = vk.ic[0][1];

        for (uint256 i = 0; i < publicInputs.length; i++) {
            // EC scalar multiplication: IC[i+1] * publicInputs[i]
            (uint256 px, uint256 py) = _ecMul(
                vk.ic[i + 1][0],
                vk.ic[i + 1][1],
                publicInputs[i]
            );
            // EC addition: vk_x += IC[i+1] * publicInputs[i]
            (vk_x_x, vk_x_y) = _ecAdd(vk_x_x, vk_x_y, px, py);
        }

        // Pairing check:
        // e(A, B) == e(alpha, beta) * e(vk_x, gamma) * e(C, delta)
        // Equivalent to:
        // e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
        return
            _pairingCheck(
                a_x,
                a_y,
                b_x,
                b_y,
                vk.alpha_x,
                vk.alpha_y,
                vk.beta_x,
                vk.beta_y,
                vk_x_x,
                vk_x_y,
                vk.gamma_x,
                vk.gamma_y,
                c_x,
                c_y,
                vk.delta_x,
                vk.delta_y
            );
    }

    function _decodeProof(
        bytes calldata proof
    )
        private
        pure
        returns (
            uint256 a_x,
            uint256 a_y,
            uint256[2] memory b_x,
            uint256[2] memory b_y,
            uint256 c_x,
            uint256 c_y
        )
    {
        a_x = uint256(bytes32(proof[0:32]));
        a_y = uint256(bytes32(proof[32:64]));
        b_x[0] = uint256(bytes32(proof[64:96]));
        b_x[1] = uint256(bytes32(proof[96:128]));
        b_y[0] = uint256(bytes32(proof[128:160]));
        b_y[1] = uint256(bytes32(proof[160:192]));
        c_x = uint256(bytes32(proof[192:224]));
        c_y = uint256(bytes32(proof[224:256]));
    }

    /// @dev BN254 EC addition precompile (address 0x06)
    function _ecAdd(
        uint256 x1,
        uint256 y1,
        uint256 x2,
        uint256 y2
    ) private view returns (uint256 x, uint256 y) {
        uint256[4] memory input = [x1, y1, x2, y2];
        uint256[2] memory result;

        assembly {
            if iszero(staticcall(gas(), 0x06, input, 0x80, result, 0x40)) {
                revert(0, 0)
            }
        }

        return (result[0], result[1]);
    }

    /// @dev BN254 EC scalar multiplication precompile (address 0x07)
    function _ecMul(
        uint256 x,
        uint256 y,
        uint256 scalar
    ) private view returns (uint256 rx, uint256 ry) {
        uint256[3] memory input = [x, y, scalar];
        uint256[2] memory result;

        assembly {
            if iszero(staticcall(gas(), 0x07, input, 0x60, result, 0x40)) {
                revert(0, 0)
            }
        }

        return (result[0], result[1]);
    }

    /// @dev BN254 pairing precompile (address 0x08)
    function _pairingCheck(
        uint256 a_x,
        uint256 a_y,
        uint256[2] memory b_x,
        uint256[2] memory b_y,
        uint256 alpha_x,
        uint256 alpha_y,
        uint256[2] memory beta_x,
        uint256[2] memory beta_y,
        uint256 vkx_x,
        uint256 vkx_y,
        uint256[2] memory gamma_x,
        uint256[2] memory gamma_y,
        uint256 c_x,
        uint256 c_y,
        uint256[2] memory delta_x,
        uint256[2] memory delta_y
    ) private view returns (bool) {
        // Negate A (negate y coordinate)
        uint256 neg_a_y = (PRIME_Q - a_y) % PRIME_Q;

        uint256[24] memory input;
        // Pair 1: e(-A, B)
        input[0] = a_x;
        input[1] = neg_a_y;
        input[2] = b_x[1];
        input[3] = b_x[0];
        input[4] = b_y[1];
        input[5] = b_y[0];
        // Pair 2: e(alpha, beta)
        input[6] = alpha_x;
        input[7] = alpha_y;
        input[8] = beta_x[1];
        input[9] = beta_x[0];
        input[10] = beta_y[1];
        input[11] = beta_y[0];
        // Pair 3: e(vk_x, gamma)
        input[12] = vkx_x;
        input[13] = vkx_y;
        input[14] = gamma_x[1];
        input[15] = gamma_x[0];
        input[16] = gamma_y[1];
        input[17] = gamma_y[0];
        // Pair 4: e(C, delta)
        input[18] = c_x;
        input[19] = c_y;
        input[20] = delta_x[1];
        input[21] = delta_x[0];
        input[22] = delta_y[1];
        input[23] = delta_y[0];

        uint256[1] memory result;
        assembly {
            if iszero(staticcall(gas(), 0x08, input, 0x300, result, 0x20)) {
                revert(0, 0)
            }
        }

        return result[0] == 1;
    }
}
