#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/v2node/config.json"
RESTART=0
NODES=()
API_HOST=""
NODE_ID=""
API_KEY=""

usage() {
  cat <<'EOF'
Usage:
  v2node-node-attach.sh --api-host URL --node-id ID --api-key KEY [--restart]
  v2node-node-attach.sh --node URL,ID,KEY [--node URL,ID,KEY ...] [--restart]

Options:
  --api-host URL       Panel API host, for example https://panel.example.com
  --node-id ID         v2node node id from the panel
  --api-key KEY        v2node communication key from the panel
  --node URL,ID,KEY    Add or update one node entry. Can be repeated.
  --config PATH        Config path. Defaults to /etc/v2node/config.json
  --restart            Restart v2node after writing config.
  -h, --help           Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_root_for_default_config() {
  if [[ "$CONFIG" == /etc/* && "${EUID}" -ne 0 ]]; then
    die "please run as root when writing $CONFIG"
  fi
}

detect_pkg_manager_install_jq() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi

  echo "jq not found, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed jq >/dev/null
  else
    die "jq is required, but no supported package manager was found"
  fi
}

normalize_api_host() {
  local value="$1"
  value="${value%/}"
  [[ -n "$value" ]] || die "ApiHost is empty"
  case "$value" in
    http://*|https://*) ;;
    *) die "ApiHost must start with http:// or https://: $value" ;;
  esac
  printf '%s' "$value"
}

validate_node_id() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || die "NodeID must be a number: $value"
  printf '%s' "$value"
}

ensure_config_exists() {
  mkdir -p "$(dirname "$CONFIG")"
  if [[ -f "$CONFIG" ]]; then
    jq empty "$CONFIG" >/dev/null || die "invalid JSON config: $CONFIG"
    return
  fi

  cat > "$CONFIG" <<'EOF'
{
  "Log": {
    "Level": "warning",
    "Output": "",
    "Access": "none"
  },
  "Nodes": []
}
EOF
}

backup_config() {
  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$CONFIG.bak.$stamp"
}

upsert_node() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  local tmp

  api_host="$(normalize_api_host "$api_host")"
  node_id="$(validate_node_id "$node_id")"
  [[ -n "$api_key" ]] || die "ApiKey is empty for $api_host node $node_id"

  tmp="$(mktemp)"
  jq \
    --arg api_host "$api_host" \
    --argjson node_id "$node_id" \
    --arg api_key "$api_key" '
      .Nodes = (.Nodes // [])
      | if any(.Nodes[]?; .ApiHost == $api_host and .NodeID == $node_id)
        then
          .Nodes |= map(
            if .ApiHost == $api_host and .NodeID == $node_id
            then . + {"ApiKey": $api_key, "Timeout": (.Timeout // 15)}
            else .
            end
          )
        else
          .Nodes += [{
            "ApiHost": $api_host,
            "NodeID": $node_id,
            "ApiKey": $api_key,
            "Timeout": 15
          }]
        end
    ' "$CONFIG" > "$tmp"
  jq empty "$tmp" >/dev/null
  mv "$tmp" "$CONFIG"
}

restart_v2node() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart v2node
  elif command -v service >/dev/null 2>&1; then
    service v2node restart
  else
    die "cannot restart v2node: systemctl/service not found"
  fi
}

parse_node_csv() {
  local raw="$1"
  local api_host node_id api_key
  IFS=',' read -r api_host node_id api_key <<< "$raw"
  [[ -n "${api_host:-}" && -n "${node_id:-}" && -n "${api_key:-}" ]] ||
    die "--node expects URL,ID,KEY: $raw"
  NODES+=("$api_host"$'\t'"$node_id"$'\t'"$api_key")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-host)
      API_HOST="${2:-}"; shift 2 ;;
    --node-id)
      NODE_ID="${2:-}"; shift 2 ;;
    --api-key)
      API_KEY="${2:-}"; shift 2 ;;
    --node)
      parse_node_csv "${2:-}"; shift 2 ;;
    --config)
      CONFIG="${2:-}"; shift 2 ;;
    --restart)
      RESTART=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

if [[ -n "$API_HOST" || -n "$NODE_ID" || -n "$API_KEY" ]]; then
  [[ -n "$API_HOST" && -n "$NODE_ID" && -n "$API_KEY" ]] ||
    die "--api-host, --node-id and --api-key must be used together"
  NODES+=("$API_HOST"$'\t'"$NODE_ID"$'\t'"$API_KEY")
fi

[[ "${#NODES[@]}" -gt 0 ]] || die "no node was provided"

need_root_for_default_config
detect_pkg_manager_install_jq
ensure_config_exists
backup_config

for item in "${NODES[@]}"; do
  IFS=$'\t' read -r api_host node_id api_key <<< "$item"
  upsert_node "$api_host" "$node_id" "$api_key"
done

echo "Updated $CONFIG"
jq '.Nodes | map({ApiHost, NodeID, Timeout})' "$CONFIG"

if [[ "$RESTART" -eq 1 ]]; then
  restart_v2node
  echo "v2node restarted"
else
  echo "v2node restart skipped; upstream file watcher should reload the config."
fi
