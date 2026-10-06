# Bosana

Edit tmux sessions and windows as a normal Neovim buffer, inspired by
[Oil](https://github.com/stevearc/oil.nvim).

```text
work
    editor
    terminal
personal
    shell
```

Rename entries by editing their names, delete them with `dd`, and move windows
with linewise cut/paste. **`:w` applies the changes to tmux.**

## Requirements and installation

- Neovim 0.10+.
- tmux on `PATH` (developed and tested with tmux 3.8-rc3).
- No Lua dependencies; Oil does not need to be installed.

For a local checkout with lazy.nvim:

```lua
{
  dir = "~/projects/personal/bosana", -- Adjust to your checkout.
  name = "bosana.nvim",
  lazy = false,
  opts = {},
}
```

Other plugin managers can load this directory as a normal Neovim plugin.
Setup is optional; the default configuration works without it.

Run `:checkhealth bosana` (or `:checkhealth Bosana`) to check Neovim compatibility,
configuration, tmux executable/version, selected server access, and host exclusion
when configured. The health check only reads tmux state.

Bosana always runs `tmux` from `PATH`, checking its availability before opening
and before every tmux command. If `tmux` cannot be found or is not executable,
it reports an explicit error asking you to install tmux and add it to `PATH`.

Open with `:Bosana`, or map a key:

```lua
vim.keymap.set("n", "<leader>bt", "<cmd>Bosana<cr>", { desc = "Edit tmux sessions" })
```

## Editing

The IDs at the start of each line are concealed text, so they follow linewise
deletions, pastes, moves, and undo. Internally the example above looks like:

```text
/$1 work
/@3     editor
/@7     terminal
/$2 personal
/@9     shell
```

The space after each ID belongs to the concealed prefix. Window names have four
additional spaces of indentation. Keep each entry's hidden prefix intact when
renaming: use `cw`, `C`, `A`, or a substitution on the name instead of replacing
the entire line with `cc`.

| Edit | Result on write |
| --- | --- |
| Change a session/window name | Rename that existing entry |
| Remove a window row | Delete that window |
| Move a window beneath another session | Transfer the window to that session |
| Reorder window rows within a session | Reorder the windows |
| Remove a session and its window rows | Delete the session |
| Leave an empty session header | Delete the session |
| Move windows out of a deleted session | Preserve those windows in their destinations |
| Reorder session blocks | No change; tmux has no corresponding session order |

Use `:wq` to apply and exit, and `:q!` to discard pending edits. Writes finish
before `:wq` exits. Successful writes re-read tmux and reset undo history, so undo
cannot restore IDs for entries that no longer exist.

Window labels are tmux's `window_name`, not pane titles. A manual window rename
disables tmux's `automatic-rename` for that window, following `rename-window`.
tmux's stored backslash escapes in session names and in 3.8+ window names are
normalized to their editable spelling.

Window order is relative: Bosana preserves existing index slots and gaps when
possible. Membership changes honor each session's `renumber-windows` option.
An active window remains selected if it survives in its original session.

### First-version boundaries

- Edit existing entries only; new ID-less rows are rejected.
- No pane editing, linked/shared windows, or grouped sessions.
- An ID may appear only once, even when the names differ.
- Window names may repeat; retained session names must be unique.
- Names cannot be empty, contain control characters, or have surrounding
  whitespace. Session names cannot contain `.` or `:` because tmux replaces them.
- Blank lines are ignored. Window rows require exactly four spaces, not tabs.

Invalid edits produce line diagnostics and leave the buffer modified.

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

**Prefix + B** creates and switches to the manager session, or switches to the
existing one. `--manager`:

- Resolves the hosting session by native ID and excludes it from both the view
  and all mutation plans.
- Sets its `detach-on-destroy` option to `off`, so closing the manager switches
  the client to a surviving session rather than detaching.
- Sets its window's `remain-on-exit` to `off`, so the manager session disappears
  when Neovim exits, provided it still contains only that window.
- Makes the buffer's `q` mapping quit the editor rather than return to another
  Neovim buffer. Unsaved edits still need to be written or explicitly discarded.

If you delete all other sessions, quitting the manager ends the final session.
Host detection verifies the selected server against `$TMUX`; a reused pane ID
on a different server cannot accidentally identify the host.

To exclude the host without changing its lifecycle, use
`:Bosana --exclude-host-session`. The separate CLI launcher script is deferred.

For a checkout that is not installed in your Neovim configuration:

```sh
nvim -u NONE \
  --cmd 'set runtimepath^=/home/nomig/projects/personal/bosana' \
  -c 'runtime plugin/bosana.lua' \
  -c 'Bosana'
```

## Commands and default mappings

| Command | Behavior |
| --- | --- |
| `:Bosana` | Open the editor, reusing an existing view without discarding edits |
| `:Bosana --manager` | Open in a dedicated hosting session |
| `:Bosana --exclude-host-session` | Exclude the hosting session |
| `:Bosana --socket-name NAME` | Select a tmux `-L` server |
| `:Bosana --socket-path PATH` | Select a tmux `-S` server |
| `:BosanaRefresh` | Refresh, refusing to overwrite unsaved edits |
| `:BosanaRefresh!` | Discard edits and load current tmux state |
| `:BosanaClose[!]` | Close; bang discards edits |

Default buffer mappings: `q` closes, `<C-l>` refreshes, and `g?` opens help.
Plugin managers usually generate help tags automatically. For a manually loaded
checkout, run `:helptags /path/to/bosana/doc` before using `:help bosana`.

## Configuration and Lua API

```lua
require("bosana").setup({
  timeout_ms = 5000,          -- Per-command timeout.
  -- socket_name = "work",   -- tmux -L; mutually exclusive with socket_path.
  -- socket_path = "/tmp/work.sock", -- tmux -S.
  exclude_host_session = false,
  excluded_sessions = {},     -- Native session IDs, e.g. { "$1" }.
  manager = false,
  keymaps = {
    ["q"] = "close",
    ["<C-l>"] = "refresh",
    ["g?"] = "help",
  },
})
```

Set an individual mapping to `false` to remove it, use a function for a custom
mapping, or set `keymaps = false` to disable all default mappings.

```lua
local bosana = require("bosana")
local bufnr, err = bosana.open({ socket_path = "/tmp/work.sock" })
local ok, err = bosana.save(bufnr) -- Defaults to the current buffer.
local ok, err = bosana.refresh({ bufnr = bufnr, force = false })
local ok, err = bosana.close({ bufnr = bufnr, force = false })
local state = bosana.get_state(bufnr) -- Copy of baseline and last execution report.
```

These operations return a result or `nil, error`; `setup()` raises configuration
errors. Without explicit socket options, tmux inherits the current server from
`$TMUX`, or uses its default server outside tmux.

## Stale state and recovery

Bosana compares a fresh snapshot with the buffer's baseline before applying
changes. External renames, moves, deletions, index changes, and server restarts
require a refresh. Merely selecting a different active window does not.

tmux operations are not transactional. If a command fails after execution starts,
Bosana retains the edited text and marks the write as blocked to prevent blind
replay. Inspect the report with:

```vim
:lua =require('bosana').get_state().last_report
```

The report contains completed command argument arrays, the failed command when
available, and the operation being processed. After a failed transfer, Bosana
also attempts to remove its temporary destination links when the original source
still holds the window; these attempts are recorded in `cleanup`. Completed
transfers and deletions are not rolled back. Preserve any edited rows you need
(for example by yanking them), then use `:BosanaRefresh!`, inspect the actual
state, and reapply the remaining edits. A failed write does not exit `:wq`.

## Development

```sh
nvim --headless -u NONE -l tests/run.lua
stylua --check lua plugin tests
```

Tests use isolated tmux sockets under `/tmp/opencode` and kill only those test
servers. That directory must exist. They exercise the parser/planner, real tmux
mutations, exclusions, failures, concealment, undo, and child Neovim exit behavior.
See [the complete test outline](tests/README.md) for every test and its purpose.
