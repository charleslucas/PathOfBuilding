-- api-stdio fork: headless entry point for current LuaJIT.
-- PoB's launcher files open with a `#@` line that PoB's own runtime skips.
-- LuaJIT since c41d727d (Oct 2026) parses a leading `#` as a line-number
-- directive and skips only `#!`, so `luajit HeadlessWrapper.lua` fails with
-- "unexpected symbol near '#'". This shim turns that header into a comment
-- (keeping the line count) for every file loaded via loadfile/dofile.
-- Usage: luajit HeadlessBoot.lua [--stdio]   (same args as HeadlessWrapper.lua)
local rawLoadfile, rawDofile = loadfile, dofile
function loadfile(path, ...)
  if path == nil then return rawLoadfile() end
  local file = io.open(path, 'rb')
  if not file then return nil, 'cannot open ' .. path end
  local source = file:read('*a')
  file:close()
  return loadstring((source:gsub('^#', '--', 1)), '@' .. path)
end
function dofile(path)
  if path == nil then return rawDofile() end
  return assert(loadfile(path))()
end
return dofile('HeadlessWrapper.lua')
