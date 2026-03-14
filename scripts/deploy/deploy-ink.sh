#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# Deploy ink! Privacy Pool to Astar / Polkadot Parachain
# ─────────────────────────────────────────────────────────
#
# Prerequisites:
#   - cargo-contract installed (cargo install cargo-contract)
#   - Substrate node running or public RPC endpoint available
#   - INK_SURI env var set (secret URI, e.g. //Alice for dev)
#
# Usage:
#   ./scripts/deploy/deploy-ink.sh [--url <ws-endpoint>]
#
# Examples:
#   ./scripts/deploy/deploy-ink.sh                             # local node ws://127.0.0.1:9944
#   ./scripts/deploy/deploy-ink.sh --url wss://rpc.shibuya.astar.network
# ─────────────────────────────────────────────────────────

set -euo pipefail

SURI="${INK_SURI:?Set INK_SURI env var (e.g. //Alice or a mnemonic)}"
URL="ws://127.0.0.1:9944"
EPOCH_DURATION=100

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            URL="$2"
            shift 2
            ;;
        --epoch-duration)
            EPOCH_DURATION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "═══════════════════════════════════════════"
echo "  ink! Privacy Pool — Deployment Script"
echo "═══════════════════════════════════════════"
echo "  Endpoint:       ${URL}"
echo "  Epoch Duration: ${EPOCH_DURATION}"
echo "═══════════════════════════════════════════"

# ── Step 1: Verify toolchain ───────────────────────────
echo ""
echo "▶ Checking prerequisites..."

if ! command -v cargo-contract &>/dev/null; then
    echo "❌ cargo-contract not found. Install with:"
    echo "   cargo install cargo-contract --force"
    exit 1
fi

CARGO_CONTRACT_VERSION=$(cargo-contract --version 2>/dev/null || echo "unknown")
echo "  cargo-contract: ${CARGO_CONTRACT_VERSION}"

# Ensure wasm target is installed
if ! rustup target list --installed | grep -q wasm32-unknown-unknown; then
    echo "  Installing wasm32-unknown-unknown target..."
    rustup target add wasm32-unknown-unknown
fi

# ── Step 2: Build the contract ─────────────────────────
echo ""
echo "▶ Building ink! contract..."
cd ink/privacy-pool

cargo contract build --release 2>&1

# Locate the built artifacts
WASM_FILE="target/ink/ink_privacy_pool.wasm"
CONTRACT_FILE="target/ink/ink_privacy_pool.contract"

if [ ! -f "$CONTRACT_FILE" ]; then
    echo "❌ Build failed: .contract bundle not found at $CONTRACT_FILE"
    exit 1
fi

echo "✅ Contract built"
echo "   WASM:     $(wc -c < "$WASM_FILE") bytes"
echo "   Bundle:   ${CONTRACT_FILE}"

# ── Step 3: Upload code to chain ───────────────────────
echo ""
echo "▶ Uploading contract code..."

UPLOAD_OUTPUT=$(cargo contract upload \
    --url "$URL" \
    --suri "$SURI" \
    --output-json \
    2>&1) || {
        # If code already exists, extract the hash and continue
        if echo "$UPLOAD_OUTPUT" | grep -q "CodeAlreadyExists"; then
            echo "  Code already uploaded, continuing to instantiate..."
        else
            echo "❌ Upload failed:"
            echo "$UPLOAD_OUTPUT"
            exit 1
        fi
    }

CODE_HASH=$(echo "$UPLOAD_OUTPUT" | jq -r '.code_hash // empty' 2>/dev/null || true)
if [ -n "$CODE_HASH" ]; then
    echo "✅ Code uploaded"
    echo "   Code hash: ${CODE_HASH}"
fi

# ── Step 4: Instantiate the contract ───────────────────
echo ""
echo "▶ Instantiating contract with epoch_duration=${EPOCH_DURATION}..."

INSTANTIATE_OUTPUT=$(cargo contract instantiate \
    --url "$URL" \
    --suri "$SURI" \
    --constructor new \
    --args "$EPOCH_DURATION" \
    --value 0 \
    --output-json \
    2>&1)

CONTRACT_ADDRESS=$(echo "$INSTANTIATE_OUTPUT" | jq -r '.contract // empty' 2>/dev/null || true)

if [ -z "$CONTRACT_ADDRESS" ]; then
    echo "❌ Instantiation failed:"
    echo "$INSTANTIATE_OUTPUT"
    exit 1
fi

echo "✅ Contract instantiated"
echo "   Address: ${CONTRACT_ADDRESS}"

# ── Step 5: Verify deployment ──────────────────────────
echo ""
echo "▶ Verifying deployment..."

# Query the current root (should be zero value for fresh contract)
ROOT_OUTPUT=$(cargo contract call \
    --url "$URL" \
    --suri "$SURI" \
    --contract "$CONTRACT_ADDRESS" \
    --message get_current_root \
    --output-json \
    --dry-run \
    2>&1)

echo "  Root query response received"

# Query governance address
GOV_OUTPUT=$(cargo contract call \
    --url "$URL" \
    --suri "$SURI" \
    --contract "$CONTRACT_ADDRESS" \
    --message get_governance \
    --output-json \
    --dry-run \
    2>&1)

echo "  Governance query response received"

# ── Step 6: Write deployment record ───────────────────
cd ../..
DEPLOY_DIR="deployments/astar"
mkdir -p "$DEPLOY_DIR"

DEPLOY_FILE="${DEPLOY_DIR}/ink-privacy-pool.json"
cat > "$DEPLOY_FILE" <<EOF
{
  "contract": "ink-privacy-pool",
  "address": "${CONTRACT_ADDRESS}",
  "code_hash": "${CODE_HASH:-unknown}",
  "endpoint": "${URL}",
  "epoch_duration": ${EPOCH_DURATION},
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cargo_contract_version": "${CARGO_CONTRACT_VERSION}"
}
EOF

echo ""
echo "═══════════════════════════════════════════"
echo "  Deployment Complete"
echo "═══════════════════════════════════════════"
echo "  Contract:  ${CONTRACT_ADDRESS}"
echo "  Record:    ${DEPLOY_FILE}"
echo "═══════════════════════════════════════════"
