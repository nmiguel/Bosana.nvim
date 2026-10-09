local M = {}

function M.id_less(a, b)
  return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
end

function M.index(state)
  state.by_session, state.by_window = {}, {}
  state.excluded = state.excluded or {}
  for _, session in ipairs(state.sessions) do
    state.by_session[session.id] = session
    for _, window in ipairs(session.windows) do
      window.session_id = session.id
      state.by_window[window.id] = window
    end
  end
  return state
end

function M.window_ids(session)
  local ids = {}
  for _, window in ipairs(session.windows) do
    ids[#ids + 1] = window.id
  end
  return ids
end

function M.resolve(desired, ids)
  local resolved = vim.deepcopy(desired)
  for _, session in ipairs(resolved.sessions) do
    session.id = ids[session.id] or session.id
    for _, window in ipairs(session.windows) do
      window.id = ids[window.id] or window.id
    end
  end
  return M.index(resolved)
end

-- Active-window changes are navigation, not conflicting edits.
function M.signature(state)
  local sessions = {}
  for _, session in ipairs(state.sessions) do
    local windows = {}
    for _, window in ipairs(session.windows) do
      windows[#windows + 1] = { window.id, window.name, window.index }
    end
    sessions[#sessions + 1] = { session.id, session.name, windows }
  end
  table.sort(sessions, function(a, b)
    return tonumber(a[1]:sub(2)) < tonumber(b[1]:sub(2))
  end)
  return { state.server_id, sessions }
end

function M.same(a, b)
  return vim.deep_equal(M.signature(a), M.signature(b))
end

function M.name_error(name, kind)
  if not name or name == "" or name:match("^%s*$") then
    return "Name cannot be empty"
  end
  if name:find("[%z\1-\31\127]") then
    return "Names containing control characters are not supported"
  end
  if name:match("^%s") or name:match("%s$") then
    return "Names cannot start or end with whitespace"
  end
  if kind == "session" and name:find("[.:]") then
    return "Session names cannot contain '.' or ':' (tmux replaces them)"
  end
end

-- Desired state has no index requirements: rows specify relative order only.
function M.matches_desired(actual, desired, baseline, server_id)
  local expected_sessions = 0
  for _, wanted in ipairs(desired.sessions) do
    expected_sessions = expected_sessions + 1
    local session = actual.by_session[wanted.id]
    if not session or session.name ~= wanted.name then
      return false, "Session did not reach the desired state: " .. wanted.id
    end
    if not vim.deep_equal(M.window_ids(session), M.window_ids(wanted)) then
      return false, "Window membership/order did not reach the desired state: " .. wanted.id
    end
    for i, window in ipairs(wanted.windows) do
      if not window.implicit and session.windows[i].name ~= window.name then
        return false, "Window did not reach the desired name: " .. window.id
      end
    end
  end
  for id in pairs(baseline.excluded) do
    local before, after = baseline.by_session[id], actual.by_session[id]
    if before then
      expected_sessions = expected_sessions + 1
      local a = M.index({ server_id = false, sessions = { before } })
      local b = M.index({ server_id = false, sessions = after and { after } or {} })
      if not M.same(a, b) then
        return false, "Excluded session changed: " .. id
      end
    end
  end
  if #actual.sessions ~= expected_sessions then
    return false, "Unexpected sessions remain after applying changes"
  end
  if #actual.sessions > 0 and actual.server_id ~= (server_id or baseline.server_id) then
    return false, "The tmux server changed while applying changes"
  end
  return true
end

return M
