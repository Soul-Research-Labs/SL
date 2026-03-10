// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GovernanceTimelock — Time-delayed execution for privileged operations
/// @notice Enforces a minimum delay between proposing and executing governance
///         actions. Supports queueing, cancelling, and executing transactions.
///         Used by PrivacyPool, EpochManager, ComplianceOracle, and RelayerFeeVault
///         to prevent instantaneous malicious governance changes.
contract GovernanceTimelock {
    // ── Types ──────────────────────────────────────────

    struct QueuedTransaction {
        address target;
        uint256 value;
        bytes data;
        uint256 eta; // earliest time of execution
        bool executed;
        bool cancelled;
    }

    // ── State ──────────────────────────────────────────

    /// @notice Admin address — can queue and cancel transactions
    address public admin;

    /// @notice Pending admin for two-step transfer
    address public pendingAdmin;

    /// @notice Minimum delay (seconds) before a queued tx can be executed
    uint256 public delay;

    /// @notice Grace period (seconds) after ETA during which tx can be executed
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice Minimum allowed delay
    uint256 public constant MINIMUM_DELAY = 1 hours;

    /// @notice Maximum allowed delay
    uint256 public constant MAXIMUM_DELAY = 30 days;

    /// @notice All queued transactions (by hash)
    mapping(bytes32 => QueuedTransaction) public queuedTransactions;

    /// @notice Whether a transaction hash is currently queued
    mapping(bytes32 => bool) public isQueued;

    // ── Events ─────────────────────────────────────────

    event TransactionQueued(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 eta
    );

    event TransactionExecuted(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data
    );

    event TransactionCancelled(bytes32 indexed txHash);

    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event AdminTransferInitiated(address indexed newAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ── Errors ─────────────────────────────────────────

    error Unauthorized();
    error InvalidDelay();
    error TransactionAlreadyQueued();
    error TransactionNotQueued();
    error TransactionNotReady();
    error TransactionStale();
    error TransactionAlreadyExecuted();
    error TransactionCancelledError();
    error ExecutionFailed();

    // ── Modifiers ──────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────

    constructor(address _admin, uint256 _delay) {
        if (_delay < MINIMUM_DELAY || _delay > MAXIMUM_DELAY)
            revert InvalidDelay();
        admin = _admin;
        delay = _delay;
    }

    // ── Queue / Execute / Cancel ───────────────────────

    /// @notice Queue a transaction for time-delayed execution.
    /// @param target The contract to call.
    /// @param value ETH value to send.
    /// @param data Calldata for the function call.
    /// @param eta Earliest execution time (must be >= block.timestamp + delay).
    /// @return txHash The hash identifying this queued transaction.
    function queueTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external onlyAdmin returns (bytes32 txHash) {
        if (eta < block.timestamp + delay) revert TransactionNotReady();

        txHash = _computeTxHash(target, value, data, eta);
        if (isQueued[txHash]) revert TransactionAlreadyQueued();

        queuedTransactions[txHash] = QueuedTransaction({
            target: target,
            value: value,
            data: data,
            eta: eta,
            executed: false,
            cancelled: false
        });
        isQueued[txHash] = true;

        emit TransactionQueued(txHash, target, value, data, eta);
    }

    /// @notice Execute a previously queued transaction after its delay has passed.
    /// @param target The contract to call (must match queued params).
    /// @param value ETH value (must match queued params).
    /// @param data Calldata (must match queued params).
    /// @param eta Execution time (must match queued params).
    function executeTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external onlyAdmin returns (bytes memory) {
        bytes32 txHash = _computeTxHash(target, value, data, eta);

        if (!isQueued[txHash]) revert TransactionNotQueued();

        QueuedTransaction storage qtx = queuedTransactions[txHash];
        if (qtx.executed) revert TransactionAlreadyExecuted();
        if (qtx.cancelled) revert TransactionCancelledError();
        if (block.timestamp < qtx.eta) revert TransactionNotReady();
        if (block.timestamp > qtx.eta + GRACE_PERIOD) revert TransactionStale();

        qtx.executed = true;
        isQueued[txHash] = false;

        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed();

        emit TransactionExecuted(txHash, target, value, data);
        return result;
    }

    /// @notice Cancel a queued transaction.
    function cancelTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external onlyAdmin {
        bytes32 txHash = _computeTxHash(target, value, data, eta);
        if (!isQueued[txHash]) revert TransactionNotQueued();

        queuedTransactions[txHash].cancelled = true;
        isQueued[txHash] = false;

        emit TransactionCancelled(txHash);
    }

    // ── Admin Management ───────────────────────────────

    /// @notice Initiate admin transfer (two-step process for safety).
    function setPendingAdmin(address _pendingAdmin) external onlyTimelock {
        pendingAdmin = _pendingAdmin;
        emit AdminTransferInitiated(_pendingAdmin);
    }

    /// @notice Accept admin role (called by the pending admin).
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Unauthorized();
        emit AdminTransferred(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    /// @notice Update the timelock delay (must be called via the timelock itself).
    function setDelay(uint256 _delay) external onlyTimelock {
        if (_delay < MINIMUM_DELAY || _delay > MAXIMUM_DELAY)
            revert InvalidDelay();
        emit DelayUpdated(delay, _delay);
        delay = _delay;
    }

    // ── View Functions ─────────────────────────────────

    /// @notice Compute the hash of a transaction (used as the queue key).
    function computeTxHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external pure returns (bytes32) {
        return _computeTxHash(target, value, data, eta);
    }

    // ── Internal ───────────────────────────────────────

    function _computeTxHash(
        address target,
        uint256 value,
        bytes memory data,
        uint256 eta
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, eta));
    }

    receive() external payable {}
}
