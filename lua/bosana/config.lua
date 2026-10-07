local M = {}

M.defaults = {
  socket_name = nil,
  socket_path = nil,
  timeout_ms = 5000,
  exclude_host_session = false,
  excluded_sessions = {}, -- Native session IDs, e.g. { "$1" }.
  manager = false,
  icons = { session = "▣", window = "▤" },
  confirm = true,
  preview = true,
  keymaps = {
    ["q"] = "close",
    ["<C-l>"] = "refresh",
    ["g?"] = "help",
  },
}

local configured = vim.deepcopy(M.defaults)

function M.validate(opts)
  for key in pairs(opts) do
    if M.defaults[key] == nil and key ~= "socket_name" and key ~= "socket_path" then
      error("Unknown Bosana option: " .. tostring(key), 0)
    end
  end
  if opts.socket_name and opts.socket_path then
    error("Use either socket_name or socket_path, not both", 0)
  end
  for _, key in ipairs({ "socket_name", "socket_path" }) do
    if opts[key] ~= nil and (type(opts[key]) ~= "string" or opts[key] == "") then
      error(key .. " must be a nonempty string", 0)
    end
  end
  if type(opts.timeout_ms) ~= "number" or opts.timeout_ms <= 0 then
    error("timeout_ms must be positive", 0)
  end
  for _, key in ipairs({ "exclude_host_session", "manager", "confirm", "preview" }) do
    if type(opts[key]) ~= "boolean" then
      error(key .. " must be a boolean", 0)
    end
  end
  if opts.icons ~= false then
    if type(opts.icons) ~= "table" then
      error("icons must be a table or false", 0)
    end
    for key, icon in pairs(opts.icons) do
      if key ~= "session" and key ~= "window" then
        error("Unknown Bosana icon: " .. tostring(key), 0)
      end
      if type(icon) ~= "string" or icon:find("[%c]") then
        error("icons." .. key .. " must be a string without control characters", 0)
      end
    end
  end
  if type(opts.excluded_sessions) ~= "table" then
    error("excluded_sessions must be a list of native session IDs", 0)
  end
  for _, id in ipairs(opts.excluded_sessions) do
    if type(id) ~= "string" or not id:match("^%$%d+$") then
      error("excluded_sessions must contain native session IDs such as '$1'", 0)
    end
  end
  if opts.keymaps ~= false and type(opts.keymaps) ~= "table" then
    error("keymaps must be a table or false", 0)
  end
  local actions = { close = true, refresh = true, save = true, help = true }
  for lhs, action in pairs(opts.keymaps or {}) do
    if type(lhs) ~= "string" or lhs == "" then
      error("Keymap keys must be nonempty strings", 0)
    end
    if action ~= false and type(action) ~= "function" and not actions[action] then
      error("Keymap actions must be close, refresh, save, help, a function, or false", 0)
    end
  end
  return opts
end

function M.setup(opts)
  configured = M.validate(vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {}))
end

function M.get(opts)
  return M.validate(vim.tbl_deep_extend("force", vim.deepcopy(configured), opts or {}))
end

return M
