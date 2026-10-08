if vim.g.loaded_bosana then
  return
end
vim.g.loaded_bosana = true

local function checked(message, value)
  if not value then
    require("bosana.message").error(message)
  end
end

vim.api.nvim_create_user_command("Bosana", function(args)
  local bufnr = require("bosana").command(args.fargs)
  checked("Could not open tmux sessions.", bufnr)
  local state = require("bosana.buffer").get(bufnr)
  if state and state.options.manager and vim.v.vim_did_enter == 0 then
    -- -c runs before VimEnter. Session plugins can replace/wipe the view in a
    -- scheduled VimEnter callback, so restore the requested manager afterwards.
    local group = vim.api.nvim_create_augroup("BosanaManagerStartup", { clear = true })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function()
        vim.schedule(function()
          checked("Could not open tmux sessions.", require("bosana").command(args.fargs))
        end)
      end,
    })
  end
end, {
  nargs = "*",
  desc = "Edit tmux sessions and windows",
  complete = function(lead)
    return vim.tbl_filter(function(option)
      return option:sub(1, #lead) == lead
    end, { "--manager", "--exclude-host-session", "--socket-name", "--socket-path" })
  end,
})

vim.api.nvim_create_user_command("BosanaRefresh", function(args)
  checked("Could not refresh tmux sessions.", require("bosana").refresh({ force = args.bang }))
end, { bang = true, desc = "Refresh tmux state (bang discards edits)" })

vim.api.nvim_create_user_command("BosanaClose", function(args)
  checked("Could not close the buffer.", require("bosana").close({ force = args.bang }))
end, { bang = true, desc = "Close Bosana (bang discards edits)" })
