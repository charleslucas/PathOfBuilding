-- Standalone test for import_items_skills keeping Wickerman (Viscera) items that the
-- legacy get-items response does not carry. Run from the PathOfBuilding root:
--   luajit src/API/tests/import_wickerman_test.lua
-- Stubs `build` and BuildOps; no PoB runtime needed.

package.path = 'runtime/lua/?.lua;src/?.lua;' .. package.path
package.preload['API.BuildOps'] = function() return { get_main_output = function() end } end
local handlers = assert(loadfile('src/API/Handlers.lua'))().handlers

local failures = 0
local function check(label, cond)
  if cond then print('ok   ' .. label) else failures = failures + 1; print('FAIL ' .. label) end
end

-- itemsTab stub: slots with selItemId; ImportItemsAndSkills mimics PoB's clear pass
-- (deletes every equipped item) and equips whatever the response carries.
local function make_build(opts)
  local items, slots = {}, {}
  local nextId = 1
  local function addItem(slotName, name)
    local id = nextId; nextId = nextId + 1
    items[id] = { id = id, name = name }
    slots[slotName].selItemId = id
    return id
  end
  for _, n in ipairs({ 'Helmet', 'Head', 'Body', 'Arm', 'Leg' }) do
    slots[n] = { selItemId = 0, SetSelItemId = function(self, id) self.selItemId = id end }
  end
  local itemsTab = { items = items, slots = slots, populated = 0 }
  function itemsTab:PopulateSlots() self.populated = self.populated + 1 end
  local seen = {}
  local importTab = {}
  function importTab:ImportItemsAndSkills(charData, clearItems)
    seen.charData = charData
    if clearItems then
      for _, slot in pairs(slots) do
        if slot.selItemId ~= 0 then items[slot.selItemId] = nil; slot.selItemId = 0 end
      end
    end
    local map = { Helm = 'Helmet', VisceraHead = 'Head', VisceraBody = 'Body', VisceraArm = 'Arm', VisceraLeg = 'Leg' }
    local all = {}
    for _, it in ipairs(charData.equipment or {}) do all[#all + 1] = it end
    for _, it in ipairs(charData.wickerman or {}) do all[#all + 1] = it end
    for _, it in ipairs(all) do
      if map[it.inventoryId] then addItem(map[it.inventoryId], it.typeLine) end
    end
    if opts and opts.throw then error('boom') end
    return { level = 90 }
  end
  build = { itemsTab = itemsTab, importTab = importTab, controls = {} }
  importTab.controls = {}
  return addItem, items, slots, seen, itemsTab
end

local function json(t)
  return require('dkjson').encode(t)
end

-- 1. Legacy response with no Viscera: equipped Viscera survive, gear is replaced.
do
  local addItem, items, slots = make_build()
  addItem('Helmet', 'Old Helm')
  local head = addItem('Head', 'Greater Justicar\'s Helm')
  local leg = addItem('Leg', 'Prosthetic Leg')
  local res = handlers.import_items_skills({
    json = json({ character = { level = 90 }, items = { { inventoryId = 'Helm', typeLine = 'New Helm' } } }),
  })
  check('legacy: import ok', res.ok == true)
  check('legacy: Head kept', slots.Head.selItemId == head and items[head] ~= nil)
  check('legacy: Leg kept', slots.Leg.selItemId == leg and items[leg] ~= nil)
  check('legacy: gear replaced', items[slots.Helmet.selItemId].name == 'New Helm')
  table.sort(res.keptWickerman)
  check('legacy: reports kept slots', table.concat(res.keptWickerman, ',') == 'Head,Leg')
end

-- 2. Response carries Viscera (OAuth-style wickerman array): the import owns those slots.
do
  local addItem, items, slots = make_build()
  local head = addItem('Head', 'Old Skull')
  local res = handlers.import_items_skills({
    json = json({ character = {}, items = {}, wickerman = { { inventoryId = 'VisceraHead', typeLine = 'Ravenous Skull' } } }),
  })
  check('wickerman array: old Head replaced', items[head] == nil and items[slots.Head.selItemId].name == 'Ravenous Skull')
  check('wickerman array: nothing reported kept', #res.keptWickerman == 0)
end

-- 3. Viscera inside items[] also counts as "the API sent them".
do
  local addItem, items, slots = make_build()
  local arm = addItem('Arm', 'Old Arm')
  local res = handlers.import_items_skills({
    json = json({ items = { { inventoryId = 'VisceraArm', typeLine = 'Warden\'s Arm' } } }),
  })
  check('items[] viscera: old Arm replaced', items[arm] == nil and items[slots.Arm.selItemId].name == 'Warden\'s Arm')
  check('items[] viscera: nothing reported kept', #res.keptWickerman == 0)
end

-- 4. clear_items = false: nothing is detached.
do
  local addItem, _, slots = make_build()
  local body = addItem('Body', 'Ornate Torso')
  local res = handlers.import_items_skills({ json = json({ items = {} }), clear_items = false })
  check('no clear: Body untouched', slots.Body.selItemId == body and #res.keptWickerman == 0)
end

-- 5. The import throws: the Viscera are still put back.
do
  local addItem, items, slots = make_build({ throw = true })
  local head = addItem('Head', 'Skull')
  local res = handlers.import_items_skills({ json = json({ items = {} }) })
  check('exception: error returned', res.ok == false)
  check('exception: Head reattached', slots.Head.selItemId == head and items[head] ~= nil)
end

-- 6. Guardian passes through like PoB's DownloadItems.
do
  local _, _, _, seen = make_build()
  handlers.import_items_skills({ json = json({ items = {}, guardian = { { inventoryId = 'Helm' } } }) })
  check('guardian passed through', seen.charData.guardian and #seen.charData.guardian == 1)
end

if failures > 0 then print(failures .. ' FAILED'); os.exit(1) end
print('ALL PASSED')
