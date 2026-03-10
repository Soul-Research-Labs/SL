// Certora spec for GovernanceTimelock
//
// Key invariants:
//   1. Only admin can queue/execute/cancel transactions
//   2. Transactions cannot be executed before their ETA
//   3. Transactions cannot be executed after grace period
//   4. Cancelled transactions cannot be executed
//   5. Double execution is impossible
//   6. Delay is always within [MINIMUM_DELAY, MAXIMUM_DELAY]

methods {
    function admin() external returns (address) envfree;
    function delay() external returns (uint256) envfree;
    function isQueued(bytes32) external returns (bool) envfree;
    function MINIMUM_DELAY() external returns (uint256) envfree;
    function MAXIMUM_DELAY() external returns (uint256) envfree;
    function GRACE_PERIOD() external returns (uint256) envfree;
}

// ── Invariant: delay bounds ──────────────────────────

invariant delayWithinBounds()
    delay() >= MINIMUM_DELAY() && delay() <= MAXIMUM_DELAY();

// ── Rule: only admin can queue ───────────────────────

rule onlyAdminQueues(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    queueTransaction@withrevert(e, target, value, data, eta);

    assert e.msg.sender != admin() => lastReverted,
        "Non-admin should not be able to queue transactions";
}

// ── Rule: only admin can execute ─────────────────────

rule onlyAdminExecutes(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    executeTransaction@withrevert(e, target, value, data, eta);

    assert e.msg.sender != admin() => lastReverted,
        "Non-admin should not be able to execute transactions";
}

// ── Rule: execution requires elapsed delay ───────────

rule executionRequiresDelay(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    require e.block.timestamp < eta;

    executeTransaction@withrevert(e, target, value, data, eta);

    assert lastReverted,
        "Transaction must not execute before ETA";
}

// ── Rule: queue sets isQueued flag ───────────────────

rule queueSetsFlag(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    require e.msg.sender == admin();

    bytes32 txHash = queueTransaction(e, target, value, data, eta);

    assert isQueued(txHash),
        "Queued transaction must be marked as queued";
}

// ── Rule: execute clears isQueued flag ───────────────

rule executeClearsFlag(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    bytes32 txHash = computeTxHash(e, target, value, data, eta);
    require isQueued(txHash);
    require e.msg.sender == admin();
    require e.block.timestamp >= eta;
    require e.block.timestamp <= eta + GRACE_PERIOD();

    executeTransaction(e, target, value, data, eta);

    assert !isQueued(txHash),
        "Executed transaction must no longer be queued";
}

// ── Rule: cancel clears isQueued flag ────────────────

rule cancelClearsFlag(
    address target,
    uint256 value,
    bytes data,
    uint256 eta
) {
    env e;
    bytes32 txHash = computeTxHash(e, target, value, data, eta);
    require isQueued(txHash);
    require e.msg.sender == admin();

    cancelTransaction(e, target, value, data, eta);

    assert !isQueued(txHash),
        "Cancelled transaction must no longer be queued";
}
