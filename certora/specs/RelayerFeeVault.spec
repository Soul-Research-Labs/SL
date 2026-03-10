// Certora spec for RelayerFeeVault
//
// Key invariants:
//   1. Only registered relayers can claim fees
//   2. Each relay hash is processed at most once
//   3. Slashing reduces stake; below-minimum stake triggers deregistration
//   4. Only governance can credit relays and slash
//   5. Vault balance conservation: deposits == credits + remaining balance

methods {
    function governance() external returns (address) envfree;
    function registeredRelayers(address) external returns (bool) envfree;
    function claimableBalance(address) external returns (uint256) envfree;
    function stakedAmount(address) external returns (uint256) envfree;
    function relayCount(address) external returns (uint256) envfree;
    function relayProcessed(bytes32) external returns (bool) envfree;
    function feePerRelay() external returns (uint256) envfree;
    function maxFeePerRelay() external returns (uint256) envfree;
    function minimumStake() external returns (uint256) envfree;
    function vaultBalance() external returns (uint256) envfree;
}

// ── Invariant: feePerRelay ≤ maxFeePerRelay ──────────

invariant feeWithinMax()
    feePerRelay() <= maxFeePerRelay();

// ── Rule: relay hash can only be processed once ──────

rule relayProcessedOnce(
    address relayer,
    bytes32 relayHash,
    uint256 sourceChainId,
    uint256 targetChainId,
    uint64 epochId
) {
    env e;
    require relayProcessed(relayHash);

    creditRelay@withrevert(e, relayer, relayHash, sourceChainId, targetChainId, epochId);

    assert lastReverted,
        "Already-processed relay should revert";
}

// ── Rule: only governance can credit relays ──────────

rule onlyGovernanceCredits(
    address relayer,
    bytes32 relayHash,
    uint256 sourceChainId,
    uint256 targetChainId,
    uint64 epochId
) {
    env e;
    creditRelay@withrevert(e, relayer, relayHash, sourceChainId, targetChainId, epochId);

    assert e.msg.sender != governance() => lastReverted,
        "Non-governance should not be able to credit relays";
}

// ── Rule: registration requires minimum stake ────────

rule registrationRequiresStake() {
    env e;
    require e.msg.value < minimumStake();

    registerRelayer@withrevert(e);

    assert lastReverted,
        "Registration with insufficient stake must revert";
}

// ── Rule: creditRelay increases claimable balance ────

rule creditIncreasesClaimable(
    address relayer,
    bytes32 relayHash,
    uint256 sourceChainId,
    uint256 targetChainId,
    uint64 epochId
) {
    env e;
    uint256 claimBefore = claimableBalance(relayer);
    require e.msg.sender == governance();
    require registeredRelayers(relayer);
    require !relayProcessed(relayHash);

    creditRelay(e, relayer, relayHash, sourceChainId, targetChainId, epochId);

    assert claimableBalance(relayer) == claimBefore + feePerRelay(),
        "Claimable balance must increase by feePerRelay";
}

// ── Rule: claim resets claimable to zero ─────────────

rule claimResetsBalance() {
    env e;
    require claimableBalance(e.msg.sender) > 0;

    claimFees(e);

    assert claimableBalance(e.msg.sender) == 0,
        "After claiming, balance must be zero";
}

// ── Rule: slashing reduces staked amount ─────────────

rule slashReducesStake(address relayer, uint256 amount, string reason) {
    env e;
    uint256 stakeBefore = stakedAmount(relayer);
    require e.msg.sender == governance();
    require registeredRelayers(relayer);
    require amount <= stakeBefore;

    slashRelayer(e, relayer, amount, reason);

    assert stakedAmount(relayer) == stakeBefore - amount,
        "Slashing must reduce stake by the slashed amount";
}
