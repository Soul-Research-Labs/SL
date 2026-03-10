// ── Certora Formal Verification Spec: Privacy Pool Invariants ──
// SPDX-License-Identifier: MIT

methods {
    function deposit(bytes32) external envfree;
    function isSpent(bytes32) external returns (bool) envfree;
    function isKnownRoot(bytes32) external returns (bool) envfree;
    function getLatestRoot() external returns (bytes32) envfree;
    function getNextLeafIndex() external returns (uint256) envfree;
    function commitmentExists(bytes32) external returns (bool) envfree;
}

// ── Nullifier Uniqueness ─────────────────────────────────────
// A nullifier, once spent, stays spent forever.
rule nullifierSpentIsIrreversible(bytes32 nullifier) {
    require isSpent(nullifier);

    env e;
    calldataarg args;
    f(e, args);

    assert isSpent(nullifier),
        "Spent nullifier must remain spent after any state transition";
}

// ── No Double Spending ───────────────────────────────────────
// A transfer with an already-spent nullifier must revert.
rule noDoubleSpend(bytes32 nullifier) {
    require isSpent(nullifier);

    env e;
    bytes memory proof;
    bytes32 root;
    bytes32[2] memory nullifiers;
    bytes32[2] memory outputs;
    nullifiers[0] = nullifier;

    transfer@withrevert(e, proof, root, nullifiers, outputs);

    assert lastReverted,
        "Transfer with already-spent nullifier must revert";
}

// ── Commitment Uniqueness ────────────────────────────────────
// A commitment deposited twice must revert.
rule noDuplicateCommitment(bytes32 commitment) {
    require commitmentExists(commitment);

    env e;
    deposit@withrevert(e, commitment);

    assert lastReverted,
        "Duplicate commitment must be rejected";
}

// ── Leaf Index Monotonicity ──────────────────────────────────
// The leaf index can only increase.
rule leafIndexMonotonicallyIncreases() {
    uint256 indexBefore = getNextLeafIndex();

    env e;
    calldataarg args;
    f(e, args);

    uint256 indexAfter = getNextLeafIndex();
    assert indexAfter >= indexBefore,
        "Leaf index must never decrease";
}

// ── Root History Integrity ───────────────────────────────────
// A known root stays known (root history is append-only within window).
// Note: After 100 roots, old roots may be evicted.
rule knownRootPersists(bytes32 root) {
    require isKnownRoot(root);
    uint256 indexBefore = getNextLeafIndex();

    env e;
    calldataarg args;
    f(e, args);

    uint256 indexAfter = getNextLeafIndex();

    // If fewer than 100 new deposits, the root should still be known
    assert (indexAfter - indexBefore < 100) => isKnownRoot(root),
        "Known root should persist within history window";
}

// ── Deposit Increases Leaf Count ─────────────────────────────
rule depositIncreasesLeafIndex(bytes32 commitment) {
    uint256 indexBefore = getNextLeafIndex();
    require !commitmentExists(commitment);

    env e;
    deposit(e, commitment);

    uint256 indexAfter = getNextLeafIndex();
    assert indexAfter == indexBefore + 1,
        "Deposit must increment leaf index by exactly 1";
}
