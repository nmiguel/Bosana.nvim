local M = {}

function M.error(message)
  -- Report an editor error without a Lua exception/traceback. err=true also
  -- prevents a failed BufWriteCmd from allowing :wq to exit.
  vim.api.nvim_echo({ { "Bosana: " .. message, "ErrorMsg" } }, true, { err = true })
end

return M
