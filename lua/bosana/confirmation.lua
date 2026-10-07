local M = {}

local function label(entry)
  return string.format("%q (%s)", entry.name, entry.id)
end

-- Describe user-visible changes, rather than temporary renames and links.
function M.actions(baseline, desired)
  local actions = {}
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] then
      for _, window in ipairs(session.windows) do
        local wanted = desired.by_window[window.id]
        if wanted and wanted.session_id ~= session.id then
          local destination = desired.by_session[wanted.session_id]
          local position
          for i, entry in ipairs(destination.windows) do
            if entry.id == window.id then
              position = i
              break
            end
          end
          actions[#actions + 1] = string.format(
            "Move window %s from %s to %s at position %d",
            label(window),
            label(session),
            label(destination),
            position
          )
        elseif not wanted and desired.by_session[session.id] then
          actions[#actions + 1] = "Delete window " .. label(window) .. " from " .. label(session)
        end
      end
    end
  end
  for _, session in ipairs(baseline.sessions) do
    if not baseline.excluded[session.id] then
      local wanted = desired.by_session[session.id]
      if not wanted then
        local remaining = 0
        for _, window in ipairs(session.windows) do
          if not desired.by_window[window.id] then
            remaining = remaining + 1
          end
        end
        actions[#actions + 1] =
          string.format("Delete session %s (%d remaining windows)", label(session), remaining)
      else
        if wanted.name ~= session.name then
          actions[#actions + 1] =
            string.format("Rename session %s to %q", label(session), wanted.name)
        end
        local before, after = {}, {}
        for _, window in ipairs(session.windows) do
          local target = desired.by_window[window.id]
          if target and target.session_id == session.id then
            before[#before + 1] = window.id
          end
        end
        for _, window in ipairs(wanted.windows) do
          local original = baseline.by_window[window.id]
          if original.name ~= window.name then
            actions[#actions + 1] = string.format(
              "Rename window %s in %s to %q",
              label(original),
              label(wanted),
              window.name
            )
          end
          if original.session_id == session.id then
            after[#after + 1] = window.id
          end
        end
        if not vim.deep_equal(before, after) then
          actions[#actions + 1] = "Reorder windows in session " .. label(wanted)
        end
      end
    end
  end
  return actions
end

function M.message(baseline, desired)
  local actions = M.actions(baseline, desired)
  local lines = { "Apply these tmux changes?" }
  for i = 1, math.min(5, #actions) do
    lines[#lines + 1] = "  " .. actions[i]
  end
  if #actions > 5 then
    lines[#lines + 1] = string.format("  … and %d more actions", #actions - 5)
  end
  return table.concat(lines, "\n")
end

function M.confirm(baseline, desired)
  return vim.fn.confirm(M.message(baseline, desired), "&Yes\n&No", 2) == 1
end

return M
