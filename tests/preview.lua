local t = require("tests.helpers")
local bosana = require("bosana")
local buffer = require("bosana.buffer")
local config = require("bosana.config")
local model = require("bosana.model")

local function move(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
  t.ok(
    vim.wait(1000, function()
      local state = buffer.get()
      return state and state.preview and not state.preview.pending
    end, 10),
    "Preview did not process cursor movement"
  )
end

local function content(preview)
  return table
    .concat(vim.api.nvim_buf_get_lines(preview.bufnr, 0, -1, false), "\n")
    :gsub("\n+$", "")
end

local function wait_content(preview, text)
  t.ok(
    vim.wait(3000, function()
      return preview.bufnr and content(preview):find(text, 1, true)
    end, 10),
    "Preview did not show " .. text
  )
end

local function emit(client, target, text, expected)
  t.ok(client:run({
    "respawn-pane",
    "-k",
    "-t",
    target,
    "printf '" .. text .. "\\n'; exec sleep 3600",
  }))
  t.ok(
    vim.wait(3000, function()
      return t.ok(client:run({ "capture-pane", "-p", "-t", target }))
        :find(expected or text, 1, true)
    end, 10),
    "Fixture pane did not produce output"
  )
end

t.test("preview captures the selected window without focusing or modifying it", function()
  local client, baseline, path = t.fixture({ { "a", "b" } })
  local first, second = baseline.sessions[1].windows[1], baseline.sessions[1].windows[2]
  emit(client, first.id, "FIRST_PANE")
  emit(client, second.id, "SECOND_PANE")
  local bufnr = t.ok(bosana.open({ socket_path = path }))
  local anchor = vim.api.nvim_get_current_win()
  local preview = buffer.get(bufnr).preview
  move(2)
  wait_content(preview, "FIRST_PANE")
  t.eq(vim.api.nvim_get_current_win(), anchor)
  t.eq(vim.api.nvim_get_current_buf(), bufnr)
  t.eq(vim.api.nvim_win_get_config(preview.win).focusable, false)
  t.eq(vim.bo[preview.bufnr].modifiable, false)
  t.eq(vim.bo[preview.bufnr].readonly, true)
  t.eq(vim.bo[preview.bufnr].buflisted, false)
  t.eq(vim.bo[bufnr].modified, false)
  move(3)
  wait_content(preview, "SECOND_PANE")
  t.ok(model.same(t.ok(client:snapshot()), baseline))
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].active, first.active)
end)

t.test("preview follows native IDs through unsaved moves, renames, and reload", function()
  local client, baseline, path = t.fixture({ { "a" }, { "b" } })
  local first, second = baseline.sessions[1].windows[1], baseline.sessions[2].windows[1]
  emit(client, first.id, "ORIGINAL_WINDOW")
  emit(client, second.id, "OTHER_WINDOW")
  local bufnr = t.ok(bosana.open({ socket_path = path }))
  local preview = buffer.get(bufnr).preview
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    t.session_line(baseline.sessions[2]),
    t.window_line(first, "pending-rename"),
    t.window_line(second),
  })
  move(2)
  wait_content(preview, "ORIGINAL_WINDOW")
  t.ok(vim.bo[bufnr].modified)
  vim.cmd("edit!")
  wait_content(preview, "ORIGINAL_WINDOW")
  t.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  t.eq(vim.bo[bufnr].modified, false)
end)

t.test("preview reads the active pane and refreshes its output on CursorHold", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local window = baseline.sessions[1].windows[1]
  emit(client, window.id, "INACTIVE_PANE")
  local pane = vim.trim(
    t.ok(client:run({ "split-window", "-t", window.id, "-P", "-F", "#{pane_id}", "sleep 3600" }))
  )
  emit(client, pane, "ACTIVE_PANE")
  local bufnr = t.ok(bosana.open({ socket_path = path }))
  local preview = buffer.get(bufnr).preview
  move(2)
  wait_content(preview, "ACTIVE_PANE")
  t.eq(content(preview):find("INACTIVE_PANE", 1, true), nil)
  emit(client, pane, "UPDATED_PANE")
  vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr })
  wait_content(preview, "UPDATED_PANE")
  t.eq(vim.bo[bufnr].modified, false)
