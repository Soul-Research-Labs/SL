// ── Certora Formal Verification Spec: Universal Nullifier Registry ──
// SPDX-License-Identifier: MIT

methods {
    function chains(uint256) external returns (uint256, string, address, uint256, bytes32, uint256, bool) envfree;
    function epochRoots(uint256, uint256) external returns (bytes32) envfree;
    function globalRoot() external returns (bytes32) envfree;
    function nullifierSpentGlobal(uint256, bytes32) external returns (bool) envfree;
    function isNullifierSpentGlobally(bytes32) external returns (bool) envfree;
    function governance() external returns (address) envfree;
}

// ── Only Governance Can Register Chains ──────────────────────
rule onlyGovernanceCanRegister(uint256 chainId, string name, address bridge) {
    env e;
    require e.msg.sender != governance();

    registerChain@withrevert(e, chainId, name, bridge);
    assert lastReverted,
        "Non-governance must not register chains";
}

// ── Epoch Root Sequential Submission ─────────────────────────
// After epoch N is recorded, the next must be N+1.
rule epochSequentialSubmission(uint256 chainId, uint256 epochId, bytes32 root, uint256 count) {
    // Get current latest epoch for the chain
    uint256 cid; string memory n; address bridge; uint256 latestEpoch; bytes32 lr; uint256 lu; bool active;
    (cid, n, bridge, latestEpoch, lr, lu, active) = chains(chainId);
    require active;
    require cid == chainId; // Chain exists

    env e;
    require e.msg.sender == bridge; // authorized caller

    // If chain already has epoch data (latestEpoch > 0 or root exists)
    require latestEpoch > 0;

    // Submit out-of-order epoch (skip one)
    uint256 badEpoch = latestEpoch + 2;
    submitEpochRoot@withrevert(e, chainId, badEpoch, root, count);
    assert lastReverted,
        "Out-of-sequence epoch submission must revert";
}

// ── No Double Epoch Recording ────────────────────────────────
rule noDoubleEpochRecording(uint256 chainId, uint256 epochId) {
    require epochRoots(chainId, epochId) != bytes32(0);

    env e;
    bytes32 root;
    uint256 count;
    submitEpochRoot@withrevert(e, chainId, epochId, root, count);
    assert lastReverted,
        "Duplicate epoch root submission must revert";
}

// ── Nullifier Reported Spent Is Permanent ────────────────────
rule nullifierReportedSpentIsPermanent(uint256 chainId, bytes32 nullifier) {
    require nullifierSpentGlobal(chainId, nullifier);

    env e;
    calldataarg args;
    f(e, args);

    assert nullifierSpentGlobal(chainId, nullifier),
        "Once reported spent, nullifier must remain spent";
}

// ── Global Lookup Reflects Per-Chain State ───────────────────
// If a nullifier is reported spent on any chain, global lookup must return true.
rule globalLookupReflectsChainState(uint256 chainId, bytes32 nullifier) {
    require nullifierSpentGlobal(chainId, nullifier);

    bool global = isNullifierSpentGlobally(nullifier);
    assert global,
        "Global lookup must reflect per-chain spent status";
}

// ── Inactive Chain Cannot Submit Roots ───────────────────────
rule inactiveChainCannotSubmit(uint256 chainId, uint256 epochId, bytes32 root, uint256 count) {
    uint256 cid; string memory n; address bridge; uint256 le; bytes32 lr; uint256 lu; bool active;
    (cid, n, bridge, le, lr, lu, active) = chains(chainId);
    require !active;
    require cid == chainId;

    env e;
    submitEpochRoot@withrevert(e, chainId, epochId, root, count);
    assert lastReverted,
        "Inactive chain must not be able to submit epoch roots";
}
