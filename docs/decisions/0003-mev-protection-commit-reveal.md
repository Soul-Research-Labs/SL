# 0003 — MEV Protection via Commit-Reveal Deposits

**Status**: Accepted  
**Date**: 2025-11-20  
**Author**: Core team

## Context

Privacy pool deposits are vulnerable to MEV (Maximal Extractable Value) attacks:

1. **Front-running**: A searcher observes a pending deposit in the mempool,
   submits the same commitment with higher gas to claim the leaf index first.
2. **Sandwich attacks**: A searcher deposits before and after a target transaction
   to correlate timing metadata.
3. **Commitment sniping**: A searcher extracts the commitment from a pending tx
   and uses it in their own deposit, denying the original depositor.

These attacks undermine the privacy guarantees that the pool is designed to provide
by creating observable deposit patterns on the public mempool.

## Decision

Implement a two-phase commit-reveal deposit mechanism in `PrivacyPool.sol`:

### Phase 1: Commit

```solidity
function commitDeposit(bytes32 commitHash) external payable
```

- `commitHash = keccak256(abi.encodePacked(commitment, depositorSalt))`
- Stores `CommitRecord { depositor, blockNumber, revealed: false }`
- Accepts the deposit value with the commit (funds locked immediately)
- Emits `DepositCommitted(depositor, commitHash)`

### Phase 2: Reveal

```solidity
function revealDeposit(bytes32 commitHash, bytes32 commitment) external
```

- Must be called by the original depositor
- Enforces timing window: `MIN_COMMIT_DELAY ≤ elapsed ≤ MAX_COMMIT_DELAY`
- Inserts the real commitment into the Merkle tree
- Emits `DepositRevealed(commitment, leafIndex)`

### Parameters

- `MIN_COMMIT_DELAY = 2 blocks` — prevents same-block front-running
- `MAX_COMMIT_DELAY = 100 blocks` — prevents stale commits from lingering
- Expired commits can be reclaimed via `reclaimExpiredCommit(commitHash)`

### Deployment

Implemented on: Solidity PrivacyPool, ink! privacy pool.
The original `deposit()` function is preserved for backward compatibility.

## Consequences

### Positive

- Eliminates front-running: the real commitment is hidden during the commit phase
- Prevents sandwich attacks: the commitment is only revealed after a delay
- Depositor-locked: only the original committer can reveal
- Expired commit reclaim prevents permanent fund lockup
- Composable with private mempool RPCs (Flashbots Protect) as defense-in-depth

### Negative

- Two transactions instead of one per deposit (higher gas cost ~60k extra)
- MIN_COMMIT_DELAY adds 2-block latency (~24s on Avalanche, ~24s on Moonbeam)
- More complex UX — SDKs must handle the two-phase flow
- Storage overhead: `CommitRecord` stored per pending deposit

## Alternatives Considered

1. **Private mempool only** (Flashbots Protect, MEV Blocker) — rejected as sole
   defense because it depends on third-party infrastructure availability and
   doesn't protect on chains without private mempool support.
2. **Encrypted mempool** (threshold encryption schemes) — rejected because no
   production-ready encrypted mempool exists on any supported chain.
3. **Submarine sends** — rejected because they require a separate escrow contract
   and the complexity is comparable to commit-reveal with worse UX.
