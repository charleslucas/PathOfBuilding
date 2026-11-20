-- API/Handlers.lua
-- Shared JSON-RPC handlers for PoB API (transport-agnostic)

-- Debug logging control
local DEBUG = os.getenv('POB_API_DEBUG') == '1'
local function debug_log(msg)
  if DEBUG then io.stderr:write('[Handlers] ' .. msg .. '\n') end
end

-- JSON: PoB bundles dkjson under lua/ and requires it as a local module (see
-- Classes/ImportTab.lua, Modules/Data.lua) — there is NO global `dkjson`. Require
-- it the same way for JSON decoding in the import handlers (3.29 import contract).
local dkjson = require('dkjson')

-- Resolve BuildOps reliably regardless of CWD
local BuildOps
do
  debug_log('Attempting to require API.BuildOps')
  local ok_ops, mod = pcall(require, 'API.BuildOps')
  debug_log('pcall require result: ok=' .. tostring(ok_ops) .. ', mod=' .. tostring(mod))
  if ok_ops and mod then
    debug_log('Successfully loaded BuildOps via require')
    BuildOps = mod
  else
    debug_log('require failed, trying dofile fallbacks')
    -- Try path relative to this file's directory
    local dir = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if type(src) == 'string' and src:sub(1,1) == '@' then
      local p = src:sub(2)
      dir = (p:gsub('[^/\\]+$', ''))
    end
    local tried = {}
    local function try(p)
      if p then table.insert(tried, p) end
      if not p then return false end
      debug_log('Trying to load: ' .. tostring(p))
      local ok2, m = pcall(dofile, p)
      if ok2 and m then
        debug_log('Successfully loaded BuildOps from: ' .. tostring(p))
        BuildOps = m
        return true
      end
      debug_log('Failed to load from: ' .. tostring(p) .. ' - error: ' .. tostring(m))
      return false
    end
    if not BuildOps then
      local _ = try(dir .. 'BuildOps.lua')
              or try((rawget(_G,'POB_SCRIPT_DIR') or '.') .. '/API/BuildOps.lua')
              or try('API/BuildOps.lua')
              or try('src/API/BuildOps.lua')
    end
    if not BuildOps then
      io.stderr:write('[Handlers] BuildOps.lua not found. Tried paths: ' .. table.concat(tried, ', ') .. '\n')
      error('API/BuildOps.lua not found. Tried: ' .. table.concat(tried, ', '))
    end
  end
end

-- API version (semantic versioning)
local API_VERSION = "1.0.0"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
  }
end

