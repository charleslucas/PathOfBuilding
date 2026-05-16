-- API/TcpServer.lua
-- Non-blocking TCP JSON-RPC server for live PoB GUI integration.
--
-- Enable by launching PoB with: $env:POB_API_TCP = "1"; & "Path of Building.exe"
-- Optional port override: $env:POB_API_TCP_PORT = "31337"
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

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start listening.
-- @param h       handlers table from API.Handlers
-- @param port    TCP port (default 31337)
function M.init(h, port)
  handlers = h
  port = tonumber(port) or 31337

  local err
  server, err = socket.bind('127.0.0.1', port)
  if not server then
    io.stderr:write(string.format('[TcpServer] bind failed: %s\n', tostring(err)))
    return false
  end
  server:settimeout(0)  -- non-blocking accept
  io.stderr:write(string.format('[TcpServer] Listening on 127.0.0.1:%d\n', port))
  return true
end

--- Called every GUI frame from main.onFrameFuncs['TcpServer'].
function M.pump()
  if not server then return end

  refresh_build()

  -- Accept new connections
  local client, err = server:accept()
  if client then
    client:settimeout(0)
    -- Send ready banner immediately on connect
    write_line(client, { ok = true, ready = true, version = get_version_meta() })
    table.insert(clients, { sock = client, buf = '' })
    io.stderr:write('[TcpServer] Client connected\n')
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
        local msg = json.decode(line)
        if not msg or type(msg) ~= 'table' then
          write_line(c.sock, { ok = false, error = 'invalid json' })
        else
          local action = msg.action
          local params = msg.params or {}

          if action == 'quit' then
            -- Disconnect this client only — PoB keeps running
            write_line(c.sock, { ok = true, message = 'disconnected' })
            c.sock:close()
            recv_err = 'closed'
          elseif action == 'load_build_xml' or action == 'new_build' then
            -- These don't make sense in TCP/GUI mode
            write_line(c.sock, { ok = false, error =
              'Use the PoB GUI to open/create builds in TCP mode. ' ..
              'In TCP mode you work with the build already open in PoB.' })
          else
            local handler = handlers and handlers[action]
            if not handler then
              write_line(c.sock, { ok = false, error = 'unknown action: ' .. tostring(action) })
            else
              local ok2, res = pcall(handler, params)
              if not ok2 then
                write_line(c.sock, { ok = false, error = 'exception: ' .. tostring(res) })
              else
                write_line(c.sock, res)
              end
            end
          end
        end
      end
    end

    if recv_err ~= 'closed' then
      table.insert(alive, c)
    else
      io.stderr:write('[TcpServer] Client disconnected\n')
    end
  end
  clients = alive
end

--- Stop the server and disconnect all clients.
function M.stop()
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
