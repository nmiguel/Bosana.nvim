local t = require("tests.helpers")
local bosana = require("bosana")
local buffer = require("bosana.buffer")
local model = require("bosana.model")
local executor = require("bosana.executor")
local planner = require("bosana.planner")

local function open(path, opts)
  local bufnr, err = bosana.open(vim.tbl_extend("force", { socket_path = path }, opts or {}))
  return t.ok(bufnr, err)
end

local function child(path, edit, final_command, opts)
  opts = opts or {}
  local root = vim.fn.getcwd()
  local argv = {
    "nvim",
    "--headless",
    "-u",
    "NONE",
    "--cmd",
    "lua vim.opt.runtimepath:prepend(" .. vim.inspect(root) .. ")",
    "--cmd",
    "lua require('bosana').setup({ confirm = false })",
    "-c",
    "runtime plugin/bosana.lua",
    "-c",
    "Bosana --socket-path " .. path .. (opts.manager and " --manager" or ""),
  }
  if opts.startup then
    -- Register restoration before the CLI launch, as user configuration does.
    table.insert(argv, 2, "--cmd")
    table.insert(argv, 3, "lua " .. opts.startup)
  end
  if edit then
    vim.list_extend(argv, { "-c", "lua " .. edit })
  end
  vim.list_extend(argv, { "-c", final_command })
  return vim.system(argv, { text = true, env = opts.env }):wait(15000)
end

local function manager_child(edit, final_command, startup)
  local client, baseline, path = t.fixture({ { "work" }, { "manager" } })
  local host = baseline.sessions[2]
  local pane = t.ok(client:display(host.id .. ":" .. host.windows[1].id, "#{pane_id}"))
  local result = child(path, edit, final_command, {
    manager = true,
    startup = startup,
    env = {
      TMUX = path .. "," .. baseline.server_id:match("^(%d+)") .. ",0",
      TMUX_PANE = pane,
    },
  })
  t.eq(result.code, 0, result.stderr)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end

local function with_attached_host(client, baseline, path, callback)
  local host = baseline.sessions[#baseline.sessions]
  local process = vim.system(
    { "tmux", "-S", path, "-C", "attach-session", "-t", host.id },
    { text = true, stdin = true, env = { TMUX = "", TMUX_PANE = "" } }
  )
  local original_tmux, original_pane = vim.env.TMUX, vim.env.TMUX_PANE
  local ok, err = xpcall(function()
    t.ok(
      vim.wait(5000, function()
        local out = client:run({ "list-clients", "-F", "#{session_id}" })
        return out == host.id .. "\n"
      end, 10),
      "Control client did not attach"
    )
    vim.env.TMUX = path .. "," .. baseline.server_id:match("^(%d+)") .. ",0"
    vim.env.TMUX_PANE = t.ok(client:display(host.id .. ":", "#{pane_id}"))
    callback(host)
  end, debug.traceback)
  vim.env.TMUX, vim.env.TMUX_PANE = original_tmux, original_pane
  process:kill(15)
  process:wait(5000)
  t.ok(ok, err)
end

local function attached_selection(client)
  return t.ok(client:run({ "list-clients", "-F", "#{session_id}\t#{window_id}" }))
end

local function confirmation_child(path, line, answer)
  local stderr = {}
  local channel = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE" }, {
    rpc = true,
    on_stderr = function(_, lines)
      vim.list_extend(stderr, lines)
    end,
  })
  t.ok(channel > 0)
  local ok, result = xpcall(function()
    vim.rpcrequest(channel, "nvim_ui_attach", 100, 24, {})
    vim.rpcrequest(
      channel,
      "nvim_exec_lua",
      [[
      local root, path, line = ...
      vim.opt.runtimepath:prepend(root)
      local bosana = require('bosana')
      bosana.setup({ confirm = true })
      local bufnr, err = bosana.open({ socket_path = path })
      assert(bufnr, err)
      vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { line })
    ]],
      { vim.fn.getcwd(), path, line }
    )
    vim.rpcnotify(
      channel,
      "nvim_exec_lua",
      [[
      local answer = ...
      vim.api.nvim_feedkeys(answer, 'nt', false)
      if answer == 'y' then
        vim.cmd('wq')
      else
        local ok, err = pcall(vim.cmd, 'wq')
        assert(not ok and tostring(err):find('Write cancelled'))
        assert(vim.bo.modified)
        assert(not require('bosana').get_state().blocked)
        vim.cmd('qa!')
      end
    ]],
      { answer }
    )
    return vim.fn.jobwait({ channel }, 15000)[1]
  end, debug.traceback)
  vim.fn.jobstop(channel)
  t.ok(ok, result)
  return { code = result, stderr = table.concat(stderr, "\n") }
end

