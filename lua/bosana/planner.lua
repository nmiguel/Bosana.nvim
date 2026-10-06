local model = require("bosana.model")
local M = {}

function M.plan(baseline, desired)
  local operations = {}
  local function add(kind, fields)
    fields.kind = kind
    operations[#operations + 1] = fields
  end
  -- All destinations receive their windows before any source loses a link.
  -- This makes exchanges between single-window sessions possible.
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] then
      for _, window in ipairs(session.windows) do
        local wanted = desired.by_window[window.id]
        if wanted and wanted.session_id ~= session.id then
          add(
            "link_window",
            { id = window.id, source = session.id, destination = wanted.session_id }
          )
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
  local used_names, renamed = {}, {}
  for _, session in ipairs(baseline.sessions) do
    used_names[session.name] = true
  end
  for _, session in ipairs(desired.sessions) do
    used_names[session.name] = true
  end
  local counter = 0
  for _, session in ipairs(baseline.sessions) do
    local wanted = desired.by_session[session.id]
    if wanted and wanted.name ~= session.name then
      local temporary
      repeat
        counter = counter + 1
        temporary = "__bosana_" .. vim.fn.getpid() .. "_" .. counter
      until not used_names[temporary]
      used_names[temporary] = true
      add("rename_session", { id = session.id, name = temporary })
      renamed[#renamed + 1] = wanted
    end
  end
  for _, session in ipairs(renamed) do
    add("rename_session", { id = session.id, name = session.name })
  end
  for _, session in ipairs(baseline.sessions) do
    local wanted = desired.by_session[session.id]
    if wanted then
      local before_ids, after_ids = model.window_ids(session), model.window_ids(wanted)
      table.sort(before_ids)
      table.sort(after_ids)
      if not vim.deep_equal(before_ids, after_ids) then
        add("renumber_session", { id = session.id })
      end
      for _, window in ipairs(wanted.windows) do
        if baseline.by_window[window.id].name ~= window.name then
          add("rename_window", { id = window.id, session = session.id, name = window.name })
        end
      end
      if not vim.deep_equal(model.window_ids(session), model.window_ids(wanted)) then
        add("reorder_session", { id = session.id, windows = model.window_ids(wanted) })
      end
    end
  end
  return operations
end

return M
