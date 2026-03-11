# MEV Protection — Design Document

> **Status**: Proposed  
> **Date**: 2026-03-11  
> **Addresses**: SECURITY.md limitation #5

---

## Problem

Privacy pool deposits and withdrawals are submitted as ordinary transactions
visible in the public mempool. This exposes users to:

1. **Front-running**: A miner/validator observes a deposit TX and inserts their
   own deposit ahead of it, manipulating the Merkle tree state.
2. **Sandwich attacks**: Wrapping a user's withdrawal between attacker
   transactions to extract value.
3. **Censorship**: A validator selectively excludes privacy pool transactions.
4. **Timing analysis**: Observers correlate deposits/withdrawals by watching
   the mempool, reducing the anonymity set.

---

## Proposed Solution: Commit-Reveal Deposits

### Overview

Replace the single-step `deposit(commitment, value)` with a two-phase protocol:

```
Phase 1 — COMMIT:  User sends hash(commitment, salt) + value
Phase 2 — REVEAL:  User reveals (commitment, salt) in a later block
```

### Contract Changes

```solidity
// New state
mapping(bytes32 => CommitRecord) public pendingCommits;

struct CommitRecord {
    address depositor;
    uint256 value;
    uint256 blockNumber;
    bool revealed;
}

uint256 public constant MIN_COMMIT_DELAY = 2;   // blocks
uint256 public constant MAX_COMMIT_DELAY = 100;  // blocks

function commitDeposit(bytes32 commitHash) external payable {
    require(msg.value > 0, "No value");
    require(pendingCommits[commitHash].depositor == address(0), "Duplicate");

    pendingCommits[commitHash] = CommitRecord({
        depositor: msg.sender,
        value: msg.value,
        blockNumber: block.number,
        revealed: false
    });

    emit DepositCommitted(commitHash, msg.sender, msg.value);
}

function revealDeposit(
    bytes32 commitment,
    bytes32 salt
) external {
    bytes32 commitHash = keccak256(abi.encodePacked(commitment, salt));
    CommitRecord storage record = pendingCommits[commitHash];

    require(record.depositor == msg.sender, "Not depositor");
    require(!record.revealed, "Already revealed");
    require(block.number >= record.blockNumber + MIN_COMMIT_DELAY, "Too early");
    require(block.number <= record.blockNumber + MAX_COMMIT_DELAY, "Expired");

    record.revealed = true;
    _insertDeposit(commitment, record.value);

    emit DepositRevealed(commitment, record.value);
}
```

### Security Properties

- **Front-running resistance**: At commit time, the actual `commitment` is
  hidden behind `hash(commitment, salt)`. An attacker cannot predict what
  commitment will be inserted.
- **Timing separation**: The `MIN_COMMIT_DELAY` ensures the commitment and
  reveal are in different blocks, preventing single-block MEV extraction.
- **Expiry**: `MAX_COMMIT_DELAY` prevents stale commits from lingering
  indefinitely. Expired commits can be reclaimed.

### Trade-offs

| Aspect     | Impact                                              |
| ---------- | --------------------------------------------------- |
| UX         | Two transactions instead of one; SDK abstracts this |
| Gas        | ~40K additional gas for the commit step             |
| Latency    | 2-block minimum delay before deposit is finalized   |
| Complexity | Additional contract state and cleanup logic         |

---

## Alternative: Private Mempool Integration

### Flashbots Protect / MEV Blocker

For EVM chains, users can submit transactions to private RPCs:

| Service           | Chain Support       | Mechanism                                 |
| ----------------- | ------------------- | ----------------------------------------- |
| Flashbots Protect | Ethereum, Avalanche | Private mempool, no front-running         |
| MEV Blocker       | Ethereum            | Order-flow auction, refunds extracted MEV |
| Blink             | Various L2s         | Private transaction submission            |

### SDK Integration

```typescript
// sdk/src/client.ts — add private RPC option
interface DepositOptions {
  usePrivateMempool?: boolean;
  flashbotsRpcUrl?: string;
}

async buildDepositTx(commitment: string, value: bigint, opts?: DepositOptions) {
  if (opts?.usePrivateMempool && opts?.flashbotsRpcUrl) {
    // Submit to private RPC instead of public mempool
    return this.submitToPrivateRpc(opts.flashbotsRpcUrl, tx);
  }
  return tx;
}
```

### Trade-offs

| Aspect        | Impact                                     |
| ------------- | ------------------------------------------ |
| Trust         | Requires trusting the private RPC provider |
| Chain support | Only available on select chains            |
| Complexity    | Minimal — just different RPC endpoint      |
| Censorship    | Provider could still censor transactions   |

---

## Recommended Approach

**Phase 1 (Near-term)**: Implement commit-reveal for deposits in
`PrivacyPool.sol`. This is chain-agnostic and requires no external
dependencies.

**Phase 2 (Medium-term)**: Add private mempool support in the SDK as an
opt-in feature for chains where it's available.

**Phase 3 (Long-term)**: Explore encrypted mempools (threshold encryption,
time-lock puzzles) as they become available on target chains.

---

## Relayer-Side Protections

The relayer already has anti-metadata features (`config.toml`):

- **Jitter** (`enable_jitter`): Randomized delay before submitting
- **Batching** (`enable_batching`): Group multiple proofs to hide individual timing
- **Dummy padding** (`enable_dummy_padding`): Insert dummy transactions

These should remain enabled in production and are complementary to on-chain
MEV protection.

---

## Implementation Priority

1. Add `commitDeposit` / `revealDeposit` to `PrivacyPool.sol`
2. Add corresponding Foundry tests
3. Update SDK `buildDepositTx` to use commit-reveal by default
4. Update Certora spec for commit-reveal invariants
5. Add private mempool RPC option to SDK
6. Document user-facing changes in SDK docs

---

## References

- [Flashbots Protect](https://docs.flashbots.net/flashbots-protect/overview)
- [MEV and Privacy Pools](https://collective.flashbots.net/)
- [Commit-Reveal Schemes](https://en.wikipedia.org/wiki/Commitment_scheme)
- SECURITY.md §Known Limitations #5
