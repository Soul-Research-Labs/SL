// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MultiSigGovernance — M-of-N multi-signature governance wallet
/// @notice Requires M confirmations from N owners to execute any transaction.
///         Designed as the timelock admin and pool governance address.
///         Supports adding/removing owners and changing the threshold via
///         self-referential proposals (i.e., the multisig calls itself).
contract MultiSigGovernance {
    // ── Types ──────────────────────────────────────────

    struct Proposal {
        address target;
        uint256 value;
        bytes data;
        uint256 confirmationCount;
        bool executed;
    }

    // ── State ──────────────────────────────────────────

    /// @notice Ordered list of current owners
    address[] public owners;

    /// @notice Quick lookup for owner status
    mapping(address => bool) public isOwner;

    /// @notice Number of required confirmations
    uint256 public threshold;

    /// @notice Auto-incrementing proposal counter
    uint256 public proposalCount;

    /// @notice All proposals by ID
    mapping(uint256 => Proposal) public proposals;

    /// @notice proposalId → owner → has confirmed
    mapping(uint256 => mapping(address => bool)) public hasConfirmed;

    // ── Events ─────────────────────────────────────────

    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed proposer,
        address target,
        uint256 value,
        bytes data
    );

    event ProposalConfirmed(uint256 indexed proposalId, address indexed owner);

    event ConfirmationRevoked(
        uint256 indexed proposalId,
        address indexed owner
    );

    event ProposalExecuted(uint256 indexed proposalId);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    // ── Errors ─────────────────────────────────────────

    error NotOwner();
    error NotSelf();
    error InvalidThreshold();
    error DuplicateOwner();
    error OwnerNotFound();
    error MinimumOneOwner();
    error ProposalAlreadyExecuted();
    error ProposalNotFound();
    error AlreadyConfirmed();
    error NotConfirmed();
    error InsufficientConfirmations();
    error ExecutionFailed();

    // ── Modifiers ──────────────────────────────────────

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        if (proposalId >= proposalCount) revert ProposalNotFound();
        _;
    }

    // ── Constructor ────────────────────────────────────

    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0) revert MinimumOneOwner();
        if (_threshold == 0 || _threshold > _owners.length)
            revert InvalidThreshold();

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0)) revert OwnerNotFound();
            if (isOwner[owner]) revert DuplicateOwner();
            isOwner[owner] = true;
            owners.push(owner);
        }

        threshold = _threshold;
    }

    // ── Submit / Confirm / Execute ─────────────────────

    /// @notice Submit a new proposal. Automatically confirms for the submitter.
    /// @return proposalId The ID of the newly created proposal.
    function submitProposal(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256 proposalId) {
        proposalId = proposalCount++;

        proposals[proposalId] = Proposal({
            target: target,
            value: value,
            data: data,
            confirmationCount: 1,
            executed: false
        });

        hasConfirmed[proposalId][msg.sender] = true;

        emit ProposalSubmitted(proposalId, msg.sender, target, value, data);
        emit ProposalConfirmed(proposalId, msg.sender);
    }

    /// @notice Confirm an existing proposal.
    function confirmProposal(
        uint256 proposalId
    ) external onlyOwner proposalExists(proposalId) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (hasConfirmed[proposalId][msg.sender]) revert AlreadyConfirmed();

        hasConfirmed[proposalId][msg.sender] = true;
        p.confirmationCount++;

        emit ProposalConfirmed(proposalId, msg.sender);
    }

    /// @notice Revoke a previous confirmation.
    function revokeConfirmation(
        uint256 proposalId
    ) external onlyOwner proposalExists(proposalId) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (!hasConfirmed[proposalId][msg.sender]) revert NotConfirmed();

        hasConfirmed[proposalId][msg.sender] = false;
        p.confirmationCount--;

        emit ConfirmationRevoked(proposalId, msg.sender);
    }

    /// @notice Execute a proposal once it has enough confirmations.
    function executeProposal(
        uint256 proposalId
    ) external onlyOwner proposalExists(proposalId) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.confirmationCount < threshold) revert InsufficientConfirmations();

        p.executed = true;

        (bool success, ) = p.target.call{value: p.value}(p.data);
        if (!success) revert ExecutionFailed();

        emit ProposalExecuted(proposalId);
    }

    // ── Self-governance (add/remove owner, change threshold) ──

    /// @notice Add a new owner. Must be called by the multisig itself.
    function addOwner(address owner) external onlySelf {
        if (owner == address(0)) revert OwnerNotFound();
        if (isOwner[owner]) revert DuplicateOwner();

        isOwner[owner] = true;
        owners.push(owner);

        emit OwnerAdded(owner);
    }

    /// @notice Remove an owner. Must be called by the multisig itself.
    ///         Automatically adjusts threshold if it exceeds new owner count.
    function removeOwner(address owner) external onlySelf {
        if (!isOwner[owner]) revert OwnerNotFound();
        if (owners.length <= 1) revert MinimumOneOwner();

        isOwner[owner] = false;

        // Remove from array (swap and pop)
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        // Adjust threshold if needed
        if (threshold > owners.length) {
            uint256 old = threshold;
            threshold = owners.length;
            emit ThresholdChanged(old, threshold);
        }

        emit OwnerRemoved(owner);
    }

    /// @notice Change the confirmation threshold. Must be called by the multisig.
    function changeThreshold(uint256 _threshold) external onlySelf {
        if (_threshold == 0 || _threshold > owners.length)
            revert InvalidThreshold();

        uint256 old = threshold;
        threshold = _threshold;
        emit ThresholdChanged(old, _threshold);
    }

    // ── View Functions ─────────────────────────────────

    /// @notice Returns the number of owners.
    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }

    /// @notice Returns all current owners.
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Check how many confirmations a proposal has.
    function getConfirmationCount(
        uint256 proposalId
    ) external view returns (uint256) {
        return proposals[proposalId].confirmationCount;
    }

    /// @notice Check if a proposal is executable.
    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return !p.executed && p.confirmationCount >= threshold;
    }

    /// @notice Receive ETH for proposals that need to send value.
    receive() external payable {}
}