t.test("real snapshots retain names, indices, and server identity", function()
  local _, baseline = t.fixture()
  t.eq(#baseline.sessions, 2)
  t.eq(#baseline.sessions[1].windows, 3)
  t.eq(baseline.sessions[1].windows[1].name, "a")
  t.ok(baseline.server_id:match("^%d+\t"))
end)

t.test("real no-op writes execute no mutations", function()
  local client, baseline = t.fixture()
  local actual, report = t.apply(client, baseline, buffer.lines(baseline))
  t.eq(report.completed, {})
  t.ok(model.same(actual, baseline))
end)

t.test("removing a session block deletes the tmux session", function()
  local client, baseline = t.fixture()
  local first = baseline.sessions[1]
  local lines = { t.session_line(first) }
  for _, window in ipairs(first.windows) do
    lines[#lines + 1] = t.window_line(window)
  end
  local actual = t.apply(client, baseline, lines)
  t.eq(#actual.sessions, 1)
  t.eq(actual.sessions[1].id, first.id)
end)

t.test("moving a window row transfers it to the end of another session", function()
  local client, baseline = t.fixture()
  local lines = buffer.lines(baseline)
  local moved = table.remove(lines, 6)
  table.insert(lines, 5, moved)
  local actual = t.apply(client, baseline, lines)
  t.eq(actual.sessions[1].windows[4].id, baseline.sessions[2].windows[1].id)
  t.eq(#actual.sessions[2].windows, 2)
end)

t.test("moving a window row to the end reorders the tmux windows", function()
  local client, baseline = t.fixture()
  local lines = buffer.lines(baseline)
  table.insert(lines, table.remove(lines, 6))
  local actual = t.apply(client, baseline, lines)
  t.eq(actual.sessions[2].windows[3].id, baseline.sessions[2].windows[1].id)
end)

t.test("duplicate IDs cannot mutate tmux", function()
  local client, baseline, path = t.fixture()
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  table.insert(lines, 6, lines[6])
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local success, err = bosana.save()
  t.eq(success, nil)
  t.contains(err, "Duplicate ID")
  t.eq(vim.bo[bufnr].modified, false)
  t.ok(vim.bo[bufnr].modifiable)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(baseline))
  t.eq(vim.diagnostic.get(bufnr, { namespace = buffer.namespace }), {})
  t.contains(bosana.get_state().last_report.validation[1].message, "Duplicate ID")
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test("creating an entry shows a short styled error and restores a usable buffer", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[#lines + 1] = "new session"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local original_echo, messages = vim.api.nvim_echo, {}
  vim.api.nvim_echo = function(chunks, history, opts)
    messages[#messages + 1] = { chunks = chunks, history = history, opts = opts }
  end
  local ok, err = pcall(vim.cmd, "write")
  vim.api.nvim_echo = original_echo
  t.ok(ok, err)
  t.eq(messages, {
    {
      chunks = { { "Bosana: Could not save changes.", "ErrorMsg" } },
      history = true,
      opts = { err = true },
    },
  })
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(baseline))
  t.eq(vim.bo[bufnr].modified, false)
  t.ok(vim.bo[bufnr].modifiable)
  t.eq(bosana.get_state().blocked, false)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
  vim.cmd("normal! u")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(baseline))
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {
    t.window_line(baseline.sessions[1].windows[1], "retry"),
  })
  t.ok(bosana.save())
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "retry")
end)

t.test("removing a window row deletes only that tmux window", function()
  local client, baseline = t.fixture()
  local lines = buffer.lines(baseline)
  local id = baseline.sessions[2].windows[1].id
  table.remove(lines, 6)
  local actual = t.apply(client, baseline, lines)
  t.eq(actual.by_window[id], nil)
  t.eq(#actual.sessions[2].windows, 2)
end)

t.test("exchange the last windows of two sessions without destroying either", function()
  local client, baseline = t.fixture({ { "a" }, { "b" } })
  local a, b = baseline.sessions[1], baseline.sessions[2]
  local actual = t.apply(client, baseline, {
    t.session_line(a),
    t.window_line(b.windows[1]),
    t.session_line(b),
    t.window_line(a.windows[1]),
  })
  t.eq(actual.by_window[a.windows[1].id].session_id, b.id)
  t.eq(actual.by_window[b.windows[1].id].session_id, a.id)
  t.eq(#actual.sessions, 2)
end)

t.test("preserve moved-out windows when their source session is deleted", function()
  local client, baseline = t.fixture()
  local first, second = baseline.sessions[1], baseline.sessions[2]
  local lines =
    { t.session_line(first), t.window_line(first.windows[1]), t.window_line(second.windows[1]) }
  local actual = t.apply(client, baseline, lines)
  t.eq(#actual.sessions, 1)
  t.eq(#actual.sessions[1].windows, 2)
  t.eq(actual.by_window[second.windows[1].id].session_id, first.id)
end)

t.test("move all windows out and tolerate automatic source-session destruction", function()
  local client, baseline = t.fixture({ { "a" }, { "b", "c" } })
  local first, second = baseline.sessions[1], baseline.sessions[2]
  local actual = t.apply(client, baseline, {
    t.session_line(first),
    t.window_line(second.windows[2]),
    t.window_line(first.windows[1]),
    t.window_line(second.windows[1]),
    t.session_line(second), -- Empty header means delete.
  })
  t.eq(#actual.sessions, 1)
  t.eq(
    model.window_ids(actual.sessions[1]),
    { second.windows[2].id, first.windows[1].id, second.windows[1].id }
  )
end)

t.test("a blank buffer deletes all sessions and handles the vanished server", function()
  local client, baseline = t.fixture()
  local actual = t.apply(client, baseline, { "" })
  t.eq(actual.sessions, {})
  t.eq(actual.server_id, false)
end)

t.test("rename swaps and deleted-session name reuse", function()
  local client, baseline = t.fixture()
  local lines = buffer.lines(baseline)
  lines[1], lines[5] =
    t.session_line(baseline.sessions[1], "session2"),
    t.session_line(baseline.sessions[2], "session1")
  local actual = t.apply(client, baseline, lines)
  t.eq(actual.by_session[baseline.sessions[1].id].name, "session2")
  t.eq(actual.by_session[baseline.sessions[2].id].name, "session1")
  local first = actual.sessions[1]
  local renamed =
    t.apply(client, actual, { t.session_line(first, "session1"), t.window_line(first.windows[1]) })
  t.eq(renamed.sessions[1].name, "session1")
end)

t.test("Unicode and shell punctuation stay literal in window names", function()
  local client, baseline = t.fixture()
  local marker = vim.fn.tempname()
  local name = "λ 日本語 ; $(touch "
    .. marker
    .. ") #(touch "
    .. marker
    .. ') #{pane_title} # "quotes" \\ end'
  local lines = buffer.lines(baseline)
  lines[2], lines[3] =
    t.window_line(baseline.sessions[1].windows[1], name),
    t.window_line(baseline.sessions[1].windows[2], name)
  local actual = t.apply(client, baseline, lines)
  t.eq(actual.sessions[1].windows[1].name, name)
  t.eq(actual.sessions[1].windows[2].name, name)
  t.eq(vim.fn.filereadable(marker), 0)
end)

t.test("reordering preserves nonzero indices and gaps", function()
  local client, baseline = t.fixture({ { "a", "b", "c" } })
  local session = baseline.sessions[1]
  for i, index in ipairs({ 3, 7, 12 }) do
    t.ok(client:run({
      "move-window",
      "-s",
      session.id .. ":" .. session.windows[i].id,
      "-t",
      session.id .. ":" .. index,
    }))
  end
  baseline = t.ok(client:snapshot())
  session = baseline.sessions[1]
  local actual = t.apply(client, baseline, {
    t.session_line(session),
    t.window_line(session.windows[3]),
    t.window_line(session.windows[1]),
    t.window_line(session.windows[2]),
  })
  t.eq(
    vim.tbl_map(function(window)
      return window.index
    end, actual.sessions[1].windows),
    { 3, 7, 12 }
  )
end)

t.test("transfers and deletions work with automatic renumbering and base-index one", function()
  local client, baseline = t.fixture()
  t.ok(client:run({ "set-option", "-g", "base-index", "1" }))
  t.ok(client:run({ "set-option", "-g", "renumber-windows", "on" }))
  for _, session in ipairs(baseline.sessions) do
    t.ok(client:run({ "move-window", "-r", "-t", session.id }))
  end
  baseline = t.ok(client:snapshot())
  local a, b = baseline.sessions[1], baseline.sessions[2]
  local actual = t.apply(client, baseline, {
    t.session_line(a),
    t.window_line(a.windows[3]),
    t.window_line(b.windows[1]),
    t.window_line(a.windows[1]),
    t.session_line(b),
    t.window_line(b.windows[3]),
    t.window_line(b.windows[2]),
  })
  t.eq(actual.sessions[1].windows[1].index, 1)
  t.eq(actual.sessions[2].windows[1].index, 1)
  t.eq(actual.by_window[a.windows[2].id], nil)
end)

t.test("active window identity survives reordering", function()
  local client, baseline = t.fixture({ { "a", "b", "c" } })
  local session = baseline.sessions[1]
  local id = session.windows[2].id
  t.ok(client:run({ "select-window", "-t", session.id .. ":" .. id }))
  -- Navigation after opening must not invalidate the baseline.
  local actual = t.apply(client, baseline, {
    t.session_line(session),
    t.window_line(session.windows[2]),
    t.window_line(session.windows[3]),
    t.window_line(session.windows[1]),
  })
  t.eq(actual.by_window[id].active, true)
end)

t.test("stale names reject the entire write before any mutations", function()
  local client, baseline = t.fixture()
  local desired = t.parse(buffer.lines(baseline), baseline)
  t.ok(client:run({
    "rename-window",
    "-t",
    baseline.sessions[1].id .. ":" .. baseline.sessions[1].windows[1].id,
    "external",
  }))
  local actual, err, report =
    executor.execute(client, baseline, desired, planner.plan(baseline, desired))
  t.eq(actual, nil)
  t.contains(err, "state changed")
  t.eq(report.completed, {})
  t.eq(report.attempted, false)
end)

t.test("a restarted server is stale even when native IDs are reused", function()
  local client, baseline = t.fixture({ { "a" } })
  t.ok(client:run({ "kill-server" }))
  t.ok(
    client:run({ "-f", "/dev/null", "new-session", "-d", "-s", "session1", "-n", "a", "sleep 3600" })
  )
  local current = t.ok(client:snapshot())
  t.eq(current.sessions[1].id, baseline.sessions[1].id)
  local actual, err =
    executor.execute(client, baseline, t.parse(buffer.lines(baseline), baseline), {})
  t.eq(actual, nil)
  t.contains(err, "state changed")
end)

t.test("linked windows are rejected before editing", function()
  local client, baseline = t.fixture()
  local first, second = baseline.sessions[1], baseline.sessions[2]
  t.ok(client:run({
    "link-window",
    "-d",
    "-s",
    first.id .. ":" .. first.windows[1].id,
    "-t",
    second.id .. ":9",
  }))
  local snapshot, err = client:snapshot()
  t.eq(snapshot, nil)
  t.contains(err, "Linked/shared")
end)

t.test("grouped sessions are rejected before editing", function()
  local client, baseline = t.fixture({ { "a" } })
  t.ok(client:run({ "new-session", "-d", "-s", "grouped", "-t", baseline.sessions[1].id }))
  local snapshot, err = client:snapshot()
  t.eq(snapshot, nil)
  t.contains(err, "Grouped sessions")
end)

t.test("excluded sessions survive deletion of all visible sessions", function()
  local client, baseline, path = t.fixture()
  local excluded = baseline.sessions[2]
  local bufnr = open(path, { excluded_sessions = { excluded.id } })
  t.eq(#vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 4)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  t.ok(bosana.save())
  local actual = t.ok(client:snapshot())
  t.eq(#actual.sessions, 1)
  t.eq(actual.sessions[1].id, excluded.id)
  t.eq(model.window_ids(actual.sessions[1]), model.window_ids(excluded))
end)

t.test("manager mode resolves the host by pane ID and configures its lifecycle", function()
  local client, baseline, path = t.fixture({ { "work" }, { "manager" } })
  local host = baseline.sessions[2]
  local pane = t.ok(client:display(host.id .. ":" .. host.windows[1].id, "#{pane_id}"))
  local original_pane, original_tmux = vim.env.TMUX_PANE, vim.env.TMUX
  vim.env.TMUX_PANE = pane
  vim.env.TMUX = path .. "," .. baseline.server_id:match("^(%d+)") .. ",0"
  local ok, err = xpcall(function()
    local bufnr = open(path, { manager = true })
    t.eq(#vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2)
    t.eq(t.ok(client:run({ "show-options", "-v", "-t", host.id, "detach-on-destroy" })), "off\n")
    t.eq(
      t.ok(client:run({
        "show-options",
        "-w",
        "-v",
        "-t",
        host.id .. ":" .. host.windows[1].id,
        "remain-on-exit",
      })),
      "off\n"
    )
    t.eq(bosana.get_state().baseline.excluded[host.id], true)
  end, debug.traceback)
  vim.env.TMUX_PANE = original_pane
  vim.env.TMUX = original_tmux
  t.ok(ok, err)
end)

t.test("Enter switches to a session or window and preserves normal-mode edits", function()
  local client, baseline, path = t.fixture({ { "a", "b" }, { "host" } })
  local session = baseline.sessions[1]
  with_attached_host(client, baseline, path, function()
    t.ok(client:run({ "select-window", "-t", session.id .. ":" .. session.windows[2].id }))
    local bufnr = open(path, { preview = false })
    local lines = buffer.lines(baseline)
    lines[1] = t.session_line(session, "unsaved-session-name")
    -- Move a window row in the buffer without moving it in tmux.
    table.insert(lines, table.remove(lines, 2))
    lines[#lines] = t.window_line(session.windows[1], "unsaved-window-name")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('execute "normal \\<CR>"')
    t.eq(attached_selection(client), session.id .. "\t" .. session.windows[2].id .. "\n")
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
    vim.cmd('execute "normal \\<CR>"')
    t.eq(attached_selection(client), session.id .. "\t" .. session.windows[1].id .. "\n")
    t.eq(vim.api.nvim_get_current_buf(), bufnr)
    t.ok(vim.bo[bufnr].modified)
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
    t.eq(t.ok(client:snapshot()).by_window[session.windows[1].id].name, "a")
  end)
end)

t.test("switch follows a window moved externally since opening", function()
  local client, baseline, path = t.fixture({ { "a", "b" }, { "host" } })
  local window = baseline.sessions[1].windows[1]
  with_attached_host(client, baseline, path, function(host)
    open(path, { preview = false })
    t.ok(client:run({
      "move-window",
      "-d",
      "-s",
      window.id,
      "-t",
      host.id .. ":",
    }))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    t.ok(bosana.switch())
    t.eq(attached_selection(client), host.id .. "\t" .. window.id .. "\n")
  end)
end)

t.test("manager Enter switches before exiting the whole editor", function()
  for _, row in ipairs({ 1, 3 }) do
    local client, baseline, path = t.fixture({ { "a", "b" }, { "manager" } })
    local session = baseline.sessions[1]
    with_attached_host(client, baseline, path, function()
      local result = child(path, [[
        local bufnr = vim.api.nvim_get_current_buf()
        vim.cmd('new')
        vim.cmd('wincmd p')
        assert(vim.api.nvim_get_current_buf() == bufnr)
        vim.api.nvim_win_set_cursor(0, { ]] .. row .. [[, 0 })
      ]], [[execute "normal \<CR>" | cquit 1]], {
        manager = true,
        env = { TMUX = vim.env.TMUX, TMUX_PANE = vim.env.TMUX_PANE },
      })
      t.eq(result.code, 0, result.stderr)
      local window = session.windows[row == 1 and 1 or 2]
      t.eq(attached_selection(client), session.id .. "\t" .. window.id .. "\n")
    end)
  end
end)

t.test("manager switch protects edits and stays open when tmux switching fails", function()
  local client, baseline, path = t.fixture({ { "work" }, { "manager" } })
  with_attached_host(client, baseline, path, function(host)
    local result = child(
      path,
      nil,
      [[lua
      local bosana = require('bosana')
      local bufnr = vim.api.nvim_get_current_buf()
      local original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { original[1] .. '-pending' })
      local ok, err = bosana.switch()
      assert(not ok and err:find('Unsaved edits', 1, true))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
      vim.bo[bufnr].modified = false
      vim.cmd('new')
      local other = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'unsaved file' })
      vim.cmd('wincmd p')
      ok, err = bosana.switch()
      assert(not ok and err:find('Unsaved edits', 1, true))
      vim.bo[other].modified = false
      local state = require('bosana.buffer').get()
      assert(state.client:run({ 'kill-session', '-t', state.baseline.sessions[1].id }))
      ok, err = bosana.switch()
      assert(not ok and err)
      assert(vim.api.nvim_get_current_buf() == bufnr)
      vim.cmd('qa!')
    ]],
      {
        manager = true,
        env = { TMUX = vim.env.TMUX, TMUX_PANE = vim.env.TMUX_PANE },
      }
    )
    t.eq(result.code, 0, result.stderr)
    t.eq(attached_selection(client), host.id .. "\t" .. host.windows[1].id .. "\n")
  end)
end)

t.test("host exclusion outside tmux returns a useful error", function()
  local original = vim.env.TMUX_PANE
  vim.env.TMUX_PANE = nil
  local bufnr, err = bosana.open({ exclude_host_session = true })
  vim.env.TMUX_PANE = original
  t.eq(bufnr, nil)
  t.contains(err, "inside a tmux pane")
end)

t.test("manager q exits the whole editor with another window and an active preview", function()
  manager_child(
    [[
      local bufnr = vim.api.nvim_get_current_buf()
      vim.cmd('new')
      vim.cmd('wincmd p')
      assert(vim.api.nvim_get_current_buf() == bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 11 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })
      assert(vim.wait(1000, function()
        local preview = require('bosana.buffer').get(bufnr).preview
        return preview.win and vim.api.nvim_win_is_valid(preview.win)
      end, 10))
      vim.g.manager_ready = true
    ]],
    "lua if vim.g.manager_ready then vim.cmd('normal q') end; vim.cmd('cquit 1')"
  )
end)

t.test("manager CLI startup restores its mode after scheduled session restoration", function()
  manager_child(
    nil,
    [[lua vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function()
        vim.schedule(function()
          local ok, err = xpcall(function()
            local buffer = require('bosana.buffer')
            assert(vim.g.session_restored, 'Session restoration did not run')
            assert(buffer.get().options.manager, 'Session restoration lost manager mode')
            assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) == 2)
            vim.cmd('normal q')
            error('Manager q did not exit')
          end, debug.traceback)
          if not ok then print(err) end
          vim.cmd('cquit 1')
        end)
      end,
    })]],
    [[
      vim.api.nvim_create_autocmd('VimEnter', {
        once = true,
        callback = function()
          vim.schedule(function()
            local buffer = require('bosana.buffer')
            local bufnr = vim.api.nvim_get_current_buf()
            local state = buffer.get(bufnr)
            assert(state.options.manager)
            local path = state.client.prefix[3]
            vim.api.nvim_buf_delete(bufnr, { force = true })
            vim.cmd('Bosana --socket-path ' .. path)
            assert(not buffer.get().options.manager)
            vim.g.session_restored = true
          end)
        end,
      })
    ]]
  )
end)

t.test("manager close protects unsaved buffers and bang exits the whole editor", function()
  manager_child(
    [[
      local bosana = require('bosana')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.cmd('new')
      local other = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'unsaved file edits' })
      vim.cmd('wincmd p')
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'unsaved manager edits' })
      local success, err = bosana.close()
      assert(not success and err:find('Unsaved edits', 1, true))
      assert(vim.api.nvim_get_current_buf() == bufnr)
      assert(vim.bo[bufnr].modified)
      vim.bo[bufnr].modified = false
      local ok = pcall(bosana.close)
      assert(not ok, 'Close must refuse unsaved edits in other buffers')
      assert(vim.api.nvim_get_current_buf() == bufnr)
      assert(vim.bo[other].modified)
      vim.bo[bufnr].modified = true
      vim.g.manager_ready = true
    ]],
    "lua if vim.g.manager_ready then vim.cmd('BosanaClose!') end; vim.cmd('cquit 1')"
  )
end)

