local model = require("bosana.model")
local tmux = require("bosana.tmux")
local M = {}

function M.execute(client, baseline, desired, operations, before_execute)
  local report = { completed = {}, attempted = false, created = { ids = {}, rows = {} } }
  local current, snapshot_err = client:snapshot(baseline.excluded)
  if not current then
    return nil, snapshot_err, report
  end
  if not model.same(current, baseline) then
    return nil, "tmux state changed since opening the buffer; refresh before saving", report
  end

  if #operations > 0 and before_execute then
    local ok, approved = pcall(before_execute)
    if not ok or not approved then
      report.cancelled = true
      return nil, ok and "Write cancelled" or tostring(approved), report
    end
    -- The confirmation waits for input; tmux may have changed in the meantime.
    current, snapshot_err = client:snapshot(baseline.excluded)
    if not current then
      return nil, snapshot_err, report
    end
    if not model.same(current, baseline) then
      return nil, "tmux state changed while confirming changes; refresh before saving", report
    end
  end

  local server_id = baseline.server_id
  local function command(args, start_server)
    if not server_id and start_server then
      local fresh, err = client:snapshot(baseline.excluded)
      if not fresh or not model.same(fresh, baseline) then
        error(err or "The tmux server changed while applying changes", 0)
      end
    else
      local identity, identity_err = client:display(nil, "#{pid}\t#{start_time}\t#{socket_path}")
      if not identity or identity ~= server_id then
        error(identity_err or "The tmux server changed while applying changes", 0)
      end
    end
    report.attempted = true
    local out, err = client:run(args)
    if out == nil then
      report.failed = vim.deepcopy(args)
      error(err, 0)
    end
    report.completed[#report.completed + 1] = vim.deepcopy(args)
    return out
  end
  local function resolve(id)
    return report.created.ids[id] or id
  end
  local function register(reference, id)
    report.created.ids[reference] = id
    local entry = desired.by_session[reference] or desired.by_window[reference]
    if entry and entry.row then
      report.created.rows[entry.row] = id
    end
  end
  local function windows(id)
    local result, err = client:windows(id)
    if not result then
      error(err, 0)
    end
    return result
  end
  local live_sessions = {}
  local temporary_links = {}
  local bootstraps = {}
  for _, session in ipairs(current.sessions) do
    live_sessions[session.id] = true
  end

  local ok, execution_err = pcall(function()
    for _, planned in ipairs(operations) do
      local operation = vim.deepcopy(planned)
      for _, key in ipairs({ "id", "session", "source", "destination", "bootstrap" }) do
        if operation[key] then
          operation[key] = resolve(operation[key])
        end
      end
      if operation.windows then
        for i, id in ipairs(operation.windows) do
          operation.windows[i] = resolve(id)
        end
      end
      report.operation = operation
      if operation.kind == "create_session" or operation.kind == "create_window" then
        if operation.kind == "create_window" then
          local destination = windows(operation.session)
          operation.index = destination[#destination].index + 1
          if operation.index > 2147483647 then
            error("No append slot available in destination session " .. operation.session, 0)
          end
        end
        local out = command(client:creation_args(operation), operation.kind == "create_session")
        local result, err = tmux.creation_result(out)
        if not result then
          error(err, 0)
        end
        if server_id and result.server_id ~= server_id then
          error("The tmux server changed while applying changes", 0)
        end
        server_id = result.server_id
        report.server_id = server_id
        if operation.kind == "create_session" then
          register(planned.id, result.session_id)
          register(planned.window.id, result.window_id)
          live_sessions[result.session_id] = true
          if operation.window.bootstrap then
            bootstraps[#bootstraps + 1] = { session = result.session_id, id = result.window_id }
          end
        else
          if result.session_id ~= operation.session then
            error("Window was created in an unexpected session", 0)
          end
          register(planned.id, result.window_id)
        end
      elseif operation.kind == "link_window" then
        local destination = windows(operation.destination)
        local index
        local args = { "link-window", "-d" }
        if operation.bootstrap then
          for _, window in ipairs(destination) do
            if window.id == operation.bootstrap then
              index = window.index
              break
            end
          end
          if not index then
            error("Temporary initial window disappeared from " .. operation.destination, 0)
          end
          -- Replace only our disposable placeholder, preserving the new
          -- session's base-index slot without ever leaving it windowless.
          args[#args + 1] = "-k"
        else
          index = destination[#destination].index + 1
        end
        if index > 2147483647 then
          error("No append slot available in destination session " .. operation.destination, 0)
        end
        temporary_links[#temporary_links + 1] = operation
        command(vim.list_extend(args, {
          "-s",
          operation.source .. ":" .. operation.id,
          "-t",
          operation.destination .. ":" .. (operation.bootstrap or index),
        }))
      elseif operation.kind == "unlink_window" then
        local source = windows(operation.session)
        command({ "unlink-window", "-k", "-t", operation.session .. ":" .. operation.id })
        if #source == 1 then
          live_sessions[operation.session] = nil
        end
      elseif operation.kind == "kill_window" then
        command({ "kill-window", "-t", operation.session .. ":" .. operation.id })
      elseif operation.kind == "kill_session" then
        -- Moving the last window out already destroys its old session.
        if live_sessions[operation.id] then
          command({ "kill-session", "-t", operation.id })
          live_sessions[operation.id] = nil
        end
      elseif operation.kind == "rename_session" then
        command({ "rename-session", "-t", operation.id, "--", (operation.name:gsub("#", "##")) })
      elseif operation.kind == "rename_window" then
        command({
          "rename-window",
          "-t",
          operation.session .. ":" .. operation.id,
          "--",
          (operation.name:gsub("#", "##")),
        })
      elseif operation.kind == "renumber_session" then
        local option, option_err =
          client:run({ "show-options", "-Av", "-t", operation.id, "renumber-windows" })
        if not option then
          error(option_err, 0)
        end
        if vim.trim(option) == "on" then
          command({ "move-window", "-r", "-t", operation.id })
        end
      elseif operation.kind == "reorder_session" then
        local ordered = windows(operation.id)
        if #ordered ~= #operation.windows then
          error("Window membership changed while reordering " .. operation.id, 0)
        end
        for i, wanted in ipairs(operation.windows) do
          if ordered[i].id ~= wanted then
            local position
            for j = i + 1, #ordered do
              if ordered[j].id == wanted then
                position = j
                break
              end
            end
            if not position then
              error("Window disappeared while reordering: " .. wanted, 0)
            end
            command({
              "swap-window",
              "-d",
              "-s",
              operation.id .. ":" .. wanted,
              "-t",
              operation.id .. ":" .. ordered[i].id,
            })
            ordered[i].id, ordered[position].id = ordered[position].id, ordered[i].id
          end
        end
      else
        error("Unknown operation: " .. tostring(operation.kind), 0)
      end
    end

    -- Swapping index occupants can change which window is selected. Restore the
    -- pre-write active ID if it still belongs to the same surviving session.
    if #operations > 0 then
      for _, session in ipairs(current.sessions) do
        if desired.by_session[session.id] then
          for _, window in ipairs(session.windows) do
            local wanted = desired.by_window[window.id]
            if window.active and wanted and wanted.session_id == session.id then
              for _, live in ipairs(windows(session.id)) do
                if live.id == window.id and not live.active then
                  command({ "select-window", "-t", session.id .. ":" .. window.id })
                end
              end
            end
          end
        end
      end
    end
  end)
  if not ok then
    -- A failed transfer may leave our temporary duplicate links behind. Remove
    -- only destination links whose original source still owns the window; this
    -- never destroys the window, and lets a subsequent refresh remain usable.
    -- Completed transfers and destructive operations are not rolled back.
    report.cleanup = {}
    local identity = client:display(nil, "#{pid}\t#{start_time}\t#{socket_path}")
    if server_id and identity == server_id then
      local function cleanup(args)
        if client:display(nil, "#{pid}\t#{start_time}\t#{socket_path}") ~= server_id then
          return
        end
        local out, cleanup_err = client:run(args)
        report.cleanup[#report.cleanup + 1] =
          { command = args, error = out == nil and cleanup_err or nil }
      end
      for _, link in ipairs(temporary_links) do
        local source, destination = client:windows(link.source), client:windows(link.destination)
        local function contains(list)
          for _, window in ipairs(list or {}) do
            if window.id == link.id then
              return true
            end
          end
          return false
        end
        if contains(source) and contains(destination) then
          cleanup({ "unlink-window", "-k", "-t", link.destination .. ":" .. link.id })
        end
      end
      -- Only disposable initial windows are removed, never newly created user
      -- windows or completed transfers. An otherwise empty bootstrap session
      -- disappears automatically when its placeholder is killed.
      for _, bootstrap in ipairs(bootstraps) do
        for _, window in ipairs(client:windows(bootstrap.session) or {}) do
          if window.id == bootstrap.id then
            cleanup({ "kill-window", "-t", bootstrap.session .. ":" .. bootstrap.id })
          end
        end
      end
    end
    report.message = tostring(execution_err)
    return nil, tostring(execution_err), report
  end
  local actual, err = client:snapshot(baseline.excluded)
  if not actual then
    report.message = err
    return nil, "Could not verify tmux state: " .. err, report
  end
  local matches, mismatch =
    model.matches_desired(actual, model.resolve(desired, report.created.ids), current, server_id)
  if not matches then
    report.message = mismatch
    return nil, mismatch, report
  end
  report.operation = nil
  return actual, nil, report
end

return M
