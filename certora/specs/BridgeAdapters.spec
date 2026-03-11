// ── Certora Formal Verification Spec: Bridge Adapter Invariants ──
// SPDX-License-Identifier: MIT
//
// Verifies security properties common to all bridge adapter implementations:
//   - Message deduplication (replay protection)
//   - Chain support enforcement
//   - Governance access control
//   - Processed message monotonicity
//   - Governance transfer safety

methods {
    function sendMessage(uint256, address, bytes, uint256) external returns (bytes32);
    function receiveMessage(uint256, address, bytes) external;
    function isChainSupported(uint256) external returns (bool) envfree;
    function bridgeProtocol() external returns (string) envfree;
    function governance() external returns (address) envfree;
    function processedMessages(bytes32) external returns (bool) envfree;
    function setGovernance(address) external;
    function registerChain(uint256, bytes32, address) external;
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

// ── Processed Message Monotonicity ───────────────────────────
// Once a message ID is marked as processed, it stays processed forever.
// No function can unset a processed flag.
rule processedMessageMonotonicity(bytes32 messageId, method f) {
    require processedMessages(messageId) == true;

    env e;
    calldataarg args;
    f(e, args);

    assert processedMessages(messageId) == true,
        "Processed message flag must never be cleared";
}

// ── Governance Non-Zero After Init ───────────────────────────
// The governance address must never become the zero address.
invariant governanceNonZero()
    governance() != 0
    {
        preserved with (env e) {
            require e.msg.sender != 0;
        }
    }

// ── Only Governance Can Register Chains ──────────────────────
// Any caller other than the governance address must be rejected
// when attempting to register a new chain.
rule onlyGovernanceCanRegisterChain(uint256 chainId, bytes32 blockchainId, address remoteReceiver) {
    env e;
    require e.msg.sender != governance();

    registerChain@withrevert(e, chainId, blockchainId, remoteReceiver);
    assert lastReverted,
        "Non-governance callers must not register chains";
}

// ── Only Governance Can Transfer Governance ───────────────────
// Governance transfer must only be callable by the current governance.
rule onlyGovernanceCanTransferGovernance(address newGovernance) {
    env e;
    require e.msg.sender != governance();

    setGovernance@withrevert(e, newGovernance);
    assert lastReverted,
        "Non-governance callers must not transfer governance";
}

// ── Governance Transfer Correctness ──────────────────────────
// After a successful governance transfer, the new address is stored.
rule governanceTransferCorrectness(address newGovernance) {
    env e;
    require e.msg.sender == governance();
    require newGovernance != 0;

    setGovernance(e, newGovernance);

    assert governance() == newGovernance,
        "Governance must be updated to the new address";
}

// ── Send Message Emits Correct Chain ─────────────────────────
// A successful sendMessage call implies the destination chain is supported.
rule sendMessageImpliesChainSupported(uint256 chainId) {
    env e;
    address recipient;
    bytes memory payload;
    uint256 gasLimit;

    sendMessage(e, chainId, recipient, payload, gasLimit);

    assert isChainSupported(chainId),
        "Successful send must be to a supported chain";
}

// ── Receive Does Not Affect Balance ──────────────────────────
// receiveMessage should not change the contract's native token balance.
// Bridge adapters are message relays, not fund holders.
rule receiveDoesNotAffectBalance(uint256 sourceChain, address sender, bytes payload) {
    env e;
    require e.msg.value == 0;

    uint256 balanceBefore = nativeBalances[currentContract];
    receiveMessage(e, sourceChain, sender, payload);
    uint256 balanceAfter = nativeBalances[currentContract];

    assert balanceBefore == balanceAfter,
        "Receive must not change contract balance";
}
