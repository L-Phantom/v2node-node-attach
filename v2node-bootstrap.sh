#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh"
ATTACH_URL="https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-node-attach.sh"
INSTALL_VERSION=""
ATTACH_ARGS=()

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-host|--node-id|--api-key|--node)
      [[ $# -ge 2 ]] || die "$1 requires a value"
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install_script="$tmp_dir/install.sh"
attach_script="$tmp_dir/v2node-node-attach.sh"

echo "Downloading official v2node installer..."
download "$INSTALL_URL" "$install_script"
chmod +x "$install_script"

echo "Installing/updating official v2node..."
if [[ -n "$INSTALL_VERSION" ]]; then
  bash "$install_script" "$INSTALL_VERSION"
else
  bash "$install_script"
fi

echo "Downloading v2node node attach helper..."
download "$ATTACH_URL" "$attach_script"
chmod +x "$attach_script"

echo "Updating v2node node config..."
bash "$attach_script" "${ATTACH_ARGS[@]}"

echo "v2node bootstrap completed."
