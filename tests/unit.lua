local t = require("tests.helpers")
local buffer = require("bosana.buffer")
local parser = require("bosana.parser")
local planner = require("bosana.planner")
local model = require("bosana.model")

t.test("removing a session block plans session deletion", function()
  local baseline = t.baseline()
  local desired = t.parse({ "/$1 one", "/@1     a", "/@2     b", "/@3     c" }, baseline)
  t.eq(planner.plan(baseline, desired), { { kind = "kill_session", id = "$2" } })
end)

t.test("moving a window between sessions plans a transfer", function()
  local baseline = t.baseline()
  local desired = t.parse({
    "/$1 one",
    "/@1     a",
    "/@2     b",
    "/@3     c",
    "/@4     d",
    "/$2 two",
    "/@5     e",
    "/@6     f",
  }, baseline)
  local operations = planner.plan(baseline, desired)
  t.eq(operations[1], { kind = "link_window", id = "@4", source = "$2", destination = "$1" })
  t.eq(operations[2], { kind = "unlink_window", id = "@4", session = "$2" })
  t.eq(desired.by_window["@4"].session_id, "$1")
end)

t.test("reordering window rows plans relative window order", function()
  local baseline = t.baseline()
  local desired = t.parse({
    "/$1 one",
    "/@1     a",
    "/@2     b",
    "/@3     c",
    "/$2 two",
    "/@5     e",
    "/@6     f",
    "/@4     d",
  }, baseline)
  t.eq(
    planner.plan(baseline, desired),
    { { kind = "reorder_session", id = "$2", windows = { "@5", "@6", "@4" } } }
  )
end)

t.test("duplicate window IDs report the offending line", function()
  local baseline = t.baseline()
  local lines = buffer.lines(baseline)
  table.insert(lines, 6, lines[6])
  local desired, errors = parser.parse(lines, baseline)
  t.eq(desired, nil)
  t.contains(errors[1].message, "Duplicate ID @4")
  t.eq(errors[1].lnum, 6)
end)

t.test("removing a window row plans deletion in its owning session", function()
  local baseline = t.baseline()
  local lines = buffer.lines(baseline)
  table.remove(lines, 6)
  local desired = t.parse(lines, baseline)
  t.eq(planner.plan(baseline, desired)[1], { kind = "kill_window", id = "@4", session = "$2" })
end)

t.test("no-op and session-header ordering produce no commands", function()
  local baseline = t.baseline()
  t.eq(planner.plan(baseline, t.parse(buffer.lines(baseline), baseline)), {})
  local desired = t.parse({
    "/$2 two",
    "/@4     d",
    "/@5     e",
    "/@6     f",
    "/$1 one",
    "/@1     a",
    "/@2     b",
    "/@3     c",
  }, baseline)
  t.eq(planner.plan(baseline, desired), {})
end)

t.test("empty headers and blank buffers delete sessions", function()
  local baseline = t.baseline()
  t.eq(#t.parse({ "/$1 one", "/$2 two", "" }, baseline).sessions, 0)
  t.eq(#planner.plan(baseline, t.parse({ "" }, baseline)), 2)
end)

t.test("renames are identity-based and duplicate window names are valid", function()
  local baseline = t.baseline()
  local lines = buffer.lines(baseline)
  lines[2], lines[3] = "/@1     same", "/@2     same"
  local desired = t.parse(lines, baseline)
  local operations = planner.plan(baseline, desired)
  t.eq(#operations, 2)
  t.eq(operations[1].kind, "rename_window")
end)

t.test("session name swaps use temporary names before final names", function()
  local baseline = t.baseline()
  local lines = buffer.lines(baseline)
  lines[1], lines[5] = "/$1 two", "/$2 one"
  local operations = planner.plan(baseline, t.parse(lines, baseline))
  t.eq(#operations, 4)
  t.ok(operations[1].name:match("^__bosana_"))
  t.ok(operations[2].name:match("^__bosana_"))
  t.eq(operations[3].name, "two")
  t.eq(operations[4].name, "one")
end)

t.test("invalid edits report diagnostics", function()
  local cases = {
    { { "new session" }, "missing ID" },
    { { "/$99 unknown" }, "Unknown ID" },
    { { "/@1     a" }, "beneath a session" },
    { { "/$1 one", "/@1   a" }, "four spaces" },
    { { "/$1 one", "/@1         a" }, "four spaces" },
    { { "/$1  one" }, "unindented" },
    { { "/$1 bad:name" }, "cannot contain" },
    { { "/$1 one", "/@1     " }, "empty" },
    { { "/$1 one", "/@1     a\tb" }, "control characters" },
    { { "/$1 one", "/@1     a " }, "whitespace" },
    { { "/$1 one", "/@1     a", "/$2 one", "/@4     d" }, "Duplicate session name" },
    { { "/$1 one", "/@1     a", "/$1 one" }, "Duplicate ID" },
  }
  for _, case in ipairs(cases) do
    local desired, errors = parser.parse(case[1], t.baseline())
    t.eq(desired, nil)
    t.contains(errors[1].message, case[2])
  end
end)

t.test("exclusions are absent from rendering and all mutation plans", function()
  local baseline = t.baseline()
  baseline.excluded["$2"] = true
  t.eq(#buffer.lines(baseline), 4)
  t.eq(planner.plan(baseline, t.parse({ "" }, baseline)), { { kind = "kill_session", id = "$1" } })
  local desired, errors = parser.parse({ "/$2 two", "/@4     d" }, baseline)
  t.eq(desired, nil)
  t.contains(errors[1].message, "excluded session")
  desired, errors = parser.parse({ "/$1 two", "/@1     a" }, baseline)
  t.eq(desired, nil)
  t.contains(errors[1].message, "Duplicate session name")
end)

t.test("state comparisons ignore navigation but detect indices and server restarts", function()
  local baseline = t.baseline()
  local current = vim.deepcopy(baseline)
  current.sessions[1].windows[1].active = true
  t.ok(model.same(baseline, current))
  current.sessions[1].windows[1].index = 8
  t.eq(model.same(baseline, current), false)
  current = vim.deepcopy(baseline)
  current.server_id = "another-server"
  t.eq(model.same(baseline, current), false)
end)

t.test("every destination link precedes all source unlinks", function()
  local baseline = t.baseline()
  local desired = t.parse({
    "/$1 one",
    "/@4     d",
    "/@5     e",
    "/@6     f",
    "/$2 two",
    "/@1     a",
    "/@2     b",
    "/@3     c",
  }, baseline)
  local operations = planner.plan(baseline, desired)
  for i = 1, 6 do
    t.eq(operations[i].kind, "link_window")
  end
  for i = 7, 12 do
    t.eq(operations[i].kind, "unlink_window")
  end
end)