end)

t.test("preview hides on session and invalid rows and cleans up when leaving", function()
  local _, baseline, path = t.fixture({ { "a" } })
  local previous = vim.api.nvim_get_current_buf()
  local bufnr = t.ok(bosana.open({ socket_path = path }))
  local preview = buffer.get(bufnr).preview
  move(2)
  local preview_buf = preview.bufnr
  t.ok(vim.api.nvim_win_is_valid(preview.win))
  move(1)
  t.eq(preview.win, nil)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "/@999999     unknown" })
  move(2)
  t.eq(preview.win, nil)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { t.window_line(baseline.sessions[1].windows[1]) })
  move(2)
  t.ok(preview.win)
  vim.api.nvim_set_current_buf(previous)
  t.eq(preview.win, nil)
  t.eq(t.ok(bosana.open({ socket_path = path })), bufnr)
  move(2)
  t.ok(preview.win)
  t.ok(bosana.close({ force = true }))
  t.eq(preview.win, nil)
  t.eq(vim.api.nvim_buf_is_valid(preview_buf), false)
end)

t.test(
  "new window rows hide previews until saved and then capture their created native ID",
  function()
    local client, baseline, path = t.fixture({ { "a" } })
    t.ok(client:run({ "set-option", "-g", "default-command", "sleep 3600" }))
    local bufnr = t.ok(bosana.open({ socket_path = path }))
    local preview = buffer.get(bufnr).preview
    move(2)
    t.ok(preview.win)
    vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "    created" })
    move(3)
    t.eq(preview.win, nil)
    t.eq(vim.bo[bufnr].modified, true)
    t.ok(model.same(t.ok(client:snapshot()), baseline))
    t.ok(bosana.save())
    local id = bosana.get_state().last_report.created.rows[3]
    t.ok(
      vim.wait(3000, function()
        return preview.win and not preview.pending and not preview.process
      end, 10),
      "Created window preview did not finish its initial capture"
    )
    t.eq(preview.target, id)
    emit(client, id, "CREATED_WINDOW")
    vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr })
    wait_content(preview, "CREATED_WINDOW")
    t.eq(preview.target, id)
  end
)

t.test("preview ignores cancelled results and never reopens after buffer deletion", function()
  local requests, kills = {}, 0
  local client = {
    capture = function(_, id, callback)
      requests[#requests + 1] = { id = id, callback = callback }
      return {
        kill = function()
          kills = kills + 1
        end,
      }
    end,
  }
  local bufnr = buffer.create(client, t.baseline(), config.get(), "preview-race")
  local preview = buffer.get(bufnr).preview
  move(2)
  move(3)
  t.eq(#requests, 2)
  t.eq(kills, 1)
  requests[2].callback("LATEST\n")
  requests[1].callback("STALE\n")
  wait_content(preview, "LATEST")
  t.eq(content(preview), "LATEST")
  move(4)
  local preview_buf = preview.bufnr
  vim.api.nvim_buf_delete(bufnr, { force = true })
  requests[3].callback("TOO_LATE\n")
  t.eq(preview.win, nil)
  t.eq(vim.api.nvim_buf_is_valid(preview_buf), false)
end)

t.test("capture errors stay in the preview and can be retried without losing edits", function()
  local requests = {}
  local client = {
    capture = function(_, _, callback)
      requests[#requests + 1] = callback
    end,
  }
  local bufnr = buffer.create(client, t.baseline(), config.get(), "preview-error")
  local preview = buffer.get(bufnr).preview
  move(2)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "/@1     edited" })
  requests[1](nil, "tmux command timed out")
  wait_content(preview, "Preview unavailable")
  t.contains(content(preview), "Preview unavailable:\ntmux command timed out")
  t.ok(vim.bo[bufnr].modified)
  vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr })
  t.ok(vim.wait(1000, function()
    return #requests == 2
  end, 10))
  requests[2]("RECOVERED\n")
  wait_content(preview, "RECOVERED")
  t.eq(content(preview), "RECOVERED")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false), { "/@1     edited" })
