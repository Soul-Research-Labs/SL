#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# Deploy CosmWasm Privacy Pool to Evmos/Cosmos Testnet
# ─────────────────────────────────────────────────────────
#
# Prerequisites:
#   - wasmd or evmosd CLI installed
#   - Wallet keyring configured
#   - COSM_CHAIN_ID, COSM_NODE, COSM_WALLET env vars set
#
# Usage:
#   ./scripts/deploy/deploy-cosmwasm.sh
# ─────────────────────────────────────────────────────────

set -euo pipefail

CHAIN_ID="${COSM_CHAIN_ID:?Set COSM_CHAIN_ID (e.g. evmos_9000-4)}"
NODE="${COSM_NODE:?Set COSM_NODE (e.g. https://tendermint.bd.evmos.dev:26657)}"
WALLET="${COSM_WALLET:?Set COSM_WALLET (key name in keyring)}"
DENOM="${COSM_DENOM:-aevmos}"
GAS_PRICES="${COSM_GAS_PRICES:-25000000000${DENOM}}"
CLI="${COSM_CLI:-evmosd}"

echo "═══════════════════════════════════════════"
echo "  CosmWasm Privacy Pool — Deployment"
echo "═══════════════════════════════════════════"
echo "  Chain:   ${CHAIN_ID}"
echo "  Node:    ${NODE}"
echo "  Wallet:  ${WALLET}"
echo "  CLI:     ${CLI}"
echo "═══════════════════════════════════════════"

# ── Step 1: Build the contract ──────────────────────────
echo ""
echo "▶ Building CosmWasm contract..."

cd cosmwasm/contracts/privacy-pool

# Use rust-optimizer for reproducible builds
if command -v docker &>/dev/null; then
    echo "  Using cosmwasm/optimizer Docker image..."
    docker run --rm -v "$(pwd)":/code \
        --mount type=volume,source="$(basename "$(pwd)")_cache",target=/target \
        --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
        cosmwasm/optimizer:0.16.0
    WASM_FILE="artifacts/cosmwasm_privacy_pool.wasm"
else
    echo "  Docker not available, building with cargo..."
    RUSTFLAGS='-C link-arg=-s' cargo build --release --target wasm32-unknown-unknown
    WASM_FILE="target/wasm32-unknown-unknown/release/cosmwasm_privacy_pool.wasm"
fi

if [ ! -f "$WASM_FILE" ]; then
    echo "❌ Build failed: wasm file not found at $WASM_FILE"
    exit 1
fi

echo "✅ Contract built: $WASM_FILE"
echo "   Size: $(wc -c < "$WASM_FILE") bytes"

cd ../../..

# ── Step 2: Upload the contract (store code) ───────────
echo ""
echo "▶ Uploading contract to chain..."

UPLOAD_RESULT=$($CLI tx wasm store "$WASM_FILE" \
    --from "$WALLET" \
    --chain-id "$CHAIN_ID" \
    --node "$NODE" \
    --gas-prices "$GAS_PRICES" \
    --gas auto \
    --gas-adjustment 1.3 \
    -b sync \
    -y \
    --output json)

TX_HASH=$(echo "$UPLOAD_RESULT" | jq -r '.txhash')
echo "  Upload TX: $TX_HASH"
echo "  Waiting for confirmation..."
sleep 10

# Query code ID from tx events
CODE_ID=$($CLI query tx "$TX_HASH" --node "$NODE" --output json \
    | jq -r '.events[] | select(.type=="store_code") | .attributes[] | select(.key=="code_id") | .value')

echo "✅ Code uploaded. Code ID: $CODE_ID"

# ── Step 3: Instantiate the contract ────────────────────
echo ""
echo "▶ Instantiating contract..."

ADMIN_ADDR=$($CLI keys show "$WALLET" -a)

INIT_MSG=$(cat <<EOF
{
  "epoch_duration": 300,
  "domain_chain_id": 9000,
  "domain_app_id": 1
}
EOF
)

INST_RESULT=$($CLI tx wasm instantiate "$CODE_ID" "$INIT_MSG" \
    --from "$WALLET" \
    --label "soul-privacy-pool-v1" \
    --admin "$ADMIN_ADDR" \
    --chain-id "$CHAIN_ID" \
    --node "$NODE" \
    --gas-prices "$GAS_PRICES" \
    --gas auto \
    --gas-adjustment 1.3 \
    -b sync \
    -y \
    --output json)

INST_TX=$(echo "$INST_RESULT" | jq -r '.txhash')
echo "  Instantiate TX: $INST_TX"
sleep 10

CONTRACT_ADDR=$($CLI query tx "$INST_TX" --node "$NODE" --output json \
    | jq -r '.events[] | select(.type=="instantiate") | .attributes[] | select(.key=="_contract_address") | .value')

echo "✅ Contract instantiated: $CONTRACT_ADDR"

# ── Step 4: Verify deployment ───────────────────────────
echo ""
echo "▶ Verifying deployment..."

$CLI query wasm contract-state smart "$CONTRACT_ADDR" \
    '{"get_pool_status":{}}' \
    --node "$NODE" \
    --output json | jq .

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Deployment Complete"
echo ""
echo "  Contract: $CONTRACT_ADDR"
echo "  Code ID:  $CODE_ID"
echo "  Chain:    $CHAIN_ID"
echo "  Admin:    $ADMIN_ADDR"
echo "═══════════════════════════════════════════"

# Save deployment info
cat > deployments/cosmwasm.json <<EOF
{
  "chain_id": "$CHAIN_ID",
  "code_id": "$CODE_ID",
  "contract_address": "$CONTRACT_ADDR",
  "admin": "$ADMIN_ADDR",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "  Deployment info saved to deployments/cosmwasm.json"
