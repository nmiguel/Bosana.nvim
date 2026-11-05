local t = require("tests.helpers")

t.test("Lua module paths are lowercase for case-insensitive filesystems", function()
  for path in vim.fs.dir(vim.fn.getcwd() .. "/lua", { depth = math.huge }) do
    t.eq(path, path:lower(), "Lua module paths must use lowercase names: " .. path)
  end
end)

t.test("the public API loads with Neovim's module cache enabled", function()
  local channel = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" },
    { rpc = true }
  )
  t.ok(channel > 0, "Could not start a fresh Neovim instance")
  local ok, err = pcall(
    vim.rpcrequest,
    channel,
    "nvim_exec_lua",
    [[
      local root = ...
      vim.opt.runtimepath:prepend(root)
      vim.loader.enable()
      local bosana = require("bosana")
      bosana.setup({ confirm = false, icons = false })
      assert(require("bosana.config").get().icons == false)
      assert(type(require("bosana.health").check) == "function")
      vim.cmd("runtime plugin/bosana.lua")
      assert(vim.fn.exists(":Bosana") == 2)
    ]],
    { vim.fn.getcwd() }
  )
  vim.fn.jobstop(channel)
  t.ok(ok, err)
end)
