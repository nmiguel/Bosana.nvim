local model = require("bosana.model")
local parser = require("bosana.parser")
local planner = require("bosana.planner")
local executor = require("bosana.executor")
local tmux = require("bosana.tmux")
local M = { total = 0, failures = {}, fixtures = {} }

function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "Values differ")
        .. "\nexpected: "
        .. vim.inspect(expected)
        .. "\nactual: "
        .. vim.inspect(actual),
      2
    )
  end
end

function M.ok(value, err)
  if not value then
    error(err or "Expected a truthy value", 2)
  end
  return value
end

function M.contains(value, expected)
  M.ok(
    type(value) == "string" and value:find(expected, 1, true),
    "Expected '" .. tostring(value) .. "' to contain '" .. expected .. "'"
  )
end

function M.test(name, callback)
  M.total = M.total + 1
  local ok, err = xpcall(callback, debug.traceback)
  M.cleanup()
  if ok then
    print("PASS " .. name)
  else
    M.failures[#M.failures + 1] = { name = name, error = err }
    print("FAIL " .. name .. "\n" .. err)
  end
end

function M.cleanup()
  for _, client in ipairs(M.fixtures) do
    client:run({ "kill-server" })
    vim.fn.delete(client.prefix[3])
  end
  M.fixtures = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "bosana" then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  require("bosana").setup({})
end

function M.baseline()
  return model.index({
    server_id = "test-server",
    sessions = {
      {
        id = "$1",
        name = "one",
        windows = {
          { id = "@1", name = "a", index = 0 },
          { id = "@2", name = "b", index = 1 },
          { id = "@3", name = "c", index = 2 },
        },
      },
      {
        id = "$2",
        name = "two",
        windows = {
          { id = "@4", name = "d", index = 0 },
          { id = "@5", name = "e", index = 1 },
          { id = "@6", name = "f", index = 2 },
        },
      },
    },
  })
end

function M.parse(lines, baseline)
  local desired, errors = parser.parse(lines, baseline)
  return M.ok(desired, vim.inspect(errors))
end

function M.fixture(names)
  M.fixture_serial = (M.fixture_serial or 0) + 1
  local path = "/tmp/opencode/bosana-tests-"
    .. vim.fn.getpid()
    .. "-"
    .. M.total
    .. "-"
    .. M.fixture_serial
    .. ".sock"
  local client = tmux.new({ socket_path = path })
  M.fixtures[#M.fixtures + 1] = client
  for i, windows in ipairs(names or { { "a", "b", "c" }, { "d", "e", "f" } }) do
    local session = "session" .. i
    M.ok(client:run({
      "-f",
      "/dev/null",
      "new-session",
      "-d",
      "-s",
      session,
      "-n",
      windows[1],
      "sleep 3600",
    }))
    M.ok(
      client:run({ "set-window-option", "-t", "=" .. session .. ":", "automatic-rename", "off" })
    )
    M.ok(client:run({ "set-window-option", "-t", "=" .. session .. ":", "allow-rename", "off" }))
    for j = 2, #windows do
      M.ok(client:run({
        "new-window",
        "-d",
        "-t",
        "=" .. session .. ":",
        "-n",
        windows[j],
        "sleep 3600",
      }))
    end
  end
  local snapshot, err = client:snapshot()
  M.ok(snapshot, err)
  return client, snapshot, path
end

function M.apply(client, baseline, lines)
  local desired = M.parse(lines, baseline)
  local actual, err, report =
    executor.execute(client, baseline, desired, planner.plan(baseline, desired))
  M.ok(actual, (err or "") .. "\n" .. vim.inspect(report))
  return actual, report
end

function M.session_line(session, name)
  return "/" .. session.id .. " " .. (name or session.name)
end

function M.window_line(window, name)
  return "/" .. window.id .. "     " .. (name or window.name)
end

return M
