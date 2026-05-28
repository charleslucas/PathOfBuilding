-- API/BuildOps.lua
-- Thin wrappers around PoB headless objects for programmatic operations

local M = {}

-- Constants
local MIN_PLAYER_LEVEL = 1
local MAX_PLAYER_LEVEL = 100
local NUM_FLASK_SLOTS = 5
local MAX_ITEM_TEXT_LENGTH = 10240  -- 10KB

-- Ensure outputs are (re)built and return the main output table safely
function M.get_main_output()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end
  local output = build.calcsTab and build.calcsTab.mainOutput or nil
  if not output then
    return nil, "no output available"
  end
  return output
end

-- Export a subset of useful stats from main output
-- If fields is provided, only export those keys (when present)
function M.export_stats(fields)
  local output, err = M.get_main_output()
  if not output then
    return nil, err
  end
  local wanted = fields or {
    "TotalDPS", "CombinedDPS", "FullDPS", "MinionTotalDPS",
    "Life", "EnergyShield", "Armour", "Evasion",
    "FireResist", "ColdResist", "LightningResist", "ChaosResist",
    "BlockChance", "SpellBlockChance",
    "LifeRegen", "Mana", "ManaRegen",
    "Ward", "DodgeChance", "SpellDodgeChance",
    "TotalEHP",
  }
  local result = {}
  for _, k in ipairs(wanted) do
    if type(output[k]) ~= 'nil' then
      result[k] = output[k]
    end
  end
  -- include some metadata if available
  result._meta = result._meta or {}
  if build and build.targetVersion then
    result._meta.treeVersion = tostring(build.targetVersion)
  end
  if build and build.characterLevel then
    result._meta.level = tonumber(build.characterLevel)
  end
  if build and build.buildName then
    result._meta.buildName = tostring(build.buildName)
  end
  return result
end

-- Read current tree allocation and metadata
function M.get_tree()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  local spec = build.spec
  local out = {
    treeVersion = spec.treeVersion,
    classId = tonumber(spec.curClassId) or 0,
    ascendClassId = tonumber(spec.curAscendClassId) or 0,
    secondaryAscendClassId = tonumber(spec.curSecondaryAscendClassId or 0) or 0,
    nodes = {},
    masteryEffects = {},
  }
  for id, _ in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)
  return out
end

-- Set tree allocation from parameters
-- params: { classId, ascendClassId, secondaryAscendClassId?, nodes:[int], masteryEffects?:{[id]=effect}, treeVersion? }
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  local classId = tonumber(params.classId or 0) or 0
  local ascendId = tonumber(params.ascendClassId or 0) or 0
  local secondaryId = tonumber(params.secondaryAscendClassId or 0) or 0
  local nodes = {}
  if type(params.nodes) == 'table' then
    for _, v in ipairs(params.nodes) do
      table.insert(nodes, tonumber(v))
    end
  end
  local mastery = params.masteryEffects or {}
  -- Bug 1: Preserve existing mastery selections when none are provided by the caller.
  -- ImportFromNodeList wipes masterySelections before setting them; if the caller omits
  -- masteryEffects, passing {} would silently clear all mastery choices.
  if next(mastery) == nil and build.spec.masterySelections then
    mastery = build.spec.masterySelections
  end
  -- Bug 2c: Preserve existing hashOverrides (tattoo/node replacement data).
  -- Passing {} drops all node overrides that were loaded from the build XML.
  local hashOverrides = (build.spec.hashOverrides ~= nil) and build.spec.hashOverrides or {}
  local treeVersion = params.treeVersion
  -- Import (resets nodes internally and rebuilds)
  build.spec:ImportFromNodeList(classId, ascendId, secondaryId, nodes, hashOverrides, mastery, treeVersion)
  -- Rebuild calcs to reflect changes
  M.get_main_output()
  return true
end

-- Export full build XML
-- Close the current build and return to the build list screen.
function M.close_build()
  if _G.main and main.SetMode then
    main:SetMode('LIST')
    _G.build = nil
    return { ok = true }
  end
  return nil, 'main:SetMode not available'
end

-- Open an existing build XML into PoB's GUI (TCP mode: makes it the active build).
-- Pass xml=nil (or omit) to create a brand-new empty build using PoB's own defaults.
function M.open_build_xml(params)
  if not _G.main or not main.SetMode then
    return nil, 'main:SetMode not available (headless mode?)'
  end
  local path = (type(params) == 'table' and params.path) or ''
  local xml  = (type(params) == 'table' and type(params.xml) == 'string') and params.xml or nil

  -- BuildMode:Init(dbFileName, buildName, buildXML, ...)
  -- dbFileName = nil  → new unsaved build
  -- buildName must be non-nil or Init() immediately returns to LIST mode
  -- BuildMode:Init(dbFileName, buildName, buildXML, ...)
  -- dbFileName = false → new/unsaved build (matches how PoB itself creates new builds)
  -- dbFileName = path  → loading from file
  local buildName = (type(params) == 'table' and params.name) or 'New Build'
  if xml then
    if path ~= '' then
      main:SetMode('BUILD', path, buildName, xml)
    else
      main:SetMode('BUILD', false, buildName, xml)
    end
  else
    main:SetMode('BUILD', false, buildName)
  end

  -- Refresh _G.build reference (may take a frame or two to fully initialize).
  if main.modes and main.modes['BUILD'] then
    _G.build = main.modes['BUILD']
  end
  local ready = _G.build and _G.build.calcsTab and _G.build.importTab and true or false
  return { ok = true, ready = ready }
