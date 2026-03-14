#!/usr/bin/env bash
# subgraph/configure.sh — Generate subgraph.yaml from template + networks.json.
#
# Usage (network mode — reads from networks.json):
#   ./configure.sh --network avalanche_fuji
#   ./configure.sh --network moonbase_alpha
#
# Usage (legacy env-var mode):
#   PRIVACY_POOL=0x... EPOCH_MANAGER=0x... GOVERNANCE_TIMELOCK=0x... \
#     START_BLOCK=12345 NETWORK=avalanche ./configure.sh
#
# This produces subgraph.yaml ready for `graph deploy`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/subgraph.template.yaml"
OUTPUT="${SCRIPT_DIR}/subgraph.yaml"
NETWORKS_JSON="${SCRIPT_DIR}/networks.json"

# ── Address validation ──────────────────────────────────────────────

validate_address() {
  local name="$1" addr="$2"
  if [[ ! "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: $name is not a valid Ethereum address: $addr" >&2
    exit 1
  fi
}

# ── Network mode (--network flag) ──────────────────────────────────

if [[ "${1:-}" == "--network" ]]; then
  DEPLOYMENT="${2:?Usage: ./configure.sh --network <network_key>}"

  if [[ ! -f "$NETWORKS_JSON" ]]; then
    echo "ERROR: networks.json not found at $NETWORKS_JSON" >&2
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for --network mode (brew install jq)" >&2
    exit 1
  fi

  # Extract network config from JSON
  ENTRY=$(jq -r --arg k "$DEPLOYMENT" '.[$k] // empty' "$NETWORKS_JSON")
  if [[ -z "$ENTRY" ]]; then
    AVAILABLE=$(jq -r 'keys | join(", ")' "$NETWORKS_JSON")
    echo "ERROR: Network '$DEPLOYMENT' not found. Available: $AVAILABLE" >&2
    exit 1
  fi

  NETWORK=$(echo "$ENTRY" | jq -r '.network')
  START_BLOCK=$(echo "$ENTRY" | jq -r '.startBlock')
  PRIVACY_POOL=$(echo "$ENTRY" | jq -r '.contracts.PrivacyPool')
  EPOCH_MANAGER=$(echo "$ENTRY" | jq -r '.contracts.EpochManager')
  GOVERNANCE_TIMELOCK=$(echo "$ENTRY" | jq -r '.contracts.GovernanceTimelock')
  DEPLOYMENT_NAME="Soul Privacy ($DEPLOYMENT)"

  echo "Using network config: $DEPLOYMENT"
else
  # ── Legacy env-var mode ──────────────────────────────────────────

  : "${PRIVACY_POOL:?Set PRIVACY_POOL to the deployed PrivacyPool address}"
  : "${EPOCH_MANAGER:?Set EPOCH_MANAGER to the deployed EpochManager address}"
  : "${GOVERNANCE_TIMELOCK:?Set GOVERNANCE_TIMELOCK to the deployed GovernanceTimelock address}"
  : "${START_BLOCK:?Set START_BLOCK to the deployment block number}"
  : "${NETWORK:=avalanche}"
  DEPLOYMENT_NAME="Soul Privacy (${NETWORK})"
fi

# ── Validate addresses ──────────────────────────────────────────────

validate_address "PRIVACY_POOL" "$PRIVACY_POOL"
validate_address "EPOCH_MANAGER" "$EPOCH_MANAGER"
validate_address "GOVERNANCE_TIMELOCK" "$GOVERNANCE_TIMELOCK"

# ── Generate subgraph.yaml from template ────────────────────────────

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found at $TEMPLATE" >&2
  exit 1
fi

echo "Generating subgraph.yaml for network=$NETWORK ..."

sed \
  -e "s|{{NETWORK}}|${NETWORK}|g" \
  -e "s|{{PRIVACY_POOL}}|${PRIVACY_POOL}|g" \
  -e "s|{{EPOCH_MANAGER}}|${EPOCH_MANAGER}|g" \
  -e "s|{{GOVERNANCE_TIMELOCK}}|${GOVERNANCE_TIMELOCK}|g" \
  -e "s|{{START_BLOCK}}|${START_BLOCK}|g" \
  -e "s|{{DEPLOYMENT_NAME}}|${DEPLOYMENT_NAME}|g" \
  "$TEMPLATE" > "$OUTPUT"

echo ""
echo "Done. Generated subgraph.yaml:"
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
