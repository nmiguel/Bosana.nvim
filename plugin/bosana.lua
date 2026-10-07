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
  checked("Could not open tmux sessions.", require("bosana").command(args.fargs))
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
