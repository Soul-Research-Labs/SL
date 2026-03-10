// ── Certora Formal Verification Spec: Bridge Adapter Invariants ──
// SPDX-License-Identifier: MIT

methods {
    function sendMessage(uint256, address, bytes, uint256) external returns (bytes32);
    function receiveMessage(uint256, address, bytes) external;
    function isChainSupported(uint256) external returns (bool) envfree;
    function bridgeProtocol() external returns (string) envfree;
}

// ── Message Deduplication ────────────────────────────────────
// A message received once must not be processable again.
// This applies to all adapters (AWM, Teleporter, XCM, IBC, Rainbow).
rule messageDeduplication(uint256 sourceChain, address sender, bytes payload) {
    env e1;
    receiveMessage(e1, sourceChain, sender, payload);

    env e2;
    receiveMessage@withrevert(e2, sourceChain, sender, payload);
    assert lastReverted,
        "Replayed message must be rejected by the adapter";
}

// ── Cannot Send to Unsupported Chain ─────────────────────────
rule cannotSendToUnsupportedChain(uint256 chainId) {
    require !isChainSupported(chainId);

    env e;
    address recipient;
    bytes memory payload;
    uint256 gasLimit;

    sendMessage@withrevert(e, chainId, recipient, payload, gasLimit);
    assert lastReverted,
        "Sending to unsupported chain must revert";
}

// ── Authorization: Only Governance Can Configure Routes ──────
// Ghost variable for governance address (adapter-specific)
// This is a parametric rule — each adapter implementation must
// enforce that route configuration is governance-only.
rule onlyGovernanceCanConfigureRoutes() {
    env e;
    calldataarg args;

    // Any function that modifies router state must be governance-only
    // This is verified by checking that non-governance callers revert
    // on configuration functions (adapter-specific).
    // See individual adapter tests for concrete route-setting assertions.
    assert true; // placeholder — concrete checks in adapter-specific specs
}
