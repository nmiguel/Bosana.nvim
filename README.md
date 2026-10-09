# Bosana

Edit tmux sessions and windows as a normal Neovim buffer, inspired by
[Oil](https://github.com/stevearc/oil.nvim).

```text
▣ work
    ▤ editor
    ▤ terminal
▣ personal
    ▤ shell
```

Open the Bosana buffer to see all your sessions and windows, then perform operations on the text itself to make changes to tmux itself. Supported operations are:

- Reorder windows within a session.
- Rename windows and sessions.
- Delete windows and sessions.
- Create windows and sessions.
- Move windows from one session to another.
- Jump to a given window.

Simply make the changes to the buffer, save with `:w` to view the changes being made (`:q!` discards changes).
Also supported is a built-in `--manager` mode, which exits automatically if the buffer is closed or if it's used to jump to a different tmux window, while also hiding its own window in the buffer.

## Requirements and installation

- Neovim 0.10+.
- tmux on `PATH`.

For a local checkout with lazy.nvim:

```lua
{
  "nmiguel/Bosana.nvim",
  commands = {
    {
      "Bosana",
      function()
        require("bosana").open()
      end,
      desc = "Open Bosana",
    },
  },
}
```

If you run into issues, run `:checkhealth bosana` (or `:checkhealth Bosana`) to check prerequesites you might be missing.

## Editing

Session and window icons are inline virtual text: they are not part of the
editable name, clipboard contents, or tmux commands. Customize them with `icons`
or set `icons = false` to hide them.

Under the hood, Bosana works like Oil, in that it uses hidden id's on each line. This is important as operations that don't work on the entire line are not supported (e.g. `D` instead of `dd`, as it only deletes from the cursor forward will not work to delete a session).

```text
/$1 work
/@3     editor
/@7     terminal
/$2 personal
/@9     shell
```

Newly created windows or sessions are differentiated by their indentation. Create a new line with no leading spaces to create a session, or 1 level of indentation to create a window associated with the session immediately above it.

Use `:e!` to discard pending edits and reload current tmux state, just like `:BosanaRefresh!`.

### Window preview

Move the cursor onto a window row to show a read-only preview panel on the right
side of the Bosana view. It displays the visible screen of that window's **active
pane**, preserving terminal colors and text styles, clipped to the panel's size.
Moving between windows updates the preview; pausing on a row refreshes its output.

## Direct CLI launch and tmux hotkey

After installing the plugin, launch an interactive editor directly:

```sh
nvim -c 'Bosana'
```

For a dedicated manager session, add this to `tmux.conf`:

```tmux
bind-key B new-session -A -s bosana -n manager \
    'exec nvim -c "Bosana --manager"'
```

Using `-n bosana` disables tmux's automatic window naming for this window.
Without it, tmux can rename the window after Bosana takes its opening snapshot,
causing a failure due to the Bosana buffer containing already stale data.

The above snippet also uses the `--manager` flag, which does the following:

- Excludes its own session from being shown in the buffer.
- Sets its `detach-on-destroy` option to `off`, so closing the manager switches
  the client to a surviving session rather than detaching.
- Sets its window's `remain-on-exit` to `off`, so the manager session disappears
  when Neovim exits, provided it still contains only that window.
- Makes the buffer's `q` mapping quit Neovim completely.
- Makes Enter switch to the selected entry and then quit the editor.
- Makes Neovim schedule Bosana to open after the session loading occurs, so that Bosana opens even if your session manager is restoring a different buffer.

To exclude the host without changing its lifecycle, use
`:Bosana --exclude-host-session`.

## Commands and default mappings

| Command                          | Behavior                                                           |
| -------------------------------- | ------------------------------------------------------------------ |
| `:Bosana`                        | Open the editor, reusing an existing view without discarding edits |
| `:Bosana --manager`              | Open in a dedicated hosting session                                |
| `:Bosana --exclude-host-session` | Exclude the hosting session                                        |
| `:Bosana --socket-name NAME`     | Select a tmux `-L` server                                          |
| `:Bosana --socket-path PATH`     | Select a tmux `-S` server                                          |
| `:BosanaRefresh`                 | Refresh, refusing to overwrite unsaved edits                       |
| `:BosanaRefresh!`                | Discard edits and load current tmux state                          |
| `:e!`                            | Discard edits and load current tmux state                          |
| `:BosanaClose[!]`                | Close; bang discards edits                                         |

Default buffer mappings: `<CR>` switches to the entry under the cursor, `q`
closes, `<C-l>` refreshes, and `g?` opens help.

## Configuration and Lua API

```lua
require("bosana").setup({
  timeout_ms = 5000,          -- Per-command timeout.
  -- socket_name = "work",   -- tmux -L; mutually exclusive with socket_path.
  -- socket_path = "/tmp/work.sock", -- tmux -S.
  exclude_host_session = false,
  excluded_sessions = {},     -- Native session IDs, e.g. { "$1" }.
  manager = false,
  icons = { session = "▣", window = "▤" },
  confirm = true,
  preview = true,
  keymaps = {
    ["<CR>"] = "switch",
    ["q"] = "close",
    ["<C-l>"] = "refresh",
    ["g?"] = "help",
  },
})
```

Set an individual mapping to `false` to remove it, use a function for a custom
mapping, or set `keymaps = false` to disable all default mappings.

Set `icons = false` to disable icons, or an individual icon to `""` to hide it.
Icons use the `BosanaSessionIcon` and `BosanaWindowIcon` highlight groups.
Set `confirm = false` to apply changes without a prompt, including in headless
automation. Both `require("bosana")` and `require("Bosana")` expose the same API.

```lua
local bosana = require("bosana")
local bufnr, err = bosana.open({ socket_path = "/tmp/work.sock" })
local ok, err = bosana.save(bufnr) -- Defaults to the current buffer.
local ok, err = bosana.switch(bufnr) -- Switch to the row under the cursor.
local ok, err = bosana.refresh({ bufnr = bufnr, force = false })
local ok, err = bosana.close({ bufnr = bufnr, force = false })
local state = bosana.get_state(bufnr) -- Copy of baseline and last execution report.
```

These operations return a result or `nil, error`; `setup()` raises configuration
errors. Without explicit socket options, tmux inherits the current server from
`$TMUX`, or uses its default server outside tmux.
