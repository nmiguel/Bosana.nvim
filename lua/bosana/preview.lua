local M = {}

local function cancel(preview)
  preview.generation = preview.generation + 1
  if preview.process then
    pcall(preview.process.kill, preview.process, 15)
    preview.process = nil
  end
end

function M.hide(state)
  local preview = state.preview
  if not preview then
    return
  end
  cancel(preview)
  if preview.win and vim.api.nvim_win_is_valid(preview.win) then
    vim.api.nvim_win_close(preview.win, true)
  end
  preview.win, preview.target = nil, nil
end

function M.destroy(state)
  M.hide(state)
  local preview = state.preview
  if preview then
    preview.destroyed = true
    if preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr) then
      vim.api.nvim_buf_delete(preview.bufnr, { force = true })
    end
  end
end

local function selection(state)
  if vim.api.nvim_get_current_buf() ~= state.bufnr then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1] or ""
  local id = line:match("^/(@%d+) ")
  local window = id and state.baseline.by_window[id]
  if window and not state.baseline.excluded[window.session_id] then
    return win, id, window
  end
end

local sgr = "\27%[[%d;:]*m"

local function clip_line(line, width)
  local plain = line:gsub(sgr, "")
  if vim.fn.strdisplaywidth(plain) <= width then
    return line
  end
  -- Find a complete UTF-8 prefix that fits, without counting ANSI sequences as
  -- screen columns. Keep even off-screen SGR codes: their state can carry onto
  -- the next captured row.
  local low, high = 0, vim.fn.strchars(plain)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(plain, 0, middle)) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  local remaining = #vim.fn.strcharpart(plain, 0, low)
  local parts, offset = {}, 1
  while offset <= #line do
    local first, last = line:find(sgr, offset)
    local text = line:sub(offset, first and first - 1 or #line)
    parts[#parts + 1] = text:sub(1, remaining)
    remaining = math.max(0, remaining - #text)
    if not first then
      break
    end
    parts[#parts + 1] = line:sub(first, last)
    offset = last + 1
  end
  return table.concat(parts)
end

local function render_text(preview, text)
  preview.text = text
  local width = vim.api.nvim_win_get_width(preview.win)
  local height = vim.api.nvim_win_get_height(preview.win)
  -- Reset attributes and clear the previous capture, then place each source
  -- row explicitly. Long rows must not wrap or scroll the preview terminal.
  local output = { "\27[0m\27[2J\27[3J\27[H\27[?7l\27[?25l" }
  for row, line in ipairs(vim.split(text:gsub("\n$", ""), "\n", { plain = true })) do
    if row > height then
      break
    end
    output[#output + 1] = "\27[" .. row .. ";1H" .. clip_line(line, width)
  end
  output[#output + 1] = "\27[0m\27[H"
  vim.api.nvim_chan_send(preview.channel, table.concat(output))
  vim.api.nvim_win_set_cursor(preview.win, { 1, 0 })
end

local function update(state, force)
  local preview = state.preview
  if preview.destroyed or not vim.api.nvim_buf_is_loaded(state.bufnr) then
    return
  end
  local win, id, window = selection(state)
  if not win then
    M.hide(state)
    return
  end
  local width = math.floor(vim.api.nvim_win_get_width(win) / 2) - 2
  local height = vim.api.nvim_win_get_height(win) - 2
  if width < 12 or height < 1 then
    M.hide(state)
    return
  end
  if not preview.bufnr or not vim.api.nvim_buf_is_valid(preview.bufnr) then
    preview.channel = nil
    preview.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[preview.bufnr].bufhidden = "hide"
    vim.bo[preview.bufnr].filetype = "bosana_preview"
    vim.bo[preview.bufnr].undolevels = -1
    vim.bo[preview.bufnr].modifiable = false
  end
  local config = {
    relative = "win",
    win = win,
    row = 0,
    col = vim.api.nvim_win_get_width(win) - width - 2,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    title = " " .. window.name .. " (" .. id .. ") ",
    title_pos = "center",
    noautocmd = true,
  }
  local changed = preview.target ~= id or preview.anchor ~= win
  if not preview.win or not vim.api.nvim_win_is_valid(preview.win) then
    preview.win = vim.api.nvim_open_win(preview.bufnr, false, config)
    vim.wo[preview.win].wrap = false
    vim.wo[preview.win].winblend = 0
    changed = true
  else
    vim.api.nvim_win_set_config(preview.win, config)
  end
  if not preview.channel then
    preview.channel = vim.api.nvim_open_term(preview.bufnr, { force_crlf = false })
    vim.bo[preview.bufnr].scrollback = 1
    vim.bo[preview.bufnr].readonly = true
  end
  if (preview.width ~= width or preview.height ~= height) and preview.text then
    render_text(preview, preview.text)
  end
  preview.width, preview.height = width, height
  if not changed and (preview.process or not force) then
    return
  end
  cancel(preview)
  preview.target, preview.anchor = id, win
  local generation = preview.generation
  if changed then
    render_text(preview, "Loading preview…")
  end
  preview.process = state.client:capture(id, function(text, err)
    if preview.destroyed or generation ~= preview.generation then
      return
    end
    preview.process = nil
    local current_win, current_id = selection(state)
    if current_win ~= win or current_id ~= id then
      M.hide(state)
      return
    end
    if not preview.win or not vim.api.nvim_win_is_valid(preview.win) then
      return
    end
    render_text(preview, text or ("Preview unavailable:\n" .. (err or "Could not capture pane")))
  end)
end

function M.update(state, force)
  local preview = state.preview
  if not preview or preview.destroyed then
    return
  end
  preview.force = preview.force or force
  if preview.pending then
    return
  end
  preview.pending = true
  vim.schedule(function()
    preview.pending = false
    local refresh = preview.force
    preview.force = false
    update(state, refresh)
  end)
end

function M.attach(state, group)
  if not state.options.preview then
    return
  end
  state.preview = { generation = 0 }
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      M.update(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      M.update(state, true)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      M.update(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufUnload" }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      M.hide(state)
    end,
  })
end

return M
