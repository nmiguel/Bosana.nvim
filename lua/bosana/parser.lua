local model = require("bosana.model")
local M = {}

-- Shared by parsing and provisional buffer decorations. Native-looking prefixes
-- are reserved so a damaged ID never silently becomes a new entry.
function M.row(line)
  if line:match("^%s*$") then
    return
  end
  local id, text = line:match("^/([%$@]%d+) (.*)$")
  if not id and line:match("^/[%$@]") then
    return nil, "Malformed ID; keep existing concealed prefixes intact"
  end
  text = text or line
  local indent, name = text:match("^( *)(.*)$")
  local kind = id and (id:sub(1, 1) == "$" and "session" or "window")
    or (#indent == 0 and "session" or "window")
  if #indent ~= (kind == "session" and 0 or 4) then
    return nil,
      kind == "session" and "Session rows must be unindented"
        or "Window rows require exactly four spaces"
  end
  return {
    id = id,
    kind = kind,
    name = name,
    column = (id and #id + 2 or 0) + #indent,
  }
end

function M.parse(lines, baseline)
  local desired = model.index({ server_id = baseline.server_id, sessions = {} })
  local errors, seen = {}, {}
  local current
  local function invalid(row, message)
    errors[#errors + 1] =
      { lnum = row - 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = message }
  end
  for row, line in ipairs(lines) do
    if not line:match("^%s*$") then
      local entry, row_err = M.row(line)
      if not entry then
        invalid(row, row_err)
        current = nil
      else
        local is_session, name = entry.kind == "session", entry.name
        local id = entry.id or ("new-" .. entry.kind .. ":" .. row)
        if entry.id then
          local original = is_session and baseline.by_session[id] or baseline.by_window[id]
          local excluded = original and baseline.excluded[is_session and id or original.session_id]
          if seen[id] then
            invalid(row, "Duplicate ID " .. id .. " (first used on line " .. seen[id] .. ")")
          end
          seen[id] = seen[id] or row
          if not original then
            invalid(row, "Unknown ID " .. id .. "; IDs cannot be changed")
          elseif excluded then
            invalid(row, "Entry belongs to an excluded session: " .. id)
          end
        end
        local name_err = model.name_error(name, is_session and "session" or "window")
        if name_err then
          invalid(row, name_err)
        end
        if is_session then
          current = { id = id, name = name, windows = {}, row = row, new = not entry.id }
          desired.sessions[#desired.sessions + 1] = current
        elseif not current then
          invalid(row, "Window must appear beneath a session header")
        else
          current.windows[#current.windows + 1] = {
            id = id,
            name = name,
            row = row,
            new = not entry.id,
          }
        end
      end
    end
  end
  -- Existing empty headers mean deletion; new ones request tmux's default window.
  desired.sessions = vim.tbl_filter(function(session)
    if session.new and #session.windows == 0 then
      session.windows[1] = { id = session.id .. ":default", new = true, implicit = true }
    end
    return #session.windows > 0
  end, desired.sessions)
  local names = {}
  for id in pairs(baseline.excluded) do
    if baseline.by_session[id] then
      names[baseline.by_session[id].name] = true
    end
  end
  for _, session in ipairs(desired.sessions) do
    if names[session.name] then
      invalid(session.row, "Duplicate session name: " .. session.name)
    end
    names[session.name] = true
  end
  model.index(desired)
  if #errors > 0 then
    return nil, errors
  end
  return desired, errors
end

return M