t.test("partial failure refreshes actual state and permits a safe retry", function()
  local client, baseline = t.fixture({ { "a" } })
  local original_run, count = client.run, 0
  client.run = function(self, args)
    if args[1] == "rename-session" then
      count = count + 1
      if count == 2 then
        return nil, "injected failure"
      end
    end
    return original_run(self, args)
  end
  local bufnr =
    buffer.create(client, baseline, { keymaps = false, confirm = false }, "failure-test")
  local lines = buffer.lines(baseline)
  lines[1] = t.session_line(baseline.sessions[1], "renamed")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local success, err = bosana.save()
  t.eq(success, nil)
  t.contains(err, "injected failure")
  local actual = t.ok(client:snapshot())
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(actual))
  t.ok(model.same(bosana.get_state().baseline, actual))
  t.eq(vim.bo[bufnr].modified, false)
  t.ok(vim.bo[bufnr].modifiable)
  local state = bosana.get_state()
  t.eq(state.blocked, false)
  t.eq(#state.last_report.completed, 1)
  t.eq(state.last_report.failed[1], "rename-session")
  t.ok(bosana.save())
  t.eq(count, 2)
end)

t.test("partial failure with unavailable recovery blocks replay until refresh", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local state = buffer.get(bufnr)
  local original_run, original_snapshot = state.client.run, state.client.snapshot
  local count, failed = 0, false
  state.client.run = function(self, args)
    if args[1] == "rename-session" then
      count = count + 1
      if count == 2 then
        failed = true
        return nil, "injected mutation failure"
      end
    end
    return original_run(self, args)
  end
  state.client.snapshot = function(self, excluded)
    if failed then
      return nil, "injected recovery failure"
    end
    return original_snapshot(self, excluded)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {
    t.session_line(baseline.sessions[1], "renamed"),
  })
  local success, err = bosana.save()
  t.eq(success, nil)
  t.contains(err, "injected mutation failure")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(baseline))
  t.eq(vim.bo[bufnr].modified, false)
  t.ok(vim.bo[bufnr].modifiable)
  t.eq(bosana.get_state().blocked, true)
  t.contains(bosana.get_state().last_report.recovery_error, "injected recovery failure")
  success, err = bosana.save()
  t.eq(success, nil)
  t.contains(err, "Previous write partly failed")
  t.eq(count, 2)
  failed = false
  t.ok(bosana.refresh({ force = true }))
  t.eq(bosana.get_state().blocked, false)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(t.ok(client:snapshot())))
  t.ok(bosana.save())
