local parser = require("bosana.parser")
local planner = require("bosana.planner")
local executor = require("bosana.executor")
local M = {}
local states = {}
local namespace = vim.api.nvim_create_namespace("bosana")
local writing = false

function M.lines(snapshot)
  local lines = {}
  for _, session in ipairs(snapshot.sessions) do
    if not snapshot.excluded[session.id] then
      lines[#lines + 1] = "/" .. session.id .. " " .. session.name
      for _, window in ipairs(session.windows) do
        lines[#lines + 1] = "/" .. window.id .. "     " .. window.name
      end
    end
  end
  return lines
end

function M.get(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return states[bufnr]
end

function M.find(key)
  for bufnr, state in pairs(states) do
    if state.key == key and vim.api.nvim_buf_is_valid(bufnr) then
      return state
    end
  end
end

local function windows_for(bufnr)
  local windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function name_column(line)
  local prefix = line:match("^/[%$@]%d+ ")
  if not prefix then
    return 0
  end
  return #prefix + (line:sub(2, 2) == "@" and 4 or 0)
end

local function constrain(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local column = name_column(line)
  if cursor[2] < column and column < #line then
    vim.api.nvim_win_set_cursor(0, { cursor[1], column })
  end
end

local window_options =
  { wrap = false, conceallevel = 3, concealcursor = "nvic", list = false, spell = false }

local function set_window_options(state, win)
  if not state.saved_windows[win] then
    local saved = {}
    for option in pairs(window_options) do
      saved[option] = vim.api.nvim_get_option_value(option, { win = win })
    end
    state.saved_windows[win] = saved
  end
  for option, value in pairs(window_options) do
    vim.api.nvim_set_option_value(option, value, { win = win })
  end
end

local function restore_window_options(state, win)
  local saved = state.saved_windows[win]
  if saved and vim.api.nvim_win_is_valid(win) then
    for option, value in pairs(saved) do
      -- Preserve any deliberate option changes made while Bosana was open.
      if vim.api.nvim_get_option_value(option, { win = win }) == window_options[option] then
        vim.api.nvim_set_option_value(option, value, { win = win })
      end
    end
  end
  state.saved_windows[win] = nil
end

local function render(state, snapshot)
  local bufnr = state.bufnr
  local cursors = {}
  for _, win in ipairs(windows_for(bufnr)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
    cursors[win] = { id = line:match("^/([%$@]%d+) "), row = cursor[1] }
  end
  local lines = M.lines(snapshot)
  local undo = vim.bo[bufnr].undolevels
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = undo
  vim.bo[bufnr].modified = false
  state.baseline, state.blocked = snapshot, false
  vim.diagnostic.reset(namespace, bufnr)
  for win, cursor in pairs(cursors) do
    local row = math.min(cursor.row, math.max(1, #lines))
    if cursor.id then
      for i, line in ipairs(lines) do
        if line:match("^/([%$@]%d+) ") == cursor.id then
          row = i
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(win, { row, name_column(lines[row] or "") })
  end
end

function M.save(bufnr)
  local state = M.get(bufnr)
  if not state then
    return nil, "Current buffer is not a Bosana buffer"
  end
  if writing then
    return nil, "A Bosana write is already in progress"
  end
  if state.blocked then
    return nil,
      "Previous write partly failed; preserve any edits you need, then use :BosanaRefresh! before retrying"
  end
  writing = true
  vim.bo[state.bufnr].modifiable = false
  local ok, result, err = pcall(function()
    local desired, errors =
      parser.parse(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), state.baseline)
    vim.diagnostic.reset(namespace, state.bufnr)
    if not desired then
      vim.diagnostic.set(namespace, state.bufnr, errors)
      if vim.api.nvim_get_current_buf() == state.bufnr then
        vim.api.nvim_win_set_cursor(0, { errors[1].lnum + 1, errors[1].col })
      end
      return nil, "Invalid edits: " .. errors[1].message
    end
    local operations = planner.plan(state.baseline, desired)
    local actual, execution_err, report =
      executor.execute(state.client, state.baseline, desired, operations)
    state.last_report = report
    if not actual then
      state.blocked = report.attempted
      local detail = state.blocked
          and (" (" .. #report.completed .. " commands completed; :BosanaRefresh! required)")
        or ""
      return nil, execution_err .. detail
    end
    render(state, actual)
    return true
  end)
  writing = false
  if vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.bo[state.bufnr].modifiable = true
    if not ok or not result then
      vim.bo[state.bufnr].modified = true
    end
  end
  if not ok then
    -- Unexpected exceptions may have happened after a mutation. Require an
    -- explicit refresh rather than replaying a possibly half-completed plan.
    state.blocked = true
    return nil, tostring(result)
  end
  return result, err
end

function M.refresh(bufnr, force)
  local state = M.get(bufnr)
  if not state then
    return nil, "Current buffer is not a Bosana buffer"
  end
  if writing then
    return nil, "A Bosana write is already in progress"
  end
  if vim.bo[state.bufnr].modified and not force then
    return nil, "Unsaved edits; use :BosanaRefresh! to discard them"
  end
  local snapshot, err = state.client:snapshot(state.baseline.excluded)
  if not snapshot then
    return nil, err
  end
  render(state, snapshot)
  return true
end

function M.close(bufnr, force)
  local state = M.get(bufnr)
  if not state then
    return nil, "Current buffer is not a Bosana buffer"
  end
  if writing then
    return nil, "A Bosana write is already in progress"
  end
  if vim.bo[state.bufnr].modified and not force then
    return nil, "Unsaved edits; write them or use :BosanaClose! to discard them"
  end
  if state.options.manager then
    vim.cmd(force and "quit!" or "quit")
    return true
  end
  if vim.api.nvim_get_current_buf() == state.bufnr then
    if state.previous and vim.api.nvim_buf_is_valid(state.previous) then
      vim.api.nvim_set_current_buf(state.previous)
    else
      vim.cmd("enew")
    end
  end
  vim.api.nvim_buf_delete(state.bufnr, { force = force or false })
  return true
end

function M.create(client, snapshot, options, key)
  local previous = vim.api.nvim_get_current_buf()
  local bufnr = vim.api.nvim_create_buf(false, false)
  local state = {
    bufnr = bufnr,
    client = client,
    options = options,
    key = key,
    previous = previous,
    saved_windows = {},
  }
  states[bufnr] = state
  vim.api.nvim_buf_set_name(bufnr, "bosana://" .. bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = "bosana"
  vim.bo[bufnr].syntax = "bosana"
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = 4
  vim.bo[bufnr].softtabstop = 4
  vim.bo[bufnr].autoindent = false
  vim.bo[bufnr].smartindent = false
  vim.bo[bufnr].indentexpr = ""
  vim.bo[bufnr].formatoptions = ""
  vim.b[bufnr].EditorConfig_disable = true

  local group = vim.api.nvim_create_augroup("BosanaBuffer" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      local success, err = M.save(bufnr)
      if not success then
        -- Raising an error from BufWriteCmd keeps :wq from exiting.
        error("Bosana: " .. err, 0)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      set_window_options(state, vim.api.nvim_get_current_win())
      constrain(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      restore_window_options(state, vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      constrain(bufnr)
      vim.schedule(function()
        constrain(bufnr)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      states[bufnr] = nil
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
  if options.keymaps then
    for lhs, action in pairs(options.keymaps) do
      if action then
        local callback = action
        if type(action) == "string" then
          callback = function()
            if action == "help" then
              vim.cmd("help bosana")
            else
              local fn = M[action]
              if not fn then
                error("Unknown Bosana action: " .. action, 0)
              end
              local success, err = fn(bufnr)
              if not success then
                vim.notify("Bosana: " .. err, vim.log.levels.ERROR)
              end
            end
          end
        end
        vim.keymap.set(
          "n",
          lhs,
          callback,
          { buffer = bufnr, silent = true, desc = "Bosana: " .. tostring(action) }
        )
      end
    end
  end
  render(state, snapshot)
  vim.api.nvim_set_current_buf(bufnr)
  -- Load concealment even when the user's config has not enabled :syntax.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("runtime! syntax/bosana.vim")
  end)
  set_window_options(state, vim.api.nvim_get_current_win())
  constrain(bufnr)
  return bufnr
end

M.namespace = namespace
return M
