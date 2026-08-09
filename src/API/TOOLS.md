# PathOfBuilding TCP API — Action Reference

This is the Lua-side JSON-RPC API served by `API/TcpServer.lua` (TCP mode) and the headless wrapper (stdio mode).
Each request is a newline-delimited JSON object: `{"action": "<name>", "params": {...}}`.
Responses are `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

pob-mcp calls these actions via the `PoBLuaTcpClient` / `PoBLuaApiClient` bridge in `pobLuaBridge.ts`.

---

## Protocol

| Action | Description |
|--------|-------------|
| `ping` | Health check; returns `{"ok":true,"pong":true}` |
| `version` | Returns PoB version, branch, platform, and API version |
| `quit` | TCP: disconnect this client (PoB keeps running). Stdio: stop the headless process |

---

## Build Lifecycle

| Action | Mode | Description | Key params |
|--------|------|-------------|-----------|
| `new_build` | stdio only | Create a new blank build | — |
| `load_build_xml` | stdio only | Load a build from an XML string | `xml`, `name` |
| `open_build_xml` | TCP only | Open a build in the GUI via `main:SetMode('BUILD', ...)` | `path`, `xml`, `name` |
| `close_build` | TCP only | Return to the build list (`main:SetMode('LIST')`) | — |
| `export_build_xml` | both | Serialise the current build to XML and return it | — |
| `save_build` | both | Write the current build XML to a file path | `path` |
| `get_build_info` | both | Name, level, class, ascendancy, tree version | — |
| `set_level` | both | Set character level and rebuild | `level` |
| `set_view_mode` | TCP only | Switch the visible GUI tab via `build.viewMode` (TREE/SKILLS/ITEMS/CALCS/CONFIG/NOTES/IMPORT/PARTY/COMPARE) | `mode` |

---

## Stats & Output

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_stats` | Export selected output stats (life, DPS, resists, etc.) | `fields[]` (optional; defaults to a fixed defensive set) |
| `get_stat_breakdown` | Tabulate the modifiers contributing to a stat, with source attribution (via `ModStore:Tabulate`). Returns `{stat, actor, config, config_note, output_value, inc_sum, more_multiplier, contributions:[{modType,value,source,name,flags}]}`. Default uses `mainEnv` player modDB + nil cfg (unconditional stats). With `use_skill_config=true` it uses the MAIN skill's `skillModList` + `skillCfg`, capturing skill-conditional mods (damage/speed/crit). | `stat` (PoB mod name, CamelCase), `actor` (player/minion), `use_skill_config` (bool) |
| `get_calc_breakdown` | Surface PoB's own computed breakdown for an output stat — the Calcs-tab multiplier chain (base→added→conversion→inc→more→crit→ailment). Reads the CALCS-mode env PoB already keeps (`calcsTab.calcsEnv.player.breakdown[stat]`); no calc re-run, no math re-derived — flattens PoB's display structure to text lines (color codes stripped, `.slots`/`.rowList` handled). Returns `{stat, found, actor, output_value, lines[]}`, or `{available[]}` when no/unknown stat is given. | `stat` (PoB output-stat key; omit to list available), `actor` |

---