end)

t.test("unexpected save exceptions refresh state and release the write lock", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "invalid edit" })
  local parser = require("bosana.parser")
  local original_parse = parser.parse
  parser.parse = function()
    error("injected unexpected exception")
  end
  local success, err = bosana.save()
  parser.parse = original_parse
  t.eq(success, nil)
  t.contains(err, "injected unexpected exception")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(t.ok(client:snapshot())))
  t.eq(vim.bo[bufnr].modified, false)
  t.ok(vim.bo[bufnr].modifiable)
  t.eq(bosana.get_state().blocked, false)
  t.contains(bosana.get_state().last_report.message, "injected unexpected exception")
  t.ok(bosana.save())
end)

t.test("concealed IDs survive linewise cut/paste and undo", function()
  local _, baseline, path = t.fixture()
  local bufnr = open(path)
  t.eq(vim.bo[bufnr].buftype, "acwrite")
  t.eq(vim.bo[bufnr].buflisted, false)
  t.eq(vim.wo.conceallevel, 3)
  t.eq(vim.wo.concealcursor, "nvic")
  local original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local function assert_concealed(lines)
    for row, line in ipairs(lines) do
      local prefix = t.ok(line:match("^/[%$@]%d+ "))
      for column = 1, #prefix do
        local concealed = vim.fn.synconcealed(row, column)
        t.eq(concealed[1], 1, "ID prefix must be concealed")
        t.eq(concealed[2], "", "ID prefix must not have a replacement character")
      end
      -- The four-space indentation and all name characters remain visible.
      for column = #prefix + 1, #line do
        t.eq(vim.fn.synconcealed(row, column)[1], 0)
      end
    end
  end
  assert_concealed(original)
  vim.cmd("normal! 2GddGp")
  local edited = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_concealed(edited)
  t.eq(edited[#edited], original[2])
  t.eq(
    t.parse(edited, baseline).by_window[baseline.sessions[1].windows[1].id].session_id,
    baseline.sessions[2].id
  )
  vim.cmd("normal! u")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
  assert_concealed(original)
end)

t.test("icons and IDs render correctly without globally enabled syntax", function()
  local channel = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE" }, { rpc = true })
  t.ok(channel > 0, "Could not start the Neovim UI test")
  local ok, err = xpcall(function()
    vim.rpcrequest(channel, "nvim_ui_attach", 50, 12, {})
    vim.rpcrequest(
      channel,
      "nvim_exec_lua",
      [[
      vim.opt.runtimepath:prepend(...)
      assert(not vim.g.syntax_on)
      local snapshot = require('bosana.model').index({
        server_id = 'screen-test',
        sessions = {
          { id = '$123', name = 'work', windows = {
            { id = '@4567', name = 'editor /@89', index = 0 },
          } },
        },
      })
      require('bosana.buffer').create({}, snapshot, require('bosana.config').get({ keymaps = false, preview = false }), 'screen-test')
    ]],
      { vim.fn.getcwd() }
    )
    local function screen_row(row)
      return vim.rpcrequest(
        channel,
        "nvim_exec_lua",
        [[
        local row = ...
        vim.cmd('redraw!')
        local text = {}
        for column = 1, 50 do
          text[column] = vim.fn.screenstring(row, column)
        end
        return table.concat(text):gsub(' +$', '')
      ]],
        { row }
      )
    end
    t.eq(screen_row(1), "▣ work")
    t.eq(screen_row(2), "    ▤ editor /@89")
    vim.rpcrequest(channel, "nvim_win_set_cursor", 0, { 2, 11 })
    vim.rpcrequest(channel, "nvim_input", "i")
    t.ok(
      vim.wait(1000, function()
        return vim.rpcrequest(channel, "nvim_get_mode").mode:sub(1, 1) == "i"
      end, 10),
      "UI test did not enter insert mode"
    )
    t.eq(screen_row(1), "▣ work")
    t.eq(screen_row(2), "    ▤ editor /@89")
    t.eq(vim.rpcrequest(channel, "nvim_buf_get_lines", 0, 0, -1, false), {
      "/$123 work",
      "/@4567     editor /@89",
    })
  end, debug.traceback)
  vim.fn.jobstop(channel)
  t.ok(ok, err)
end)

t.test(":wq waits for affirmative confirmation before applying and exiting", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local line = t.window_line(baseline.sessions[1].windows[1], "confirmed-before-exit")
  local result = confirmation_child(path, line, "y")
  t.eq(result.code, 0, result.stderr)
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "confirmed-before-exit")
end)

t.test("declining confirmation keeps :wq in the modified editor", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local line = t.window_line(baseline.sessions[1].windows[1], "declined")
  local result = confirmation_child(path, line, "n")
  t.eq(result.code, 0, result.stderr)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test(":w applies edits, refreshes the baseline, and resets undo", function()
  local client, baseline, path = t.fixture()
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[2] = t.window_line(baseline.sessions[1].windows[1], "written")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.cmd("write")
  t.eq(vim.bo[bufnr].modified, false)
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "written")
  t.eq(bosana.get_state().baseline.sessions[1].windows[1].name, "written")
  vim.cmd("normal! u")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
end)

t.test("refresh refuses unsaved edits and bang explicitly discards them", function()
  local _, baseline, path = t.fixture()
  local bufnr = open(path)
  local original = buffer.lines(baseline)
  vim.api.nvim_buf_set_lines(
    bufnr,
    1,
    2,
    false,
    { t.window_line(baseline.sessions[1].windows[1], "pending") }
  )
  local success, err = bosana.refresh()
  t.eq(success, nil)
  t.contains(err, "Unsaved edits")
  vim.cmd("BosanaRefresh!")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
  t.eq(vim.bo[bufnr].modified, false)
end)

t.test("opening the same view preserves pending edits", function()
  local _, baseline, path = t.fixture()
  local bufnr = open(path)
  vim.api.nvim_buf_set_lines(
    bufnr,
    1,
    2,
    false,
    { t.window_line(baseline.sessions[1].windows[1], "pending") }
  )
  t.eq(open(path), bufnr)
  t.eq(
    vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1],
    t.window_line(baseline.sessions[1].windows[1], "pending")
  )
end)

