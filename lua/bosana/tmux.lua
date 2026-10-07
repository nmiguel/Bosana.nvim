local model = require("bosana.model")
local M = {}
local Client = {}
Client.__index = Client

local function lines(text)
  if text == "" then
    return {}
  end
  return vim.split(text:gsub("\n$", ""), "\n", { plain = true })
end

local function no_server(err)
  return err:find("no server running", 1, true)
    or err:find("no sessions", 1, true)
    or (
      err:find("error connecting to", 1, true)
      and (
        err:find("No such file or directory", 1, true) or err:find("Connection refused", 1, true)
      )
    )
end

function M.new(opts)
  local prefix = { "tmux" }
  if opts.socket_path then
    vim.list_extend(prefix, { "-S", opts.socket_path })
  elseif opts.socket_name then
    vim.list_extend(prefix, { "-L", opts.socket_name })
  end
  return setmetatable({ prefix = prefix, timeout_ms = opts.timeout_ms or 5000 }, Client)
end

function M.check_executable()
  if vim.fn.executable("tmux") ~= 1 then
    return nil,
      "tmux executable 'tmux' was not found in PATH or is not executable. Install tmux and add it to PATH."
  end
  local path = vim.fn.exepath("tmux")
  return path ~= "" and path or "tmux"
end

local function command_result(result)
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    if message == "" then
      message = result.code == 124 and "tmux command timed out"
        or ("tmux exited with code " .. result.code)
    end
    return nil, message
  end
  return result.stdout or ""
end

function Client:run(args)
  local executable, executable_err = M.check_executable()
  if not executable then
    return nil, executable_err
  end
  local argv = vim.list_extend(vim.deepcopy(self.prefix), args)
  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait(self.timeout_ms)
  end)
  if not ok then
    return nil, tostring(result)
  end
  return command_result(result)
end

-- Capture the visible screen with ANSI colors/styles for the preview terminal.
-- Native window IDs still resolve while rows have unsaved moves/names.
function Client:capture(window_id, callback)
  local executable, err = M.check_executable()
  if not executable then
    vim.schedule(function()
      callback(nil, err)
    end)
    return
  end
  local argv = vim.list_extend(vim.deepcopy(self.prefix), {
    "capture-pane",
    "-p",
    "-e",
    "-t",
    window_id,
  })
  local ok, process = pcall(
    vim.system,
    argv,
    { text = true, timeout = self.timeout_ms },
    function(result)
      vim.schedule(function()
        callback(command_result(result))
      end)
    end
  )
  if not ok then
    vim.schedule(function()
      callback(nil, tostring(process))
    end)
    return
  end
  return process
end

function Client:display(target, format)
  local args = { "display-message", "-p" }
  if target then
    vim.list_extend(args, { "-t", target })
  end
  vim.list_extend(args, { "-F", format })
  local out, err = self:run(args)
  if out == nil then
    return nil, err
  end
  -- Remove only tmux's final newline, preserving the actual value.
  return (out:gsub("\n$", ""))
end

function Client:host()
  local pane = vim.env.TMUX_PANE
  local origin = vim.env.TMUX and vim.env.TMUX:match("^(.*),%d+,%d+$")
  if not pane or not pane:match("^%%%d+$") or not origin then
    return nil, "Host-session exclusion requires running inside a tmux pane"
  end
  local out, err = self:display(pane, "#{session_id}\t#{window_id}\t#{socket_path}")
  if not out then
    return nil, err
  end
  local session, window, socket = out:match("^(%$%d+)\t(@%d+)\t(.+)$")
  if not session then
    return nil, "Could not resolve the hosting pane on the selected tmux server"
  end
  local uv = vim.uv or vim.loop
  if (uv.fs_realpath(socket) or socket) ~= (uv.fs_realpath(origin) or origin) then
    return nil, "The selected tmux server is not the server hosting this Neovim instance"
  end
  return { session_id = session, window_id = window }
end

function Client:name(target, kind)
  local name, err = self:display(target, "#{" .. kind .. "_name}")
  if not name then
    return nil, err
  end
  -- tmux sanitizes session names, and (since 3.8) window names, by doubling
  -- literal backslashes in storage. Present their editable spelling instead.
  if kind == "session" or self.escaped_window_names then
    name = name:gsub("\\\\", "\\")
  end
  return name
end

