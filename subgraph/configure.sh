#!/usr/bin/env bash
# subgraph/configure.sh — Populate subgraph.yaml with deployed addresses.
#
# Usage:
#   PRIVACY_POOL=0x... EPOCH_MANAGER=0x... GOVERNANCE_TIMELOCK=0x... \
#     START_BLOCK=12345 NETWORK=avalanche ./configure.sh
#
# This produces subgraph.yaml ready for `graph deploy`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBGRAPH_YAML="${SCRIPT_DIR}/subgraph.yaml"

# ── Required environment ────────────────────────────────────────────

: "${PRIVACY_POOL:?Set PRIVACY_POOL to the deployed PrivacyPool address}"
: "${EPOCH_MANAGER:?Set EPOCH_MANAGER to the deployed EpochManager address}"
: "${GOVERNANCE_TIMELOCK:?Set GOVERNANCE_TIMELOCK to the deployed GovernanceTimelock address}"
: "${START_BLOCK:?Set START_BLOCK to the deployment block number}"
: "${NETWORK:=avalanche}"

# ── Validate addresses ──────────────────────────────────────────────

validate_address() {
  local name="$1" addr="$2"
  if [[ ! "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: $name is not a valid Ethereum address: $addr" >&2
    exit 1
  fi
}

validate_address "PRIVACY_POOL" "$PRIVACY_POOL"
validate_address "EPOCH_MANAGER" "$EPOCH_MANAGER"
validate_address "GOVERNANCE_TIMELOCK" "$GOVERNANCE_TIMELOCK"

# ── Patch subgraph.yaml ────────────────────────────────────────────

echo "Configuring subgraph.yaml for network=$NETWORK ..."

# Use portable sed syntax (macOS + Linux)
sedi() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Replace network
sedi "s|network: .*|network: ${NETWORK}|g" "$SUBGRAPH_YAML"

# Replace PrivacyPool address & startBlock (first data source)
sedi "s|address: \"0x0000000000000000000000000000000000000000\" # Replace with deployed address|address: \"${PRIVACY_POOL}\"|" "$SUBGRAPH_YAML"
sedi "0,/startBlock: 1 # Replace with deployment block number/{s|startBlock: 1 # Replace with deployment block number|startBlock: ${START_BLOCK}|}" "$SUBGRAPH_YAML"

# Replace EpochManager address & startBlock (second data source)
sedi "s|address: \"0x0000000000000000000000000000000000000000\" # Replace with deployed address|address: \"${EPOCH_MANAGER}\"|" "$SUBGRAPH_YAML"
sedi "0,/startBlock: 1 # Replace with deployment block number/{s|startBlock: 1 # Replace with deployment block number|startBlock: ${START_BLOCK}|}" "$SUBGRAPH_YAML"

# Replace GovernanceTimelock address & startBlock (third data source)
sedi "s|address: \"0x0000000000000000000000000000000000000000\" # Replace with deployed address|address: \"${GOVERNANCE_TIMELOCK}\"|" "$SUBGRAPH_YAML"
sedi "0,/startBlock: 1 # Replace with deployment block number/{s|startBlock: 1 # Replace with deployment block number|startBlock: ${START_BLOCK}|}" "$SUBGRAPH_YAML"

echo ""
echo "Done. Updated subgraph.yaml:"
echo "  Network:              $NETWORK"
echo "  PrivacyPool:          $PRIVACY_POOL"
echo "  EpochManager:         $EPOCH_MANAGER"
echo "  GovernanceTimelock:   $GOVERNANCE_TIMELOCK"
echo "  Start Block:          $START_BLOCK"
echo ""
echo "Next steps:"
echo "  cd subgraph"
echo "  graph codegen"
echo "  graph build"
echo "  graph deploy --studio <subgraph-name>"
