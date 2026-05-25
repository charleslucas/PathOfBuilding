# PathOfBuilding — API Fork (`api-stdio` branch)

This is a fork of [Path of Building Community](https://github.com/PathOfBuildingCommunity/PathOfBuilding) with a JSON-RPC API layer added to the `api-stdio` branch. It serves as the calculation backend for [pob-mcp](https://github.com/charleslucas/pob-mcp).

## Part of poe_mcp_suite

This repository is part of [poe_mcp_suite](https://github.com/charleslucas/poe_mcp_suite) — a collection of MCP servers for Path of Exile designed to work together with Claude. See the suite repo for an overview of all available servers and tools.

---

## What this fork adds

The `api-stdio` branch adds `src/API/` — a thin JSON-RPC API layer that exposes PoB's full calculation engine over either:

- **TCP socket** (live GUI mode): Claude connects to a running PoB GUI via `TcpServer.lua`. Every change appears in the PoB window in real time. PoB can be minimised — a background keepalive keeps its frame loop running at ~60 fps.
- **stdio** (headless mode): `HeadlessWrapper.lua` spawns a LuaJIT process that loads and calculates builds without a GUI.

Both modes share the same `Handlers.lua` / `BuildOps.lua` API surface. See [`src/API/TOOLS.md`](src/API/TOOLS.md) for the full list of available actions.

### Key additions

| File | Purpose |
|------|---------|
| `src/API/TcpServer.lua` | Non-blocking TCP server pumped by PoB's frame loop via `onFrameFuncs` |
| `src/API/Handlers.lua` | JSON-RPC dispatcher — maps action names to `BuildOps` calls |
| `src/API/BuildOps.lua` | All build read/write operations (tree, items, gems, stats, mastery, config) |
| `src/API/TOOLS.md` | Full action reference with parameter docs and implementation notes |
| `LaunchPoBWithAPI.bat` | *(in pob-mcp repo)* Launches PoB with TCP env vars and auto-patches `Main.lua` |

### Notable implementation notes

- `calc_with` temporarily sets `build.viewMode = "CALCULATOR"` before calling `calcFunc(override, false)` to bypass the 30+ second `calcFullDPS` path that fires when the passive tree tab is open.
- The `handlers.calc_with` response returns only JSON-safe scalar fields — the raw `env.player.output` table contains Lua functions and userdata that `dkjson` cannot encode.
- Mastery effect simulation patches `allocNode.sd` and `node.modList` directly via `tree:ProcessStats(node)` because `calcs.initEnv` ignores `override.masteryEffects`.

---

## Launching with the TCP API

Use `LaunchPoBWithAPI.bat` from the `pob-mcp` repo rather than the normal PoB shortcut. It:
1. Sets `POB_API_TCP=1` and `POB_API_TCP_PORT=59166`
2. Checks whether the TCP patch is still in `Modules/Main.lua`; re-applies it if PoB updated and overwrote it
3. Launches `Path of Building.exe`

PoB's built-in updater will overwrite `Modules/Main.lua` and show an integrity check warning — this is expected. Re-launching via the batch file self-heals.

---

## Original project

Path of Building was created by David Gowor and is maintained by the Path of Building Community team.

- Upstream repo: [PathOfBuildingCommunity/PathOfBuilding](https://github.com/PathOfBuildingCommunity/PathOfBuilding)
- License: MIT (see [LICENSE.md](LICENSE.md))

For general PoB usage, documentation, and issues unrelated to the API layer, refer to the upstream project.
