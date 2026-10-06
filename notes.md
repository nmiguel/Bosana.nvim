# The goal

Create a neovim plugin for managing tmux session and windows. Have an oil like (nvim plugin), but for tmux sessions, windows. It should be able to be opened from the cli.
For now, panes are not supported.


Use the output of tmux listing all windows and sessions. For each window and session assign it an id, which is hidden in the main buffer.
Once the buffer is saved and exited, compare the ids in each and any changes made, and make those into tmux commands and run them.
Use oil.nvim ostensibly as reference, as most of its core should be the same, the only difference is how the buffer is initially built and what commands are run once the buffer is saved and exited.

The buffer should look like this (more features will follow, but this is the core). Note that each line has a hidden id, which is not shown to the user.

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
<session_2_name>
    <session_2_window_1_current_title>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>

### Examples

Initial state:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
<session_2_name>
    <session_2_window_1_current_title>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>

Exited State 1:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>

Means: deleted session 2

Exited State 2:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
    <session_2_window_1_current_title>
<session_2_name>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>

Means: move session_2_window_1 to the end of session 1

Exited State 3:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
<session_2_name>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>
    <session_2_window_1_current_title>

Means: move session_2_window_1 to the last position of the session

Exited State 4:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
<session_2_name>
    <session_2_window_1_current_title>
    <session_2_window_1_current_title>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>

Means: this is invalid and should error

Exited State 5:

<session_1_name>
    <session_1_window_1_current_title>
    <session_1_window_2_current_title>
    <session_1_window_3_current_title>
<session_2_name>
    <session_2_window_2_current_title>
    <session_2_window_3_current_title>

Means: delete session_2_window_1

## Open questions

- [x] How to summon directly from the cli, rather than just as a command in neovim
  - Run `nvim -c 'Bosana'` after installing the plugin. `nvim -l` runs a Lua script rather than an interactive editor.
  - See `plan.md` for the agreed first-version behavior and `README.md` for the tmux hotkey workflow.
