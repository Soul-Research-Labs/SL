#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# Deploy Near Privacy Pool to Near Testnet
# ─────────────────────────────────────────────────────────
#
# Prerequisites:
#   - near-cli-rs installed (cargo install near-cli-rs)
#   - Logged in: near login
#   - NEAR_ACCOUNT_ID env var set
#
# Usage:
#   ./scripts/deploy/deploy-near.sh [--testnet|--mainnet]
# ─────────────────────────────────────────────────────────

set -euo pipefail

NETWORK="${1:---testnet}"
NEAR_ACCOUNT="${NEAR_ACCOUNT_ID:?Set NEAR_ACCOUNT_ID env var}"

echo "═══════════════════════════════════════════"
echo "  Near Privacy Pool — Deployment Script"
echo "═══════════════════════════════════════════"
echo "  Network:  ${NETWORK}"
echo "  Account:  ${NEAR_ACCOUNT}"
echo "═══════════════════════════════════════════"

# ── Step 1: Build the contract ──────────────────────────
echo ""
echo "▶ Building Near contract..."
cd near/contracts/privacy-pool
cargo build --target wasm32-unknown-unknown --release

# Copy wasm to output directory
WASM_FILE="target/wasm32-unknown-unknown/release/near_privacy_pool.wasm"

if [ ! -f "$WASM_FILE" ]; then
    echo "❌ Build failed: WASM file not found at $WASM_FILE"
    exit 1
fi

echo "✅ Contract built: $WASM_FILE"
echo "   Size: $(wc -c < "$WASM_FILE") bytes"

# ── Step 2: Create sub-account for the contract ────────
CONTRACT_ACCOUNT="privacy-pool.${NEAR_ACCOUNT}"
echo ""
echo "▶ Creating contract account: ${CONTRACT_ACCOUNT}"

near account create-account fund-myself "${CONTRACT_ACCOUNT}" '5 NEAR' \
    autogenerate-new-keypair save-to-keychain \
    sign-as "${NEAR_ACCOUNT}" \
    network-config "${NETWORK/--/}" \
    sign-with-keychain send 2>/dev/null || echo "  (account may already exist, continuing)"

# ── Step 3: Deploy the contract ─────────────────────────
echo ""
echo "▶ Deploying contract to ${CONTRACT_ACCOUNT}..."

near contract deploy "${CONTRACT_ACCOUNT}" \
    use-file "${WASM_FILE}" \
    without-init-call \
    network-config "${NETWORK/--/}" \
    sign-with-keychain send

echo "✅ Contract deployed"

# ── Step 4: Initialize the contract ─────────────────────
echo ""
echo "▶ Initializing contract..."

near contract call-function as-transaction "${CONTRACT_ACCOUNT}" \
    new json-args '{"epoch_duration": 300, "domain_chain_id": 1313161555, "domain_app_id": 1}' \
    prepaid-gas '30 Tgas' \
    attached-deposit '0 NEAR' \
    sign-as "${NEAR_ACCOUNT}" \
    network-config "${NETWORK/--/}" \
    sign-with-keychain send

echo "✅ Contract initialized"

# ── Step 5: Verify deployment ───────────────────────────
echo ""
echo "▶ Verifying deployment..."

near contract call-function as-read-only "${CONTRACT_ACCOUNT}" \
    get_pool_status json-args '{}' \
    network-config "${NETWORK/--/}"

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Deployment Complete"
echo ""
echo "  Contract:   ${CONTRACT_ACCOUNT}"
echo "  Network:    ${NETWORK/--/}"
echo "  Explorer:   https://explorer.${NETWORK/--/}net.near.org/accounts/${CONTRACT_ACCOUNT}"
echo "═══════════════════════════════════════════"
