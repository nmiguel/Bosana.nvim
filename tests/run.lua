vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
vim.cmd("runtime plugin/bosana.lua")

local t = require("tests.helpers")
local ok, err = xpcall(function()
  require("tests.unit")
  require("tests.integration")
  require("tests.buffer")
  require("tests.preview")
  require("tests.dependencies")
end, debug.traceback)
t.cleanup()
if not ok then
  print(err)
  vim.cmd("cquit 1")
end
print(string.format("\n%d tests, %d failures", t.total, #t.failures))
if #t.failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
