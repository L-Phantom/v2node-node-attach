#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_URL="https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh"
ATTACH_URL="https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-node-attach.sh"
CONFIG="/etc/v2node/config.json"
LISTEN_PORT="443"
INSTALL_V2NODE=0
INSTALL_VERSION=""
RESTART_V2NODE=0
DEBUG="${V2NODE_MUX_DEBUG:-0}"

NODES=()
AUTO_NODES=()
ATTACH_ARGS=()
FIRST_API_HOST=""
FIRST_NODE_ID=""
FIRST_API_KEY=""
LAST_PANEL_ERROR=""

on_error() {
  local code="$?"
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local cmd="${BASH_COMMAND:-unknown}"
  echo "Error: v2node-443-mux.sh failed at line $line: $cmd (exit $code)" >&2
  exit "$code"
}
trap on_error ERR

usage() {
  cat <<'EOF'
Usage:
  v2node-443-mux.sh --node API_HOST,NODE_ID,API_KEY [--node ...]
  v2node-443-mux.sh --node SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY [--node ...]

Options:
  --node API_HOST,NODE_ID,API_KEY
                         Read Reality SNI and backend service port from panel.
  --node SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY
                         Manual fallback. LOCAL_PORT is v2node backend port.
  --listen-port PORT     Public Nginx listen port. Defaults to 443.
  --install-v2node       Install/update official v2node before attaching nodes.
  --install-version VER  Install a specific official v2node version.
  --restart-v2node       Restart v2node after writing config.
  --debug                Print safe panel API diagnostics.
  -h, --help             Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "please run as root"
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || die "port must be a number: $value"
  (( value >= 1 && value <= 65535 )) || die "port out of range: $value"
  printf '%s' "$value"
}

validate_sni() {
  local value="$1"
  [[ -n "$value" ]] || die "SNI is empty"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid SNI: $value"
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
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${packages[@]}" >/dev/null
  else
    die "no supported package manager was found"
  fi
}

ensure_command() {
  local command_name="$1"
  local package_name="${2:-$1}"
  if command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi
  echo "$command_name not found, installing..."
  install_packages "$package_name"
}

ensure_base_packages() {
  ensure_command curl curl
  ensure_command wget wget
  ensure_command jq jq
}

debug_enabled() {
  [[ "$DEBUG" == "1" || "$DEBUG" == "true" || "$DEBUG" == "yes" ]]
}

debug_file_summary() {
  local label="$1"
  local file="$2"
  debug_enabled || return 0
  jq -r --arg label "$label" '
    def one_line: tostring | gsub("[\r\n\t]+"; " ") | .[0:180];
    "Debug: tried \($label)",
    "Debug: keys: \((keys_unsorted // []) | join(","))",
    (if has("status") then "Debug: status=\(.status | one_line)" else empty end),
    (if has("message") then "Debug: message=\(.message | one_line)" else empty end),
    (if has("msg") then "Debug: msg=\(.msg | one_line)" else empty end),
    (if has("error") then "Debug: error=\(.error | one_line)" else empty end)
  ' "$file" >&2 2>/dev/null || true
}

remember_panel_error() {
  local label="$1"
  local file="$2"
  local summary
  summary="$(jq -r --arg label "$label" '
    def one_line: tostring | gsub("[\r\n\t]+"; " ") | .[0:180];
    [
      "endpoint=\($label)",
      (if has("status") then "status=\(.status | one_line)" else empty end),
      (if has("message") then "message=\(.message | one_line)" else empty end),
      (if has("msg") then "msg=\(.msg | one_line)" else empty end),
      (if has("error") then "error=\(.error | one_line)" else empty end)
    ] | join(" ")
  ' "$file" 2>/dev/null || true)"
  [[ -n "$summary" ]] && LAST_PANEL_ERROR="$summary"
}

panel_config_is_usable() {
  local file="$1"
  jq -e '
    type == "object" and
    ([ .. | objects | select(
      has("serverName") or has("server_name") or has("sni") or
      has("reality_settings") or has("realitySettings") or
      has("service_port") or has("local_port") or has("listen_port") or
      has("server_port") or has("port") or has("tls_settings") or
      has("network_settings")
    ) ] | length > 0)
  ' "$file" >/dev/null 2>&1
}

