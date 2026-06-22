# v2node-node-attach

Small helper script for appending or updating `Nodes` entries in
`/etc/v2node/config.json`.

It is designed to work with the official `v2node` installer. You can either run
the full bootstrap command, or install `v2node` first and then run the attach
helper one or more times.

## Usage

Full one-command install and attach:

```bash
wget -N https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-bootstrap.sh && bash v2node-bootstrap.sh \
  --api-host https://node.example.com \
  --node-id 6 \
  --api-key your-api-key
```

Full one-command install and attach multiple panel nodes:

```bash
wget -N https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-bootstrap.sh && bash v2node-bootstrap.sh \
  --node https://panel-a.example.com,1,aaa \
  --node https://panel-b.example.com,2,bbb
```

Attach nodes only, when official `v2node` is already installed:

```bash
wget -N https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-node-attach.sh && bash v2node-node-attach.sh \
  --node https://panel-a.example.com,1,aaa \
  --node https://panel-b.example.com,2,bbb
```

The script is idempotent. Running it again with the same `ApiHost + NodeID`
updates the existing node entry instead of duplicating it.

## 443 SNI mux for Reality/TCP

For `VLESS + TCP + Reality + xtls-rprx-vision`, multiple production panels can
share the same public `IP:443` by using different SNI values. This does not
modify `v2node`; it installs/updates `v2node`, appends node entries, and writes
an Nginx `stream` SNI router.

```bash
wget -N https://raw.githubusercontent.com/L-Phantom/v2node-node-attach/main/v2node-443-mux.sh && bash v2node-443-mux.sh \
  --install-v2node \
  --node https://panel-a.example.com,1,aaa \
  --node https://panel-b.example.com,2,bbb
```

Each `--node` value is:

```text
API_HOST,NODE_ID,API_KEY
```

The script reads the Reality SNI and backend service port from the panel node
config automatically.

Panel requirements:

- The client/connect port shown to users can stay `443`.
- The backend service port must be different for each panel node, for example
  `14431`, `14432`, `14433`.
- The Reality `Server Name (SNI)` must be different for each backend, for
  example `a.example.com`, `b.example.com`.
- Do not let `v2node` listen on the host public `0.0.0.0:443`; Nginx owns the
  public `443` and forwards by SNI.

Generated routing:

```text
public :443
  a.example.com -> 127.0.0.1:14431
  b.example.com -> 127.0.0.1:14432
```

If official `v2node` is already installed, remove `--install-v2node`.

If your panel API is customized and auto-detection fails, use the manual
fallback format:

```bash
bash v2node-443-mux.sh \
  --node a.example.com,14431,https://panel-a.example.com,1,aaa \
  --node b.example.com,14432,https://panel-b.example.com,2,bbb
```

For API detection diagnostics, add `--debug` or set `V2NODE_MUX_DEBUG=1`.
The script prints endpoint/status/message summaries only; it does not print the
full API key.

## Notes

- The script backs up the old config before writing.
- By default it does not restart `v2node`. The upstream service watches
  `/etc/v2node/config.json` and reloads on file changes.
- Pass `--restart` if you want the helper to restart `v2node` explicitly.
- Pass `--config /path/to/config.json` for testing or non-standard installs.
- The 443 mux script backs up `/etc/nginx/nginx.conf` before adding a top-level
  `stream` include. If your server already has a custom `stream` block, add
  `include /etc/nginx/stream.d/*.conf;` inside that block before running it.
