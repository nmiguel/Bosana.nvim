local t = require("tests.helpers")
local bosana = require("bosana")
local buffer = require("bosana.buffer")
local model = require("bosana.model")
local tmux = require("bosana.tmux")
local health = require("bosana.health")

local function with_value(object, key, value, callback)
  local original = object[key]
  object[key] = value
  local ok, result = xpcall(callback, debug.traceback)
  object[key] = original
  t.ok(ok, result)
  return result
end

local function health_report()
  local messages, reporter = {}, {}
  for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
    reporter[kind] = function(message)
      messages[#messages + 1] = { kind = kind, message = message }
    end
  end
  with_value(vim, "health", reporter, health.check)
  return messages
end

local function report_text(messages, kind)
  local lines = {}
  for _, message in ipairs(messages) do
    if not kind or kind == message.kind then
      lines[#lines + 1] = message.message
    end
  end
  return table.concat(lines, "\n")
end

t.test("missing tmux on PATH prevents spawning and reports an actionable command error", function()
  with_value(vim.env, "PATH", "", function()
    with_value(vim, "system", function()
      error("A process must not be spawned when tmux is missing")
    end, function()
      local out, err = tmux.new({}):run({ "-V" })
      t.eq(out, nil)
      t.contains(err, "tmux executable 'tmux' was not found in PATH")
      t.contains(err, "Install tmux")
      local bufnr
      bufnr, err = bosana.open()
      t.eq(bufnr, nil)
      t.contains(err, "tmux executable 'tmux' was not found in PATH")
      local success, command_err = pcall(vim.cmd, "Bosana")
      t.eq(success, false)
      t.contains(command_err, "Bosana: tmux executable 'tmux' was not found in PATH")
    end)
  end)
end)

t.test("missing or nonexecutable configured tmux paths report explicit errors", function()
  local missing = "/tmp/opencode/bosana-missing-tmux-" .. vim.fn.getpid()
  local bufnr, err = bosana.open({ tmux = missing })
  t.eq(bufnr, nil)
  t.contains(err, "tmux executable '" .. missing .. "' does not exist or is not executable")
  t.contains(err, "configure Bosana's tmux option")
  local out
  out, err = tmux.new({ tmux = "/tmp/opencode" }):run({ "-V" })
  t.eq(out, nil)
  t.contains(err, "does not exist or is not executable")
end)

t.test("an absolute tmux executable works even when PATH is empty", function()
  local executable = t.ok(tmux.check_executable("tmux"))
  with_value(vim.env, "PATH", "", function()
    local version, err = tmux.new({ tmux = executable }):run({ "-V" })
    t.ok(version, err)
    t.contains(version, "tmux ")
  end)
end)

t.test("losing tmux after opening rejects writes and refresh without losing edits", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = t.ok(bosana.open({ socket_path = path }))
  local lines = buffer.lines(baseline)
  lines[2] = t.window_line(baseline.sessions[1].windows[1], "pending")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  with_value(vim.env, "PATH", "", function()
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "was not found in PATH")
    t.eq(bosana.get_state().last_report.attempted, false)
    t.eq(bosana.get_state().blocked, false)
    t.ok(vim.bo[bufnr].modified)
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
    success, err = bosana.refresh({ force = true })
    t.eq(success, nil)
    t.contains(err, "was not found in PATH")
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
  end)
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test("health reports dependencies and server access without mutations", function()
  local client, baseline, path = t.fixture({ { "a" } })
  bosana.setup({ socket_path = path })
  local messages = health_report()
  t.eq(report_text(messages, "error"), "")
  local text = report_text(messages)
  t.contains(text, "Neovim 0.10+")
  t.contains(text, "configuration is valid")
  t.contains(text, "tmux executable: " .. vim.fn.exepath("tmux"))
  t.contains(text, "tmux ")
  t.contains(text, "socket path " .. path)
  t.contains(text, "1 editable sessions, 1 windows")
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)

t.test("health reports missing tmux before attempting any process", function()
  with_value(vim.env, "PATH", "", function()
    with_value(vim, "system", function()
      error("Health must not spawn a missing executable")
    end, function()
      local messages = health_report()
      t.contains(report_text(messages, "error"), "tmux executable 'tmux' was not found in PATH")
      t.eq(#vim.tbl_filter(function(message)
        return message.kind == "error"
      end, messages), 1)
    end)
  end)
end)

t.test("health treats an empty server as informational and does not start it", function()
  local path = "/tmp/opencode/bosana-health-empty-" .. vim.fn.getpid() .. ".sock"
  bosana.setup({ socket_path = path })
  local messages = health_report()
  t.eq(report_text(messages, "error"), "")
  t.contains(report_text(messages, "info"), "No sessions are running")
  t.eq((vim.uv or vim.loop).fs_stat(path), nil)
end)

t.test("health reports unsupported linked-window topology", function()
  local client, baseline, path = t.fixture({ { "a" }, { "b" } })
  local source, destination = baseline.sessions[1], baseline.sessions[2]
  t.ok(client:run({
    "link-window",
    "-d",
    "-s",
    source.id .. ":" .. source.windows[1].id,
    "-t",
    destination.id .. ":9",
  }))
  bosana.setup({ socket_path = path })
  local before =
    t.ok(client:run({ "list-windows", "-a", "-F", "#{session_id}:#{window_id}:#{window_index}" }))
  t.contains(report_text(health_report(), "error"), "Linked/shared windows")
  t.eq(
    client:run({ "list-windows", "-a", "-F", "#{session_id}:#{window_id}:#{window_index}" }),
    before
  )
end)

t.test("both lowercase and capitalized checkhealth commands discover Bosana", function()
  local _, _, path = t.fixture({ { "a" } })
  bosana.setup({ socket_path = path })
  for _, name in ipairs({ "bosana", "Bosana" }) do
    vim.cmd("checkhealth " .. name)
    local bufnr = vim.api.nvim_get_current_buf()
    -- Newer Neovim versions render health reports asynchronously.
    t.ok(
      vim.wait(15000, function()
        return vim.api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modifiable
      end, 10),
      "Health check did not finish"
    )
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    t.contains(text, "Bosana")
    t.contains(text, "tmux executable:")
    t.contains(text, "Selected server is readable")
    t.eq(text:find("ERROR", 1, true), nil)
  end
end)

t.test("health checks manager host exclusion without changing its lifecycle options", function()
  local client, baseline, path = t.fixture({ { "work" }, { "manager" } })
  local host = baseline.sessions[2]
  local target = host.id .. ":" .. host.windows[1].id
  local pane = t.ok(client:display(target, "#{pane_id}"))
  t.ok(client:run({ "set-option", "-t", host.id, "detach-on-destroy", "on" }))
  t.ok(client:run({ "set-window-option", "-t", target, "remain-on-exit", "on" }))
  bosana.setup({ socket_path = path, manager = true })
  with_value(vim.env, "TMUX", path .. "," .. baseline.server_id:match("^(%d+)") .. ",0", function()
    with_value(vim.env, "TMUX_PANE", pane, function()
      local messages = health_report()
      t.eq(report_text(messages, "error"), "")
      t.contains(report_text(messages, "ok"), "Hosting session resolved and excluded: " .. host.id)
      t.contains(report_text(messages, "ok"), "1 editable sessions, 1 windows")
    end)
  end)
  t.eq(client:run({ "show-options", "-v", "-t", host.id, "detach-on-destroy" }), "on\n")
  t.eq(client:run({ "show-options", "-w", "-v", "-t", target, "remain-on-exit" }), "on\n")
  t.ok(model.same(t.ok(client:snapshot()), baseline))
end)
