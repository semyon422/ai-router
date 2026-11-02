# ai-router

Standalone multi-channel AI inference router: named users with API keys and per-user
model grants, ChatGPT/Codex OAuth channels, GLM and OpenAI-compatible upstreams,
usage statistics, an MCP management API and a read-only web admin dashboard.

The full specification is in [ai/router/spec.md](ai/router/spec.md).

## Layout

- `ai/router/` — the router: server, providers, repos, admin pages, MCP tools, tests.
  Modules are required as `ai.router.*` relative to this repository root.
- `aqua/` — git submodule (`github.com/semyon422/aqua`): the main external Lua dependency
  (`ai.openai.*`, `ai.zai.*`, `web.*`, `mcp.*`, `rdb.*`, ...).
- `3rd-deps/lua/ljsqlite3.lua` — MIT-licensed SQLite FFI wrapper (stepelu/lua-ljsqlite3).
- `docker/` — container entrypoint, health check, config loader and secret generator.
- `compose.yaml` — the `ai-router` service (loopback bind, host networking, state in `server-state/`).

## Development (Linux)

1. `git submodule update --init`
2. Provision the gitignored runtime artifacts from a rizu checkout (or the VPS):
   `bin/linux64/{libsqlite3.so,libssl.so.3,libcrypto.so.3}` (OpenSSL 3.5.7, SQLite 3.53.4)
   and `tree/` (luasocket/ssl). The entrypoint asserts exact versions.
3. `./test` — headless test suite (system LuaJIT, no window or GPU needed).
4. `./luajit ai/router/proxy.lua [config_path]` — run the router locally; the default
   config is `userdata/ai_router.lua` (layout in `docker/ai-router-config.example.lua`).
5. `./luajit ai/router/smoke.lua` — end-to-end smoke test against a local mock upstream.

## Deployment

Deploys to `/home/semyon422/ai-router` on the VPS, one `ai-router` compose service
(listening on `127.0.0.1:28083`), state in `server-state/` (`config.lua`, `network.lua`,
`router.db`):

- `make config` — create the private config with random secrets (one time).
- Push to `master` (or dispatch the workflow) — GitHub Actions runs
  `./deploy.sh <commit>` over SSH: checkout, `./test`, compose recreate, health wait.
  There is no automatic rollback; a failed health check leaves the new version running
  and reports a red workflow.
- `make logs`, `make shell` — inspect the running service.
