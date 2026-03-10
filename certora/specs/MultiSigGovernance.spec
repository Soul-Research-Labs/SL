// Certora spec for MultiSigGovernance
//
// Key invariants:
//   1. threshold is always >= 1 and <= owner count
//   2. Only owners can submit/confirm/revoke proposals
//   3. A proposal cannot be executed twice
//   4. A proposal requires >= threshold confirmations to execute
//   5. Confirmation count matches actual confirmed owners
//   6. Self-governance functions (addOwner/removeOwner/changeThreshold) only callable by self

methods {
    function threshold() external returns (uint256) envfree;
    function proposalCount() external returns (uint256) envfree;
    function isOwner(address) external returns (bool) envfree;
    function getOwnerCount() external returns (uint256) envfree;
    function hasConfirmed(uint256, address) external returns (bool) envfree;
    function getConfirmationCount(uint256) external returns (uint256) envfree;
    function isExecutable(uint256) external returns (bool) envfree;
}

// ── Invariant: threshold bounds ──────────────────────

invariant thresholdBounds()
    threshold() >= 1 && threshold() <= getOwnerCount()
    {
        preserved {
            requireInvariant ownerCountPositive();
        }
    }

invariant ownerCountPositive()
    getOwnerCount() >= 1;

// ── Rule: only owners can submit ─────────────────────

rule onlyOwnerSubmits(
    address target,
    uint256 value,
    bytes data
) {
    env e;
    submitProposal@withrevert(e, target, value, data);

    assert !isOwner(e.msg.sender) => lastReverted,
        "Non-owner should not be able to submit proposals";
}

// ── Rule: only owners can confirm ────────────────────

rule onlyOwnerConfirms(uint256 proposalId) {
    env e;
    confirmProposal@withrevert(e, proposalId);

    assert !isOwner(e.msg.sender) => lastReverted,
        "Non-owner should not be able to confirm proposals";
}

// ── Rule: submit auto-confirms ───────────────────────

rule submitAutoConfirms(
    address target,
    uint256 value,
    bytes data
) {
    env e;
    require isOwner(e.msg.sender);

    uint256 pid = submitProposal(e, target, value, data);

    assert hasConfirmed(pid, e.msg.sender),
        "Submitter should be auto-confirmed";
    assert getConfirmationCount(pid) >= 1,
        "Confirmation count should be at least 1 after submit";
}

// ── Rule: double confirmation reverts ────────────────

rule doubleConfirmReverts(uint256 proposalId) {
    env e;
    require isOwner(e.msg.sender);
    require hasConfirmed(proposalId, e.msg.sender);

    confirmProposal@withrevert(e, proposalId);

    assert lastReverted,
        "Double confirmation must revert";
}

// ── Rule: confirm increments count ───────────────────

rule confirmIncrementsCount(uint256 proposalId) {
    env e;
    require isOwner(e.msg.sender);
    require !hasConfirmed(proposalId, e.msg.sender);

    uint256 countBefore = getConfirmationCount(proposalId);

    confirmProposal(e, proposalId);

    uint256 countAfter = getConfirmationCount(proposalId);
    assert countAfter == countBefore + 1,
        "Confirmation count must increase by 1";
}

// ── Rule: revoke decrements count ────────────────────

rule revokeDecrementsCount(uint256 proposalId) {
    env e;
    require isOwner(e.msg.sender);
    require hasConfirmed(proposalId, e.msg.sender);

    uint256 countBefore = getConfirmationCount(proposalId);

    revokeConfirmation(e, proposalId);

    uint256 countAfter = getConfirmationCount(proposalId);
    assert countAfter == countBefore - 1,
        "Confirmation count must decrease by 1";
    assert !hasConfirmed(proposalId, e.msg.sender),
        "Owner should no longer be confirmed after revocation";
}

// ── Rule: execution requires threshold confirmations ──

rule executionRequiresThreshold(uint256 proposalId) {
    env e;
    require getConfirmationCount(proposalId) < threshold();

    executeProposal@withrevert(e, proposalId);

    assert lastReverted,
        "Proposal must not execute without sufficient confirmations";
}

// ── Rule: double execution reverts ───────────────────

rule noDoubleExecution(uint256 proposalId) {
    env e1; env e2;

    // First execution succeeds
    require getConfirmationCount(proposalId) >= threshold();
    executeProposal(e1, proposalId);

    // Second execution must revert
    executeProposal@withrevert(e2, proposalId);

    assert lastReverted,
        "Executed proposal must not be executable again";
}

// ── Rule: proposal count only increases ──────────────

rule proposalCountMonotonic(
    address target,
    uint256 value,
    bytes data
) {
    env e;
    uint256 countBefore = proposalCount();

    submitProposal(e, target, value, data);

    uint256 countAfter = proposalCount();
    assert countAfter == countBefore + 1,
        "Proposal count must increase by exactly 1";
}

// ── Rule: addOwner only via self ─────────────────────

rule addOwnerOnlySelf(address newOwner) {
    env e;
    require e.msg.sender != currentContract;

    addOwner@withrevert(e, newOwner);

    assert lastReverted,
        "addOwner must only be callable by the multisig itself";
}

// ── Rule: removeOwner only via self ──────────────────

rule removeOwnerOnlySelf(address ownerToRemove) {
    env e;
    require e.msg.sender != currentContract;

    removeOwner@withrevert(e, ownerToRemove);

    assert lastReverted,
        "removeOwner must only be callable by the multisig itself";
}

// ── Rule: changeThreshold only via self ──────────────

rule changeThresholdOnlySelf(uint256 newThreshold) {
    env e;
    require e.msg.sender != currentContract;

    changeThreshold@withrevert(e, newThreshold);

    assert lastReverted,
        "changeThreshold must only be callable by the multisig itself";
}

// ── Rule: addOwner increases owner count ─────────────

rule addOwnerIncreasesCount(address newOwner) {
    env e;
    require e.msg.sender == currentContract;
    require !isOwner(newOwner);

    uint256 countBefore = getOwnerCount();

    addOwner(e, newOwner);

    uint256 countAfter = getOwnerCount();
    assert countAfter == countBefore + 1,
        "Owner count must increase by 1 after addOwner";
    assert isOwner(newOwner),
        "New owner must be recognized as owner";
}
