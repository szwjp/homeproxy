# AGENTS.md — luci-app-homeproxy

OpenWrt/ImmortalWrt LuCI application that provides a web UI to configure and
run [sing-box](https://github.com/SagiNet/sing-box) as a transparent proxy on
router devices.

## Build / Test / Lint

There is **no local build**. This is an OpenWrt LuCI package — it compiles only
inside the OpenWrt buildroot or the CI pipeline.

```sh
# CI builds ipk/apk packages via GitHub Actions (.github/workflows/build-ipk.yml)
# Triggered on push/PR to master/dev branches.

# Sync translations (requires OpenWrt LuCI's po2lmo tool)
# Run inside OpenWrt SDK:
cd package/luci-app-homeproxy
$(TOPDIR)/feeds/luci/luci.mk  # handles po → lmo, installs files
```

## Architecture

```
LuCI Web UI (JavaScript)
  │  htdocs/luci-static/resources/
  │  ├── homeproxy.js          Shared constants & helpers
  │  └── view/homeproxy/
  │      ├── client.js         Main client config page (1548 lines)
  │      ├── node.js           Node management & subscription share-link parsing
  │      ├── server.js         Inbound server config
  │      └── status.js         Status display
  │
  ▼  RPC (ubus)
Backend (ucode)
  │  root/usr/share/rpcd/ucode/luci.homeproxy
  │    ACL list I/O, cert upload, connection check, sing-box keygen
  │  root/etc/homeproxy/scripts/
  │    ├── homeproxy.uc        Shared library (validation, helpers)
  │    ├── generate_client.uc  UCI → sing-box client JSON (975 lines)
  │    ├── generate_server.uc  UCI → sing-box server JSON
  │    ├── update_subscriptions.uc  Fetch & parse subscription URLs
  │    ├── firewall_pre.uc / firewall_post.ut  nftables rule generation
  │    └── migrate_config.uc   Config migration between versions
  │
  ▼  shell
System (init / uci-defaults)
    root/etc/init.d/homeproxy  procd service (shell, 338 lines)
    root/etc/uci-defaults/     Run once on install: firewall includes, initial config
    root/etc/config/homeproxy  Default UCI config (infra, routing, dns, etc.)
```

**Data flow**: User edits settings in LuCI → UCI config files → ucode scripts
generate sing-box JSON → init.d starts sing-box with JSON → nftables rules
redirect traffic → sing-box proxies it.

## Key Files & Directories

| Path | Purpose |
|---|---|
| `Makefile` | Package metadata, dependencies (`sing-box`, `firewall4`, `kmod-nft-tproxy`) |
| `root/etc/config/homeproxy` | Default UCI config with all sections |
| `root/etc/init.d/homeproxy` | procd init script (start/stop/reload) |
| `root/etc/homeproxy/scripts/generate_client.uc` | Core: UCI→JSON for client mode |
| `root/etc/homeproxy/scripts/homeproxy.uc` | Shared ucode library |
| `root/usr/share/rpcd/ucode/luci.homeproxy` | RPC methods exposed to frontend |
| `htdocs/luci-static/resources/view/homeproxy/client.js` | Main UI page |
| `htdocs/luci-static/resources/view/homeproxy/node.js` | Node editor + share-link parser |
| `root/etc/homeproxy/resources/` | GeoIP/GFW/china list data files |
| `root/etc/homeproxy/scripts/update_subscriptions.uc` | Subscription URL fetching |
| `po/zh_Hans/homeproxy.po` | Chinese translations |

## Coding Conventions

- **Language**: ucode (backend scripts), JavaScript ES5 `'use strict'` (frontend), shell (init)
- **Module system**: LuCI `'require'` directives (not ES modules)
- **Style**: 2-space indent in JS, tabs in shell; SPDX license header on every source file
- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) —
  `type(scope): description`, e.g. `fix(generator/client): ...`, `chore(resources): ...`
- **Branching**: `master` (stable), `dev` (development); PRs target both
- **Error handling**: ucode scripts return `{ result: false, error: '...' }`; init script
  logs to `/var/run/homeproxy/homeproxy.log` and returns non-zero on failure
- **Naming**: UCI sections use `snake_case`; JS uses `camelCase`; ucode uses both

## Git Workflow

- `master` — stable releases
- `dev` — active development
- PRs opened against both branches (CI runs on both)
- Releases published via GitHub Releases trigger CI artifact builds

## CI/CD

GitHub Actions (`.github/workflows/build-ipk.yml`):
- Builds `.ipk` and `.apk` packages on push to `master`/`dev` and PRs
- Triggers on changes to `htdocs/`, `po/`, `root/`, `Makefile`, `.github/`
- Checks out `alpinelinux/apk-tools` (for APK) and `openwrt/luci` (for po2lmo)
- Release events auto-publish built packages

## Tips for AI Agents

- **No local dev server**: You cannot run or test this locally. Testing must happen
  on an actual OpenWrt device or via the CI. Focus on code review and static analysis.
- **ucode is the backbone**: Most logic is in `.uc` files under `root/etc/homeproxy/scripts/`.
  Ucode is a JavaScript-like language for OpenWrt — it has `import` from `fs`, `ubus`, `uci`.
- **UCI is the database**: All settings go through UCI (`/etc/config/homeproxy`). The
  `generate_*.uc` scripts read UCI and output sing-box JSON. Don't modify sing-box JSON
  directly — modify the UCI-to-JSON generation logic.
- **share-link parsing**: `node.js`'s `parseShareLink()` handles importing nodes from
  VMess/VLESS/Trojan/Shadowsocks/Hysteria2/etc. URI schemes. This is a common extension point.
- **Known pain point**: Subscription page is slow with many nodes (noted in README TODO).
  The `update_subscriptions.uc` script fetches and parses all subscriptions synchronously.
- **Translation workflow**: Edit `po/zh_Hans/homeproxy.po`, run
  `.github/rescan-translation.sh` to update `.pot` template.
- **Security-sensitive**: `root/etc/homeproxy/certs/` stores TLS certificates;
  `root/etc/capabilities/homeproxy.json` defines seccomp-like jail capabilities.