try_panel_config_request() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  local output="$4"
  local path="$5"
  local token_name="$6"
  local label="$7"
  local url="${api_host}${path}"
  local curl_error
  local curl_args=(
    -fsSL
    --connect-timeout 8
    --max-time 20
    --get
    -A "v2node go-resty (https://github.com/go-resty/resty)"
    -H "Accept: application/json"
    --data-urlencode "node_id=$node_id"
    --data-urlencode "node_type=v2node"
  )

  case "$token_name" in
    token|key|api_key) curl_args+=(--data-urlencode "$token_name=$api_key") ;;
    none) ;;
  esac

  curl_error="$(mktemp)"
  if curl "${curl_args[@]}" "$url" -o "$output" 2>"$curl_error"; then
    rm -f "$curl_error"
    if jq empty "$output" >/dev/null 2>&1; then
      debug_file_summary "$label" "$output"
      if panel_config_is_usable "$output"; then
        echo "Fetched node config: $label" >&2
        return 0
      fi
      remember_panel_error "$label" "$output"
    fi
  else
    if debug_enabled; then
      echo "Debug: request failed $label" >&2
      sed 's/[[:cntrl:]]//g' "$curl_error" | cut -c 1-240 >&2 || true
    fi
  fi
  rm -f "$curl_error"
  return 1
}

fetch_panel_config() {
  local api_host="$1"
  local node_id="$2"
  local api_key="$3"
  local output="$4"

  if try_panel_config_request "$api_host" "$node_id" "$api_key" "$output" \
    "/api/v2/server/config" "token" \
    "/api/v2/server/config?node_type=v2node&node_id=$node_id&token=***"; then
    return 0
  fi

  if try_panel_config_request "$api_host" "$node_id" "$api_key" "$output" \
    "/api/v2/server/config" "key" \
    "/api/v2/server/config?node_type=v2node&node_id=$node_id&key=***"; then
    return 0
  fi

  if try_panel_config_request "$api_host" "$node_id" "$api_key" "$output" \
    "/api/v2/server/config" "api_key" \
    "/api/v2/server/config?node_type=v2node&node_id=$node_id&api_key=***"; then
    return 0
  fi

  return 1
}

