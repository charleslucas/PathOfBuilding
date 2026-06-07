-- API/TcpServer.lua
-- Non-blocking TCP JSON-RPC server for live PoB GUI integration.
--
-- Enable by launching PoB with: $env:POB_API_TCP = "1"; & "Path of Building.exe"
-- Optional port override: $env:POB_API_TCP_PORT = "59166"
--
-- Protocol: same newline-delimited JSON as the stdio server (Handlers.lua).
-- The server binds to 127.0.0.1 only (loopback — not reachable over LAN).
--
-- Differences from stdio mode:
--   - load_build_xml and new_build are not supported (use the GUI to open builds)
--   - quit does NOT close PoB; it only disconnects the MCP client
--   - _G.build is refreshed to main.modes["BUILD"] before each request so
--     handlers always see the currently active build

local M = {}

-- ── JSON library ─────────────────────────────────────────────────────────────
local json
do
  local ok, mod = pcall(require, 'dkjson')
  if ok and mod then
    json = mod
  else
    local base = rawget(_G, 'POB_SCRIPT_DIR') or '.'
    for _, p in ipairs({
      base .. '/runtime/lua/dkjson.lua',
      base .. '/../runtime/lua/dkjson.lua',
      'runtime/lua/dkjson.lua',
    }) do
      local ok2, m = pcall(dofile, p)
      if ok2 and type(m) == 'table' then json = m; break end
    end
  end
  if not json then error('[TcpServer] dkjson not found') end
end

-- ── LuaSocket ────────────────────────────────────────────────────────────────
-- PoB ships socket.dll with entry point luaopen_socket_core (not luaopen_socket),
-- so require('socket') fails. Fall back to package.loadlib with the correct name.
local socket_ok, socket = pcall(require, 'socket')
if not socket_ok then
  local loader = package.loadlib and (
    package.loadlib('./socket.dll',  'luaopen_socket_core') or
    package.loadlib('socket.dll',    'luaopen_socket_core')
  )
  if loader then
    local ok2, core = pcall(loader)
    if ok2 and core then
      socket    = core
      socket_ok = true
      -- socket.core lacks the socket.bind() convenience wrapper from socket.lua;
      -- add a minimal shim so the rest of TcpServer can use socket.bind() unchanged.
      if not socket.bind then
        socket.bind = function(host, port)
          local srv, err = socket.tcp()
          if not srv then return nil, err or 'tcp() failed' end
          pcall(function() srv:setoption('reuseaddr', true) end)
          local ok3, e2 = srv:bind(host, port)
          if not ok3 then srv:close(); return nil, e2 end
          ok3, e2 = srv:listen(5)
          if not ok3 then srv:close(); return nil, e2 end
          return srv
        end
      end
    end
  end
end
if not socket_ok then
  io.stderr:write('[TcpServer] LuaSocket not available — TCP mode disabled\n')
  M.available = false
  M.init = function() return false end
  M.pump = function() end
  M.stop = function() end
  return M
end
M.available = true

-- ── State ─────────────────────────────────────────────────────────────────────
local server   = nil
local clients  = {}   -- list of { sock, buf }
local handlers = nil

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function j_encode(tbl)
  return json.encode(tbl, { indent = false })
end

local function write_line(sock, tbl)
  sock:send(j_encode(tbl) .. '\n')
end

local function get_version_meta()
  return {
    number     = _G.launch and launch.versionNumber  or '?',
    branch     = _G.launch and launch.versionBranch  or '?',
    platform   = _G.launch and launch.versionPlatform or '?',
    apiVersion = '1.0.0',
    mode       = 'tcp',
  }
end

-- Refresh the global `build` to whatever is currently open in the GUI.
local function refresh_build()
  if _G.main and main.modes and main.modes['BUILD'] then
    _G.build = main.modes['BUILD']
  end
end


-- ── Background keepalive ──────────────────────────────────────────────────────
-- SimpleGraphic calls GetMessageW (blocking) when PoB loses focus, which
-- freezes the frame loop and stops our TCP pump.  We use a background
-- subscript (LaunchSubScript) to post WM_NULL every ~16 ms — this unblocks
-- GetMessageW and keeps the render loop cycling at ~60 fps in the background.
--
-- WM_NULL (PostMessageA) is used rather than SetTimer because WM_TIMER is a
-- synthesized low-priority message that does NOT trigger SimpleGraphic's
-- render path, while a real posted WM_NULL does.
--
-- Exit: PostMessageA returns 0 when the window is destroyed (PoB shutting
-- down), which breaks the loop so the subscript exits cleanly.
-- Sentinel file path used to signal the keepalive subscript to stop.
-- The file exists while the TCP server is running; deleting it causes the
-- subscript to exit immediately rather than waiting for the window handle
-- to become invalid (which can take several seconds during shutdown).
local sentinel_path = './pob-api.run'