t.test("scheduled startup opens with colliding session-restored buffer names", function()
  local _, _, path = t.fixture({ { "a" } })
  local script = string.format(
    [[
    local restored = { vim.api.nvim_get_current_buf(), vim.api.nvim_create_buf(true, false) }
    local names = { 'bosana://' .. (restored[2] + 1), 'bosana://' .. (restored[2] + 2) }
    for i, bufnr in ipairs(restored) do
      vim.api.nvim_buf_set_name(bufnr, names[i])
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'restored edits ' .. i })
      vim.bo[bufnr].modified = false
    end
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function()
        vim.schedule(function()
          local ok, err = xpcall(function()
            vim.cmd('Bosana --socket-path ' .. %s)
            local bosana = require('bosana')
            local bufnr = vim.api.nvim_get_current_buf()
            assert(bosana.get_state(bufnr))
            local name = vim.api.nvim_buf_get_name(bufnr)
            assert(name ~= names[1] and name ~= names[2])
            assert(bosana.open({ socket_path = %s }) == bufnr)
            assert(bosana.close())
            for i, restored_bufnr in ipairs(restored) do
              assert(vim.api.nvim_buf_get_name(restored_bufnr) == names[i])
              assert(vim.api.nvim_buf_get_lines(restored_bufnr, 0, -1, false)[1] == 'restored edits ' .. i)
            end
          end, debug.traceback)
          if not ok then
            print(err)
            vim.cmd('cquit 1')
          end
          vim.cmd('qa!')
        end)
      end,
    })
  ]],
    vim.inspect(path),
    vim.inspect(path)
  )
  local result = vim
    .system({
      "nvim",
      "--headless",
      "-u",
      "NONE",
      "--cmd",
      "lua vim.opt.runtimepath:prepend(" .. vim.inspect(vim.fn.getcwd()) .. ")",
      "-c",
      "runtime plugin/bosana.lua",
      "-c",
      "lua " .. script,
    }, { text = true })
    :wait(15000)
  t.eq(result.code, 0, result.stderr)
