local t = require("tests.helpers")
local bosana = require("bosana")
local buffer = require("bosana.buffer")
local config = require("bosana.config")
local model = require("bosana.model")
local planner = require("bosana.planner")
local executor = require("bosana.executor")

local function fixture(names)
  local client, baseline, path = t.fixture(names or { { "a" } })
  t.ok(client:run({ "set-option", "-g", "default-command", "sleep 3600" }))
  return client, baseline, path
end

local function names(session)
  return vim.tbl_map(function(window)
    return window.name
  end, session.windows)
end

t.test(
  "new windows receive native IDs and replace the last window without losing the session",
  function()
    local client, baseline = fixture()
    local session = baseline.sessions[1]
    local actual, report = t.apply(client, baseline, { t.session_line(session), "    replacement" })
    t.eq(actual.sessions[1].id, session.id)
    t.eq(names(actual.sessions[1]), { "replacement" })
    t.eq(actual.by_window[session.windows[1].id], nil)
    t.eq(report.created.rows[2], actual.sessions[1].windows[1].id)
    t.eq(report.completed[1][1], "new-window")
    local _, noop = t.apply(client, actual, buffer.lines(actual))
    t.eq(noop.completed, {})
  end
)

t.test("a new session reuses its first explicit window and creates no extra windows", function()
  local client, baseline = fixture()
  local lines = buffer.lines(baseline)
  vim.list_extend(lines, { "new", "    first", "    second", "    first" })
  local actual, report = t.apply(client, baseline, lines)
  t.eq(names(actual.sessions[2]), { "first", "second", "first" })
  t.eq(report.created.rows[3], actual.sessions[2].id)
  t.eq(report.created.rows[4], actual.sessions[2].windows[1].id)
  for _, window in ipairs(actual.sessions[2].windows) do
    t.eq(client:run({ "show-options", "-wAv", "-t", window.id, "automatic-rename" }), "off\n")
  end
end)

