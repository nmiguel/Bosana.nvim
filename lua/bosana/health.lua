local config = require("bosana.config")
local tmux = require("bosana.tmux")
local M = {}

function M.check()
  vim.health.start("Bosana")

  if vim.fn.has("nvim-0.10") == 0 then
    vim.health.error("Bosana requires Neovim 0.10 or newer")
    return
  end
  vim.health.ok("Neovim 0.10+ is available")

  local valid, opts = pcall(config.get)
  if not valid then
    vim.health.error("Invalid Bosana configuration: " .. tostring(opts))
    return
  end
  vim.health.ok("Bosana configuration is valid")

  local executable, executable_err = tmux.check_executable()
  if not executable then
    vim.health.error(executable_err)
    return
  end
  vim.health.ok("tmux executable: " .. executable)

  local client = tmux.new(opts)
  local version, version_err = client:run({ "-V" })
  if not version then
    vim.health.error("Unable to run tmux: " .. version_err)
    return
  end
  vim.health.ok(vim.trim(version))

  if opts.socket_path then
    vim.health.info("Selected server: socket path " .. opts.socket_path)
  elseif opts.socket_name then
    vim.health.info("Selected server: socket name " .. opts.socket_name)
  elseif vim.env.TMUX and vim.env.TMUX ~= "" then
    vim.health.info("Selected server: inherited from $TMUX")
  else
    vim.health.info("Selected server: default tmux server")
  end

  local excluded = {}
  for _, id in ipairs(opts.excluded_sessions) do
    excluded[id] = true
  end
  if opts.manager or opts.exclude_host_session then
    local host, host_err = client:host()
    if not host then
      vim.health.error(host_err)
      return
    end
    excluded[host.session_id] = true
    vim.health.ok("Hosting session resolved and excluded: " .. host.session_id)
  end

  local snapshot, snapshot_err = client:snapshot(excluded)
  if not snapshot then
    vim.health.error("Cannot read the selected tmux server: " .. snapshot_err)
    return
  end
  if #snapshot.sessions == 0 then
    vim.health.info(
      "No sessions are running on the selected server; Bosana will show an empty buffer"
    )
    return
  end
  local windows, visible = 0, 0
  for _, session in ipairs(snapshot.sessions) do
    if not excluded[session.id] then
      visible = visible + 1
      windows = windows + #session.windows
    end
  end
  vim.health.ok(
    string.format("Selected server is readable: %d editable sessions, %d windows", visible, windows)
  )
end

return M