function Client:windows(session_id)
  local out, err = self:run({
    "list-windows",
    "-t",
    session_id,
    "-F",
    "#{window_id}\t#{window_index}\t#{window_active}",
  })
  if not out then
    return nil, err
  end
  local windows = {}
  for _, line in ipairs(lines(out)) do
    local id, index, active = line:match("^(@%d+)\t(%d+)\t([01])$")
    if not id then
      return nil, "Malformed tmux window listing"
    end
    windows[#windows + 1] = { id = id, index = tonumber(index), active = active == "1" }
  end
  table.sort(windows, function(a, b)
    return a.index < b.index
  end)
  return windows
end

function Client:snapshot(excluded)
  local session_format = "#{session_id}\t#{session_grouped}"
  local window_format = "#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}"
  local session_out, err = self:run({ "list-sessions", "-F", session_format })
  if session_out == nil then
    if no_server(err) then
      return model.index({
        server_id = false,
        sessions = {},
        excluded = vim.deepcopy(excluded or {}),
      })
    end
    return nil, err
  end
  local server_id, server_err = self:display(nil, "#{pid}\t#{start_time}\t#{socket_path}")
  if not server_id then
    return nil, server_err
  end
  local version, version_err = self:display(nil, "#{version}")
  if not version then
    return nil, version_err
  end
  local major, minor = version:match("^(%d+)%.(%d+)")
  self.escaped_window_names = major
      and (tonumber(major) > 3 or (tonumber(major) == 3 and tonumber(minor) >= 8))
    or false
  local window_out, window_err = self:run({ "list-windows", "-a", "-F", window_format })
  if not window_out then
    return nil, window_err
  end
  local state =
    model.index({ server_id = server_id, sessions = {}, excluded = vim.deepcopy(excluded or {}) })
  for _, line in ipairs(lines(session_out)) do
    local id, grouped = line:match("^(%$%d+)\t([01])$")
    if not id then
      return nil, "Malformed tmux session listing"
    end
    if grouped == "1" and not state.excluded[id] then
      return nil, "Grouped sessions are not supported in this version (" .. id .. ")"
    end
    local name, name_err = self:name(id .. ":", "session")
    if not name then
      return nil, name_err
    end
    local invalid = model.name_error(name, "session")
    if invalid and not state.excluded[id] then
      return nil, "Unsupported session name for " .. id .. ": " .. invalid
    end
    local session = { id = id, name = name, windows = {} }
    state.sessions[#state.sessions + 1] = session
    state.by_session[id] = session
  end
  for _, line in ipairs(lines(window_out)) do
    local session_id, id, index, active = line:match("^(%$%d+)\t(@%d+)\t(%d+)\t([01])$")
    if not id or not state.by_session[session_id] then
      return nil, "tmux state changed while listing windows; refresh and try again"
    end
    if state.by_window[id] then
      return nil, "Linked/shared windows are not supported in this version (" .. id .. ")"
    end
    local name, name_err = self:name(session_id .. ":" .. id, "window")
    if not name then
      return nil, name_err
    end
    local invalid = model.name_error(name, "window")
    if invalid and not state.excluded[session_id] then
      return nil, "Unsupported window name for " .. id .. ": " .. invalid
    end
    local window = {
      id = id,
      name = name,
      index = tonumber(index),
      session_id = session_id,
      active = active == "1",
    }
    local session = state.by_session[session_id]
    session.windows[#session.windows + 1] = window
    state.by_window[id] = window
  end
  table.sort(state.sessions, model.id_less)
  for _, session in ipairs(state.sessions) do
    table.sort(session.windows, function(a, b)
      return a.index < b.index
    end)
  end
  -- A listing is multiple commands. Reject topology changes during collection.
  local end_sessions = self:run({ "list-sessions", "-F", session_format })
  local end_windows = self:run({ "list-windows", "-a", "-F", window_format })
  local end_server = self:display(nil, "#{pid}\t#{start_time}\t#{socket_path}")
  local function topology(text)
    -- Switching the active window is not a structural change.
    return text and text:gsub("\t[01]\n", "\n")
  end
  if
    session_out ~= end_sessions
    or topology(window_out) ~= topology(end_windows)
    or server_id ~= end_server
  then
    return nil, "tmux state changed while collecting the snapshot; refresh and try again"
  end
  return state
end

return M