t.test("a header-only new session retains tmux's default name and automatic renaming", function()
  local client, baseline = fixture()
  local lines = buffer.lines(baseline)
  lines[#lines + 1] = "default"
  local actual = t.apply(client, baseline, lines)
  local session = actual.sessions[2]
  t.eq(session.name, "default")
  t.eq(#session.windows, 1)
  t.ok(session.windows[1].name ~= "__bosana_bootstrap")
  t.contains(client:display(session.windows[1].id, "#{pane_start_command}"), "sleep 3600")
  t.eq(
    client:run({ "show-options", "-wAv", "-t", session.windows[1].id, "automatic-rename" }),
    "on\n"
  )
end)

t.test("new sessions accept mixed created and moved windows in buffer order", function()
  local client, baseline = fixture({ { "a", "b" }, { "c" } })
  local a, b, c =
    baseline.sessions[1].windows[1],
    baseline.sessions[1].windows[2],
    baseline.sessions[2].windows[1]
  local actual = t.apply(client, baseline, {
    "new",
    t.window_line(c, "moved-renamed"),
    "    created",
    t.window_line(a),
    "    another",
    t.session_line(baseline.sessions[1]),
    t.window_line(b),
  })
  local session = actual.sessions[2]
  t.eq(session.name, "new")
  t.eq(names(session), { "moved-renamed", "created", "a", "another" })
  t.eq(session.windows[1].id, c.id)
  t.eq(session.windows[3].id, a.id)
  t.eq(actual.by_session[baseline.sessions[2].id], nil)
end)

t.test(
  "moving all windows to a new session removes the bootstrap and preserves server identity",
  function()
    local client, baseline = fixture({ { "a" }, { "b" } })
    local a, b = baseline.sessions[1].windows[1], baseline.sessions[2].windows[1]
    local actual = t.apply(client, baseline, { "destination", t.window_line(b), t.window_line(a) })
    t.eq(#actual.sessions, 1)
    t.eq(actual.server_id, baseline.server_id)
    t.eq(model.window_ids(actual.sessions[1]), { b.id, a.id })
    t.eq(names(actual.sessions[1]), { "b", "a" })
    t.eq(actual.sessions[1].windows[1].index, 0)
    t.eq(actual.sessions[1].windows[2].index, 1)
  end
)

t.test("new sessions reuse deleted names and names freed by renames", function()
  local client, baseline = fixture({ { "a" }, { "b" } })
  local actual = t.apply(client, baseline, {
    t.session_line(baseline.sessions[1], "renamed"),
    t.window_line(baseline.sessions[1].windows[1]),
    "session1",
    "    new-one",
    "session2",
    "    new-two",
  })
  t.eq(actual.server_id, baseline.server_id)
  t.eq(actual.by_session[baseline.sessions[1].id].name, "renamed")
  t.eq(actual.by_session[baseline.sessions[2].id], nil)
  t.eq(actual.sessions[2].name, "session1")
  t.eq(actual.sessions[3].name, "session2")
end)

t.test("replacing every session creates replacements before destroying the old server", function()
  local client, baseline = fixture()
  local actual = t.apply(client, baseline, { "session1", "    replacement" })
  t.eq(#actual.sessions, 1)
  t.eq(actual.sessions[1].name, "session1")
  t.ok(actual.sessions[1].id ~= baseline.sessions[1].id)
  t.eq(actual.server_id, baseline.server_id)
end)

t.test(
  "creation names keep Unicode, leading dashes, and shell/format punctuation literal",
  function()
    local client, baseline = fixture()
    local marker = "/tmp/opencode/bosana-creation-marker-" .. vim.fn.getpid()
    local session = '-日本語 \\ #{window_name} ## "quotes" ; $(touch ' .. marker .. ")"
    local window = '-λ \\ #{session_name} ## "quotes" ; $(touch '
      .. marker
      .. ") #(touch "
      .. marker
      .. ")"
    local actual = t.apply(client, baseline, { session, "    " .. window, "    " .. window })
    t.eq(actual.sessions[1].name, session)
    t.eq(names(actual.sessions[1]), { window, window })
    t.eq(vim.fn.filereadable(marker), 0)
  end
)

t.test("new windows preserve existing index gaps and the active native ID", function()
  local client, baseline = fixture({ { "a", "b" } })
  local session = baseline.sessions[1]
  for i, index in ipairs({ 3, 7 }) do
    t.ok(client:run({
      "move-window",
      "-s",
      session.id .. ":" .. session.windows[i].id,
      "-t",
      session.id .. ":" .. index,
    }))
  end
  t.ok(client:run({ "select-window", "-t", session.windows[2].id }))
  baseline = t.ok(client:snapshot())
  session = baseline.sessions[1]
  local actual = t.apply(client, baseline, {
    t.session_line(session),
    t.window_line(session.windows[1]),
    "    middle",
    t.window_line(session.windows[2]),
  })
  t.eq(names(actual.sessions[1]), { "a", "middle", "b" })
  t.eq(
    vim.tbl_map(function(window)
      return window.index
    end, actual.sessions[1].windows),
    { 3, 7, 8 }
  )
  t.eq(actual.by_window[session.windows[2].id].active, true)
end)

t.test("mixed creation and transfers honor base-index and automatic renumbering", function()
  local client, baseline = fixture({ { "a", "b" } })
  t.ok(client:run({ "set-option", "-g", "base-index", "1" }))
  t.ok(client:run({ "set-option", "-g", "renumber-windows", "on" }))
  local actual = t.apply(client, baseline, {
    t.session_line(baseline.sessions[1]),
    "    replacement",
    t.window_line(baseline.sessions[1].windows[2]),
    "new",
    t.window_line(baseline.sessions[1].windows[1]),
    "    created",
  })
  for _, session in ipairs(actual.sessions) do
    t.eq(
      vim.tbl_map(function(window)
        return window.index
      end, session.windows),
      { 1, 2 }
    )
  end
  t.eq(names(actual.sessions[1]), { "replacement", "b" })
  t.eq(names(actual.sessions[2]), { "a", "created" })
end)

t.test("an empty Bosana view can start its selected server and save native IDs", function()
  local client = fixture()
  t.ok(client:run({ "kill-server" }))
  vim.list_extend(client.prefix, { "-f", "/dev/null" })
  local baseline = t.ok(client:snapshot())
  t.eq(baseline.server_id, false)
  local bufnr = buffer.create(client, baseline, config.get({ preview = false }), "empty-creation")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "    first", "two", "    second" })
  t.ok(bosana.save())
  local actual = t.ok(client:snapshot())
  t.ok(actual.server_id)
  t.eq(#actual.sessions, 2)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(actual))
  t.eq(bosana.get_state().last_report.server_id, actual.server_id)
  t.ok(bosana.save())
  t.eq(bosana.get_state().last_report.completed, {})
end)

t.test(
  "a server restarted after initial creation is not mutated by later creation operations",
  function()
    local client = fixture()
    t.ok(client:run({ "kill-server" }))
    vim.list_extend(client.prefix, { "-f", "/dev/null" })
    local baseline = t.ok(client:snapshot())
    local original_run, restarted = client.run, false
    client.run = function(self, args)
      local out, err = original_run(self, args)
      if args[1] == "new-session" and not restarted then
        restarted = true
        t.ok(original_run(self, { "kill-server" }))
        -- kill-server can return before the old socket has finished closing.
        t.ok(
          vim.wait(5000, function()
            return original_run(self, {
              "new-session",
              "-d",
              "-s",
              "foreign",
              "-n",
              "untouched",
              "sleep 3600",
            }) ~= nil
          end, 20),
          "Replacement test server did not start"
        )
      end
      return out, err
    end
    local desired = t.parse({ "new", "    first", "    second" }, baseline)
    local actual, err, report =
      executor.execute(client, baseline, desired, planner.plan(baseline, desired))
    t.eq(actual, nil)
    t.contains(err, "server changed")
    t.eq(#report.completed, 1)
    local foreign = t.ok(client:snapshot())
    t.eq(#foreign.sessions, 1)
    t.eq(foreign.sessions[1].name, "foreign")
    t.eq(names(foreign.sessions[1]), { "untouched" })
  end
)

t.test(
  "new names cannot collide with excluded sessions and excluded sessions are untouched",
  function()
    local client, baseline, path = fixture({ { "a" }, { "host" } })
    local host = baseline.sessions[2]
    local bufnr = t.ok(bosana.open({ socket_path = path, excluded_sessions = { host.id } }))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { host.name })
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "Duplicate session name")
    t.ok(model.same(t.ok(client:snapshot()), baseline))
    local lines = buffer.lines(bosana.get_state().baseline)
    lines[#lines + 1] = "created"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    t.ok(bosana.save())
    local actual = t.ok(client:snapshot())
    t.eq(actual.by_session[host.id], baseline.by_session[host.id])
  end
)

t.test(
  "partial creation failures retain created user windows and refresh for a no-op retry",
  function()
    local client, baseline = fixture()
    local original_run = client.run
    client.run = function(self, args)
      if args[1] == "new-window" then
        return nil, "injected creation failure"
      end
      return original_run(self, args)
    end
    local bufnr = buffer.create(client, baseline, config.get(), "creation-failure")
    local lines = buffer.lines(baseline)
    vim.list_extend(lines, { "new", "    first", "    second" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "injected creation failure")
    local actual = t.ok(client:snapshot())
    t.eq(#actual.sessions, 2)
    t.eq(names(actual.sessions[2]), { "first" })
    t.eq(bosana.get_state().last_report.created.rows[4], actual.sessions[2].windows[1].id)
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(actual))
    t.eq(bosana.get_state().blocked, false)
    client.run = original_run
    t.ok(bosana.save())
    t.eq(bosana.get_state().last_report.completed, {})
  end
)

t.test(
  "failed new-destination transfers clean up both links and disposable bootstrap windows",
  function()
    for _, fail_kind in ipairs({ "link-window", "unlink-window" }) do
      local client, baseline = fixture()
      local desired = t.parse({ "new", t.window_line(baseline.sessions[1].windows[1]) }, baseline)
      local original_run, failed = client.run, false
      client.run = function(self, args)
        if args[1] == fail_kind and not failed then
          failed = true
          return nil, "injected transfer failure"
        end
        return original_run(self, args)
      end
      local actual, err, report =
        executor.execute(client, baseline, desired, planner.plan(baseline, desired))
      t.eq(actual, nil)
      t.contains(err, "injected transfer failure")
      t.ok(#report.cleanup > 0)
      t.ok(model.same(t.ok(client:snapshot()), baseline))
    end
  end
)

t.test("unavailable recovery blocks replaying partial window creations until refresh", function()
  local client, baseline = fixture()
  local original_run, original_snapshot = client.run, client.snapshot
  local count, failed = 0, false
  client.run = function(self, args)
    if args[1] == "new-window" then
      count = count + 1
      if count == 2 then
        failed = true
        return nil, "injected creation failure"
      end
    end
    return original_run(self, args)
  end
  client.snapshot = function(self, excluded)
    if failed then
      return nil, "injected recovery failure"
    end
    return original_snapshot(self, excluded)
  end
  local bufnr = buffer.create(client, baseline, config.get(), "creation-blocked")
  local lines = buffer.lines(baseline)
  vim.list_extend(lines, { "    first", "    second" })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local success = bosana.save()
  t.eq(success, nil)
  t.eq(bosana.get_state().blocked, true)
  t.eq(bosana.save(), nil)
  t.eq(count, 2)
  failed = false
  t.ok(bosana.refresh({ force = true }))
  t.eq(names(bosana.get_state().baseline.sessions[1]), { "a", "first" })
  t.ok(bosana.save())
  t.eq(count, 2)
end)

t.test(
  "bootstrap replacement cannot destroy an externally replaced window in the same slot",
  function()
    local client, baseline = fixture()
    local source = baseline.sessions[1].windows[1]
    local original_run, replaced = client.run, false
    client.run = function(self, args)
      if args[1] == "link-window" and not replaced then
        replaced = true
        local destination = t.ok(args[#args]:match("^(%$%d+):"))
        t.ok(original_run(self, {
          "new-window",
          "-d",
          "-k",
          "-t",
          destination .. ":0",
          "-n",
          "external",
          "sleep 3600",
        }))
      end
      return original_run(self, args)
    end
    local desired = t.parse({ "new", t.window_line(source) }, baseline)
    local actual = executor.execute(client, baseline, desired, planner.plan(baseline, desired))
    t.eq(actual, nil)
    actual = t.ok(client:snapshot())
    t.eq(#actual.sessions, 2)
    t.eq(actual.by_window[source.id].session_id, baseline.sessions[1].id)
    t.eq(names(actual.sessions[2]), { "external" })
  end
)
