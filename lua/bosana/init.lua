local config = require("bosana.config")
local tmux = require("bosana.tmux")
local buffer = require("bosana.buffer")
local M = {}

function M.setup(opts)
  config.setup(opts)
end

function M.open(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    return nil, "Bosana requires Neovim 0.10 or newer"
  end
  local ok, options = pcall(config.get, opts)
  if not ok then
    return nil, tostring(options)
  end
  local executable, executable_err = tmux.check_executable()
  if not executable then
    return nil, executable_err
  end
  local client = tmux.new(options)
  local excluded = {}
  for _, id in ipairs(options.excluded_sessions) do
    excluded[id] = true
  end
  local host
  if options.exclude_host_session or options.manager then
    local err
    host, err = client:host()
    if not host then
      return nil, err
    end
    excluded[host.session_id] = true
  end
  local ids = vim.tbl_keys(excluded)
  table.sort(ids)
  local key = vim.inspect({ client.prefix, ids, options.manager })
  local existing = buffer.find(key)
  if existing then
    if vim.api.nvim_get_current_buf() ~= existing.bufnr then
      existing.previous = vim.api.nvim_get_current_buf()
      local switched, switch_err = pcall(vim.api.nvim_set_current_buf, existing.bufnr)
      if not switched then
        return nil, tostring(switch_err)
      end
    end
    return existing.bufnr
  end
  local snapshot, err = client:snapshot(excluded)
  if not snapshot then
    return nil, err
  end
  if options.manager then
    local out
    out, err = client:run({ "set-option", "-t", host.session_id, "detach-on-destroy", "off" })
    if out == nil then
      return nil, err
    end
    out, err = client:run({
      "set-window-option",
      "-t",
      host.session_id .. ":" .. host.window_id,
      "remain-on-exit",
      "off",
    })
    if out == nil then
      return nil, err
    end
  end
  local created, bufnr = pcall(buffer.create, client, snapshot, options, key)
  if not created then
    local unfinished = buffer.find(key)
    if unfinished then
      pcall(vim.api.nvim_buf_delete, unfinished.bufnr, { force = true })
    end
    return nil, tostring(bufnr)
  end
  return bufnr
end

function M.save(bufnr)
  return buffer.save(bufnr)
end

function M.switch(bufnr)
  return buffer.switch(bufnr)
end

function M.refresh(opts)
  opts = opts or {}
  return buffer.refresh(opts.bufnr, opts.force)
end

function M.close(opts)
  opts = opts or {}
  return buffer.close(opts.bufnr, opts.force)
end

function M.get_state(bufnr)
  local state = buffer.get(bufnr)
  if not state then
    return nil
  end
  return {
    bufnr = state.bufnr,
    baseline = vim.deepcopy(state.baseline),
    blocked = state.blocked,
    last_report = vim.deepcopy(state.last_report),
  }
end

function M.command(args)
  local opts, i = {}, 1
  while i <= #args do
    local arg = args[i]
    if arg == "--manager" then
      opts.manager = true
    elseif arg == "--exclude-host-session" then
      opts.exclude_host_session = true
    elseif arg == "--socket-name" or arg == "--socket-path" then
      i = i + 1
      if not args[i] or args[i]:match("^%-%-") then
        return nil, "Missing value for " .. arg
      end
      opts[arg == "--socket-name" and "socket_name" or "socket_path"] = args[i]
    else
      return nil, "Unknown Bosana argument: " .. arg
    end
    i = i + 1
  end
  return M.open(opts)
end

return M