extract_config_sni() {
  local file="$1"
  jq -r '
    def walk(f):
      . as $in
      | if type == "object" then reduce keys[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then map(walk(f)) | f
        else f end;
    def parse_json_strings:
      walk(if type == "string" then (. as $value | try fromjson catch $value) else . end);
    def clean_sni:
      tostring | split(",")[0] | split(":")[0] | gsub("^\\s+|\\s+$"; "");
    parse_json_strings as $root
    | [
        $root | .. | objects
        | .serverName? // .server_name? // .server_name_sni? // .sni? // .SNI?
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
  local public_port="$2"
  jq -r --arg public_port "$public_port" '
    def walk(f):
      . as $in
      | if type == "object" then reduce keys[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then map(walk(f)) | f
        else f end;
    def parse_json_strings:
      walk(if type == "string" then (. as $value | try fromjson catch $value) else . end);
    def port_value:
      if type == "number" then tostring
      elif type == "string" then (capture("(?<port>[0-9]{1,5})").port? // empty)
      else empty end;
    def valid_port:
      select(length > 0) | select((tonumber >= 1) and (tonumber <= 65535));
    parse_json_strings as $root
    | (
        [
          $root | .. | objects
          | .service_port? // .servicePort? // .local_port? // .localPort?
            // .listen_port? // .listenPort? // .backend_port? // .backendPort?
            // .target_port? // .targetPort?
        ]
        | map(port_value | valid_port)
        | map(select(. != $public_port))
        | first
      ) //
      (
        [
          $root | .. | objects
          | .server_port? // .serverPort? // .port? // .Port?
        ]
        | map(port_value | valid_port)
        | map(select(. != $public_port))
        | first
      ) //
      empty
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
    if [[ -n "$LAST_PANEL_ERROR" ]]; then
      die "cannot read node config from $api_host node $node_id; last panel response: $LAST_PANEL_ERROR"
    fi
    die "cannot read node config from $api_host node $node_id; use manual form SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY"
  fi

  sni="$(extract_config_sni "$config_file")"
  local_port="$(extract_config_port "$config_file" "$LISTEN_PORT")"
  rm -f "$config_file"

  [[ -n "$sni" ]] || die "cannot auto-detect Reality SNI for $api_host node $node_id"
  [[ -n "$local_port" ]] || die "cannot auto-detect backend service port for $api_host node $node_id"

  sni="$(validate_sni "$sni")"
  local_port="$(validate_port "$local_port")"
  echo "Auto-detected route: $sni -> 127.0.0.1:$local_port ($api_host node $node_id)"
  NODES+=("$sni"$'\t'"$local_port"$'\t'"$api_host"$'\t'"$node_id"$'\t'"$api_key")
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
    return 0
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
    return 0
  fi

  die "--node expects API_HOST,NODE_ID,API_KEY or SNI,LOCAL_PORT,API_HOST,NODE_ID,API_KEY: $raw"
}

validate_routes() {
  local item sni local_port api_host node_id api_key
  local seen_snis="" seen_ports=""

  for item in "${NODES[@]}"; do
    IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"
    if [[ "$local_port" == "$LISTEN_PORT" ]]; then
      die "backend service port for $sni is $local_port, same as public listen port $LISTEN_PORT. Change panel service/listen port to a non-$LISTEN_PORT port."
    fi
    case $'\n'"$seen_snis"$'\n' in
      *$'\n'"$sni"$'\n'*) die "duplicate SNI: $sni" ;;
    esac
    case $'\n'"$seen_ports"$'\n' in
      *$'\n'"$local_port"$'\n'*) die "duplicate backend service port: $local_port" ;;
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
  local tmp_dir="$1"
  local install_script
  [[ "$INSTALL_V2NODE" -eq 1 ]] || {
    echo "Skipping official v2node install/update; --install-v2node was not provided."
    return 0
  }
  [[ -n "$FIRST_API_HOST" && -n "$FIRST_NODE_ID" && -n "$FIRST_API_KEY" ]] ||
    die "cannot determine first node for non-interactive upstream install"

  install_script="$tmp_dir/install.sh"
  echo "Downloading official v2node installer..."
  download "$INSTALL_URL" "$install_script"
  chmod +x "$install_script"

  local args=()
  [[ -n "$INSTALL_VERSION" ]] && args+=("$INSTALL_VERSION")
  args+=(--api-host "$FIRST_API_HOST" --node-id "$FIRST_NODE_ID" --api-key "$FIRST_API_KEY")

  echo "Installing/updating official v2node..."
  bash "$install_script" "${args[@]}"
}

run_attach_helper() {
  local tmp_dir="$1"
  local attach_script="$tmp_dir/v2node-node-attach.sh"

  echo "Downloading v2node node attach helper..."
  download "$ATTACH_URL" "$attach_script"
  chmod +x "$attach_script"

  echo "Updating $CONFIG..."
  if [[ "$RESTART_V2NODE" -eq 1 ]]; then
    bash "$attach_script" "${ATTACH_ARGS[@]}" --restart
  else
    bash "$attach_script" "${ATTACH_ARGS[@]}"
  fi
}

ensure_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    return 0
  fi
  echo "nginx not found, installing..."
  install_packages nginx
}

nginx_has_builtin_stream() {
  nginx -V 2>&1 | grep -q -- '--with-stream' &&
    ! nginx -V 2>&1 | grep -q -- '--with-stream=dynamic'
}

find_nginx_stream_module() {
  local module
  for module in \
    /usr/lib/nginx/modules/ngx_stream_module.so \
    /usr/lib64/nginx/modules/ngx_stream_module.so \
    /usr/share/nginx/modules/ngx_stream_module.so \
    /etc/nginx/modules/ngx_stream_module.so; do
    [[ -f "$module" ]] && { printf '%s' "$module"; return 0; }
  done
  find /usr /etc -path '*/nginx/modules/ngx_stream_module.so' -print -quit 2>/dev/null || true
}

nginx_loads_stream_module() {
  local nginx_conf="/etc/nginx/nginx.conf"
  nginx_has_builtin_stream && return 0
  grep -Eq '^[[:space:]]*load_module[[:space:]]+.*ngx_stream_module\.so' "$nginx_conf" 2>/dev/null && return 0
  if grep -Eq '^[[:space:]]*include[[:space:]]+(/etc/nginx/)?modules-enabled/\*\.conf;' "$nginx_conf" 2>/dev/null &&
    grep -REq '^[[:space:]]*load_module[[:space:]]+.*ngx_stream_module\.so' /etc/nginx/modules-enabled 2>/dev/null; then
    return 0
  fi
  return 1
}

remove_own_stream_block_if_stream_unknown() {
  local nginx_conf="/etc/nginx/nginx.conf"
  if nginx -t >/dev/null 2>&1; then
    return 0
  fi
  if ! nginx -t 2>&1 | grep -q 'unknown directive "stream"'; then
    return 0
  fi
  if ! grep -q 'include /etc/nginx/stream.d/\*.conf;' "$nginx_conf" 2>/dev/null; then
    return 0
  fi

  echo "Repairing old generated stream block before loading stream module..."
  cp "$nginx_conf" "$nginx_conf.bak.remove-generated-stream.$(date +%Y%m%d%H%M%S)"
  awk '
    /^[[:space:]]*stream[[:space:]]*\{[[:space:]]*$/ {
      buffer = $0 ORS
      depth = 1
      in_stream = 1
      has_mux_include = 0
      next
    }
    in_stream {
      buffer = buffer $0 ORS
      if ($0 ~ /include[[:space:]]+\/etc\/nginx\/stream\.d\/\*\.conf;/) {
        has_mux_include = 1
      }
      depth += gsub(/\{/, "{")
      depth -= gsub(/\}/, "}")
      if (depth <= 0) {
        if (!has_mux_include) {
          printf "%s", buffer
        }
        buffer = ""
        in_stream = 0
      }
      next
    }
    { print }
  ' "$nginx_conf" > "$nginx_conf.tmp.$$"
  mv "$nginx_conf.tmp.$$" "$nginx_conf"
}

install_nginx_stream_package() {
  echo "Installing nginx stream module package..."
  if command -v apt-get >/dev/null 2>&1; then
    install_packages libnginx-mod-stream
  elif command -v yum >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  elif command -v dnf >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  elif command -v apk >/dev/null 2>&1; then
    install_packages nginx-mod-stream
  elif command -v pacman >/dev/null 2>&1; then
    install_packages nginx-mainline
  else
    die "cannot install nginx stream module: unsupported package manager"
  fi
}

enable_nginx_stream_module() {
  local nginx_conf="/etc/nginx/nginx.conf"
  local module_path

  remove_own_stream_block_if_stream_unknown
  nginx_loads_stream_module && return 0

  install_nginx_stream_package
  nginx_loads_stream_module && return 0

  module_path="$(find_nginx_stream_module)"
  [[ -n "$module_path" ]] || die "ngx_stream_module.so not found after installing stream module package"

  echo "Adding load_module $module_path to $nginx_conf"
  cp "$nginx_conf" "$nginx_conf.bak.load-stream.$(date +%Y%m%d%H%M%S)"
  {
    echo "load_module $module_path;"
    cat "$nginx_conf"
  } > "$nginx_conf.tmp.$$"
  mv "$nginx_conf.tmp.$$" "$nginx_conf"
}

ensure_nginx_stream_include() {
  local nginx_conf="/etc/nginx/nginx.conf"
  mkdir -p /etc/nginx/stream.d

  if grep -q 'include /etc/nginx/stream.d/\*.conf;' "$nginx_conf" 2>/dev/null; then
    return 0
  fi

  if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$nginx_conf"; then
    die "nginx.conf already has a stream block. Add this inside it: include /etc/nginx/stream.d/*.conf;"
  fi

  echo "Adding stream include to $nginx_conf"
  cp "$nginx_conf" "$nginx_conf.bak.stream-include.$(date +%Y%m%d%H%M%S)"
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

  echo "Writing $conf"
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
}

reload_nginx() {
  echo "Testing nginx config..."
  nginx -t
  echo "Reloading nginx..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
  elif command -v service >/dev/null 2>&1; then
    service nginx reload >/dev/null 2>&1 || service nginx restart
  else
    nginx -s reload
  fi
}

listening_on_port() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | awk 'NR > 1 { found=1 } END { exit found ? 0 : 1 }'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { found=1 } END { exit found ? 0 : 1 }'
  else
    return 2
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
  echo "Runtime checks:"
  if listening_on_port "$LISTEN_PORT"; then
    echo "  OK public :$LISTEN_PORT is listening"
  else
    echo "  WARN public :$LISTEN_PORT is not listening"
  fi
  for item in "${NODES[@]}"; do
    IFS=$'\t' read -r sni local_port api_host node_id api_key <<< "$item"
    if listening_on_port "$local_port"; then
      echo "  OK backend 127.0.0.1:$local_port is listening for $sni"
    else
      echo "  WARN backend 127.0.0.1:$local_port is not listening for $sni"
    fi
  done
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
    --debug)
      DEBUG=1
      shift ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

need_root
ensure_base_packages
discover_auto_nodes
[[ "${#NODES[@]}" -gt 0 ]] || die "no node was provided"
validate_routes

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install_v2node_if_requested "$tmp_dir"
run_attach_helper "$tmp_dir"
ensure_nginx
enable_nginx_stream_module
ensure_nginx_stream_include
write_nginx_mux_config
reload_nginx
print_summary
