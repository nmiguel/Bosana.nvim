local t = require("tests.helpers")
local bosana = require("bosana")
local buffer = require("bosana.buffer")
local model = require("bosana.model")
local confirmation = require("bosana.confirmation")

local function with_confirm(answer, callback)
  local original = vim.fn.confirm
  local prompts = {}
  vim.fn.confirm = function(message, buttons, default)
    prompts[#prompts + 1] = { message = message, buttons = buttons, default = default }
    return type(answer) == "function" and answer() or answer
  end
  local ok, err = xpcall(function()
    callback(prompts)
  end, debug.traceback)
  vim.fn.confirm = original
  t.ok(ok, err)
end

local function open(path, opts)
  return t.ok(
    bosana.open(vim.tbl_extend("force", { socket_path = path, confirm = true }, opts or {}))
  )
end

t.test("capitalized module inference resolves to the same public API", function()
  t.eq(require("Bosana"), bosana)
  require("Bosana").setup({ confirm = false, icons = false })
  t.eq(require("bosana.config").get().icons, false)
end)

t.test("icons follow linewise edits and undo without entering names", function()
  local _, baseline, path = t.fixture()
  local bufnr = open(path, { icons = { session = "S", window = "W" } })
  local original = buffer.lines(baseline)
  local function check_icons()
    t.ok(
      vim.wait(1000, function()
        return not buffer.get(bufnr).icons_pending
      end, 10),
      "Icons did not update after editing"
    )
    local ns = vim.api.nvim_get_namespaces()["bosana.icons"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    t.eq(#marks, #lines)
    for i, mark in ipairs(marks) do
      local prefix = t.ok(lines[i]:match("^/[%$@]%d+ "))
      local session = lines[i]:sub(2, 2) == "$"
      t.eq(mark[2], i - 1)
      t.eq(mark[3], #prefix + (session and 0 or 4))
      t.eq(mark[4].virt_text[1][1], session and "S " or "W ")
      t.eq(mark[4].virt_text_pos, "inline")
    end
  end
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
  check_icons()
  vim.cmd("normal! 2GddGp")
  check_icons()
  local edited = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  t.eq(t.parse(edited, baseline).by_window[baseline.sessions[1].windows[1].id].name, "a")
  vim.cmd("normal! u")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
  check_icons()
end)

t.test("icons can be disabled and icon/confirmation configuration is validated", function()
  local _, _, path = t.fixture({ { "a" } })
  local bufnr = open(path, { icons = false })
  local ns = vim.api.nvim_get_namespaces()["bosana.icons"]
  t.eq(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}), {})
  for _, opts in ipairs({
    { icons = true },
    { icons = { window = 1 } },
    { icons = { session = "\n" } },
    { icons = { pane = "P" } },
    { confirm = "yes" },
  }) do
    local success = pcall(bosana.setup, opts)
    t.eq(success, false)
  end
end)

t.test("switch rejects unknown rows without changing the buffer", function()
  local _, _, path = t.fixture({ { "a" } })
  local bufnr = open(path, { preview = false })
  for _, line in ipairs({ "", "/@999999     unknown", "/$999999 unknown" }) do
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    local success, err = bosana.switch()
    t.eq(success, nil)
    t.contains(err, "not a known tmux session or window")
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { line })
  end
end)

t.test("Enter mapping can be disabled or remapped", function()
  local _, _, path = t.fixture({ { "a" } })
  open(path, { keymaps = { ["<CR>"] = false, s = "switch" } })
  t.eq(vim.fn.maparg("<CR>", "n"), "")
  t.eq(vim.fn.maparg("s", "n", false, true).desc, "Bosana: switch")
end)

t.test("confirmation summarizes logical changes without temporary commands", function()
  local baseline = t.baseline()
  local desired = t.parse({
    "/$1 renamed",
    "/@3     c",
    "/@1     renamed-a",
    "/@4     d",
    "/$2 two",
    "/@5     e",
    "/@6     f",
  }, baseline)
  local actions = confirmation.actions(baseline, desired)
  t.eq(#actions, 5)
  local text = table.concat(actions, "\n")
  t.contains(text, 'Delete window "b" (@2)')
  t.contains(text, 'Move window "d" (@4) from "two" ($2) to "renamed" ($1) at position 3')
  t.contains(text, 'Rename session "one" ($1) to "renamed"')
  t.contains(text, 'Rename window "a" (@1) in "renamed" ($1) to "renamed-a"')
  t.contains(text, 'Reorder windows in session "renamed" ($1)')
  t.eq(text:find("__bosana_", 1, true), nil)
  local deleted =
    t.parse({ "/$1 one", "/@1     a", "/@2     b", "/@3     c", "/@4     d" }, baseline)
  local deletion = confirmation.actions(baseline, deleted)
  t.eq(#deletion, 2)
  t.contains(deletion[2], 'Delete session "two" ($2) (2 remaining windows)')
end)

t.test("confirmation shows five actions and counts the remainder", function()
  local baseline = t.baseline()
  local lines = buffer.lines(baseline)
  for i, line in ipairs(lines) do
    lines[i] = line .. "-renamed"
  end
  local desired = t.parse(lines, baseline)
  t.eq(#confirmation.actions(baseline, desired), 8)
  local message = confirmation.message(baseline, desired)
  t.eq(#vim.split(message, "\n", { plain = true }), 7)
  t.contains(message, "… and 3 more actions")
  t.eq(message:find('Rename window "f"', 1, true), nil)
end)

t.test(
  "creation confirmation describes default windows and moves without temporary references",
  function()
    local baseline = t.baseline()
    local lines = buffer.lines(baseline)
    local moved = table.remove(lines, 2)
    vim.list_extend(lines, { "new", "    created", moved, "default" })
    local actions = table.concat(confirmation.actions(baseline, t.parse(lines, baseline)), "\n")
    t.contains(actions, 'Create session "new"')
    t.contains(actions, 'Create window "created" in session "new" (new) at position 1')
    t.contains(actions, 'Move window "a" (@1) from "one" ($1) to "new" (new) at position 2')
    t.contains(actions, 'Create session "default" with a default window')
    t.eq(actions:find("__bosana_", 1, true), nil)
    t.eq(actions:find("new-session:", 1, true), nil)
    t.eq(actions:find("new-window:", 1, true), nil)
  end
)

t.test("declining creation keeps ID-less rows and affirmative retry creates them once", function()
  local client, baseline, path = t.fixture({ { "a" } })
  t.ok(client:run({ "set-option", "-g", "default-command", "sleep 3600" }))
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  vim.list_extend(lines, { "    terminal", "new", "    shell" })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  with_confirm(2, function(prompts)
    t.eq(bosana.save(), nil)
    t.contains(prompts[1].message, 'Create window "terminal"')
    t.eq(bosana.get_state().last_report.attempted, false)
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
    t.ok(vim.bo[bufnr].modified)
    t.ok(model.same(t.ok(client:snapshot()), baseline))
  end)
  with_confirm(1, function()
    t.ok(bosana.save())
  end)
  local actual = t.ok(client:snapshot())
  t.eq(#actual.sessions, 2)
  t.eq(#actual.sessions[1].windows, 2)
  t.eq(#actual.sessions[2].windows, 1)
  with_confirm(function()
    error("A second save must not prompt or create duplicates")
  end, function()
    t.ok(bosana.save())
  end)
  t.ok(model.same(t.ok(client:snapshot()), actual))
end)

t.test("creation is rejected before mutation when tmux changes during confirmation", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[#lines + 1] = "    pending"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  with_confirm(function()
    t.ok(client:run({ "rename-window", "-t", baseline.sessions[1].windows[1].id, "external" }))
    return 1
  end, function()
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "tmux state changed while confirming")
    t.eq(bosana.get_state().last_report.attempted, false)
  end)
  local actual = t.ok(client:snapshot())
  t.eq(#actual.sessions[1].windows, 1)
  t.eq(actual.sessions[1].windows[1].name, "external")
end)

t.test(
  "pending rows show icons, support undo, and follow their new native ID after saving",
  function()
    local client, baseline, path = t.fixture({ { "a" } })
    t.ok(client:run({ "set-option", "-g", "default-command", "sleep 3600" }))
    local bufnr = open(path, { confirm = false, preview = false })
    local lines = { "new", "    created" }
    vim.list_extend(lines, buffer.lines(baseline))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    t.ok(vim.wait(1000, function()
      return not buffer.get(bufnr).icons_pending
    end, 10))
    local ns = vim.api.nvim_get_namespaces()["bosana.icons"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    t.eq(#marks, 4)
    t.eq({ marks[1][2], marks[1][3] }, { 0, 0 })
    t.eq({ marks[2][2], marks[2][3] }, { 1, 4 })
    t.eq(marks[1][4].virt_text[1][1], "▣ ")
    t.eq(marks[2][4].virt_text[1][1], "▤ ")
    t.eq(vim.fn.synIDattr(vim.fn.synID(1, 1, 1), "name"), "BosanaSession")
    t.eq(vim.fn.synconcealed(1, 1)[1], 0)
    vim.cmd("normal! u")
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(baseline))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 2, 4 })
    local success, err = bosana.switch()
    t.eq(success, nil)
    t.contains(err, "save with :w")
    t.ok(model.same(t.ok(client:snapshot()), baseline))
    t.ok(bosana.save())
    local id = bosana.get_state().last_report.created.rows[2]
    t.eq(vim.api.nvim_get_current_line():match("^/(@%d+) "), id)
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 4)
    local saved = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.cmd("normal! u")
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), saved)
  end
)

t.test("declining a save retains edits and allows an immediate confirmed retry", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[2] = t.window_line(baseline.sessions[1].windows[1], "confirmed")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  with_confirm(2, function(prompts)
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "Write cancelled")
    t.eq(#prompts, 1)
    t.eq(prompts[1].buttons, "&Yes\n&No")
    t.eq(prompts[1].default, 2)
    t.contains(prompts[1].message, 'Rename window "a"')
    t.ok(vim.bo[bufnr].modified)
    t.ok(vim.bo[bufnr].modifiable)
    t.eq(bosana.get_state().blocked, false)
    t.eq(bosana.get_state().last_report.attempted, false)
    t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
    t.ok(model.same(t.ok(client:snapshot()), baseline))
  end)
  with_confirm(1, function(prompts)
    t.ok(bosana.save())
    t.eq(#prompts, 1)
  end)
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "confirmed")
  t.eq(vim.bo[bufnr].modified, false)
end)

t.test("no-op, invalid, and stale writes do not prompt", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  with_confirm(function()
    error("This write should not show a confirmation")
  end, function(prompts)
    t.ok(bosana.save())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/@oops malformed" })
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "Invalid edits")
    local lines = buffer.lines(baseline)
    lines[2] = t.window_line(baseline.sessions[1].windows[1], "pending")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    t.ok(client:run({ "rename-window", "-t", baseline.sessions[1].id .. ":", "external" }))
    success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "tmux state changed")
    t.eq(#prompts, 0)
    t.eq(bosana.get_state().blocked, false)
  end)
end)

t.test("tmux changes during confirmation prevent all planned mutations", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[2] = t.window_line(baseline.sessions[1].windows[1], "pending")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  with_confirm(function()
    t.ok(client:run({ "rename-window", "-t", baseline.sessions[1].id .. ":", "external" }))
    return 1
  end, function()
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "tmux state changed while confirming")
    t.eq(bosana.get_state().last_report.attempted, false)
    t.eq(bosana.get_state().blocked, false)
  end)
  t.eq(t.ok(client:snapshot()).sessions[1].windows[1].name, "external")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(t.ok(client:snapshot())))
  t.eq(vim.bo[bufnr].modified, false)
end)

t.test("interrupted confirmation keeps the write retryable", function()
  local _, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {
    t.window_line(baseline.sessions[1].windows[1], "pending"),
  })
  with_confirm(function()
    error("Vim:Interrupt")
  end, function()
    local success, err = bosana.save()
    t.eq(success, nil)
    t.contains(err, "Interrupt")
    t.eq(bosana.get_state().blocked, false)
    t.eq(bosana.get_state().last_report.attempted, false)
    t.ok(vim.bo[bufnr].modified)
    t.ok(vim.bo[bufnr].modifiable)
  end)
end)