## Passive Tree

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_tree` | Current node allocation, mastery selections, class/ascend IDs | — |
| `set_tree` | Replace full tree from node list + mastery effects | `classId`, `ascendClassId`, `nodes[]`, `masteryEffects{}`, `treeVersion` |
| `update_tree_delta` | Add/remove specific nodes without replacing the whole tree | `addNodes[]`, `removeNodes[]` |
| `search_nodes` | Search tree nodes by name or stat keyword | `keyword`, `nodeType` (normal/notable/keystone/jewel/mastery), `maxResults`, `includeAllocated` |
| `calc_with` | Non-destructive what-if simulation: returns slim output stats for a temporary node/mastery change | `addNodes[]`, `removeNodes[]`, `masteryEffects{}` |

**`calc_with` implementation notes:**
- Temporarily sets `build.viewMode = "CALCULATOR"` before calling `calcFunc(override, false)` to bypass the 30+ second `calcFullDPS` path that fires when the passive tree tab is open.
- For mastery effects: patches `allocNode.sd` and `node.modList` in place via `tree:ProcessStats(node)` then restores them — `calcs.initEnv` reads `modList` directly and ignores `override.masteryEffects`.
- Returns only JSON-safe scalar fields (`CombinedDPS`, `TotalDPS`, `Life`, `TotalEHP`, `EnergyShield`, `Minion.{CombinedDPS,TotalDPS}`). The full `env.player.output` table contains Lua functions and userdata that `dkjson` cannot encode.

---

## Passive Tree Specs

| Action | Description | Key params |
|--------|-------------|-----------|
| `list_specs` | List all specs with title, class, node count, active flag | — |
| `select_spec` | Switch the active spec and rebuild | `index` |
| `create_spec` | Create a new spec; optionally copy from existing | `title`, `copyFrom`, `activate` |
| `delete_spec` | Delete a spec (cannot delete the last one) | `index` |
| `rename_spec` | Rename a spec | `index`, `title` |

---

## Item Sets

| Action | Description | Key params |
|--------|-------------|-----------|
| `list_item_sets` | List all item sets | — |
| `select_item_set` | Switch the active item set and rebuild | `id` |

---

## Skills & Gems

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_skills` | All socket groups with gem names, slot, enabled state | — |
| `set_main_selection` | Set main socket group and active skill index | `mainSocketGroup`, `mainActiveSkill`, `skillPart` |
| `create_socket_group` | Create a new empty socket group | `label`, `slot`, `enabled`, `includeInFullDPS` |
| `add_gem` | Add a gem to a group | `groupIndex`, `gemName`, `level`, `quality`, `qualityId`, `enabled` |
| `set_gem_level` | Set gem level | `groupIndex`, `gemIndex`, `level` |
| `set_gem_quality` | Set gem quality and quality type | `groupIndex`, `gemIndex`, `quality`, `qualityId` |
| `remove_gem` | Remove a gem | `groupIndex`, `gemIndex` |
| `remove_skill` | Remove an entire socket group | `groupIndex` |
| `set_socket_group_enabled` | Enable/disable a socket group | `groupIndex`, `enabled` |
| `set_gem_enabled` | Enable/disable a specific gem | `groupIndex`, `gemIndex`, `enabled` |
| `list_spectres` | List active spectres; optionally search the spectre library | `search?` |
| `set_spectres` | Set the raised-spectre list (names or metadata ids; fuzzy match) | `spectres`, `mode?` |

---

## Items

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_items` | All equipped items with name, base, rarity, raw text | — |
| `add_item_text` | Parse and add an item from clipboard text | `text`, `slotName`, `noAutoEquip` |
| `set_flask_active` | Enable/disable a flask | `index` (1–5), `active` |

---

## Configuration

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_config` | Current bandit, pantheon, enemy level | — |
| `set_config` | Set bandit, pantheon gods, enemy level | `bandit`, `pantheonMajorGod`, `pantheonMinorGod`, `enemyLevel` |

---

## Masteries

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_mastery_options` | All mastery nodes with available effects and which is currently selected | — |

**Field notes:** Effect objects have `effectId` (from `effect.effect`), `stats[]` (from `effect.stats`), `selected` (bool). Node flag is `node.m or node.isMastery`.

---

## Notes

| Action | Description | Key params |
|--------|-------------|-----------|
| `get_notes` | Read the Notes tab content | — |
| `set_notes` | Write the Notes tab content (overwrites) | `text` |

---

## Analysis

| Action | Description | Key params |
|--------|-------------|-----------|
| `evaluate_anoint_candidates` | Rank all anointable notables by simulated DPS/EHP delta | `slot` (Amulet/Belt), `focus` (dps/defence/both), `limit` |
| `generate_weighted_trade_query` | Generate a PoB weighted-stat trade query JSON for a gear slot | `slot`, `options{}` |

---

## Character Import

These actions receive pre-fetched JSON from the PoE API (Node.js fetches, Lua processes).

| Action | Description | Key params |
|--------|-------------|-----------|
| `import_passive_tree` | Import passive tree and jewels from the PoE API response | `json` (tree JSON string), `char_data{}`, `clear_jewels` |
| `import_items_skills` | Import equipped items and skill gems from the PoE API response | `json` (items JSON string), `clear_items`, `clear_skills`, `ignore_weapon_swap` |

---

## TCP vs Stdio differences

| | TCP (GUI) | Stdio (headless) |
|-|-----------|-----------------|
| `new_build` / `load_build_xml` | **Rejected** — use `open_build_xml` | Supported |
| `open_build_xml` / `close_build` | Supported | Not applicable |
| `quit` | Disconnects client only | Stops LuaJIT process |
| Build state | Live GUI build — user sees every change | In-memory only |
| `build` global | Refreshed from `main.modes["BUILD"]` each frame | Set by headless wrapper |
