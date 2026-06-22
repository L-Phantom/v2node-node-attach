#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh"
ATTACH_URL="https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-node-attach.sh"
INSTALL_VERSION=""
ATTACH_ARGS=()
FIRST_API_HOST=""
FIRST_NODE_ID=""
FIRST_API_KEY=""

usage() {
  cat <<'EOF'
Usage:
  v2node-bootstrap.sh --api-host URL --node-id ID --api-key KEY
  v2node-bootstrap.sh --node URL,ID,KEY [--node URL,ID,KEY ...]

Options:
  --api-host URL          Panel API host, for example https://panel.example.com
  --node-id ID            v2node node id from the panel
  --api-key KEY           v2node communication key from the panel
  --node URL,ID,KEY       Add or update one node entry. Can be repeated.
  --install-version VER   Install a specific upstream v2node version.
  --restart               Force restart after writing config.
  -h, --help              Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

download() {
  local url="$1"
  local target="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$target"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$target" "$url"
  else
    die "curl or wget is required"
  fi
}

remember_first_node() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  if [[ -z "$FIRST_API_HOST" ]]; then
    FIRST_API_HOST="$api_host"
    FIRST_NODE_ID="$node_id"
    FIRST_API_KEY="$api_key"
  fi
}

parse_node_csv() {
  local raw="$1"
  local api_host node_id api_key
  IFS=',' read -r api_host node_id api_key <<< "$raw"
  [[ -n "${api_host:-}" && -n "${node_id:-}" && -n "${api_key:-}" ]] ||
    die "--node expects URL,ID,KEY: $raw"
  remember_first_node "$api_host" "$node_id" "$api_key"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-host)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ATTACH_ARGS+=("$1" "$2")
      FIRST_API_HOST="${FIRST_API_HOST:-$2}"
      shift 2 ;;
    --node-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ATTACH_ARGS+=("$1" "$2")
      FIRST_NODE_ID="${FIRST_NODE_ID:-$2}"
      shift 2 ;;
    --api-key)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ATTACH_ARGS+=("$1" "$2")
      FIRST_API_KEY="${FIRST_API_KEY:-$2}"
      shift 2 ;;
    --node)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      parse_node_csv "$2"
      ATTACH_ARGS+=("$1" "$2")
      shift 2 ;;
    --restart)
      ATTACH_ARGS+=("$1")
      shift ;;
    --install-version)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      INSTALL_VERSION="$2"
      shift 2 ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[[ "${#ATTACH_ARGS[@]}" -gt 0 ]] || die "no node was provided"
[[ -n "$FIRST_API_HOST" && -n "$FIRST_NODE_ID" && -n "$FIRST_API_KEY" ]] ||
  die "cannot determine first node for non-interactive upstream install"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install_script="$tmp_dir/install.sh"
attach_script="$tmp_dir/v2node-node-attach.sh"

echo "Downloading official v2node installer..."
download "$INSTALL_URL" "$install_script"
chmod +x "$install_script"

echo "Installing/updating official v2node..."
INSTALL_ARGS=()
if [[ -n "$INSTALL_VERSION" ]]; then
  INSTALL_ARGS+=("$INSTALL_VERSION")
fi
INSTALL_ARGS+=(
  --api-host "$FIRST_API_HOST"
  --node-id "$FIRST_NODE_ID"
  --api-key "$FIRST_API_KEY"
)
bash "$install_script" "${INSTALL_ARGS[@]}"

echo "Downloading v2node node attach helper..."
download "$ATTACH_URL" "$attach_script"
chmod +x "$attach_script"

echo "Updating v2node node config..."
bash "$attach_script" "${ATTACH_ARGS[@]}"

echo "v2node bootstrap completed."
