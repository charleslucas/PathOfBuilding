-- Standalone test for BuildOps loadout matching. Run from the PathOfBuilding root:
--   luajit src/API/tests/loadouts_test.lua
-- Uses a stub `build`; no PoB runtime needed.

local M = assert(loadfile('src/API/BuildOps.lua'))()

local function family(titles)
  local sets, order = {}, {}
  for i, title in ipairs(titles) do sets[i] = { title = title }; order[i] = i end
  return sets, order
end

local function make_build(trees, items, skills, configs)
  local calls = {}
  local specList = {}
  for i, title in ipairs(trees) do specList[i] = { title = title } end
  local itemSets, itemOrder = family(items)
  local skillSets, skillOrder = family(skills)
  local configSets, configOrder = family(configs)
  local b = {
    treeTab = { specList = specList, activeSpec = 1 },
    itemsTab = { itemSets = itemSets, itemSetOrderList = itemOrder, activeItemSetId = 1 },
    skillsTab = { skillSets = skillSets, skillSetOrderList = skillOrder, activeSkillSetId = 1 },
    configTab = { configSets = configSets, configSetOrderList = configOrder, activeConfigSetId = 1 },
  }
  function b.treeTab:SetActiveSpec(id) table.insert(calls, 'tree ' .. id); self.activeSpec = id end
  function b.itemsTab:SetActiveItemSet(id) table.insert(calls, 'item ' .. id); self.activeItemSetId = id end
  function b.skillsTab:SetActiveSkillSet(id) table.insert(calls, 'skill ' .. id); self.activeSkillSetId = id end
  function b.configTab:SetActiveConfigSet(id) table.insert(calls, 'config ' .. id); self.activeConfigSetId = id end
  return b, calls
end

local failures = 0
local function check(label, cond)
  if cond then print('ok   ' .. label) else failures = failures + 1; print('FAIL ' .. label) end
end