end)

t.test("direct startup and :wq complete mutations before exiting", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local line = t.window_line(baseline.sessions[1].windows[1], "saved-before-exit")
  local result =
    child(path, "vim.api.nvim_buf_set_lines(0, 1, 2, false, { " .. vim.inspect(line) .. " })", "wq")
  t.eq(result.code, 0, result.stderr)
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "saved-before-exit")
end)

t.test("failed :wq stays in the refreshed editor", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local line = t.window_line(baseline.sessions[1].windows[1])
  local result = child(
    path,
    "vim.api.nvim_buf_set_lines(0, 2, 2, false, { " .. vim.inspect(line) .. " })",
    [[lua local ok,err = pcall(vim.cmd, 'wq'); assert(not ok); assert(tostring(err):find('Bosana: Could not save changes.',1,true)); assert(not tostring(err):find('Lua callback',1,true)); assert(not vim.bo.modified); assert(not require('bosana').get_state().blocked); print('WRITE_BLOCKED'); vim.cmd('qa!')]]
  )
  t.eq(result.code, 0, result.stderr)
  t.contains(result.stderr, "WRITE_BLOCKED")
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test(":q! discards edits without changing tmux", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local result = child(path, [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })]], "q!")
  t.eq(result.code, 0, result.stderr)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test("invalid command arguments and socket configuration are rejected", function()
  local bufnr, err = bosana.command({ "--socket-path" })
  t.eq(bufnr, nil)
  t.contains(err, "Missing value")
  bufnr, err = bosana.command({ "--unknown" })
  t.eq(bufnr, nil)
  t.contains(err, "Unknown")
  bufnr, err = bosana.open({ socket_name = "one", socket_path = "/tmp/two" })
  t.eq(bufnr, nil)
  t.contains(err, "either")
  bufnr, err = bosana.open({ keymaps = { q = 123 } })
  t.eq(bufnr, nil)
  t.contains(err, "Keymap actions")
end)