end

function M.export_build_xml()
  if not build or not build.SaveDB then
    return nil, 'build not initialized'
  end
  -- Ensure the calculation environment (mainEnv) is populated before saving,
  -- since Build:Save() references calcsTab.mainEnv for PlayerStat elements.
  if build.calcsTab and build.calcsTab.BuildOutput then
    pcall(build.calcsTab.BuildOutput, build.calcsTab)
  end
  local xml = build:SaveDB('api-export')
  if not xml then return nil, 'failed to compose xml' end
  return xml
end

-- Save build XML to a file path
function M.save_build(filePath)
  if not filePath or type(filePath) ~= 'string' or filePath == '' then
    return nil, 'missing or invalid file path'
  end
  local xml, err = M.export_build_xml()
  if not xml then return nil, err end
  local f, ferr = io.open(filePath, 'w')
  if not f then return nil, 'cannot open file for writing: ' .. tostring(ferr) end
  f:write(xml)
  f:close()
  -- Clear PoB's "unsaved changes" flags so the UI doesn't prompt on navigation.
  if build then
    build.modFlag = false
    if build.notesTab  then build.notesTab.modFlag  = false end
    if build.configTab then build.configTab.modFlag = false end
    if build.treeTab   then build.treeTab.modFlag   = false end
    if build.skillsTab then build.skillsTab.modFlag = false end
    if build.itemsTab  then build.itemsTab.modFlag  = false end
  end
  return { size = #xml, path = filePath }
end

-- Set player level and rebuild
function M.set_level(level)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  local lvl = tonumber(level)
  if not lvl or lvl < MIN_PLAYER_LEVEL or lvl > MAX_PLAYER_LEVEL then
    return nil, string.format('invalid level (must be %d-%d)', MIN_PLAYER_LEVEL, MAX_PLAYER_LEVEL)
  end
  build.characterLevel = lvl
  build.characterLevelAutoMode = false
  if build.configTab and build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  M.get_main_output()
  return true
end

-- Basic build info
function M.get_build_info()
  if not build then return nil, 'build not initialized' end
  local info = {
    name = build.buildName,
    level = build.characterLevel,
    className = build and build.buildClassName or (build.Build and build.Build.className) or nil,
    ascendClassName = build and build.buildAscendName or (build.Build and build.Build.ascendClassName) or nil,
    treeVersion = build.targetVersion or (build.spec and build.spec.treeVersion) or nil,
  }
  return info
end

-- Update tree by delta lists
function M.update_tree_delta(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local current, err = M.get_tree()
  if not current then return nil, err end
  local set = {}
  for _, id in ipairs(current.nodes) do set[id] = true end
  if params and type(params.removeNodes) == 'table' then
    for _, id in ipairs(params.removeNodes) do set[tonumber(id)] = nil end
  end
  if params and type(params.addNodes) == 'table' then
    for _, id in ipairs(params.addNodes) do set[tonumber(id)] = true end
  end
  local nodes = {}
  for id,_ in pairs(set) do table.insert(nodes, id) end
  table.sort(nodes)
  local mastery = current.masteryEffects or {}
  local classId = params.classId or current.classId or 0
  local ascendId = params.ascendClassId or current.ascendClassId or 0
  local secId = params.secondaryAscendClassId or current.secondaryAscendClassId or 0
  local tv = params.treeVersion or current.treeVersion
  -- Bug 2c: Preserve existing hashOverrides (tattoo/node overrides loaded from build XML).
  local hashOverrides = (build.spec.hashOverrides ~= nil) and build.spec.hashOverrides or {}
  build.spec:ImportFromNodeList(tonumber(classId) or 0, tonumber(ascendId) or 0, tonumber(secId) or 0, nodes, hashOverrides, mastery, tv)
  M.get_main_output()
  return true
end


-- Calculate what-if scenario without persisting changes
-- params: { addNodes?: number[], removeNodes?: number[], masteryEffects?: {[id]=effectId}, useFullDPS?: boolean }
function M.calc_with(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end

  -- Collect nodes to temporarily add/remove (only unallocated add / allocated remove)
  local toAdd, toRemove = {}, {}
  if params and type(params.addNodes) == 'table' then
    for _, id in ipairs(params.addNodes) do
      local n = build.spec.nodes[tonumber(id)] or build.spec.nodes[tostring(id)]
      if n and not build.spec.allocNodes[n.id] then table.insert(toAdd, n) end
    end
  end
  if params and type(params.removeNodes) == 'table' then
    for _, id in ipairs(params.removeNodes) do
      local n = build.spec.nodes[tonumber(id)] or build.spec.nodes[tostring(id)]
      if n and build.spec.allocNodes[n.id] then table.insert(toRemove, n) end
    end
  end

  -- Handle mastery effects by temporarily patching node modLists
  -- (calcs.initEnv reads allocNode.modList directly; it does not handle override.masteryEffects)
  if params and type(params.masteryEffects) == 'table' and not params.addNodes and not params.removeNodes then
    local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
    local spec = build.spec
    local tree = spec and spec.tree
    -- Patch each affected mastery node
    local savedState = {}
    for k, v in pairs(params.masteryEffects) do
      local nodeId   = tonumber(k)
      local effectId = tonumber(v)
      if nodeId and effectId then
        local node   = spec.allocNodes and spec.allocNodes[nodeId]
        local effect = tree and tree.masteryEffects and tree.masteryEffects[effectId]
        if node and effect then
          savedState[nodeId] = { sd = node.sd, modList = node.modList }
          node.sd = effect.sd
          tree:ProcessStats(node)  -- rebuilds node.modList from new sd
        end
      end
    end
    local savedViewMode = build.viewMode
    build.viewMode = "CALCULATOR"
    local out = calcFunc({}, false)
    build.viewMode = savedViewMode
    -- Restore patched nodes
    for nodeId, saved in pairs(savedState) do
      local node = spec.allocNodes and spec.allocNodes[nodeId]
      if node then
        node.sd      = saved.sd
        node.modList = saved.modList
      end
    end
    return out, baseOut
  end

  -- No node changes: return base calc directly (no simulation needed)
  if #toAdd == 0 and #toRemove == 0 then
    local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
    return baseOut, baseOut
  end

  local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  local override = {}
  if #toAdd > 0 then
    override.addNodes = {}
    for _, n in ipairs(toAdd) do override.addNodes[n] = true end
  end
  if #toRemove > 0 then
    override.removeNodes = {}
    for _, n in ipairs(toRemove) do override.removeNodes[n] = true end
  end
  if params and type(params.masteryEffects) == 'table' then
    override.masteryEffects = params.masteryEffects
  end

  -- Bypass calcFullDPS which runs unconditionally when viewMode=="TREE",
  -- making each call 30+ seconds. calcs.perform correctly sets CombinedDPS.
  local savedViewMode = build.viewMode
  build.viewMode = "CALCULATOR"
  local out = calcFunc(override, false)
  build.viewMode = savedViewMode
  return out, baseOut
end


-- Get basic config values
function M.get_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local cfg = {
    bandit = build.configTab.input and build.configTab.input.bandit or build.bandit,
    pantheonMajorGod = build.configTab.input and build.configTab.input.pantheonMajorGod or build.pantheonMajorGod,
    pantheonMinorGod = build.configTab.input and build.configTab.input.pantheonMinorGod or build.pantheonMinorGod,
    enemyLevel = build.configTab.enemyLevel,
  }
  return cfg
end

-- Set selected config values and rebuild
function M.set_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local input = build.configTab.input or {}
  build.configTab.input = input
  local changed = false
  if params.bandit ~= nil then input.bandit = tostring(params.bandit); changed = true end
  if params.pantheonMajorGod ~= nil then input.pantheonMajorGod = tostring(params.pantheonMajorGod); changed = true end
  if params.pantheonMinorGod ~= nil then input.pantheonMinorGod = tostring(params.pantheonMinorGod); changed = true end
  if params.enemyLevel ~= nil then build.configTab.enemyLevel = tonumber(params.enemyLevel) or build.configTab.enemyLevel; changed = true end
  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end
  M.get_main_output()
  return true
end


-- Skills API
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  local groups = {}
  for idx, g in ipairs(build.skillsTab.socketGroupList or {}) do
    local names = {}
    if g.displaySkillList then
      for _, eff in ipairs(g.displaySkillList) do
        if eff and eff.activeEffect and eff.activeEffect.grantedEffect then
          table.insert(names, eff.activeEffect.grantedEffect.name)
        end
      end
    end
    table.insert(groups, {
      index = idx,
      label = g.label,
      slot = g.slot,
      enabled = g.enabled,
      includeInFullDPS = g.includeInFullDPS,
      mainActiveSkill = g.mainActiveSkill,
      skills = names,
    })
  end
  local result = {
    mainSocketGroup = build.mainSocketGroup,
    calcsSkillNumber = build.calcsTab.input and build.calcsTab.input.skill_number or nil,
    groups = groups,
  }
  return result
end

function M.set_main_selection(params)
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.mainSocketGroup ~= nil then
    build.mainSocketGroup = tonumber(params.mainSocketGroup) or build.mainSocketGroup
  end
  local g = build.skillsTab.socketGroupList[build.mainSocketGroup]
  if not g then return nil, 'invalid mainSocketGroup' end
  if params.mainActiveSkill ~= nil then
    g.mainActiveSkill = tonumber(params.mainActiveSkill) or g.mainActiveSkill
  end
  if params.skillPart ~= nil then
    local idx = g.mainActiveSkill or 1
    local src = g.displaySkillList and g.displaySkillList[idx] and g.displaySkillList[idx].activeEffect and g.displaySkillList[idx].activeEffect.srcInstance
    if src then src.skillPart = tonumber(params.skillPart) end
  end
  -- Keep calcsTab in sync: use active group index
  build.calcsTab.input.skill_number = build.mainSocketGroup
  M.get_main_output()
  return true
end

-- Items API
function M.add_item_text(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.text) ~= 'string' then return nil, 'missing text' end

  -- Validate input to prevent potential issues
  if #params.text == 0 then return nil, 'item text cannot be empty' end
  if #params.text > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  -- Use pcall to safely handle item creation
  local ok, item = pcall(new, 'Item', params.text)
  if not ok then return nil, 'invalid item text: ' .. tostring(item) end
  if not item or not item.baseName then return nil, 'failed to parse item' end

  item:NormaliseQuality()
  -- Bug 4: When slotName is provided, force noAutoEquip so AddItem does not auto-equip
  -- to a different slot (e.g. Flask 5 instead of Flask 4). We will explicitly set the
  -- target slot below.
  local noAutoEquip = params.noAutoEquip == true or (params.slotName ~= nil)
  build.itemsTab:AddItem(item, noAutoEquip)
  if params.slotName then
    local slot = tostring(params.slotName)
    if build.itemsTab.slots[slot] then
      build.itemsTab.slots[slot]:SetSelItemId(item.id)
      build.itemsTab:PopulateSlots()
    end
  end
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return { id = item.id, name = item.name, slot = params.slotName or item:GetPrimarySlot() }
end

-- Clear (unequip) an item from a specific slot
-- params: { slotName: string }
function M.clear_item_slot(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.slotName) ~= 'string' then return nil, 'slotName required' end
  local slot = build.itemsTab.slots[params.slotName]
  if not slot then return nil, 'slot not found: ' .. params.slotName end
  slot:SetSelItemId(0)
  build.itemsTab:PopulateSlots()
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return { slot = params.slotName, cleared = true }
end

function M.set_flask_active(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local idx = tonumber(params.index)
  local active = params.active == true
  if not idx or idx < 1 or idx > NUM_FLASK_SLOTS then
    return nil, string.format('invalid flask index (must be 1-%d)', NUM_FLASK_SLOTS)
  end
  local slotName = 'Flask ' .. tostring(idx)
  if not build.itemsTab.activeItemSet or not build.itemsTab.activeItemSet[slotName] then return nil, 'slot not found' end
  build.itemsTab.activeItemSet[slotName].active = active
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return true
end


-- Get equipped items summary
function M.get_items()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = { }
  -- Prefer orderedSlots for deterministic order
  local ordered = itemsTab.orderedSlots or {}
  local seen = {}
  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    local entry = { slot = slotName, id = selId }
    if selId > 0 then
      local it = itemsTab.items[selId]
      if it then
        entry.name = it.name
        entry.baseName = it.baseName
        entry.type = it.type
        entry.rarity = it.rarity
        entry.raw = it.raw
      end
    end
    -- Flask/Tincture activation flag stored in activeItemSet
    local set = itemsTab.activeItemSet
    if set and set[slotName] and set[slotName].active ~= nil then
      entry.active = set[slotName].active and true or false
    end
    table.insert(result, entry)
  end
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Add any remaining slots not in ordered list
  for slotName, _ in pairs(itemsTab.slots or {}) do add_slot(slotName) end
  return result
end


-- Skill/Gem Creation and Modification API

-- Create a new socket group
-- params: { label?: string, slot?: string, enabled?: boolean, includeInFullDPS?: boolean }
function M.create_socket_group(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then params = {} end

  local socketGroup = {
    label = params.label or '',
    slot = params.slot,
    enabled = params.enabled ~= false,
    includeInFullDPS = params.includeInFullDPS == true,
    gemList = {},
    mainActiveSkill = 1,
    mainActiveSkillCalcs = 1,
  }

  -- Get the active skill set
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  -- Add to socket group list
  table.insert(skillSet.socketGroupList, socketGroup)
  local index = #skillSet.socketGroupList

  -- Process the socket group
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { index = index, label = socketGroup.label }
end

-- Add a gem to a socket group
-- params: { groupIndex: number, gemName: string, level?: number, quality?: number, qualityId?: string, enabled?: boolean }
function M.add_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemName then return nil, 'missing groupIndex or gemName' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found at index ' .. tostring(groupIndex) end

  -- Create gem instance
  local gemInstance = {
    nameSpec = tostring(params.gemName),
    level = tonumber(params.level) or 20,
    quality = tonumber(params.quality) or 0,
    qualityId = params.qualityId or 'Default',
    enabled = params.enabled ~= false,
    enableGlobal1 = true,
    enableGlobal2 = false,
    count = tonumber(params.count) or 1,
  }

  -- Try to find gem data
  if build.data and build.data.gems then
    for _, gemData in pairs(build.data.gems) do
      if gemData.name == gemInstance.nameSpec or gemData.nameSpec == gemInstance.nameSpec then
        gemInstance.gemId = gemData.id
        if gemData.grantedEffect then
          gemInstance.skillId = gemData.grantedEffect.id
        elseif gemData.grantedEffectId then
          gemInstance.skillId = gemData.grantedEffectId
        end
        gemInstance.gemData = gemData
        break
      end
    end
  end

  table.insert(socketGroup.gemList, gemInstance)
  local gemIndex = #socketGroup.gemList

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { gemIndex = gemIndex, name = gemInstance.nameSpec }
end

-- Set gem level
-- params: { groupIndex: number, gemIndex: number, level: number }
function M.set_gem_level(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.level then
    return nil, 'missing groupIndex, gemIndex, or level'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local level = tonumber(params.level)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if level < 1 or level > 40 then return nil, 'invalid level (must be 1-40)' end

  gemInstance.level = level

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Set gem quality
-- params: { groupIndex: number, gemIndex: number, quality: number, qualityId?: string }
function M.set_gem_quality(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.quality then
    return nil, 'missing groupIndex, gemIndex, or quality'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local quality = tonumber(params.quality)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if quality < 0 or quality > 23 then return nil, 'invalid quality (must be 0-23)' end

  gemInstance.quality = quality
  if params.qualityId then
    gemInstance.qualityId = tostring(params.qualityId)
  end

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a socket group
-- params: { groupIndex: number }
function M.remove_skill(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex then return nil, 'missing groupIndex' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  -- Don't allow removing special groups with sources
  if socketGroup.source then
    return nil, 'cannot remove special socket groups (item/node granted skills)'
  end

  table.remove(skillSet.socketGroupList, groupIndex)

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a gem from a socket group
-- params: { groupIndex: number, gemIndex: number }
function M.remove_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex then
    return nil, 'missing groupIndex or gemIndex'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  table.remove(socketGroup.gemList, gemIndex)

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end


-- Search for passive tree nodes by keyword
-- params: { keyword: string, nodeType?: string ('normal'|'notable'|'keystone'), maxResults?: number, includeAllocated?: boolean }
-- Return the current state of a single passive node, including any stat
-- transformations applied by socketed Timeless Jewels (Lethal Pride, etc.).
-- PoB computes these in PassiveSpec:BuildAllDependsAndPathsFor — by the time
-- we read node.sd here, it already reflects the transformed text.
--
-- Returns a flat structure:
--   { id, dn, type, allocated, sd, conqueredBy = {seed, conqueror_type} | nil }
--
-- dn is the (possibly transformed) display name. sd is the array of
-- (possibly transformed) stat description lines. conqueredBy is set only when
-- the node is being transformed by a Timeless Jewel; it indicates which one.
function M.get_node_state(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' then return nil, 'missing params' end
  local nodeId = params.node_id or params.nodeId
  if not nodeId then return nil, 'missing node_id' end
  -- node IDs may arrive as strings; PoB indexes by numeric ID
  local idNum = tonumber(nodeId)
  if not idNum then return nil, 'node_id must be numeric' end

  local node = build.spec.nodes and build.spec.nodes[idNum]
  if not node then return nil, 'node not found: ' .. tostring(nodeId) end

  local allocated = build.spec.allocNodes and build.spec.allocNodes[idNum] ~= nil

  local nType = 'normal'
  if node.isKeystone then nType = 'keystone'
  elseif node.isNotable then nType = 'notable'
  elseif node.isJewelSocket then nType = 'jewel'
  elseif node.isMultipleChoiceOption then nType = 'mastery'
  elseif node.ascendancyName then nType = 'ascendancy'
  end

  -- Copy stat descriptions defensively; PoB may reuse the underlying table.
  local sd = {}
  if type(node.sd) == 'table' then
    for i, line in ipairs(node.sd) do sd[i] = line end
  end

  local conqueredBy = nil
  if node.conqueredBy then
    local cq = node.conqueredBy
    conqueredBy = {
      seed = cq.id,
      conqueror_type = cq.conqueror and cq.conqueror.type or nil,
    }
  end

  return {
    id = idNum,
    dn = node.dn or node.name,
    type = nType,
    allocated = allocated,
    sd = sd,
    conqueredBy = conqueredBy,
    ascendancyName = node.ascendancyName,
  }
end

-- Tabulate the modifiers contributing to a given stat, with source
-- attribution. Uses the live calc env's player (or minion) modDB and
-- ModStore:Tabulate to enumerate each contributing modifier's value, type
-- (BASE/INC/MORE/OVERRIDE/FLAG), and source ("Tree:nodeId", item name, etc).
--
-- Accuracy note: a nil config is used, so only UNCONDITIONAL modifiers are
-- captured. This is complete for defensive/attribute stats (Life, resists,
-- Strength, Armour, EnergyShield, regen, etc.) but INCOMPLETE for damage and
-- other skill-conditional stats, where mods depend on the active skill's
-- config. The caller is told this so it can scope expectations.
function M.get_stat_breakdown(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  if type(params) ~= 'table' then return nil, 'missing params' end
  local statName = params.stat or params.name
  if type(statName) ~= 'string' or statName == '' then
    return nil, 'missing stat name'
  end

  if build.calcsTab.BuildOutput then
    pcall(build.calcsTab.BuildOutput, build.calcsTab)
  end
  local env = build.calcsTab.mainEnv
  if not env then return nil, 'no calc env available' end

  local actorName = (params.actor == 'minion') and 'minion' or 'player'
  local actor = env[actorName]
  if not actor or not actor.modDB then
    return nil, 'no modDB for actor ' .. actorName
  end
  local modDB = actor.modDB

  local contributions = {}
  local modTypes = { 'BASE', 'INC', 'MORE', 'OVERRIDE', 'FLAG' }
  for _, modType in ipairs(modTypes) do
    local ok, tab = pcall(function() return modDB:Tabulate(modType, nil, statName) end)
    if ok and type(tab) == 'table' then
      for _, entry in ipairs(tab) do
        local mod = entry.mod
        local v = entry.value
        -- Keep only JSON-safe scalar values; skip table-valued (LIST) mods.
        local vt = type(v)
        if vt == 'number' or vt == 'boolean' or vt == 'string' then
          table.insert(contributions, {
            modType = modType,
            value = v,
            source = (mod and mod.source) or '?',
            name = (mod and mod.name) or statName,
            flags = (mod and mod.flags) or 0,
          })
        end
      end
    end
  end

  local output = build.calcsTab.mainOutput
  local outVal = nil
  if output and type(output[statName]) ~= 'nil' then
    outVal = output[statName]
  end

  return {
    stat = statName,
    actor = actorName,
    output_value = outVal,
    contributions = contributions,
  }
end

function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword = params.keyword:lower()
  local nodeType = params.nodeType and params.nodeType:lower() or nil
  if nodeType == "any" or nodeType == "" then nodeType = nil end
  local maxResults = tonumber(params.maxResults) or 50
  local includeAllocated = params.includeAllocated ~= false

  local results = {}
  local count = 0

  -- Get allocated nodes set for quick lookup
  local allocatedSet = {}
  if build.spec.allocNodes then
    for id, _ in pairs(build.spec.allocNodes) do
      allocatedSet[id] = true
    end
  end

  -- Search through all nodes
  for id, node in pairs(build.spec.nodes) do
    if count >= maxResults then break end

    -- Skip if already allocated and we don't want allocated nodes
    if not includeAllocated and allocatedSet[id] then
      goto continue
    end

    -- Filter by node type if specified
    if nodeType then
      local nType = 'normal'
      if node.isKeystone then nType = 'keystone'
      elseif node.isNotable then nType = 'notable'
      elseif node.isJewelSocket then nType = 'jewel'
      elseif node.isMultipleChoiceOption then nType = 'mastery'
      elseif node.ascendancyName then nType = 'ascendancy'
      end
      if nType ~= nodeType then goto continue end
    end

    -- Check if keyword matches name
    local matches = false
    if node.name and node.name:lower():find(keyword, 1, true) then
      matches = true
    end

    -- Check if keyword matches stats/modifiers
    if not matches and node.sd then
      for _, stat in ipairs(node.sd) do
        if type(stat) == 'string' and stat:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    -- Check modifiers list
    if not matches and node.modList then
      for _, mod in ipairs(node.modList) do
        local modStr = tostring(mod)
        if modStr:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    if matches then
      local nodeType = 'normal'
      if node.isKeystone then nodeType = 'keystone'
      elseif node.isNotable then nodeType = 'notable'
      elseif node.isJewelSocket then nodeType = 'jewel'
      elseif node.isMultipleChoiceOption then nodeType = 'mastery'
      elseif node.ascendancyName then nodeType = 'ascendancy'
      end

      local stats = {}
      if node.sd then
        for _, stat in ipairs(node.sd) do
          if type(stat) == 'string' then
            table.insert(stats, stat)
          end
        end
      end

      table.insert(results, {
        id = id,
        name = node.name or 'Unnamed',
        type = nodeType,
        stats = stats,
        allocated = allocatedSet[id] == true,
        x = node.x,
        y = node.y,
        orbit = node.orbit,
        orbitIndex = node.orbitIndex,
        ascendancyName = node.ascendancyName,
      })
      count = count + 1
    end

    ::continue::
  end

  -- Sort results: keystones first, then notables, then normal
  table.sort(results, function(a, b)
    local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, ascendancy = 5, normal = 6 }
    local aOrder = typeOrder[a.type] or 99
    local bOrder = typeOrder[b.type] or 99
    if aOrder ~= bOrder then
      return aOrder < bOrder
    end
    return (a.name or '') < (b.name or '')
  end)

  return { nodes = results, count = #results }
end


-- ============================================================
-- Spec (passive tree spec) management
-- ============================================================

local function spec_info(spec, index, activeIndex)
  return {
    index = index,
    title = spec.title or ('Spec ' .. tostring(index)),
    className = spec.curClassName or 'Unknown',
    ascendClassName = spec.curAscendClassName or 'None',
    nodeCount = spec.allocNodes and (function() local n=0; for _ in pairs(spec.allocNodes) do n=n+1 end; return n end)() or 0,
    treeVersion = spec.treeVersion,
    active = (index == activeIndex),
  }
end

local function get_spec_list()
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  local activeIdx = tt.activeSpec or 1
  local result = {}
  for i, spec in ipairs(specs) do
    table.insert(result, spec_info(spec, i, activeIdx))
  end
  return { specs = result, activeSpec = activeIdx }
end

function M.list_specs()
  return get_spec_list()
end

function M.select_spec(index)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  tt.activeSpec = index
  build.spec = specs[index]
  M.get_main_output()
  return get_spec_list()
end

function M.create_spec(params)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  -- Clone from an existing spec or create empty
  local newSpec
  if params and params.copyFrom and specs[params.copyFrom] then
    -- Deep copy the source spec's nodes/masteries; reuse same spec object structure
    local src = specs[params.copyFrom]
    newSpec = { treeVersion = src.treeVersion, curClassId = src.curClassId, curAscendClassId = src.curAscendClassId,
                curClassName = src.curClassName, curAscendClassName = src.curAscendClassName,
                allocNodes = {}, masterySelections = {}, title = params.title or (src.title .. ' (copy)') }
    for id, v in pairs(src.allocNodes or {}) do newSpec.allocNodes[id] = v end
    for id, v in pairs(src.masterySelections or {}) do newSpec.masterySelections[id] = v end
  else
    newSpec = { treeVersion = latestTreeVersion, curClassId = 0, curAscendClassId = 0,
                curClassName = 'Scion', curAscendClassName = 'None',
                allocNodes = {}, masterySelections = {}, title = params and params.title or ('Spec ' .. tostring(#specs + 1)) }
  end
  table.insert(specs, newSpec)
  tt.specList = specs
  local newIdx = #specs
  if params and params.activate then
    tt.activeSpec = newIdx
    build.spec = newSpec
    M.get_main_output()
  end
  return get_spec_list()
end

function M.delete_spec(index)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if #specs <= 1 then return nil, 'cannot delete the last spec' end
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  table.remove(specs, index)
  -- Adjust active spec index if needed
  if tt.activeSpec >= index and tt.activeSpec > 1 then
    tt.activeSpec = tt.activeSpec - 1
  end
  build.spec = specs[tt.activeSpec]
  M.get_main_output()
  return get_spec_list()
end

function M.rename_spec(index, title)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  specs[index].title = tostring(title)
  return get_spec_list()
end


-- ============================================================
-- Item set management
-- ============================================================

local function itemset_info(set, id, activeId)
  return {
    id = id,
    title = set.title or ('Item Set ' .. tostring(id)),
    useSecondWeaponSet = set.useSecondWeaponSet == true,
    active = (id == activeId),
  }
end

local function get_itemset_list()
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local it = build.itemsTab
  local sets = it.itemSets or {}
  local order = it.itemSetOrderList or {}
  local activeId = it.activeItemSetId or 1
  local result = {}
  for _, id in ipairs(order) do
    local set = sets[id]
    if set then
      table.insert(result, itemset_info(set, id, activeId))
    end
  end
  return { itemSets = result, activeItemSetId = activeId }
end

function M.list_item_sets()
  return get_itemset_list()
end

function M.select_item_set(id)
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local it = build.itemsTab
  local sets = it.itemSets or {}
  if not sets[id] then return nil, 'item set id not found: ' .. tostring(id) end
  if it.SetActiveItemSet then
    it:SetActiveItemSet(id)
  else
    it.activeItemSetId = id
    it.activeItemSet = sets[id]
  end
  build.buildFlag = true
  M.get_main_output()
  return get_itemset_list()
end


-- ============================================================
-- Mastery options
-- ============================================================

function M.get_mastery_options()
  if not build or not build.spec then return nil, 'build not initialized' end
  local spec = build.spec
  local result = {}
  for id, node in pairs(spec.nodes or {}) do
    if (node.m or node.isMastery) and not node.ascendancyName then
      local options = {}
      for _, effect in ipairs(node.masteryEffects or {}) do
        local eid = effect.effect  -- effect.effect is the numeric ID; effect.id is nil
        local selected = (spec.masterySelections and spec.masterySelections[node.id] == eid) == true
        table.insert(options, { effectId = eid, stats = effect.stats or {}, selected = selected })
      end
      if #options > 0 then
        table.insert(result, { nodeId = id, name = node.name or node.dn or 'Mastery', options = options })
      end
    end
  end
  return { masteries = result }
end


-- ============================================================
-- Socket group and gem enable/disable toggles
-- ============================================================

function M.set_socket_group_enabled(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or params.enabled == nil then return nil, 'missing groupIndex or enabled' end
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end
  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found at index ' .. tostring(groupIndex) end
  socketGroup.enabled = params.enabled == true
  if build.skillsTab.ProcessSocketGroup then build.skillsTab:ProcessSocketGroup(socketGroup) end
  build.buildFlag = true
  M.get_main_output()
  return { groupIndex = groupIndex, label = socketGroup.label or '', enabled = socketGroup.enabled }
end

function M.set_gem_enabled(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or params.enabled == nil then
    return nil, 'missing groupIndex, gemIndex, or enabled'
  end
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end
  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end
  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end
  gemInstance.enabled = params.enabled == true
  if build.skillsTab.ProcessSocketGroup then build.skillsTab:ProcessSocketGroup(socketGroup) end
  build.buildFlag = true
  M.get_main_output()
  return true
end


-- ============================================================
-- Anointment evaluation
-- ============================================================

function M.evaluate_anoint_candidates(params)
  if not build or not build.itemsTab or not build.calcsTab then return nil, 'build not initialized' end
  local slotName = (params and params.slot) or 'Amulet'
  local focus    = (params and params.focus) or 'both'
  local limit    = tonumber(params and params.limit) or 50

  -- Only Amulet and (Cord) Belt support anointment
  if slotName ~= 'Amulet' and slotName ~= 'Belt' then
    return nil, 'anointment is only supported for Amulet and Belt slots'
  end

  local activeItemSet = build.itemsTab.activeItemSet
  local slotEntry = activeItemSet and activeItemSet[slotName]
  local item = slotEntry and build.itemsTab.items[slotEntry.selItemId]
  if not item then
    return nil, 'no item equipped in slot: ' .. slotName
  end

  -- Save state, then point displayItem at the target item
  local savedDisplayItem   = build.itemsTab.displayItem
  local savedAnointSlot    = build.itemsTab.anointEnchantSlot
  build.itemsTab.displayItem     = item
  build.itemsTab.anointEnchantSlot = 1

  -- slotType drives the calc engine replacement slot
  local slotType = item.base and item.base.type or slotName

  local calcFunc = build.calcsTab:GetMiscCalculator()
  if not calcFunc then
    build.itemsTab.displayItem     = savedDisplayItem
    build.itemsTab.anointEnchantSlot = savedAnointSlot
    return nil, 'failed to get calc function'
  end

  -- Base stats without any anoint
  local baseCalc = calcFunc({ repSlotName = slotType, repItem = build.itemsTab:anointItem(nil) })
  local baseDPS  = baseCalc and (baseCalc.CombinedDPS or baseCalc.TotalDPS or 0) or 0
  local baseEHP  = baseCalc and (baseCalc.TotalEHP or 0) or 0

  local candidates = {}
  local evaluated  = 0
  local skipped    = 0

  for id, node in pairs(build.spec.nodes or {}) do
    -- Only anointable notables not already allocated
    if node.recipe and #node.recipe >= 1 and node.isNotable and not node.isKeystone
        and not node.ascendancyName and not build.spec.allocNodes[id] then
      local ok, output = pcall(function()
        return calcFunc({ repSlotName = slotType, repItem = build.itemsTab:anointItem(node) })
      end)
      if ok and output then
        local dps      = output.CombinedDPS or output.TotalDPS or 0
        local ehp      = output.TotalEHP or 0
        local dpsDelta = dps - baseDPS
        local ehpDelta = ehp - baseEHP
        local score
        if focus == 'dps' then
          score = baseDPS > 0 and (dpsDelta / baseDPS) or dpsDelta
        elseif focus == 'defence' then
          score = baseEHP > 0 and (ehpDelta / baseEHP) or ehpDelta
        else
          local dpsN = baseDPS > 0 and (dpsDelta / baseDPS) or 0
          local ehpN = baseEHP > 0 and (ehpDelta / baseEHP) or 0
          score = dpsN + 0.5 * ehpN
        end
        table.insert(candidates, {
          nodeId   = id,
          name     = node.dn or node.name or 'Unknown',
          dpsDelta = dpsDelta,
          ehpDelta = ehpDelta,
          score    = score,
          recipe   = node.recipe,
        })
        evaluated = evaluated + 1
      else
        skipped = skipped + 1
      end
    end
  end

  -- Restore state
  build.itemsTab.displayItem     = savedDisplayItem
  build.itemsTab.anointEnchantSlot = savedAnointSlot

  table.sort(candidates, function(a, b) return a.score > b.score end)

  local top = {}
  for i = 1, math.min(limit, #candidates) do top[i] = candidates[i] end

  return {
    candidates = top,
    base       = { CombinedDPS = baseDPS, TotalEHP = baseEHP },
    evaluated  = evaluated,
    skipped    = skipped,
    slot       = slotName,
    baseType   = item.baseName or item.name or slotName,
    focus      = focus,
  }
end


-- ============================================================
-- Weighted trade query generation (mirrors PoB's Find Upgrade)
-- ============================================================

function M.generate_weighted_trade_query(params)
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local slotName = params and params.slot
  if not slotName then return nil, 'slot is required' end

  local slot = build.itemsTab.slots[slotName]
  if not slot then return nil, 'slot not found: ' .. tostring(slotName) end

  local tradeQuery = build.itemsTab.tradeQuery
  if not tradeQuery then return nil, 'tradeQuery not initialized' end

  -- Ensure default stat weights exist
  if not tradeQuery.statSortSelectionList or #tradeQuery.statSortSelectionList == 0 then
    tradeQuery.statSortSelectionList = {
      { label = 'Full DPS',          stat = 'FullDPS',   weightMult = 1.0 },
      { label = 'Effective Hit Pool', stat = 'TotalEHP', weightMult = 0.5 },
    }
  end

  -- Build options with sensible defaults for headless use
  local options = {
    influence1       = 1,
    influence2       = 1,
    includeCorrupted = false,
    includeMirrored  = false,
    includeScourge   = false,
    includeEldritch  = false,
    includeSynthesis = false,
    statWeights      = tradeQuery.statSortSelectionList,
  }

  -- Apply any caller-supplied overrides
  if params.options and type(params.options) == 'table' then
    for k, v in pairs(params.options) do
      options[k] = v
    end
  end

  -- Instantiate a generator against the build's tradeQuery object
  local ok_gen, gen = pcall(function() return new("TradeQueryGenerator", tradeQuery) end)
  if not ok_gen or not gen then
    return nil, 'failed to create TradeQueryGenerator: ' .. tostring(gen)
  end

  -- Capture result via callback
  local capturedJson, capturedErr
  gen.requesterCallback = function(_, queryJson, errMsg)
    capturedJson = queryJson
    capturedErr  = errMsg
  end
  gen.requesterContext = nil

  -- Launch the query (creates coroutine, opens no-op GUI popup in headless)
  local ok_start, startErr = pcall(gen.StartQuery, gen, slot, options)
  if not ok_start then
    return nil, 'StartQuery failed: ' .. tostring(startErr)
  end

  -- Drive the coroutine to completion (replaces the OnFrame loop)
  if gen.calcContext and gen.calcContext.co then
    local maxIter = 200000
    local iter = 0
    while coroutine.status(gen.calcContext.co) ~= 'dead' and iter < maxIter do
      local ok_resume, resumeErr = coroutine.resume(gen.calcContext.co, gen)
      if not ok_resume then
        return nil, 'coroutine error: ' .. tostring(resumeErr)
      end
      iter = iter + 1
    end
    -- FinishQuery builds the trade JSON and fires the callback
    local ok_finish, finishErr = pcall(gen.FinishQuery, gen)
    if not ok_finish then
      return nil, 'FinishQuery failed: ' .. tostring(finishErr)
    end
  end

  if not capturedJson then
    return nil, capturedErr or 'no query generated'
  end

  return { query = capturedJson, warning = capturedErr }
end

function M.get_notes()
  if not build or not build.notesTab then return nil, 'build/notesTab not initialized' end
  return { notes = build.notesTab.controls.edit.buf or '' }
end

function M.set_notes(params)
  if not build or not build.notesTab then return nil, 'build/notesTab not initialized' end
  local text = (type(params) == 'table' and type(params.text) == 'string') and params.text or ''
  if build.notesTab.controls.edit.SetText then
    build.notesTab.controls.edit:SetText(text)
  else
    build.notesTab.controls.edit.buf = text
  end
  build.notesTab.modFlag = true
  build.modFlag = true
  return { ok = true }
end

return M