-- Linked loadouts, selected by plain name, switch every linked family.
do
  local b, calls = make_build(
    { 'Leveling', 'Mapping {1}', 'Bossing {2}' },
    { 'Leveling', 'Mapping {1}', 'Bossing {2}' },
    { 'Leveling', 'Mapping gems {1}', 'Bossing gems {2}' },
    { 'Default' })
  build = b
  local list = M.list_loadouts()
  check('three rows', #list.loadouts == 3)
  check('all complete', list.loadouts[1].complete and list.loadouts[2].complete and list.loadouts[3].complete)
  check('linked title kept', list.loadouts[2].title == 'Mapping {1}' and list.loadouts[2].name == 'Mapping')
  check('Leveling active at start', list.loadouts[1].active)

  local res, err = M.select_loadout({ name = 'mapping' })
  check('select by plain name works: ' .. tostring(err), res ~= nil)
  check('switched tree, items, skills (config is a wildcard)',
    table.concat(calls, ',') == 'tree 2,item 2,skill 2')
  check('selected report complete', res and res.selected.complete and res.selected.title == 'Mapping {1}')
  check('Mapping now active', res and res.loadouts[2].active and not res.loadouts[1].active)
end

-- A tree linked to two groups gives one row per link, and the bare name is ambiguous.
do
  local b = make_build({ 'Both {1,2}' }, { 'A {1}', 'B {2}' }, { 'Default' }, { 'Default' })
  build = b
  local list = M.list_loadouts()
  check('one row per link', #list.loadouts == 2 and list.loadouts[1].title == 'Both {1}'
    and list.loadouts[2].title == 'Both {2}')
  check('row 2 matches item set B', list.loadouts[2].itemSet.id == 2)
  local res, err = M.select_loadout({ name = 'Both' })
  check('bare name is ambiguous', res == nil and err:find('ambiguous') ~= nil)
  res = M.select_loadout({ name = 'Both {2}' })
  check('full title selects', res ~= nil and b.itemsTab.activeItemSetId == 2)
end

-- An incomplete loadout is refused unless allowPartial is passed.
do
  local b, calls = make_build({ 'Main', 'Orphan' }, { 'Main', 'Other' }, { 'Default' }, { 'Default' })
  build = b
  local res, err = M.select_loadout({ name = 'Orphan' })
  check('incomplete refused', res == nil and err:find('item set') ~= nil)
  check('nothing switched', #calls == 0 and b.treeTab.activeSpec == 1)
  res = M.select_loadout({ name = 'Orphan', allowPartial = true })
  check('allowPartial switches the tree only', res ~= nil and b.treeTab.activeSpec == 2
    and b.itemsTab.activeItemSetId == 1)
  check('missing reported', res and res.selected.missing[1] == 'item set')
end

-- Unknown names list what is available; index selection works.
do
  local b = make_build({ 'Main', 'Alt' }, { 'Main', 'Alt' }, { 'Default' }, { 'Default' })
  build = b
  local res, err = M.select_loadout({ name = 'Nope' })
  check('unknown name lists titles', res == nil and err:find('Main, Alt') ~= nil)
  res = M.select_loadout({ index = 2 })
  check('select by index', res ~= nil and b.treeTab.activeSpec == 2 and b.itemsTab.activeItemSetId == 2)
end

-- select_spec goes through SetActiveSpec (which re-sockets jewels in PoB).
do
  local b, calls = make_build({ 'One', 'Two' }, { 'Default' }, { 'Default' }, { 'Default' })
  build = b
  M.select_spec(2)
  check('select_spec uses SetActiveSpec', calls[1] == 'tree 2' and b.treeTab.activeSpec == 2)
end

-- Colour codes are stripped for names; set matching is exact like PoB's (case-sensitive).
do
  local b = make_build({ '^4Early Maps', '^3^2End Game' }, { '^4Early Maps', '^3^2End Game', 'end game' },
    { '^4Early Maps', '^3^2End Game' }, { 'Default' })
  build = b
  local list = M.list_loadouts()
  check('colour codes stripped from titles', list.loadouts[1].title == 'Early Maps'
    and list.loadouts[2].itemSet.title == 'End Game')
  check('case-different set not matched', list.loadouts[2].itemSet.id == 2)
  local res = M.select_loadout({ name = 'end game' })
  check('user input matches without colour codes', res ~= nil and b.treeTab.activeSpec == 2
    and b.itemsTab.activeItemSetId == 2 and b.skillsTab.activeSkillSetId == 2)
end

-- Set creation. copyTable is PoB's (Modules/Common.lua); the stubs mirror NewSkillSet / NewConfigSet.
function copyTable(tbl, noRecurse)
  local out = {}
  for k, v in pairs(tbl) do
    if not noRecurse and type(v) == 'table' then out[k] = copyTable(v) else out[k] = v end
  end
  return out
end

local function add_set_creation(b)
  function b.skillsTab:NewSkillSet(id) local s = { id = id, socketGroupList = {} }; self.skillSets[id] = s; return s end
  function b.configTab:NewConfigSet(id)
    local s = { id = id, input = {}, placeholder = {}, customModsList = { { title = 'Default', enabled = true, text = '' } } }
    self.configSets[id] = s
    return s
  end
  function b:SyncLoadouts() end
end

do
  local b = make_build({ 'Main' }, { 'Main' }, { 'Main' }, { 'Main' })
  add_set_creation(b)
  build = b
  b.skillsTab.skillSets[1].socketGroupList = { { label = 'SRS', gemList = { { nameSpec = 'Summon Raging Spirit', level = 20 } } } }
  b.configTab.configSets[1].input = { enemyIsBoss = 'Pinnacle' }
  b.configTab.configSets[1].customModsList = { { title = 'Default', enabled = true, text = '+1 to Level of all Gems' } }

  local res = M.create_skill_set({ title = 'Copy', copyFrom = 1 })
  check('skill set created', res ~= nil and b.skillsTab.skillSets[2] and b.skillsTab.skillSetOrderList[2] == 2)
  local copied = b.skillsTab.skillSets[2].socketGroupList[1].gemList[1]
  copied.level = 1
  check('gem copy is independent', b.skillsTab.skillSets[1].socketGroupList[1].gemList[1].level == 20)

  M.create_config_set({ title = 'Copy', copyFrom = 1 })
  local cfg = b.configTab.configSets[2]
  check('config input copied', cfg.input.enemyIsBoss == 'Pinnacle')
  cfg.customModsList[1].text = 'changed'
  check('custom mods copy is independent', b.configTab.configSets[1].customModsList[1].text == '+1 to Level of all Gems')

  local _, err = M.create_skill_set({ copyFrom = 99 })
  check('unknown copyFrom refused', err and err:find('99') ~= nil)
end

-- create_loadout reuses families that already have the title and creates the rest.
do
  local b = make_build({ 'Main', 'Bossing' }, { 'Main', 'Bossing' }, { 'Main', 'Leveling' }, { 'Main', 'Leveling' })
  add_set_creation(b)
  build = b
  local res, err = M.create_loadout({ title = '  Bossing ', copyFrom = { skills = 1, config = 1 } })
  check('create_loadout succeeds: ' .. tostring(err), res ~= nil)
  check('tree and items reused, not duplicated', #b.treeTab.specList == 2 and #b.itemsTab.itemSetOrderList == 2)
  check('skill and config sets created with the title', b.skillsTab.skillSets[3].title == 'Bossing'
    and b.configTab.configSets[3].title == 'Bossing')
  check('created reported', res and res.created.skills and res.created.config and not res.created.items)
  check('new loadout is complete and active', res and res.selected and res.selected.complete
    and b.treeTab.activeSpec == 2 and b.skillsTab.activeSkillSetId == 3 and b.configTab.activeConfigSetId == 3)
  local _, err2 = M.create_loadout({ title = '   ' })
  check('blank title refused', err2 == 'title required')
end

-- A family with a single set is a wildcard shared by every loadout; creating a
-- loadout must not add a second set there (that would orphan the other loadouts).
do
  local b = make_build({ 'Main', 'Bossing' }, { 'Main', 'Bossing' }, { 'Default' }, { 'Default' })
  add_set_creation(b)
  build = b
  local res, err = M.create_loadout({ title = 'Bossing' })
  check('wildcard create succeeds: ' .. tostring(err), res ~= nil)
  check('single-set families stay single', #b.skillsTab.skillSetOrderList == 1 and #b.configTab.configSetOrderList == 1)
  check('shared reported', res and res.shared.skills and res.shared.config)
  local list = M.list_loadouts()
  check('existing loadout still complete', list.loadouts[1].complete)
end

print(failures == 0 and 'ALL PASSED' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
