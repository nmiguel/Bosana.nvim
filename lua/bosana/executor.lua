local model = require("bosana.model")
local M = {}

function M.execute(client, baseline, desired, operations)
  local report = { completed = {}, attempted = false }
  local current, snapshot_err = client:snapshot(baseline.excluded)
  if not current then
    return nil, snapshot_err, report
  end
  if not model.same(current, baseline) then
    return nil, "tmux state changed since opening the buffer; refresh before saving", report
  end

  local function command(args)
    local identity, identity_err = client:display(nil, "#{pid}\t#{start_time}\t#{socket_path}")
    if not identity or identity ~= baseline.server_id then
      error(identity_err or "The tmux server changed while applying changes", 0)
    end
    report.attempted = true
    local out, err = client:run(args)
    if out == nil then
      report.failed = vim.deepcopy(args)
      error(err, 0)
    end
    report.completed[#report.completed + 1] = vim.deepcopy(args)
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
  for _, session in ipairs(current.sessions) do
    live_sessions[session.id] = true
  end

  local ok, execution_err = pcall(function()
    for _, operation in ipairs(operations) do
      report.operation = vim.deepcopy(operation)
      if operation.kind == "link_window" then
        local destination = windows(operation.destination)
        local index = destination[#destination].index + 1
        if index > 2147483647 then
          error("No append slot available in destination session " .. operation.destination, 0)
        end
        temporary_links[#temporary_links + 1] = operation
        command({
          "link-window",
          "-d",
          "-s",
          operation.source .. ":" .. operation.id,
          "-t",
          operation.destination .. ":" .. index,
        })
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
    if identity == baseline.server_id then
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
          local args = { "unlink-window", "-k", "-t", link.destination .. ":" .. link.id }
          local out, cleanup_err = client:run(args)
          report.cleanup[#report.cleanup + 1] =
            { command = args, error = out == nil and cleanup_err or nil }
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
  local matches, mismatch = model.matches_desired(actual, desired, current)
  if not matches then
    report.message = mismatch
    return nil, mismatch, report
  end
  report.operation = nil
  return actual, nil, report
end

return M