-- PoB writes into the shared data.skills tables while it loads and calculates a
-- build, so every later build in this process inherited those writes (ported from
-- upstream pob-mcp #57):
--  * SkillsTab sets `levels[level].cost = {}` for triggered skills, zeroing that
--    level's cost for every later build (a ManaCost went from 52 to 0).
--  * CalcSetup flags item-granted supports `grantedEffect.fromItem = true`; CalcTools
--    then stops that support gem supporting ordinary skills in later builds.
--  * Data.lua fills `statMap` lazily; processMod may set `hasGlobalEffect` on the way.
-- Each grantedEffect, its statMap and level tables are snapshotted one level deep
-- when this file loads (end of Main:Init, before any build has calculated) and put
-- back before every API-driven build load / new build.
local sharedSnapshot, sharedCounts = {}, {}
local function snapshotTable(t)
  local copy, n = {}, 0
  for k, v in pairs(t) do copy[k] = v; n = n + 1 end
  sharedSnapshot[t], sharedCounts[t] = copy, n
end
if type(data) == 'table' and type(data.skills) == 'table' then
  for _, grantedEffect in pairs(data.skills) do
    if type(grantedEffect) == 'table' then
      snapshotTable(grantedEffect)
      if type(grantedEffect.statMap) == 'table' then snapshotTable(grantedEffect.statMap) end
      if type(grantedEffect.levels) == 'table' then
        for _, levelData in pairs(grantedEffect.levels) do
          if type(levelData) == 'table' then snapshotTable(levelData) end
        end
      end
    end
  end
end
local function restoreSharedData()
  for t, copy in pairs(sharedSnapshot) do
    -- rawget/rawset: statMap's __index would otherwise create the entry
    local n, dirty = 0, false
    for k, v in pairs(t) do
      n = n + 1
      if copy[k] ~= v then rawset(t, k, copy[k]); dirty = true end
    end
    -- Keys PoB removed only show up as a missing count or next to a change
    if dirty or n ~= sharedCounts[t] then
      for k, v in pairs(copy) do
        if rawget(t, k) ~= v then rawset(t, k, v) end
      end
    end
  end
end

-- (Ported from upstream pob-mcp #59.) Which tinctures apply must not depend on table addresses. mergeTinctures
-- (Modules/CalcPerform.lua) walks `env.tinctures` with pairs() and stops after
-- `TinctureLimit` items. The set is keyed by item objects, so with more active
-- tinctures than the limit the one that applies follows pointer hash order,
-- which changes between processes and with allocation history. Before each
-- perform, keep only the first `limit` tinctures in slot order (Flask 1..5, the
-- order initEnv inserts them in; a calc override's repItem takes the slot it
-- replaces). The rest would have been skipped anyway, so with at most `limit`
-- active nothing changes.
-- PoB loads Modules/Calcs through LoadModule on every CalcsTab, so wrap the
-- loader as well as the calcs table of the build that already exists.
do
  local function tinctureSlotOrder(env)
    local order, seen = {}, {}
    local itemsTab = env.build and env.build.itemsTab
    local override = env.override or {}
    if itemsTab and itemsTab.orderedSlots then
      for _, slot in ipairs(itemsTab.orderedSlots) do
        local item = itemsTab.items[slot.selItemId]
        if override.repSlotName == slot.slotName and override.repItem then item = override.repItem end
        if item and env.tinctures[item] and not seen[item] then
          order[#order + 1], seen[item] = item, true
        end
      end
    end
    -- Not found in a slot (e.g. a toggleTincture override): stable by text.
    local rest = {}
    for item in pairs(env.tinctures) do
      if not seen[item] then rest[#rest + 1] = item end
    end
    table.sort(rest, function(a, b)
      return tostring(a.raw or a.name or '') < tostring(b.raw or b.name or '')
    end)
    for _, item in ipairs(rest) do order[#order + 1] = item end
    return order
  end

  local function patchCalcs(calcs)
    if type(calcs) ~= 'table' or type(calcs.perform) ~= 'function' then return calcs end
    local perform = calcs.perform
    if calcs.__pobmcpTinctureOrder then return calcs end
    calcs.__pobmcpTinctureOrder = true
    calcs.perform = function(env, ...)
      if type(env) == 'table' and type(env.tinctures) == 'table' and next(env.tinctures) and env.modDB then
        local limit = math.max(env.modDB:Sum('BASE', nil, 'TinctureLimit'), 0)
        local order = tinctureSlotOrder(env)
        for i = limit + 1, #order do env.tinctures[order[i]] = nil end
      end
      return perform(env, ...)
    end
    return calcs
  end

  if type(LoadModule) == 'function' then
    local loadModule = LoadModule
    function LoadModule(fileName, ...)
      if type(fileName) == 'string' and (fileName:gsub('%.lua$', '')) == 'Modules/Calcs' then
        return patchCalcs(loadModule(fileName, ...))
      end
      -- Pass every return value through; PoB modules may return several.
      return loadModule(fileName, ...)
    end
  end
  local b = rawget(_G, 'build')
  if type(b) == 'table' and b.calcsTab then patchCalcs(b.calcsTab.calcs) end
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

-- Headless (stdio) build loading, hardened (ported from upstream pob-mcp #52).
-- These handlers only run headless: in TCP mode the PoB window owns the build.
-- Set when the last load_build_xml failed: build-reading actions then refuse
-- instead of answering with whatever build happens to be in memory.
local lastLoadError = nil
local HEADLESS = type(rawget(_G, 'loadBuildFromXML')) == 'function'
-- Headless runs in dev mode, which autosaves the outgoing build on every switch
-- and opens an error popup when that fails; loads treat popups as failures.
-- (Never set in the GUI: it would be persisted to the user's settings.)
if HEADLESS and _G.launch and _G.launch.main then _G.launch.main.disableDevAutoSave = true end

local function closePopups()
  local main = _G.launch and _G.launch.main
  local titles = {}
  if main and main.popups then
    for i, popup in ipairs(main.popups) do titles[i] = tostring(popup.title) end
    while #main.popups > 0 do main:ClosePopup() end
  end
  return titles
end

-- Load a build without inheriting anything from the outgoing one, and fail loudly
-- instead of leaving the previous build's output in place. Returns true when PoB
-- had to convert the build to the current game version.
local function loadFresh(xml, name)
  if _G.launch then _G.launch.promptMsg = nil end
  closePopups()
  -- PoB reuses the build object across loads; cluster-jewel subGraphs from the
  -- outgoing build point at replaced sockets and PostLoad asserts on them.
  if build and build.spec then build.spec.subGraphs = {} end
  -- Loading straight over another build can read its tabs (e.g. a stale
  -- activeSpec index); passing through an empty build resets them.
  _G.newBuild()
  -- A blank build still calculates, so restore shared data after it.
  restoreSharedData()
  local stale = build and build.calcsTab and build.calcsTab.mainOutput
  _G.loadBuildFromXML(xml, name)
  local prompt = _G.launch and _G.launch.promptMsg
  if _G.launch then _G.launch.promptMsg = nil end
  if prompt then error('PoB prompt: ' .. tostring(prompt), 0) end
  -- A build without a supported targetVersion opens the "Game Version" popup; do
  -- what its default button does in the GUI: convert, which reloads the build.
  local converted = false
  local main = _G.launch and _G.launch.main
  local popup = main and main.popups and main.popups[1]
  if popup and #main.popups == 1 and popup.title == 'Game Version'
      and popup.controls and popup.controls.convert and popup.controls.convert.onClick then
    popup.controls.convert.onClick()
    converted = true
  end
  local popups = closePopups()
  if #popups > 0 then error('PoB opened a popup: ' .. table.concat(popups, ' | '), 0) end
  -- PoB can close the build without throwing; Shutdown clears savers.
  if not build or not build.savers or not build.spec then
    error('PoB did not initialize the build; check the XML and supported build version', 0)
  end
  local output = build.calcsTab and build.calcsTab.mainOutput
  if not output or output == stale then error('build did not produce a fresh calculation', 0) end
  return converted
end

handlers.new_build = function(params)
  if not _G.newBuild then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  if build and build.spec then build.spec.subGraphs = {} end
  _G.newBuild()
  -- A blank build still calculates, so restore after it, not before.
  restoreSharedData()
  lastLoadError = nil
  return { ok = true }
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then
    return { ok = false, error = 'missing xml' }
  end
  local name = (params.name and tostring(params.name)) or 'API Build'
  if not _G.loadBuildFromXML then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  local ok, res = pcall(loadFresh, params.xml, name)
  if not ok then
    lastLoadError = tostring(res)
    return { ok = false, error = lastLoadError }
  end
  lastLoadError = nil
  return { ok = true, build_id = 1, converted = res == true or nil }
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err }
  end
  return { ok = true, stats = stats }
end

handlers.get_items = function(params)
  local list, err = BuildOps.get_items()
  if not list then return { ok = false, error = err } end
  return { ok = true, items = list }
end

handlers.get_skills = function(params)
  local info, err = BuildOps.get_skills()
  if not info then return { ok = false, error = err } end
  return { ok = true, skills = info }
end

handlers.get_tree = function(params)
  local tree, err = BuildOps.get_tree()
  if not tree then
    return { ok = false, error = err }
  end
  return { ok = true, tree = tree }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  local skills = BuildOps.get_skills()
  return { ok = true, skills = skills }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then
    return { ok = false, error = err }
  end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.add_item_text = function(params)
  local res, err = BuildOps.add_item_text(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, item = res }
end

handlers.restore_item_slot = function(params)
  local res, err = BuildOps.restore_item_slot(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.clear_item_slot = function(params)
  local res, err = BuildOps.clear_item_slot(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err } end
  return { ok = true, xml = xml }
end

handlers.open_build_xml = function(params)
  -- GUI mode: SetMode loads the build on the next frame, so restoring now is
  -- before it calculates.
  restoreSharedData()
  local res, err = BuildOps.open_build_xml(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true }
end

handlers.close_build = function(params)
  local res, err = BuildOps.close_build()
  if not res then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_view_mode = function(params)
  if not params or params.mode == nil then
    return { ok = false, error = 'missing mode' }
  end
  local ok2, result = BuildOps.set_view_mode(params.mode)
  if not ok2 then return { ok = false, error = result } end
  return { ok = true, mode = result }
end

handlers.set_flask_active = function(params)
  local ok2, err = BuildOps.set_flask_active(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err } end
  return { ok = true, info = info }
end

handlers.get_gem_detail = function(params)
  local gem, err = BuildOps.get_gem_detail(params or {})
  if not gem then return { ok = false, error = err } end
  return { ok = true, gem = gem }
end

handlers.update_tree_delta = function(params)
  local res, err = BuildOps.update_tree_delta(params or {})
  if not res then return { ok = false, error = err } end
  local tree = BuildOps.get_tree()
  -- Pass through the ACTUAL outcome so the caller reports what landed, not what was asked for.
  return {
    ok = true,
    tree = tree,
    added = res.added,
    removed = res.removed,
    autoPathedNodes = res.autoPathedNodes,
    droppedNodes = res.droppedNodes,
    skippedAscendancyNodes = res.skippedAscendancyNodes,
    masteryNoEffect = res.masteryNoEffect,
  }
end

-- Default calc_with fields; callers may request more scalar output keys via
-- params.fields (e.g. MissingFireResist for resistance headroom).
local CALC_WITH_FIELDS = { 'CombinedDPS', 'TotalDPS', 'AverageDamage', 'Life', 'TotalEHP', 'EnergyShield' }
local function slimCalcOutput(out, extraFields)
  if type(out) ~= 'table' then return nil end
  -- JSON-safe scalars only (the full output has functions/userdata)
  local slim = {}
  local function put(k)
    local v = out[k]
    if type(v) == 'number' then
      if v == v and v ~= math.huge and v ~= -math.huge then slim[k] = v end
    elseif type(v) == 'boolean' or type(v) == 'string' then
      slim[k] = v
    end
  end
  for _, k in ipairs(CALC_WITH_FIELDS) do put(k) end
  if type(extraFields) == 'table' then
    for _, k in ipairs(extraFields) do if type(k) == 'string' then put(k) end end
  end
  local minion = type(out.Minion) == 'table' and out.Minion or nil
  if minion then
    slim.Minion = { CombinedDPS = minion.CombinedDPS, TotalDPS = minion.TotalDPS }
  end
  return slim
end

handlers.get_timeless_jewels = function(params)
  local res, err = BuildOps.get_timeless_jewels()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.export_full_stats = function(params)
  local res, err = BuildOps.export_full_stats()
  if not res then return { ok = false, error = err } end
  return { ok = true, stats = res }
end

handlers.parse_item = function(params)
  local res, err = BuildOps.parse_item(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, item = res }
end

handlers.calc_with = function(params)
  params = params or {}
  local out, base, unrecognised = BuildOps.calc_with(params)
  if not out then return { ok = false, error = base } end
  return {
    ok = true,
    output = slimCalcOutput(out, params.fields),
    base = slimCalcOutput(base, params.fields),
    unrecognisedLines = (unrecognised and #unrecognised > 0) and unrecognised or nil,
  }
end

handlers.get_config = function(params)
  local cfg, err = BuildOps.get_config()
  if not cfg then return { ok = false, error = err } end
  local labels = BuildOps.get_config_labels and BuildOps.get_config_labels() or nil
  return { ok = true, config = cfg, labels = labels }
end

handlers.set_config = function(params)
  local res, err = BuildOps.set_config(params or {})
  if not res then return { ok = false, error = err } end
  local cfg = BuildOps.get_config()
  return { ok = true, config = cfg, applied = res.applied, rejected = res.rejected }
end

handlers.get_notes = function(params)
  local res, err = BuildOps.get_notes()
  if not res then return { ok = false, error = err } end
  return { ok = true, notes = res.notes }
end

handlers.set_notes = function(params)
  local ok2, err = BuildOps.set_notes(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.create_socket_group = function(params)
  local res, err = BuildOps.create_socket_group(params or {})
  if not res then return { ok = false, error = err or 'failed to create socket group' } end
  return { ok = true, socketGroup = res }
end

handlers.add_gem = function(params)
  local res, err = BuildOps.add_gem(params or {})
  if not res then return { ok = false, error = err or 'failed to add gem' } end
  return { ok = true, gem = res }
end

handlers.set_gem_level = function(params)
  local ok2, err = BuildOps.set_gem_level(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem level' } end
  return { ok = true }
end

handlers.set_gem_quality = function(params)
  local ok2, err = BuildOps.set_gem_quality(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem quality' } end
  return { ok = true }
end

handlers.remove_skill = function(params)
  local ok2, err = BuildOps.remove_skill(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove skill' } end
  return { ok = true }
end

handlers.remove_gem = function(params)
  local ok2, err = BuildOps.remove_gem(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove gem' } end
  return { ok = true }
end

handlers.get_node_state = function(params)
  local res, err = BuildOps.get_node_state(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, node = res }
end

handlers.get_node_power = function(params)
  local res, err = BuildOps.get_node_power(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.get_stat_breakdown = function(params)
  local res, err = BuildOps.get_stat_breakdown(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, breakdown = res }
end

handlers.get_calc_breakdown = function(params)
  local res, err = BuildOps.get_calc_breakdown(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, breakdown = res }
end

handlers.search_nodes = function(params)
  local res, err = BuildOps.search_nodes(params or {})
  if not res then return { ok = false, error = err or 'failed to search nodes' } end
  return { ok = true, results = res }
end

handlers.save_build = function(params)
  if not params or type(params.path) ~= 'string' then
    return { ok = false, error = 'missing path' }
  end
  local res, err = BuildOps.save_build(params.path)
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_specs = function(params)
  local res, err = BuildOps.list_specs()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_spec = function(params)
  if not params or params.index == nil then return { ok = false, error = 'missing index' } end
  local res, err = BuildOps.select_spec(tonumber(params.index))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_spec = function(params)
  local res, err = BuildOps.create_spec(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.delete_spec = function(params)
  if not params or params.index == nil then return { ok = false, error = 'missing index' } end
  local res, err = BuildOps.delete_spec(tonumber(params.index))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.rename_spec = function(params)
  if not params or params.index == nil or params.title == nil then
    return { ok = false, error = 'missing index or title' }
  end
  local res, err = BuildOps.rename_spec(tonumber(params.index), tostring(params.title))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_item_sets = function(params)
  local res, err = BuildOps.list_item_sets()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_item_set = function(params)
  if not params or params.id == nil then return { ok = false, error = 'missing id' } end
  local res, err = BuildOps.select_item_set(tonumber(params.id))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_item_set = function(params)
  local res, err = BuildOps.create_item_set(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_skill_sets = function(params)
  local res, err = BuildOps.list_skill_sets()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_skill_set = function(params)
  if not params or params.id == nil then return { ok = false, error = 'missing id' } end
  local res, err = BuildOps.select_skill_set(tonumber(params.id))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_config_sets = function(params)
  local res, err = BuildOps.list_config_sets()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_config_set = function(params)
  if not params or params.id == nil then return { ok = false, error = 'missing id' } end
  local res, err = BuildOps.select_config_set(tonumber(params.id))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_loadouts = function(params)
  local res, err = BuildOps.list_loadouts()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_skill_set = function(params)
  local res, err = BuildOps.create_skill_set(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_config_set = function(params)
  local res, err = BuildOps.create_config_set(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_loadout = function(params)
  local res, err = BuildOps.create_loadout(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_loadout = function(params)
  local res, err = BuildOps.select_loadout(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.get_mastery_options = function(params)
  local res, err = BuildOps.get_mastery_options()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.get_ailments = function(params)
  local res, err = BuildOps.get_ailments()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.set_socket_group_enabled = function(params)
  local res, err = BuildOps.set_socket_group_enabled(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.set_gem_enabled = function(params)
  local ok2, err = BuildOps.set_gem_enabled(params or {})
  if not ok2 then return { ok = false, error = err or 'failed' } end
  return { ok = true }
end

handlers.list_spectres = function(params)
  local res, err = BuildOps.list_spectres(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.set_spectres = function(params)
  local res, err = BuildOps.set_spectres(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.get_full_dps_breakdown = function()
  local res, err = BuildOps.get_full_dps_breakdown()
  if not res then return { ok = false, error = err } end
  return {
    ok         = true,
    skills     = res.skills,
    fullDPS    = res.fullDPS,
    fullDotDPS = res.fullDotDPS,
    playerDPS  = res.playerDPS,
  }
end

handlers.probe_stat_weights = function(params)
  local res, err = BuildOps.probe_stat_weights(params or {})
  if not res then return { ok = false, error = err } end
  return {
    ok        = true,
    base      = res.base,
    slot      = res.slot,
    carrier   = res.carrier,
    results   = res.results,
    evaluated = res.evaluated,
    failed    = res.failed,
  }
end

handlers.evaluate_anoint_candidates = function(params)
  local res, err = BuildOps.evaluate_anoint_candidates(params or {})
  if not res then return { ok = false, error = err } end
  return {
    ok         = true,
    candidates = res.candidates,
    base       = res.base,
    evaluated  = res.evaluated,
    skipped    = res.skipped,
    slot       = res.slot,
    baseType   = res.baseType,
    focus      = res.focus,
  }
end

handlers.generate_weighted_trade_query = function(params)
  if not params or type(params.slot) ~= 'string' then
    return { ok = false, error = 'missing slot' }
  end
  local res, err = BuildOps.generate_weighted_trade_query(params)
  if not res then return { ok = false, error = err } end
  return { ok = true, query = res.query, warning = res.warning }
end

-- ---------------------------------------------------------------------------
-- Character import handlers
-- Node.js fetches the JSON bodies from pathofexile.com and forwards them here.
-- We delegate directly to the existing ImportTab methods; the controls table
-- already exists (created in ImportTab:Init), so we only need to patch the
-- boolean state fields the import functions read before calling them.
-- ---------------------------------------------------------------------------

handlers.import_passive_tree = function(params)
  if not params or type(params.json) ~= 'string' then
    return { ok = false, error = 'missing json' }
  end
  if not build or not build.importTab then
    return { ok = false, error = 'build not initialized' }
  end

  local charData = params.char_data
  if type(charData) ~= 'table' then
    return { ok = false, error = 'missing char_data' }
  end

  -- Set the state on the existing control object rather than replacing it.
  -- Replacing controls with plain tables breaks the Import tab UI (controls
  -- lack IsShown() and other methods PoB calls when rendering the tab).
  local clearJewels = params.clear_jewels ~= false
  local ctrl = build.importTab.controls.charImportTreeClearJewels
  if ctrl then ctrl.state = clearJewels end

  -- PoB 3.29 changed the signature to ImportPassiveTreeAndJewels(charData, deleteJewels).
  -- charData now carries the PARSED passives (charData.passives) and jewels
  -- (charData.jewels = passives.items); the method reads charData.league directly and no
  -- longer takes the raw JSON string or the global charSelectLeague. Mirror PoB's own
  -- DownloadPassiveTree flow (Classes/ImportTab.lua): decode the passive-skills JSON and
  -- attach it to charData before the call.
  local passivesTable, _, decErr = dkjson.decode(params.json)
  if type(passivesTable) ~= 'table' then
    return { ok = false, error = 'failed to decode passives json: ' .. tostring(decErr) }
  end
  charData.passives = passivesTable
  charData.jewels = passivesTable.items

  local ok, err = pcall(build.importTab.ImportPassiveTreeAndJewels, build.importTab, charData, clearJewels)
  if not ok then
    return { ok = false, error = 'import_passive_tree exception: ' .. tostring(err) }
  end

  local info, infoErr = BuildOps.get_build_info()
  if not info then return { ok = false, error = infoErr } end
  BuildOps.get_main_output()
  return {
    ok            = true,
    status        = 'Passive tree imported',
    level         = info.level,
    className     = info.className,
    ascendClassName = info.ascendClassName,
  }
end

handlers.import_items_skills = function(params)
  if not params or type(params.json) ~= 'string' then
    return { ok = false, error = 'missing json' }
  end
  if not build or not build.importTab then
    return { ok = false, error = 'build not initialized' }
  end

  -- Set state on existing controls rather than replacing them (see import_passive_tree).
  local ctrls = build.importTab.controls
  if ctrls.charImportItemsClearItems       then ctrls.charImportItemsClearItems.state       = params.clear_items ~= false end
  if ctrls.charImportItemsClearSkills      then ctrls.charImportItemsClearSkills.state      = params.clear_skills ~= false end
  if ctrls.charImportItemsIgnoreWeaponSwap then ctrls.charImportItemsIgnoreWeaponSwap.state = params.ignore_weapon_swap == true end

  -- PoB 3.29 changed the signature to
  -- ImportItemsAndSkills(charData, clearItems, clearSkills, ignoreWeaponSwap), where charData
  -- carries the equipment (charData.equipment = items). It no longer takes the raw JSON
  -- string. The get-items API response has both `.items` and `.character`; mirror PoB's own
  -- DownloadItems flow. (The clear controls above are now redundant with the args but harmless.)
  local resp, _, decErr = dkjson.decode(params.json)
  if type(resp) ~= 'table' then
    return { ok = false, error = 'failed to decode items json: ' .. tostring(decErr) }
  end
  local charData = (type(resp.character) == 'table') and resp.character or {}
  charData.equipment = resp.items

  local ok, ret = pcall(build.importTab.ImportItemsAndSkills, build.importTab, charData,
    params.clear_items ~= false, params.clear_skills ~= false, params.ignore_weapon_swap == true)
  if not ok then
    return { ok = false, error = 'import_items_skills exception: ' .. tostring(ret) }
  end

  BuildOps.get_main_output()
  return {
    ok        = true,
    status    = 'Items and skills imported',
    level     = (type(ret) == 'table' and ret.level) or (type(charData) == 'table' and charData.level) or nil,
    character = (type(ret) == 'table' and ret) or charData,
  }
end

-- After a failed headless load, build-reading actions refuse until the next good
-- load or new_build (they would otherwise answer from the previous build).
local LOAD_INDEPENDENT = {
  ping = true, version = true, new_build = true, load_build_xml = true, quit = true,
}
if HEADLESS then
  for action, fn in pairs(handlers) do
    if not LOAD_INDEPENDENT[action] then
      handlers[action] = function(...)
        if lastLoadError then
          return { ok = false, error = 'last build load failed (' .. lastLoadError .. '); load a build or call new_build first' }
        end
        return fn(...)
      end
    end
  end
end

handlers.get_warnings = function()
  local res, err = BuildOps.get_warnings()
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, warnings = res.warnings, count = res.count }
end

return {
  handlers = handlers,
  version_meta = version_meta,
}
