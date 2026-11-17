#@
---@diagnostic disable: lowercase-global
-- This wrapper allows the program to run headless on any OS (in theory)
-- It can be run using a standard lua interpreter, although LuaJIT is preferable

-- define global SimpleGraphic API functions. some of these have dummy function
-- bodies intended for headless use.
dofile("_SimpleGraphic.def.lua")

function GetVirtualScreenSize()
	return 1920, 1080
end

-- Callbacks
__callbackTable__ = { }

function runCallback(name, ...)
	if __callbackTable__[name] then
		return __callbackTable__[name](...)
	elseif __mainObject__ and __mainObject__[name] then
		return __mainObject__[name](__mainObject__, ...)
	end
end

local l_require = require
function require(name)
	-- Hack to stop it looking for lcurl, which we don't really need
	if name == "lcurl.safe" then
		return
	end
	return l_require(name)
end


-- ===== api-stdio fork additions (charleslucas/PathOfBuilding) =====
-- Real Inflate via LuaJIT FFI + bundled zlib1.dll (upstream def stub returns "")
function Inflate(data)
	if not data or data == "" then return nil end
	local ok, ffi = pcall(require, 'ffi')
	if ok and ffi then
		local ok2, zlib = pcall(ffi.load, 'zlib1')
		if ok2 and zlib then
			pcall(function()
				ffi.cdef[[
					int uncompress(unsigned char *dest, unsigned long *destLen,
					               const unsigned char *source, unsigned long sourceLen);
				]]
			end)
			local outLen = ffi.new('unsigned long[1]', #data * 20 + 65536)
			local out = ffi.new('unsigned char[?]', outLen[0])
			local src = ffi.cast('const unsigned char*', data)
			local ret = pcall(function() return zlib.uncompress(out, outLen, src, #data) end)
			if ret then
				return ffi.string(out, outLen[0])
			end
		end
	end
	return nil
end
function GetScriptPath()
	return rawget(_G, 'POB_SCRIPT_DIR') or ""
end
function GetRuntimePath()
	return rawget(_G, 'POB_SCRIPT_DIR') or ""
end

-- Determine script directory for robust relative loading
local function get_script_dir()
  local info = debug and debug.getinfo and debug.getinfo(1, 'S')
  local src = info and info.source or ''
  if type(src) == 'string' and src:sub(1,1) == '@' then
    local path = src:sub(2)
    return (path:gsub('[^/\\]+$', '')):gsub('[ /\\]$', '')
  end
  return ''
end
local POB_SCRIPT_DIR = get_script_dir()
if POB_SCRIPT_DIR == '' then
  local f1 = io.open('HeadlessWrapper.lua', 'r')
  if f1 then f1:close(); POB_SCRIPT_DIR = '.' end
end
if POB_SCRIPT_DIR == '' then
  local f2 = io.open('src/HeadlessWrapper.lua', 'r')
  if f2 then f2:close(); POB_SCRIPT_DIR = 'src' end
end
if POB_SCRIPT_DIR ~= '' then
  _G.POB_SCRIPT_DIR = POB_SCRIPT_DIR
  package.path = table.concat({ POB_SCRIPT_DIR .. '/?.lua', POB_SCRIPT_DIR .. '/?/init.lua', package.path }, ';')
end
-- Add PoB runtime lua path so modules like 'xml' resolve without external LUA_PATH
do
  local candidates = { "../runtime/lua", "runtime/lua", "../../runtime/lua" }
  if POB_SCRIPT_DIR ~= '' then
    table.insert(candidates, 1, POB_SCRIPT_DIR .. '/../runtime/lua')
    table.insert(candidates, 1, POB_SCRIPT_DIR .. '/runtime/lua')
  end
  for _, p in ipairs(candidates) do
    local f = io.open(p .. "/xml.lua", "r")
    if f then f:close()
      if not string.find(package.path, p .. "/?.lua", 1, true) then
        package.path = p .. "/?.lua;" .. p .. "/?/init.lua;" .. package.path
      end
      break
    end
  end
end

local function has_flag(flag)
  if type(arg) ~= 'table' then return false end
  for i = 1, #arg do if arg[i] == flag then return true end end
  return false
end
local POB_STDIO_MODE = os.getenv('POB_API_STDIO') == '1' or has_flag('--stdio')
if POB_STDIO_MODE and type(_G.utf8) ~= 'table' then
  local ok_u, mod = pcall(require, 'utf8')
  if ok_u and type(mod) == 'table' then
    _G.utf8 = mod
  else
    for _, sp in ipairs({ POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/utf8.lua') or 'utf8.lua',
                          POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/lua-utf8.lua') or 'lua-utf8.lua',
                          'src/utf8.lua', 'src/lua-utf8.lua' }) do
      local ok2, stub = pcall(dofile, sp)
      if ok2 and type(stub) == 'table' then _G.utf8 = stub; break end
    end
  end
end
-- ===== end fork additions =====


dofile("Launch.lua")

-- Prevents loading of ModCache
-- Allows running mod parsing related tests without pushing ModCache
-- The CI env var will be true when run from github workflows but should be false for other tools using the headless wrapper 
__mainObject__.continuousIntegrationMode = os.getenv("CI")

runCallback("OnInit")
runCallback("OnFrame") -- Need at least one frame for everything to initialise

if __mainObject__.promptMsg and not POB_STDIO_MODE then
	-- Something went wrong during startup
	print(__mainObject__.promptMsg)
	io.read("*l")
	return
end

-- The build module; once a build is loaded, you can find all the good stuff in here
build = __mainObject__.main.modes["BUILD"]

-- Here's some helpful helper functions to help you get started
function newBuild()
	__mainObject__.main:SetMode("BUILD", false, "Help, I'm stuck in Path of Building!")
	runCallback("OnFrame")
end
function loadBuildFromXML(xmlText, name)
	__mainObject__.main:SetMode("BUILD", false, name or "", xmlText)
	runCallback("OnFrame")
end
function loadBuildFromJSON(characterJSON)
	__mainObject__.main:SetMode("BUILD", false, "")
	runCallback("OnFrame")
	-- characterJSON could, for example, be the response from the PoE API:
	-- https://www.pathofexile.com/developer/docs/reference#characters-get
	local dkjson = require "dkjson"
	local input = dkjson.decode(characterJSON)
	local charData = build.importTab:ImportItemsAndSkills(input)
	build.importTab:ImportPassiveTreeAndJewels(input)
	-- You now have a build without a correct main skill selected, or any configuration options set
	-- Good luck!
end

-- api-stdio fork: start the stdio JSON-RPC server (POB_API_STDIO=1 or --stdio)
if POB_STDIO_MODE then
	if __mainObject__.promptMsg then
		io.stderr:write('[HeadlessWrapper] Error during init: ' .. tostring(__mainObject__.promptMsg) .. '\n')
		error(__mainObject__.promptMsg)
	end
	_G.build = build
	dofile((POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/API/Server.lua')) or 'API/Server.lua')
	return
end
