local model = require("bosana.model")
local M = {}

function M.plan(baseline, desired)
  local operations = {}
  local function add(kind, fields)
    fields.kind = kind
    operations[#operations + 1] = fields
  end
  local used_names, renamed = {}, {}
  for _, session in ipairs(baseline.sessions) do
    used_names[session.name] = true
  end
  for _, session in ipairs(desired.sessions) do
    used_names[session.name] = true
  end
  local counter = 0
  local function temporary_name()
    local name
    repeat
      counter = counter + 1
      name = "__bosana_" .. vim.fn.getpid() .. "_" .. counter
    until not used_names[name]
    used_names[name] = true
    return name
  end
  local initial_windows, bootstraps = {}, {}
  -- Create destinations and replacement windows before any source can disappear.
  -- Temporary session names allow deleted/renamed names to be reused safely.
  for _, session in ipairs(desired.sessions) do
    if session.new then
      local initial
      for _, window in ipairs(session.windows) do
        if window.new then
          initial = window
          break
        end
      end
      if not initial then
        initial = { id = "bootstrap:" .. session.id, name = "__bosana_bootstrap" }
        bootstraps[session.id] = initial.id
      end
      initial_windows[initial.id] = true
      add("create_session", {
        id = session.id,
        name = temporary_name(),
        window = { id = initial.id, name = initial.name, bootstrap = not initial.new },
      })
    end
  end
  for _, session in ipairs(desired.sessions) do
    for _, window in ipairs(session.windows) do
      if window.new and not initial_windows[window.id] then
        add("create_window", { id = window.id, session = session.id, name = window.name })
      end
    end
  end
  -- All destinations receive their windows before any source loses a link.
  -- This makes exchanges between single-window sessions possible.
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] then
      for _, window in ipairs(session.windows) do
        local wanted = desired.by_window[window.id]
        if wanted and wanted.session_id ~= session.id then
          add("link_window", {
            id = window.id,
            source = session.id,
            destination = wanted.session_id,
            bootstrap = bootstraps[wanted.session_id],
          })
          bootstraps[wanted.session_id] = nil
        end
      end
    end
  end
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] then
      for _, window in ipairs(session.windows) do
        local wanted = desired.by_window[window.id]
        if wanted and wanted.session_id ~= session.id then
          add("unlink_window", { id = window.id, session = session.id })
        elseif not wanted and desired.by_session[session.id] then
          add("kill_window", { id = window.id, session = session.id })
        end
      end
    end
  end
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] and not desired.by_session[session.id] then
      add("kill_session", { id = session.id })
    end
  end
  for _, session in ipairs(baseline.sessions) do
    local wanted = desired.by_session[session.id]
    if wanted and wanted.name ~= session.name then
      add("rename_session", { id = session.id, name = temporary_name() })
      renamed[#renamed + 1] = wanted
    end
  end
  for _, session in ipairs(desired.sessions) do
    if session.new then
      renamed[#renamed + 1] = session
    end
  end
  for _, session in ipairs(renamed) do
    add("rename_session", { id = session.id, name = session.name })
  end
  for _, wanted in ipairs(desired.sessions) do
    local session = baseline.by_session[wanted.id]
    local before = session and model.window_ids(session) or {}
    local before_ids, after_ids = vim.deepcopy(before), model.window_ids(wanted)
    table.sort(before_ids)
    table.sort(after_ids)
    if not vim.deep_equal(before_ids, after_ids) then
      add("renumber_session", { id = wanted.id })
    end
    for _, window in ipairs(wanted.windows) do
      local original = baseline.by_window[window.id]
      if original and original.name ~= window.name then
        add("rename_window", { id = window.id, session = wanted.id, name = window.name })
      end
    end
    if not vim.deep_equal(before, model.window_ids(wanted)) then
      add("reorder_session", { id = wanted.id, windows = model.window_ids(wanted) })
    end
  end
  return operations
end

return M