local keepalive_script = [=[
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi then return end
ffi.cdef[[
  void* FindWindowA(const char* c, const char* t);
  int   PostMessageA(void* h, unsigned int m, unsigned long w, long l);
  void  Sleep(unsigned long ms);
]]
local u32 = ffi.load('user32')
local k32 = ffi.load('kernel32')
local hwnd = u32.FindWindowA(nil, 'Path of Building')
if hwnd == nil then return end
-- sentinel_path is passed in as the first subscript argument (...)
local sentinel = ...
ConPrintf('[PoB API] Background keepalive active (~60 fps)')
while true do
  -- Primary exit: sentinel file deleted by M.stop() when PoB shuts down
  local f = io.open(sentinel, 'r')
  if not f then break end
  f:close()
  -- Fallback exit: PostMessageA returns 0 when window handle is invalid
  local ok = u32.PostMessageA(hwnd, 0, 0, 0)
  if ok == 0 then break end
  k32.Sleep(16)
end
]=]

local function start_keepalive()
  if not _G.LaunchSubScript then return end  -- headless mode has no subscripts
  -- Create sentinel file — its existence signals "keep running"
  local sf = io.open(sentinel_path, 'w')
  if sf then sf:close() end
  local id, err = pcall(function()
    return LaunchSubScript(keepalive_script, 'GetScriptPath', 'ConPrintf', sentinel_path)
  end)
  -- id here is the pcall ok flag; the actual ID is in err when ok=true
  local script_id = id and err or nil
  if script_id and _G.launch and launch.RegisterSubScript then
    -- Register so OnSubFinished doesn't crash when the subscript exits
    launch:RegisterSubScript(script_id, nil)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start listening.
-- @param h       handlers table from API.Handlers
-- @param port    TCP port (default 59166 = 0xE71E, spells "EXILE" with 7→I in leet)
function M.init(h, port)
  handlers = h
  -- Default 59166 = 0xE71E. Chosen because (a) it's in the IANA dynamic port
  -- range (49152-65535), so no collision risk with registered services, and
  -- (b) the hex spells "EXILE" if you read 7 as I — a PoE-themed nod that
  -- avoids the security-tool baggage of the previous default (31337).
  port = tonumber(port) or 59166

  local err
  server, err = socket.bind('127.0.0.1', port)
  if not server then
    io.stderr:write(string.format('[TcpServer] bind failed: %s\n', tostring(err)))
    return false
  end
  server:settimeout(0)  -- non-blocking accept
  io.stderr:write(string.format('[TcpServer] Listening on 127.0.0.1:%d\n', port))

  -- Hook main.Shutdown so the keepalive stops instantly when PoB exits,
  -- rather than waiting for the window handle to become invalid.
  if _G.main and main.Shutdown then
    local _orig = main.Shutdown
    main.Shutdown = function(self2, ...)
      M.stop()
      return _orig(self2, ...)
    end
  end

  start_keepalive()
  ConPrintf('[PoB API] ========================================')
  ConPrintf('[PoB API] PoB auto-updates are SUPPRESSED while the')
  ConPrintf('[PoB API]   TCP API is active. The Update Ready')
  ConPrintf('[PoB API]   button is hidden and the toast is muted')
  ConPrintf('[PoB API]   so they can not break the connection.')
  ConPrintf('[PoB API]')
  ConPrintf('[PoB API] REMEMBER to check for PoB updates manually')
  ConPrintf('[PoB API]   every few weeks. To update:')
  ConPrintf('[PoB API]     1. Close PoB.')
  ConPrintf('[PoB API]     2. Relaunch WITHOUT LaunchPoBWithAPI.bat')
  ConPrintf('[PoB API]        (use the normal PoB shortcut).')
  ConPrintf('[PoB API]     3. Click Check for Update / Update Ready')
  ConPrintf('[PoB API]        as usual.')
  ConPrintf('[PoB API]     4. Close PoB again, relaunch WITH the')
  ConPrintf('[PoB API]        .bat -- it will re-patch Main.lua.')
  ConPrintf('[PoB API] ========================================')
  return true
end

--- Called every GUI frame from main.onFrameFuncs['TcpServer'].
function M.pump()
  if not server then return end

  local ok, err = pcall(M._pump_inner)
  if not ok then
    io.stderr:write('[TcpServer] pump error (continuing): ' .. tostring(err) .. '\n')
  end
end

-- Track connected client count for console messages
local client_count = 0
-- Track update-available state so we warn once when it first appears
local update_warned = false
-- Track node power coroutine state to detect completion and avoid double-kick
local power_building = false
local power_kicked   = false  -- true once we've kicked recalc for this connection

