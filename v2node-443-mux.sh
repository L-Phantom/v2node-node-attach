#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh"
ATTACH_URL="https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-node-attach.sh"
LISTEN_PORT="443"
INSTALL_V2NODE=0
INSTALL_VERSION=""
RESTART_V2NODE=0
NODES=()
AUTO_NODES=()
ATTACH_ARGS=()
FIRST_API_HOST=""
FIRST_NODE_ID=""
FIRST_API_KEY=""

usage() {
  cat <<'EOF'
Usage:
  v2node-443-mux.sh --node API_HOST,NODE_ID,API_KEY [--node ...]
  v2node-443-mux.sh --node SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY [--node ...]

Options:
  --node API_HOST,NODE_ID,API_KEY
                         Recommended. Read SNI and service port from panel.
  --node SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY
                         Manual fallback. LOCAL_PORT must match service port.
  --listen-port PORT     Public mux listen port. Defaults to 443.
  --install-v2node       Install/update upstream v2node before attaching nodes.
  --install-version VER  Install a specific upstream v2node version.
  --restart-v2node       Restart v2node after writing config.
  -h, --help             Show this help.

Example:
  bash v2node-443-mux.sh \
    --install-v2node \
    --node https://panel-a.example.com,1,aaa \
    --node https://panel-b.example.com,2,bbb
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "please run as root"
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

install_packages() {
  local packages=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${packages[@]}" >/dev/null
  else
    die "no supported package manager was found"
  fi
}

ensure_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found, installing..."
    install_packages nginx
  fi
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi
  echo "jq not found, installing..."
  install_packages jq
}