t.test("literal session names and leading dashes survive renaming", function()
  local client, baseline = t.fixture({ { "a" } })
  local name = "-work\\dir #{window_name} ## literal"
  local window = "-window #{session_name} ## literal"
  local actual = t.apply(client, baseline, {
    t.session_line(baseline.sessions[1], name),
    t.window_line(baseline.sessions[1].windows[1], window),
  })
  t.eq(actual.sessions[1].name, name)
  t.eq(actual.sessions[1].windows[1].name, window)
end)

t.test("host detection rejects another server with reused pane IDs", function()
  local host_client, baseline, host_path = t.fixture({ { "host" } })
  local _, _, other_path = t.fixture({ { "other" } })
  local original_tmux, original_pane = vim.env.TMUX, vim.env.TMUX_PANE
  vim.env.TMUX = host_path .. "," .. baseline.server_id:match("^(%d+)") .. ",0"
  vim.env.TMUX_PANE = t.ok(host_client:display(baseline.sessions[1].id .. ":", "#{pane_id}"))
  local bufnr, err = bosana.open({ socket_path = other_path, exclude_host_session = true })
  vim.env.TMUX, vim.env.TMUX_PANE = original_tmux, original_pane
  t.eq(bufnr, nil)
  t.contains(err, "not the server hosting")
end)