function M._pump_inner()
  refresh_build()

  -- Kick node power recalc once per connection as soon as a build is loaded.
  -- Then drive the coroutine ourselves each frame — PoB only calls BuildPower()
  -- from tree tab rendering, so it won't run in the background otherwise.
  if _G.build and build.calcsTab then
    if client_count > 0 and not power_kicked then
      power_kicked = true
      build.calcsTab.powerBuildFlag = true
    end
    if build.calcsTab.powerBuilder or build.calcsTab.powerBuildFlag then
      build.calcsTab:BuildPower()
    end
    local is_building = build.calcsTab.powerBuilder ~= nil
                     or build.calcsTab.powerBuildFlag == true
    if not power_building and is_building then
      ConPrintf('[PoB API] Node power recalculation started')
    end
    if power_building and not is_building then
      ConPrintf('[PoB API] Node power recalculation complete')
    end
    power_building = is_building
  end

  -- Warn in the console the moment PoB detects a pending update,
  -- so the user sees a clear message before they can click "Update Ready".
  if not update_warned and _G.launch and launch.updateAvailable
      and launch.updateAvailable ~= 'none' then
    update_warned = true
    ConPrintf('[PoB API] !! UPDATE DETECTED -- DO NOT CLICK "Update Ready" !!')
    ConPrintf('[PoB API] Clicking it will remove the API patch mid-session')
    ConPrintf("[PoB API] and break Claude's connection until PoB is relaunched.")
    ConPrintf('[PoB API] To update safely: close PoB, relaunch WITHOUT the batch')
    ConPrintf('[PoB API] file, apply the update, then relaunch WITH it to re-patch.')
  end
  -- Accept new connections
  local client, _err = server:accept()
  if client then
    client:settimeout(0)
    pcall(write_line, client, { ok = true, ready = true, version = get_version_meta() })
    client_count = client_count + 1
    table.insert(clients, { sock = client, buf = '' })
    ConPrintf('[PoB API] Claude connected (%d client(s) active)', client_count)
    power_kicked = false  -- reset so we kick once the build is ready
  end

  -- Service connected clients
  local alive = {}
  for _, c in ipairs(clients) do
    -- Drain available data (non-blocking)
    local data, recv_err, partial = c.sock:receive(8192)
    local chunk = data or partial or ''
    if chunk ~= '' then
      c.buf = c.buf .. chunk
    end

    -- Process every complete newline-delimited JSON message
    while true do
      local nl = c.buf:find('\n', 1, true)
      if not nl then break end
      local line = c.buf:sub(1, nl - 1):match('^%s*(.-)%s*$')  -- trim
      c.buf = c.buf:sub(nl + 1)

      if line ~= '' then
        local ok2, msg = pcall(json.decode, line)
        msg = ok2 and msg or nil
        if not msg or type(msg) ~= 'table' then
          ConPrintf('[PoB API] Bad request (invalid JSON)')
          pcall(write_line, c.sock, { ok = false, error = 'invalid json' })
        else
          local action = msg.action
          local params = msg.params or {}

          if action == 'quit' then
            ConPrintf('[PoB API] Claude disconnected (quit)')
            pcall(write_line, c.sock, { ok = true, message = 'disconnected' })
            c.sock:close()
            recv_err = 'closed'
          elseif action == 'load_build_xml' or action == 'new_build' then
            ConPrintf('[PoB API] Rejected: %s (use PoB GUI in TCP mode)', action)
            pcall(write_line, c.sock, { ok = false, error =
              'Use the PoB GUI to open/create builds in TCP mode. ' ..
              'In TCP mode you work with the build already open in PoB.' })
          else
            local handler = handlers and handlers[action]
            if not handler then
              ConPrintf('[PoB API] Unknown action: %s', tostring(action))
              pcall(write_line, c.sock, { ok = false, error = 'unknown action: ' .. tostring(action) })
            else
              ConPrintf('[PoB API] >> %s', action)
              local ok3, res = pcall(handler, params)
              if not ok3 then
                ConPrintf('[PoB API] !! %s failed: %s', action, tostring(res):sub(1, 80))
                pcall(write_line, c.sock, { ok = false, error = 'exception: ' .. tostring(res) })
              else
                ConPrintf('[PoB API] << %s ok', action)
                pcall(write_line, c.sock, res)
              end
            end
          end
        end
      end
    end

    if recv_err ~= 'closed' then
      table.insert(alive, c)
    else
      client_count = math.max(0, client_count - 1)
      ConPrintf('[PoB API] Claude disconnected (%d client(s) active)', client_count)
      if client_count == 0 then power_kicked = false end
    end
  end
  clients = alive
end

--- Stop the server and disconnect all clients.
function M.stop()
  -- Delete sentinel file first — this causes the keepalive subscript to exit
  -- immediately on its next iteration, so PoB can shut down without delay.
  os.remove(sentinel_path)
  for _, c in ipairs(clients) do
    pcall(function() c.sock:close() end)
  end
  clients = {}
  if server then
    pcall(function() server:close() end)
    server = nil
  end
  io.stderr:write('[TcpServer] Stopped\n')
end

return M