ensure_nginx_stream_module() {
  if nginx -V 2>&1 | grep -q -- '--with-stream'; then
    return
  fi

  if [[ -d /etc/nginx/modules-enabled ]] && ls /etc/nginx/modules-enabled/*stream*.conf >/dev/null 2>&1; then
    return
  fi

  echo "nginx stream module not detected, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    install_packages libnginx-mod-stream
  elif command -v yum >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  elif command -v dnf >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  elif command -v apk >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  else
    die "nginx stream module is required, but no supported package manager was found"
  fi
}

validate_sni() {
  local value="$1"
  [[ -n "$value" ]] || die "SNI is empty"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid SNI: $value"
  printf '%s' "$value"
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || die "port must be a number: $value"
  (( value >= 1 && value <= 65535 )) || die "port out of range: $value"
  printf '%s' "$value"
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

fetch_panel_config() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  local output="$4"
  local endpoint url

  local endpoints=(
    "/api/v1/server/UniProxy/config?node_id=$node_id&node_type=vless"
    "/api/v1/server/UniProxy/config?node_id=$node_id"
    "/api/v2/server/config?node_id=$node_id&node_type=vless"
    "/api/v2/server/config?node_id=$node_id"
    "/api/v1/server/VLess/config?node_id=$node_id"
    "/api/v1/server/vless/config?node_id=$node_id"
  )

  for endpoint in "${endpoints[@]}"; do
    url="${api_host}${endpoint}"
    if curl -fsSL \
      --connect-timeout 8 \
      --max-time 20 \
      -H "Authorization: $api_key" \
      -H "X-Api-Key: $api_key" \
      -H "X-Node-ID: $node_id" \
      "$url" -o "$output" 2>/dev/null; then
      if jq empty "$output" >/dev/null 2>&1; then
        echo "Fetched node config: $endpoint" >&2
        return 0
      fi
    fi
  done

  return 1
}

extract_config_sni() {
  local file="$1"
  jq -r '
    def walk(f):
      . as $in
      | if type == "object" then
          reduce keys[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then
          map(walk(f)) | f
        else
          f
        end;
    def parse_json_strings:
      walk(if type == "string" then (try fromjson catch .) else . end);
    def clean_sni:
      tostring
      | split(",")[0]
      | split(":")[0]
      | gsub("^\\s+|\\s+$"; "");
    parse_json_strings as $root
    |
    [
      $root.. | objects
      | .serverName? // .server_name? // .server_name_sni? // .sni? // .SNI?
        // .dest? // .Dest? // .target? // .Target?
        // .reality_server_name? // .realityServerName?
        // .serverNames?[]? // .server_names?[]? // .server_names?
    ]
    | map(select((type == "string" or type == "number") and (tostring | length > 0)))
    | map(clean_sni)
    | map(select(test("^[A-Za-z0-9._-]+$")))
    | map(select(test("[A-Za-z]")))
    | first // empty
  ' "$file"
}

extract_config_port() {
  local file="$1"
  jq -r '
    def walk(f):
      . as $in
      | if type == "object" then
          reduce keys[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then
          map(walk(f)) | f
        else
          f
        end;
    def parse_json_strings:
      walk(if type == "string" then (try fromjson catch .) else . end);
    parse_json_strings as $root
    |
    [
      $root.. | objects
      | .service_port? // .server_port? // .port? // .local_port? // .listen_port?
        // .ServicePort? // .ServerPort? // .Port? // .serverPort?
    ]
    | map(
        if type == "number" then tostring
        elif type == "string" then .
        else empty end
      )
    | map(capture("(?<port>[0-9]{1,5})").port? // empty)
    | map(select((tonumber >= 1) and (tonumber <= 65535)))
    | first // empty
  ' "$file"
}

discover_node_route() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  local config_file sni local_port
  config_file="$(mktemp)"

  if ! fetch_panel_config "$api_host" "$node_id" "$api_key" "$config_file"; then
    rm -f "$config_file"
    die "cannot read node config from $api_host node $node_id; use manual form SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY"
  fi

  sni="$(extract_config_sni "$config_file")"
  local_port="$(extract_config_port "$config_file")"
  rm -f "$config_file"

  [[ -n "$sni" ]] ||
    die "cannot auto-detect Reality SNI for $api_host node $node_id; use manual form SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY"
  [[ -n "$local_port" ]] ||
    die "cannot auto-detect service port for $api_host node $node_id; use manual form SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY"

  sni="$(validate_sni "$sni")"
  local_port="$(validate_port "$local_port")"
  NODES+=("$sni"$'\t'"$local_port"$'\t'"$api_host"$'\t'"$node_id"$'\t'"$api_key")
  echo "Auto-detected route: $sni -> 127.0.0.1:$local_port ($api_host node $node_id)"
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
  local parts_count sni local_port api_host node_id api_key
  parts_count="$(awk -F',' '{print NF}' <<< "$raw")"

  if [[ "$parts_count" -eq 3 ]]; then
    IFS=',' read -r api_host node_id api_key <<< "$raw"
    api_host="$(normalize_api_host "$api_host")"
    node_id="$(validate_node_id "$node_id")"
    [[ -n "$api_key" ]] || die "ApiKey is empty for $api_host node $node_id"

    AUTO_NODES+=("$api_host"$'\t'"$node_id"$'\t'"$api_key")
    ATTACH_ARGS+=("--node" "$api_host,$node_id,$api_key")
    remember_first_node "$api_host" "$node_id" "$api_key"
    return
  fi

  if [[ "$parts_count" -eq 5 ]]; then
    IFS=',' read -r sni local_port api_host node_id api_key <<< "$raw"
    sni="$(validate_sni "$sni")"
    local_port="$(validate_port "$local_port")"
    api_host="$(normalize_api_host "$api_host")"
    node_id="$(validate_node_id "$node_id")"
    [[ -n "$api_key" ]] || die "ApiKey is empty for $api_host node $node_id"

    NODES+=("$sni"$'\t'"$local_port"$'\t'"$api_host"$'\t'"$node_id"$'\t'"$api_key")
    ATTACH_ARGS+=("--node" "$api_host,$node_id,$api_key")
    remember_first_node "$api_host" "$node_id" "$api_key"
    return
  fi

  die "--node expects API_HOST,NODE_ID,API_KEY or SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY: $raw"
}

validate_routes() {
  local item sni local_port api_host node_id api_key seen_snis="" seen_ports=""
  for item in "${NODES[@]}"; do
    IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"

    if [[ "$local_port" == "$LISTEN_PORT" ]]; then
      die "LOCAL_PORT must not equal public listen port $LISTEN_PORT: $sni"
    fi

    case $'\n'"$seen_snis"$'\n' in
      *$'\n'"$sni"$'\n'*) die "duplicate SNI: $sni" ;;
    esac
    case $'\n'"$seen_ports"$'\n' in
      *$'\n'"$local_port"$'\n'*) die "duplicate LOCAL_PORT: $local_port" ;;
    esac

    seen_snis+="${sni}"$'\n'
    seen_ports+="${local_port}"$'\n'
  done
}

discover_auto_nodes() {
  local item api_host node_id api_key
  for item in "${AUTO_NODES[@]}"; do
    IFS=$'\t' read -r api_host node_id api_key <<< "$item"
    discover_node_route "$api_host" "$node_id" "$api_key"
  done
}

install_v2node_if_requested() {
  [[ "$INSTALL_V2NODE" -eq 1 ]] || return
  [[ -n "$FIRST_API_HOST" && -n "$FIRST_NODE_ID" && -n "$FIRST_API_KEY" ]] ||
    die "cannot determine first node for non-interactive upstream install"

  local install_script="$1/install.sh"
  echo "Downloading official v2node installer..."
  download "$INSTALL_URL" "$install_script"
  chmod +x "$install_script"

  local install_args=()
  if [[ -n "$INSTALL_VERSION" ]]; then
    install_args+=("$INSTALL_VERSION")
  fi
  install_args+=(
    --api-host "$FIRST_API_HOST"
    --node-id "$FIRST_NODE_ID"
    --api-key "$FIRST_API_KEY"
  )

  echo "Installing/updating official v2node..."
  bash "$install_script" "${install_args[@]}"
}

run_attach_helper() {
  local tmp_dir="$1"
  local attach_script="$tmp_dir/v2node-node-attach.sh"
  local local_attach
  local_attach="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v2node-node-attach.sh"

  if [[ -x "$local_attach" ]]; then
    attach_script="$local_attach"
  else
    echo "Downloading v2node node attach helper..."
    download "$ATTACH_URL" "$attach_script"
    chmod +x "$attach_script"
  fi

  echo "Updating /etc/v2node/config.json..."
  if [[ "$RESTART_V2NODE" -eq 1 ]]; then
    bash "$attach_script" "${ATTACH_ARGS[@]}" --restart
  else
    bash "$attach_script" "${ATTACH_ARGS[@]}"
  fi
}

ensure_nginx_stream_include() {
  local nginx_conf="/etc/nginx/nginx.conf"
  local stream_dir="/etc/nginx/stream.d"
  mkdir -p "$stream_dir"

  [[ -f "$nginx_conf" ]] || die "nginx config not found: $nginx_conf"

  if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$nginx_conf"; then
    if ! grep -q '/etc/nginx/stream.d/\*.conf' "$nginx_conf"; then
      echo "Error: nginx.conf already has a stream block but does not include /etc/nginx/stream.d/*.conf" >&2
      echo "Please add this line inside the existing stream block:" >&2
      echo "    include /etc/nginx/stream.d/*.conf;" >&2
      exit 1
    fi
    return
  fi

  cp "$nginx_conf" "$nginx_conf.bak.$(date +%Y%m%d%H%M%S)"
  cat >> "$nginx_conf" <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
}

write_nginx_mux_config() {
  local conf="/etc/nginx/stream.d/v2node-443-mux.conf"
  local first_backend=""
  local item sni local_port api_host node_id api_key

  for item in "${NODES[@]}"; do
    IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"
    first_backend="${first_backend:-127.0.0.1:$local_port}"
  done

  {
    echo "# Generated by v2node-443-mux.sh. Do not edit manually."
    echo "map \$ssl_preread_server_name \$v2node_mux_backend {"
    echo "    default $first_backend;"
    for item in "${NODES[@]}"; do
      IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"
      echo "    $sni 127.0.0.1:$local_port;"
    done
    echo "}"
    echo
    echo "server {"
    echo "    listen 0.0.0.0:$LISTEN_PORT;"
    echo "    proxy_pass \$v2node_mux_backend;"
    echo "    ssl_preread on;"
    echo "}"
  } > "$conf"

  echo "Wrote $conf"
}

reload_nginx() {
  nginx -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
  elif command -v service >/dev/null 2>&1; then
    service nginx reload >/dev/null 2>&1 || service nginx restart
  else
    nginx -s reload
  fi
}

print_summary() {
  local item sni local_port api_host node_id api_key
  echo
  echo "v2node 443 mux completed."
  echo "Public listen: :$LISTEN_PORT"
  echo "Routes:"
  for item in "${NODES[@]}"; do
    IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"
    echo "  - $sni -> 127.0.0.1:$local_port ($api_host node $node_id)"
  done
  echo
  echo "Panel requirement: each backend node service port must match its LOCAL_PORT,"
  echo "while the client/connect port can stay $LISTEN_PORT."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      parse_node_csv "$2"
      shift 2 ;;
    --listen-port)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      LISTEN_PORT="$(validate_port "$2")"
      shift 2 ;;
    --install-v2node)
      INSTALL_V2NODE=1
      shift ;;
    --install-version)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      INSTALL_VERSION="$2"
      shift 2 ;;
    --restart-v2node)
      RESTART_V2NODE=1
      shift ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

need_root
ensure_jq
discover_auto_nodes

[[ "${#NODES[@]}" -gt 0 ]] || die "no node was provided"
validate_routes

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install_v2node_if_requested "$tmp_dir"
run_attach_helper "$tmp_dir"
ensure_nginx
ensure_nginx_stream_module
ensure_nginx_stream_include
write_nginx_mux_config
reload_nginx
print_summary
