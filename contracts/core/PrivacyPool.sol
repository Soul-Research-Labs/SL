// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPrivacyPool} from "../interfaces/IPrivacyPool.sol";
import {IProofVerifier} from "../interfaces/IProofVerifier.sol";
import {IEpochManager} from "../interfaces/IEpochManager.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";
import {PoseidonHasher} from "../libraries/PoseidonHasher.sol";
import {ProofEnvelope} from "../libraries/ProofEnvelope.sol";
import {EmergencyPause} from "./EmergencyPause.sol";

/// @title PrivacyPool — Core privacy pool for shielded transactions
/// @notice Chain-agnostic privacy pool supporting deposits, private transfers,
///         and withdrawals with ZK proof verification. Deploys on Avalanche,
///         Moonbeam, Astar, Evmos, Aurora, and any EVM chain.
/// @dev Uses domain-separated nullifiers (V2) for cross-chain safety.
///      Proof verification is delegated to a pluggable IProofVerifier.
///      Inherits EmergencyPause for circuit-breaker capabilities.
contract PrivacyPool is IPrivacyPool, EmergencyPause {
    using MerkleTree for MerkleTree.TreeData;

    // ── State ──────────────────────────────────────────────────────────

    MerkleTree.TreeData private _tree;
    IProofVerifier public immutable verifier;
    IEpochManager public epochManager;

    /// @notice Domain identifiers for this deployment
    uint256 public immutable domainChainId;
    uint256 public immutable domainAppId;

    /// @notice Nullifier set — spent nullifiers cannot be reused
    mapping(bytes32 => bool) public nullifierSpent;

    /// @notice Commitment set — tracks all deposited commitments
    mapping(bytes32 => bool) public commitmentExists;

    /// @notice Pool balance tracking
    uint256 public poolBalance;

    /// @notice Governance / admin (for epoch manager updates only, not fund access)
    address public governance;

    /// @notice Optional compliance oracle (address(0) = compliance disabled)
    IComplianceOracle public complianceOracle;

    // ── Errors ─────────────────────────────────────────────────────────

    error InvalidDeposit();
    error InvalidProof();
    error NullifierAlreadySpent(bytes32 nullifier);
    error UnknownMerkleRoot();
    error InsufficientPoolBalance();
    error InvalidWithdrawAmount();
    error CommitmentAlreadyExists();
    error Unauthorized();
    error TransferFailed();
    error ComplianceCheckFailed();

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(
        address _verifier,
        address _epochManager,
        uint256 _domainChainId,
        uint256 _domainAppId,
        address _guardian,
        address _complianceOracle
    ) {
        verifier = IProofVerifier(_verifier);
        epochManager = IEpochManager(_epochManager);
        domainChainId = _domainChainId;
        domainAppId = _domainAppId;
        governance = msg.sender;
        _tree.init();
        _initPause(_guardian);
        if (_complianceOracle != address(0)) {
            complianceOracle = IComplianceOracle(_complianceOracle);
        }
    }

    /// @dev Required by EmergencyPause — returns governance address.
    function _pauseGovernance() internal view override returns (address) {
        return governance;
    }

    // ── Deposit ────────────────────────────────────────────────────────

    /// @inheritdoc IPrivacyPool
    function deposit(
        bytes32 commitment,
        uint256 amount
    ) external payable whenNotPaused {
        if (amount == 0 || msg.value != amount) revert InvalidDeposit();
        if (commitmentExists[commitment]) revert CommitmentAlreadyExists();

        commitmentExists[commitment] = true;
        (uint256 leafIndex, uint256 newRoot) = _tree.insert(
            uint256(commitment)
        );
        poolBalance += amount;

        emit Deposit(commitment, leafIndex, amount, block.timestamp);
    }

    // ── Transfer ───────────────────────────────────────────────────────

    /// @inheritdoc IPrivacyPool
    function transfer(
        bytes calldata proof,
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        uint256 _domainChainId,
        uint256 _domainAppId
    ) external whenNotPaused {
        // Validate Merkle root
        if (!_tree.isKnownRoot(uint256(merkleRoot))) revert UnknownMerkleRoot();

        // Compliance check (if oracle is configured)
        _checkCompliance(nullifiers, outputCommitments, proof);

        // Check nullifiers haven't been spent
        _checkAndSpendNullifiers(nullifiers);

        // Build public inputs array for verifier
        uint256[] memory publicInputs = _buildTransferPublicInputs(
            merkleRoot,
            nullifiers,
            outputCommitments,
            _domainChainId,
            _domainAppId
        );

        // Verify ZK proof
        if (!verifier.verifyTransferProof(proof, publicInputs))
            revert InvalidProof();

        // Insert new commitments
        (uint256 idx1, ) = _tree.insert(uint256(outputCommitments[0]));
        (, uint256 newRoot) = _tree.insert(uint256(outputCommitments[1]));

        emit Transfer(
            nullifiers[0],
            nullifiers[1],
            outputCommitments[0],
            outputCommitments[1],
            bytes32(newRoot)
        );
    }

    // ── Withdraw ───────────────────────────────────────────────────────

    /// @inheritdoc IPrivacyPool
    function withdraw(
        bytes calldata proof,
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        address payable recipient,
        uint256 exitValue
    ) external whenNotPaused {
        if (exitValue == 0) revert InvalidWithdrawAmount();
        if (exitValue > poolBalance) revert InsufficientPoolBalance();
        if (!_tree.isKnownRoot(uint256(merkleRoot))) revert UnknownMerkleRoot();

        // Compliance check (if oracle is configured)
        _checkCompliance(nullifiers, outputCommitments, proof);

        // Check blocked recipients
        if (address(complianceOracle) != address(0)) {
            if (complianceOracle.isBlocked(recipient))
                revert ComplianceCheckFailed();
        }

        _checkAndSpendNullifiers(nullifiers);

        // Public inputs include exit_value and recipient for the withdraw circuit
        uint256[] memory publicInputs = _buildWithdrawPublicInputs(
            merkleRoot,
            nullifiers,
            outputCommitments,
            exitValue,
            recipient
        );

        if (!verifier.verifyWithdrawProof(proof, publicInputs))
            revert InvalidProof();

        // Insert change commitments
        _tree.insert(uint256(outputCommitments[0]));
        (, uint256 newRoot) = _tree.insert(uint256(outputCommitments[1]));

        poolBalance -= exitValue;

        // Transfer funds to recipient
        (bool success, ) = recipient.call{value: exitValue}("");
        if (!success) revert TransferFailed();

        emit Withdrawal(
            nullifiers[0],
            nullifiers[1],
            recipient,
            exitValue,
            bytes32(newRoot)
        );
    }

    // ── View Functions ─────────────────────────────────────────────────

    /// @inheritdoc IPrivacyPool
    function getLatestRoot() external view returns (bytes32) {
        return bytes32(_tree.getLatestRoot());
    }

    /// @inheritdoc IPrivacyPool
    function isKnownRoot(bytes32 root) external view returns (bool) {
        return _tree.isKnownRoot(uint256(root));
    }

    /// @inheritdoc IPrivacyPool
    function isSpent(bytes32 nullifier) external view returns (bool) {
        return nullifierSpent[nullifier];
    }

    /// @inheritdoc IPrivacyPool
    function getNextLeafIndex() external view returns (uint256) {
        return _tree.nextLeafIndex;
    }

    /// @inheritdoc IPrivacyPool
    function getPoolBalance() external view returns (uint256) {
        return poolBalance;
    }

    // ── Governance ─────────────────────────────────────────────────────

    function setEpochManager(address _epochManager) external onlyGovernance {
        epochManager = IEpochManager(_epochManager);
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    function setComplianceOracle(
        address _complianceOracle
    ) external onlyGovernance {
        complianceOracle = IComplianceOracle(_complianceOracle);
    }

    // ── Internal ───────────────────────────────────────────────────────

    function _checkCompliance(
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        bytes calldata proof
    ) private view {
        if (address(complianceOracle) == address(0)) return;
        if (
            !complianceOracle.checkCompliance(
                nullifiers,
                outputCommitments,
                proof
            )
        ) revert ComplianceCheckFailed();
    }

    function _checkAndSpendNullifiers(bytes32[2] calldata nullifiers) private {
        for (uint256 i = 0; i < 2; i++) {
            if (nullifierSpent[nullifiers[i]]) {
                revert NullifierAlreadySpent(nullifiers[i]);
            }
            nullifierSpent[nullifiers[i]] = true;

            // Register with epoch manager for cross-chain sync
            if (address(epochManager) != address(0)) {
                epochManager.registerNullifier(nullifiers[i]);
            }
        }
    }

    function _buildTransferPublicInputs(
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        uint256 _chainId,
        uint256 _appId
    ) private pure returns (uint256[] memory) {
        uint256[] memory inputs = new uint256[](7);
        inputs[0] = uint256(merkleRoot);
        inputs[1] = uint256(nullifiers[0]);
        inputs[2] = uint256(nullifiers[1]);
        inputs[3] = uint256(outputCommitments[0]);
        inputs[4] = uint256(outputCommitments[1]);
        inputs[5] = _chainId;
        inputs[6] = _appId;
        return inputs;
    }

    function _buildWithdrawPublicInputs(
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        uint256 exitValue,
        address recipient
    ) private pure returns (uint256[] memory) {
        uint256[] memory inputs = new uint256[](7);
        inputs[0] = uint256(merkleRoot);
        inputs[1] = uint256(nullifiers[0]);
        inputs[2] = uint256(nullifiers[1]);
        inputs[3] = uint256(outputCommitments[0]);
        inputs[4] = uint256(outputCommitments[1]);
        inputs[5] = exitValue;
        inputs[6] = uint256(uint160(recipient));
        return inputs;
    }

    /// @notice Receive ETH/native tokens
    receive() external payable {}
}