t.test("closing restores the original buffer and window options", function()
  local _, _, path = t.fixture()
  local previous = vim.api.nvim_get_current_buf()
  vim.wo.wrap, vim.wo.conceallevel, vim.wo.concealcursor = true, 0, ""
  open(path)
  t.eq(vim.wo.wrap, false)
  t.eq(vim.wo.conceallevel, 3)
  t.ok(bosana.close())
  t.eq(vim.api.nvim_get_current_buf(), previous)
  t.eq(vim.wo.wrap, true)
  t.eq(vim.wo.conceallevel, 0)
  t.eq(vim.wo.concealcursor, "")
end)

t.test("failed transfers remove temporary links without destroying windows", function()
  local client, baseline = t.fixture({ { "a" }, { "b" } })
  local first, second = baseline.sessions[1], baseline.sessions[2]
  local desired = t.parse({
    t.session_line(first),
    t.window_line(second.windows[1]),
    t.session_line(second),
    t.window_line(first.windows[1]),
  }, baseline)
  local original_run, count = client.run, 0
  client.run = function(self, args)
    if args[1] == "unlink-window" then
      count = count + 1
      if count == 1 then
        return nil, "injected transfer failure"
      end
    end
    return original_run(self, args)
  end
  local actual, err, report =
    executor.execute(client, baseline, desired, planner.plan(baseline, desired))
  t.eq(actual, nil)
  t.contains(err, "injected transfer failure")
  t.eq(#report.cleanup, 2)
  t.eq(report.cleanup[1].error, nil)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test("real manager startup inherits its tmux server and cleans up on exit", function()
  local client, baseline = t.fixture({ { "work" } })
  local root = vim.fn.getcwd()
  local verify =
    [[local b=require('bosana'); local s=b.get_state(); assert(s); assert(#vim.api.nvim_buf_get_lines(0,0,-1,false)==2); assert(next(s.baseline.excluded)); assert(vim.system({'tmux','set-option','-g','@bosana-started','yes'}):wait().code==0)]]
  t.ok(client:run({
    "new-session",
    "-d",
    "-s",
    "bosana",
    "-n",
    "manager",
    "nvim",
    "--headless",
    "-u",
    "NONE",
    "--cmd",
    "lua vim.opt.runtimepath:prepend(" .. vim.inspect(root) .. ")",
    "-c",
    "runtime plugin/bosana.lua",
    "-c",
    "Bosana --manager",
    "-c",
    "lua " .. verify,
    "-c",
    "wq",
  }))
  t.ok(
    vim.wait(15000, function()
      local marker = client:run({ "show-options", "-gv", "@bosana-started" })
      local host = client:run({ "has-session", "-t", "=bosana" })
      return marker == "yes\n" and host == nil
    end, 50),
    "Manager did not start and clean up"
  )
  local actual = t.ok(client:snapshot())
  t.eq(#actual.sessions, 1)
  t.eq(actual.sessions[1].id, baseline.sessions[1].id)
end)