t.test(":e! discards edits and loads external tmux changes with host exclusions intact", function()
  local client, baseline, path = t.fixture()
  local bufnr = open(path, { excluded_sessions = { baseline.sessions[2].id } })
  local first = baseline.sessions[1]
  vim.api.nvim_win_set_cursor(0, { 3, 8 })
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { t.window_line(first.windows[1], "pending") })
  t.ok(client:run({ "rename-window", "-t", first.id .. ":" .. first.windows[2].id, "external" }))
  t.ok(client:run({ "new-window", "-d", "-t", first.id .. ":", "-n", "new", "sleep 3600" }))
  local current = t.ok(client:snapshot({ [baseline.sessions[2].id] = true }))
  vim.cmd("edit!")
  t.eq(vim.api.nvim_get_current_buf(), bufnr)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(current))
  t.ok(model.same(bosana.get_state().baseline, current))
  t.eq(vim.bo[bufnr].modified, false)
  t.eq(bosana.get_state().blocked, false)
  t.eq(vim.api.nvim_win_get_cursor(0)[1], 3)
  t.eq(vim.bo[bufnr].buftype, "acwrite")
  t.eq(vim.bo[bufnr].buflisted, false)
  t.eq(vim.bo[bufnr].filetype, "bosana")
  t.eq(vim.fn.synconcealed(1, 1)[1], 1)
  vim.cmd("normal! u")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), buffer.lines(current))
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {
    t.session_line(current.sessions[1], "pending-after-reload"),
  })
  t.ok(vim.wait(1000, function()
    return not buffer.get(bufnr).icons_pending
  end, 10))
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    vim.api.nvim_get_namespaces()["bosana.icons"],
    0,
    -1,
    { details = true }
  )
  t.eq(#marks, #buffer.lines(current))
  t.eq(marks[1][2], 0)
  t.eq(marks[1][3], #("/" .. first.id .. " "))
  t.eq(marks[1][4].virt_text[1][1], "▣ ")
end)

t.test(":edit protects unsaved changes and failed :e! retains the edited buffer", function()
  local _, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  local lines = buffer.lines(baseline)
  lines[2] = t.window_line(baseline.sessions[1].windows[1], "pending")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local success = pcall(vim.cmd, "edit")
  t.eq(success, false)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
  local original_path = vim.env.PATH
  vim.env.PATH = ""
  local err
  success, err = pcall(vim.cmd, "edit!")
  vim.env.PATH = original_path
  t.eq(success, false)
  t.contains(err, "Bosana: Could not refresh tmux sessions.")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
  t.ok(vim.bo[bufnr].modified)
  t.ok(model.same(bosana.get_state().baseline, baseline))
  t.eq(vim.fn.synconcealed(1, 1)[1], 1)
end)

t.test(":e! clears partial-failure recovery blocking", function()
  local client, baseline, path = t.fixture({ { "a" } })
  local bufnr = open(path)
  buffer.get(bufnr).blocked = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "pending edits" })
  t.ok(client:run({ "rename-window", "-t", baseline.sessions[1].id .. ":", "external" }))
  vim.cmd("edit!")
  t.eq(bosana.get_state().blocked, false)
  t.eq(bosana.get_state().baseline.sessions[1].windows[1].name, "external")
  with_confirm(function()
    error("A refreshed no-op write must not prompt")
  end, function()
    t.ok(bosana.save())
  end)
end)