end)

t.test("preview can be disabled and rejects invalid configuration", function()
  local _, _, path = t.fixture({ { "a" } })
  local bufnr = t.ok(bosana.open({ socket_path = path, preview = false }))
  t.eq(buffer.get(bufnr).preview, nil)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  t.eq(#vim.api.nvim_list_wins(), 1)
  t.eq(pcall(bosana.setup, { preview = "yes" }), false)
end)

t.test("asynchronous capture reports missing tmux without starting a process", function()
  local client = require("bosana.tmux").new({ socket_name = "preview-unused" })
  local path, result, done = vim.env.PATH
  vim.env.PATH = ""
  local process = client:capture("@1", function(text, err)
    result, done = { text = text, err = err }, true
  end)
  vim.env.PATH = path
  t.eq(process, nil)
  t.ok(vim.wait(1000, function()
    return done
  end, 10))
  t.eq(result.text, nil)
  t.contains(result.err, "not found in PATH")
end)

t.test(
  "attached preview preserves colors/styles, resizes, permits editing, and does not block :wq",
  function()
    local client, baseline, path = t.fixture({ { "a" } })
    emit(
      client,
      baseline.sessions[1].windows[1].id,
      "\\033[38;2;12;34;56;48;2;65;43;21;1;4mVISIBLE_PREVIEW\\033[0m",
      "VISIBLE_PREVIEW"
    )
    local channel = vim.fn.jobstart(
      { "nvim", "--embed", "--headless", "-u", "NONE" },
      { rpc = true }
    )
    t.ok(channel > 0, "Could not start the preview UI test")
    local ok, err = xpcall(function()
      vim.rpcrequest(channel, "nvim_ui_attach", 100, 24, { rgb = true })
      vim.rpcrequest(
        channel,
        "nvim_exec_lua",
        [[
      local root, path = ...
      vim.opt.runtimepath:prepend(root)
      -- Enable highlight-state inspection before drawing; its first call
      -- rebuilds Neovim's highlight table for a legacy-grid UI.
      vim.api.nvim__inspect_cell(1, 0, 0)
      assert(require('bosana').open({ socket_path = path, confirm = false }))
      vim.api.nvim_win_set_cursor(0, { 2, 8 })
    ]],
        { vim.fn.getcwd(), path }
      )
      local function ready()
        return vim.rpcrequest(
          channel,
          "nvim_exec_lua",
          [[
        local preview = require('bosana.buffer').get().preview
        return preview.win ~= nil and preview.bufnr ~= nil
          and table.concat(vim.api.nvim_buf_get_lines(preview.bufnr, 0, -1, false), '\n'):find('VISIBLE_PREVIEW', 1, true) ~= nil
      ]],
          {}
        )
      end
      t.ok(vim.wait(3000, ready, 10), "Attached preview did not load")
      local screen = vim.rpcrequest(
        channel,
        "nvim_exec_lua",
        [[
      vim.cmd('redraw!')
      local rows = {}
      for row = 1, 24 do
        local text = {}
        for column = 1, 100 do
          text[column] = vim.fn.screenstring(row, column)
        end
        rows[row] = table.concat(text)
      end
      return table.concat(rows, '\n')
    ]],
        {}
      )
      t.contains(screen, "VISIBLE_PREVIEW")
      t.contains(screen, "▤ a")
      local function first_cell()
        return vim.rpcrequest(
          channel,
          "nvim_exec_lua",
          [[
        vim.cmd('redraw!')
        local preview = require('bosana.buffer').get().preview
        local first = vim.api.nvim_buf_get_lines(preview.bufnr, 0, 1, false)[1]:sub(1, 1)
        -- Floats have their own grid even in a single-grid attached UI. Inspect
        -- the content cell inside its border, rather than the underlying editor.
        for grid = 1, 64 do
          local ok, cell = pcall(vim.api.nvim__inspect_cell, grid, 1, 1)
          if ok and cell[1] == first then
            return cell
          end
        end
        return { '', {} }
      ]],
          {}
        )
      end
      local cell = first_cell()
      t.eq(cell[1], "V")
      t.eq(cell[2].foreground, 0x0c2238, vim.inspect(cell))
      t.eq(cell[2].background, 0x412b15)
      t.eq(cell[2].bold, true)
      t.eq(cell[2].underline, true)
      vim.rpcrequest(channel, "nvim_ui_try_resize", 24, 12)
      t.ok(
        vim.wait(1000, function()
          return vim.rpcrequest(
            channel,
            "nvim_exec_lua",
            "return require('bosana.buffer').get().preview.win == nil",
            {}
          )
        end, 10),
        "Preview did not hide in a narrow editor"
      )
      vim.rpcrequest(channel, "nvim_ui_try_resize", 100, 24)
      t.ok(vim.wait(3000, ready, 10), "Preview did not return after resizing")
      t.ok(
        vim.wait(3000, function()
          return first_cell()[2].foreground == 0x0c2238
        end, 10),
        "Resized preview did not preserve its foreground"
      )
      emit(client, baseline.sessions[1].windows[1].id, "PLAIN_REFRESH")
      vim.rpcrequest(
        channel,
        "nvim_exec_lua",
        [[
      vim.api.nvim_exec_autocmds('CursorHold', { buffer = vim.api.nvim_get_current_buf() })
    ]],
        {}
      )
      t.ok(
        vim.wait(3000, function()
          return first_cell()[1] == "P"
        end, 10),
        "Plain refresh did not replace the colored capture"
      )
      cell = first_cell()
      t.ok(cell[2].foreground ~= 0x0c2238, "Old foreground leaked into the refresh")
      t.ok(cell[2].background ~= 0x412b15, "Old background leaked into the refresh")
      t.ok(not cell[2].bold and not cell[2].underline, "Old text styles leaked into the refresh")
      vim.rpcrequest(channel, "nvim_input", "A-renamed")
      t.ok(
        vim.wait(1000, function()
          return vim.rpcrequest(channel, "nvim_get_mode").mode:sub(1, 1) == "i"
        end, 10),
        "Preview prevented entering insert mode"
      )
      vim.rpcrequest(channel, "nvim_input", "\027")
      t.ok(vim.wait(1000, function()
        return vim.rpcrequest(channel, "nvim_get_mode").mode == "n"
      end, 10))
      vim.rpcrequest(channel, "nvim_exec_lua", "vim.schedule(function() vim.cmd('wq') end)", {})
      t.eq(vim.fn.jobwait({ channel }, 5000)[1], 0, ":wq did not exit with a visible preview")
      t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "a-renamed")
    end, debug.traceback)
    vim.fn.jobstop(channel)
    t.ok(ok, err)
  end
)

t.test("colored captures clip long Unicode rows without wrapping or losing later rows", function()
  local requests = {}
  local client = {
    capture = function(_, _, callback)
      requests[#requests + 1] = callback
    end,
  }
  local bufnr = buffer.create(client, t.baseline(), config.get(), "preview-colored-clipping")
  local preview = buffer.get(bufnr).preview
  move(2)
  local width = vim.api.nvim_win_get_width(preview.win)
  requests[1]("\27[31m" .. string.rep("界", width) .. "\27[32m\nNEXT_ROW\27[0m\n")
  wait_content(preview, "NEXT_ROW")
  local lines = vim.api.nvim_buf_get_lines(preview.bufnr, 0, -1, false)
  t.eq(lines[1], string.rep("界", math.floor(width / 2)))
  t.eq(lines[2], "NEXT_ROW")
  t.eq(content(preview):find("\27", 1, true), nil)
  t.eq(vim.bo[preview.bufnr].buftype, "terminal")
  t.eq(vim.bo[preview.bufnr].scrollback, 1)
  t.eq(vim.bo[bufnr].modified, false)
end)
