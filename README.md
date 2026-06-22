# v2node-node-attach

Small helper script for appending or updating `Nodes` entries in
`/etc/v2node/config.json`.

It is designed to work with the official `v2node` installer. Install `v2node`
first, then run this helper one or more times to attach extra production
panels without manually editing JSON.

## Usage

Install official `v2node`:

```bash
wget -N https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh && bash install.sh
```

Attach one panel node:

```bash
wget -N https://raw.githubusercontent.com/YOUR_GITHUB_USER/v2node-node-attach/main/v2node-node-attach.sh
bash v2node-node-attach.sh \
  --api-host https://node.example.com \
  --node-id 6 \
  --api-key your-api-key
```

Attach multiple panel nodes in one command:

```bash
wget -N https://raw.githubusercontent.com/YOUR_GITHUB_USER/v2node-node-attach/main/v2node-node-attach.sh
bash v2node-node-attach.sh \
  --node https://panel-a.example.com,1,aaa \
  --node https://panel-b.example.com,2,bbb
```

The script is idempotent. Running it again with the same `ApiHost + NodeID`
updates the existing node entry instead of duplicating it.

## Notes

- The script backs up the old config before writing.
- By default it does not restart `v2node`. The upstream service watches
  `/etc/v2node/config.json` and reloads on file changes.
- Pass `--restart` if you want the helper to restart `v2node` explicitly.
- Pass `--config /path/to/config.json` for testing or non-standard installs.

