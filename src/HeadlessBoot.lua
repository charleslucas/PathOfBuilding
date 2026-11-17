-- api-stdio fork: headless entry point for current LuaJIT.
-- PoB's launcher files open with a `#@` line that PoB's own runtime skips.
-- LuaJIT since c41d727d (Oct 2026) parses a leading `#` as a line-number
-- directive and skips only `#!`, so `luajit HeadlessWrapper.lua` fails with
-- "unexpected symbol near '#'". This shim turns that header into a comment
-- (keeping the line count) for every file loaded via loadfile/dofile.
-- Usage: luajit HeadlessBoot.lua [--stdio]   (same args as HeadlessWrapper.lua)

-- Run interpreted. With the JIT compiler on, current rolling LuaJIT builds
-- (2.1.1793275035, Nov 2026) intermittently crash with an access violation
-- (0xC0000005) while loading builds that combine a timeless jewel with cluster
-- jewels: ~50% of runs, sometimes on the very first load. With the JIT off: 0
-- crashes in 15 such loads, and no measurable slowdown (PoB's calc code gains
-- nothing from the JIT here: 40 calc_with calls take 0.2s either way).
-- Set POB_LUAJIT_JIT=1 to re-enable it, e.g. to test a newer LuaJIT.
if jit and jit.off and os.getenv('POB_LUAJIT_JIT') ~= '1' then jit.off() end

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
