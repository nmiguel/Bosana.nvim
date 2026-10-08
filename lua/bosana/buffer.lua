local parser = require("bosana.parser")
local planner = require("bosana.planner")
local executor = require("bosana.executor")
local confirmation = require("bosana.confirmation")
local message = require("bosana.message")
local preview = require("bosana.preview")
local M = {}
local states = {}
local namespace = vim.api.nvim_create_namespace("bosana")
local icon_namespace = vim.api.nvim_create_namespace("bosana.icons")
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

local function render_icons(state)
  local bufnr = state.bufnr
  vim.api.nvim_buf_clear_namespace(bufnr, icon_namespace, 0, -1)
  if not state.options.icons then
    return
  end
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local kind = line:match("^/([%$@])%d+ ")
    local icon = kind and state.options.icons[kind == "$" and "session" or "window"]
    if icon and icon ~= "" and name_column(line) < #line then
      vim.api.nvim_buf_set_extmark(bufnr, icon_namespace, row - 1, name_column(line), {
        virt_text = { { icon .. " ", kind == "$" and "BosanaSessionIcon" or "BosanaWindowIcon" } },
        virt_text_pos = "inline",
      })
    end
  end
end

local function attach_icons(state)
  if state.attached then
    return
  end
  state.attached = vim.api.nvim_buf_attach(state.bufnr, false, {
    on_lines = function()
      if not state.icons_pending then
        state.icons_pending = true
        -- Undo adjusts extmarks after on_lines. Rebuild once that has finished.
        vim.schedule(function()
          state.icons_pending = false
          if states[state.bufnr] == state and vim.api.nvim_buf_is_loaded(state.bufnr) then
            render_icons(state)
            preview.update(state, true)
          end
        end)
      end
    end,
    on_detach = function()
      state.attached = false
    end,
  })
end

local function load_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Reloading clears syntax matches but can leave b:current_syntax intact.
    vim.b[bufnr].current_syntax = nil
    vim.cmd("runtime! syntax/bosana.vim")
  end)
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

local function mark_special(bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].buflisted = false
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
  render_icons(state)
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
  preview.update(state, true)
end

local function recover(state)
  local blocked = state.blocked
  local ok, snapshot, err = pcall(state.client.snapshot, state.client, state.baseline.excluded)
  if not ok or not snapshot then
    if state.last_report then
      state.last_report.recovery_error = ok and err or tostring(snapshot)
    end
    -- If tmux is unavailable, at least remove invalid/stale edits from the view.
    render(state, state.baseline)
    state.blocked = blocked
    return
  end
  render(state, snapshot)
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
  state.last_report = nil
  vim.bo[state.bufnr].modifiable = false
  local ok, result, err = pcall(function()
    local desired, errors =
      parser.parse(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), state.baseline)
    vim.diagnostic.reset(namespace, state.bufnr)
    if not desired then
      state.last_report = { completed = {}, attempted = false, validation = errors }
      return nil, "Invalid edits: " .. errors[1].message
    end
    local operations = planner.plan(state.baseline, desired)
    local before_execute
    if state.options.confirm ~= false then
      before_execute = function()
        return confirmation.confirm(state.baseline, desired)
      end
    end
    local actual, execution_err, report =
      executor.execute(state.client, state.baseline, desired, operations, before_execute)
    state.last_report = report
    if not actual then
      state.blocked = report.attempted
      report.message = execution_err
      return nil, execution_err
    end
    render(state, actual)
    return true
  end)
  if not ok then
    state.blocked = true
    state.last_report = state.last_report or { completed = {}, attempted = true }
    state.last_report.message = tostring(result)
  end
  local cancelled = state.last_report and state.last_report.cancelled
  if (not ok or not result) and not cancelled then
    local recovered, recovery_err = pcall(recover, state)
    if not recovered then
      state.blocked = true
      state.last_report.recovery_error = tostring(recovery_err)
      vim.bo[state.bufnr].modified = true
    end
  end
  writing = false
  if vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.bo[state.bufnr].modifiable = true
    if cancelled then
      vim.bo[state.bufnr].modified = true
    end
  end
  if not ok then
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

function M.switch(bufnr)
  local state = M.get(bufnr)
  if not state then
    return nil, "Current buffer is not a Bosana buffer"
  end
  if writing then
    return nil, "A Bosana write is already in progress"
  end
  if vim.api.nvim_get_current_buf() ~= state.bufnr then
    return nil, "The Bosana buffer must be current to switch to an entry"
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1] or ""
  local id = line:match("^/([%$@]%d+) ")
  local entry = id and (state.baseline.by_session[id] or state.baseline.by_window[id])
  if not entry or state.baseline.excluded[entry.session_id or id] then
    return nil, "Current line is not a known tmux session or window"
  end
  if state.options.manager then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].modified then
        return nil, "Unsaved edits; write or discard them before switching from manager mode"
      end
    end
  end
  local success, err = state.client:switch(id)
  if not success then
    return nil, err
  end
  if state.options.manager then
    vim.cmd("quitall")
  end
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
    vim.cmd(force and "quitall!" or "quitall")
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
  -- Name-change handlers should see a special buffer, not a regular file.
  mark_special(bufnr)
  -- Session restoration can retain a URI whose number is now this buffer's ID.
  local name_id = bufnr
  while vim.fn.bufnr("bosana://" .. name_id) ~= -1 do
    name_id = name_id + 1
  end
  vim.api.nvim_buf_set_name(bufnr, "bosana://" .. name_id)
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

  vim.api.nvim_set_hl(0, "BosanaSessionIcon", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "BosanaWindowIcon", { default = true, link = "Special" })
  attach_icons(state)

  local group = vim.api.nvim_create_augroup("BosanaBuffer" .. bufnr, { clear = true })
  preview.attach(state, group)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      local success = M.save(bufnr)
      if not success then
        local cancelled = state.last_report and state.last_report.cancelled
        message.error(cancelled and "Write cancelled." or "Could not save changes.")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- :edit can relist the buffer while reloading it.
      mark_special(bufnr)
      local reload = state.reload
      state.reload = nil
      if reload then
        -- Neovim unloads and empties the buffer before BufReadCmd. Restore it
        -- first so failed reads retain edits and render can follow stable IDs.
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, reload.lines)
        vim.bo[bufnr].modified = reload.modified
        for win, cursor in pairs(reload.cursors) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
            vim.api.nvim_win_set_cursor(win, cursor)
          end
        end
      end
      attach_icons(state)
      render_icons(state)
      load_syntax(bufnr)
      -- :edit performs its unsaved-buffer check before invoking BufReadCmd.
      local success = M.refresh(bufnr, true)
      if not success then
        message.error("Could not refresh tmux sessions.")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      local cursors = {}
      for _, win in ipairs(windows_for(bufnr)) do
        cursors[win] = vim.api.nvim_win_get_cursor(win)
      end
      state.reload = {
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        modified = vim.bo[bufnr].modified,
        cursors = cursors,
      }
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      mark_special(bufnr)
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
      preview.destroy(state)
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
                message.error("Unknown action.")
                return
              end
              local success = fn(bufnr)
              if not success then
                local messages = {
                  switch = "Could not switch to the tmux entry.",
                  save = "Could not save changes.",
                  refresh = "Could not refresh tmux sessions.",
                  close = "Could not close the buffer.",
                }
                message.error(messages[action] or "Could not complete the action.")
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
  load_syntax(bufnr)
  set_window_options(state, vim.api.nvim_get_current_win())
  constrain(bufnr)
  return bufnr
end

M.namespace = namespace
return M
