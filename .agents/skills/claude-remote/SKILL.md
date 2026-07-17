---
name: claude-remote
description: Deploy a new Claude Code remote-control instance in a fresh tmux window inside the firstmate repo. Use when the captain invokes /claude-remote (e.g. "/claude-remote", "new remote instance", "deploy a remote Claude").
---

# claude-remote

Deploy a visible Claude Code remote-control instance in a new tmux window.

## Workflow

1. Determine which tmux session to use (default: `WoL`).
2. Create a new tmux window with the `ccrc` command running inside the firstmate repo:

```sh
tmux -S /tmp/wol-tmux/default new-window -t WoL -n <name> -d 'cd /home/dereklinux/firstmate && env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions --permission-mode bypassPermissions --remote-control'
```

3. The `<name>` defaults to `ccrc` unless the captain specified a custom name.

## Implementation notes

- The `ccrc` alias expands to `env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions --permission-mode bypassPermissions --remote-control`
- The `--remote-control` flag runs Claude in headless mode, listening for remote commands rather than an interactive prompt
- The captain can also use `ccrc` directly (alias in `.zshrc` and `.bashrc`) but needs to pipe input via stdin, e.g. `echo "instruction" | ccrc`
- For a visible interactive session (non-remote-control), omit the `--remote-control` flag

## Captain-facing output

After creating the window, tell the captain which window to switch to (e.g. "Window 4 — switch with Ctrl+B 4 or `:selectw -t ccrc`").
