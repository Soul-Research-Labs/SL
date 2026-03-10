// Certora spec for ComplianceOracle
//
// Key invariants:
//   1. Only governance can block/unblock addresses and commitments
//   2. Only governance can modify auditor list
//   3. When compliance is disabled, checkCompliance always returns true
//   4. Policy version only increases
//   5. Blocked commitments cause compliance failure

methods {
    function governance() external returns (address) envfree;
    function complianceEnabled() external returns (bool) envfree;
    function policyVersion() external returns (uint256) envfree;
    function isBlocked(address) external returns (bool) envfree;
    function authorizedAuditors(address) external returns (bool) envfree;
}

// ── Invariant: policy version is positive ────────────

invariant policyVersionPositive()
    policyVersion() >= 1;

// ── Rule: only governance can block ──────────────────

rule onlyGovernanceBlocks(address target, string reason) {
    env e;
    blockAddress@withrevert(e, target, reason);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to block addresses";
}

// ── Rule: only governance can unblock ────────────────

rule onlyGovernanceUnblocks(address target) {
    env e;
    unblockAddress@withrevert(e, target);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to unblock addresses";
}

// ── Rule: block sets isBlocked flag ──────────────────

rule blockSetsFlag(address target, string reason) {
    env e;
    require e.msg.sender == governance();

    blockAddress(e, target, reason);

    assert isBlocked(target),
        "Blocked address must be marked as blocked";
}

// ── Rule: unblock clears isBlocked flag ──────────────

rule unblockClearsFlag(address target) {
    env e;
    require e.msg.sender == governance();
    require isBlocked(target);

    unblockAddress(e, target);

    assert !isBlocked(target),
        "Unblocked address must no longer be blocked";
}

// ── Rule: policy version monotonically increases ─────

rule policyVersionMonotonic() {
    env e;
    uint256 versionBefore = policyVersion();
    require e.msg.sender == governance();

    updatePolicy(e);

    assert policyVersion() > versionBefore,
        "Policy version must increase after update";
}

// ── Rule: only governance manages auditors ───────────

rule onlyGovernanceAddsAuditor(address auditor) {
    env e;
    addAuditor@withrevert(e, auditor);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to add auditors";
}

rule onlyGovernanceRemovesAuditor(address auditor) {
    env e;
    removeAuditor@withrevert(e, auditor);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to remove auditors";
}

// ── Rule: governance transfer ────────────────────────

rule onlyGovernanceTransfers(address newGov) {
    env e;
    transferGovernance@withrevert(e, newGov);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to transfer governance";
}
