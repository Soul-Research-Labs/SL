# Soul Privacy SDK — Python

Python client library for the Soul Privacy Stack multi-chain ZK privacy middleware.

## Installation

```bash
pip install -e "sdks/python[dev]"
```

## Quick Start

```python
from soul_privacy import SoulPrivacyClient, NoteWallet, ChainConfig, ChainType

# Configure chain connection
config = ChainConfig(
    chain_id=43113,
    rpc_url="https://api.avax-test.network/ext/bc/C/rpc",
    pool_address="0x...",
    epoch_manager_address="0x...",
    chain_type=ChainType.EVM,
)

# On-chain reads
client = SoulPrivacyClient(config)
root = client.get_latest_root()
balance = client.get_pool_balance()

# Local note management
wallet = NoteWallet(spending_key=b"\x01" * 32)
note = wallet.create_note(value=1000)
nullifier = wallet.compute_nullifier_v2(note, chain_id=43113, app_id=1)
```

## Modules

| Module | Class | Description |
|--------|-------|-------------|
| `client` | `SoulPrivacyClient` | EVM on-chain reads and unsigned transaction building |
| `wallet` | `NoteWallet` | Local shielded note tracking, creation, and selection |
| `prover` | `ProofClient` | Async HTTP client for the Lumora ZK proof coprocessor |
| `types` | — | Data classes: `ChainConfig`, `Note`, `NullifierInfo`, `GeneratedProof`, etc. |

## Proof Generation

```python
import asyncio
from soul_privacy import ProofClient

prover = ProofClient(base_url="http://localhost:8080")

proof = asyncio.run(prover.prove_transfer(
    merkle_root=root,
    input_commitments=[note.commitment],
    spending_keys=[wallet._spending_key],
    merkle_paths=[[b"\x00" * 32] * 32],
    path_indices=[[0] * 32],
    output_values=[600, 400],
    output_pubkeys=[b"\x05" * 32, b"\x06" * 32],
    output_blindings=[b"\x07" * 32, b"\x08" * 32],
    chain_id=43113,
))
```

## Testing

```bash
cd sdks/python
pip install -e ".[dev]"
pytest -v
```

## Notes

- **Poseidon hash**: The wallet currently uses SHA-256 as a placeholder. Production deployments should use Poseidon over BN254 to match the on-chain circuits.
- **EVM only**: `SoulPrivacyClient` currently supports EVM chains. Substrate, CosmWasm, and NEAR support is planned.
