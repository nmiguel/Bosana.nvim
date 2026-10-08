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

Rename entries by editing their names, delete them with `dd`, and move windows
with linewise cut/paste. **`:w` previews the actions and asks for confirmation
before applying the changes to tmux.**

## Requirements and installation

- Neovim 0.10+.
- tmux on `PATH`.

For a local checkout with lazy.nvim:

```lua
{
  "nmiguel/Bosana.nvim",
  opts = {},
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

Other plugin managers can load this directory as a normal Neovim plugin.
Setup is optional; the default configuration works without it.

Run `:checkhealth bosana` (or `:checkhealth Bosana`) to check Neovim compatibility,
configuration, tmux executable/version, selected server access, and host exclusion
when configured. The health check only reads tmux state.

Bosana always runs `tmux` from `PATH`, checking its availability before opening
and before every tmux command. If `tmux` cannot be found or is not executable,
the Lua API and health check report an explicit error asking you to install tmux
and add it to `PATH`. Interactive commands show a short error-styled message.

Open with `:Bosana`, or map a key:

```lua
vim.keymap.set("n", "<leader>bt", "<cmd>Bosana<cr>", { desc = "Edit tmux sessions" })
```

## Editing

Session and window icons are inline virtual text: they are not part of the
editable name, clipboard contents, or tmux commands. Customize them with `icons`
or set `icons = false` to hide them.

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

| Edit                                  | Result on write                                    |
| ------------------------------------- | -------------------------------------------------- |
| Change a session/window name          | Rename that existing entry                         |
| Remove a window row                   | Delete that window                                 |
| Move a window beneath another session | Transfer the window to that session                |
| Reorder window rows within a session  | Reorder the windows                                |
| Remove a session and its window rows  | Delete the session                                 |
| Leave an empty session header         | Delete the session                                 |
| Move windows out of a deleted session | Preserve those windows in their destinations       |
| Reorder session blocks                | No change; tmux has no corresponding session order |

Use `:w` or `:wq` to apply and exit, and `:q!` to discard pending edits. Writes finish
before `:wq` exits. Successful writes re-read tmux and reset undo history, so undo
cannot restore IDs for entries that no longer exist.

Writes with changes show a synchronous **Yes/No** confirmation listing up to five
logical actions (renames, moves, deletions, or reorders), plus the number of any
remaining actions. Press `y` to apply or `n`/Escape to cancel; No is the default.
Cancellation keeps your edits and prevents `:wq` from exiting. No-op writes do
not prompt. tmux state is checked both before and after confirmation.

Use `:e!` to discard pending edits and reload current tmux state, just like
`:BosanaRefresh!`. If reloading fails, the edited buffer is retained.

Window labels are tmux's `window_name`, not pane titles. A manual window rename
disables tmux's `automatic-rename` for that window, following `rename-window`.
tmux's stored backslash escapes in session names and in 3.8+ window names are
normalized to their editable spelling.

Window order is relative: Bosana preserves existing index slots and gaps when
possible. Membership changes honor each session's `renumber-windows` option.
An active window remains selected if it survives in its original session.

### Window preview

Move the cursor onto a window row to show a read-only preview panel on the right
side of the Bosana view. It displays the visible screen of that window's **active
pane**, preserving terminal colors and text styles, clipped to the panel's size.
Moving between windows updates the preview; pausing on a row refreshes its output.

Captures run asynchronously on the selected tmux server, without switching its
active window or taking focus from the editor. Native IDs keep previews attached
to the correct window during unsaved renames and moves. Session headers, blank
or unknown rows, and leaving Bosana hide the panel. It also hides when the editor
is too small. Capture failures appear inside the panel and leave edits intact.

Set `preview = false` in `setup()` or `open()` to disable it.

### Editing boundaries

- Edit existing entries only; new ID-less rows are rejected.
- No pane editing, linked/shared windows, or grouped sessions.
- An ID may appear only once, even when the names differ.
- Window names may repeat; retained session names must be unique.
- Names cannot be empty, contain control characters, or have surrounding
  whitespace. Session names cannot contain `.` or `:` because tmux replaces them.
- Blank lines are ignored. Window rows require exactly four spaces, not tabs.

Invalid edits show a short error-styled message and refresh the buffer from tmux,
discarding the invalid edits. Creating new sessions or windows is not supported.

## Direct CLI launch and tmux hotkey

After installing the plugin, launch an interactive editor directly:

```sh
nvim -c 'Bosana'
```

To open Bosana in a new tmux window after Neovim startup:

```tmux
bind b new-window -n bosana \
    'nvim -c "autocmd VimEnter * ++once lua vim.schedule(function() vim.cmd([[Bosana]]) end)"'
```

The explicit `-n bosana` disables tmux's automatic window naming for this window.
Without it, tmux can rename the window after Bosana takes its opening snapshot,
causing the first save to fail with “tmux state changed since opening the buffer.”

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
`:Bosana --exclude-host-session`.

For a checkout that is not installed in your Neovim configuration:

```sh
nvim -u NONE \
  --cmd 'set runtimepath^=/path/to/bosana' \
  -c 'runtime plugin/bosana.lua' \
  -c 'Bosana'
```

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
  icons = { session = "▣", window = "▤" },
  confirm = true,
  preview = true,
  keymaps = {
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

Failed writes show a short error-styled message and automatically refresh the
buffer to reflect actual tmux state. tmux operations are not transactional, so
some changes may already have been applied. Inspect the detailed report with:

```vim
:lua =require('bosana').get_state().last_report
```

The report contains completed command argument arrays, the failed command when
available, and the operation being processed. After a failed transfer, Bosana
also attempts to remove its temporary destination links when the original source
still holds the window; these attempts are recorded in `cleanup`. Completed
transfers and deletions are not rolled back. Inspect the refreshed state and
reapply any remaining changes. If tmux cannot be read during recovery, Bosana
restores its last known snapshot; writes remain blocked if mutations may have
occurred, until `:BosanaRefresh!` or `:e!` succeeds. Recovery failures are recorded
in `recovery_error`. Validation details are recorded in `validation`.
A failed write does not exit `:wq`. Cancelling confirmation keeps your edits.

## Development

```sh
nvim --headless -u NONE -l tests/run.lua
stylua --check lua plugin tests
```

Tests use isolated tmux sockets under `/tmp/opencode` and kill only those test
servers. That directory must exist. They exercise the parser/planner, real tmux
mutations, exclusions, failures, concealment, undo, and child Neovim exit behavior.
Preview tests cover active-pane captures, cursor changes, unsaved moves, reloads,
asynchronous cancellation, failures, cleanup, Unicode clipping, and attached-UI
colors/styles, resizing, and exit.
See [the complete test outline](tests/README.md) for every test and its purpose.
