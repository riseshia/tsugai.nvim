# Development

The design and its reasons live in [spec.md](spec.md). Keep it in sync when behavior changes.

## Layout

- `plugin/tsugai.lua`: sets the default key mappings on startup.
- `lua/tsugai/`: the Neovim side. `init.lua` holds `setup()`, the config and the global mappings, `sidecar.lua` starts the sidecar and blocks on requests, `diff.lua` draws and accepts proposals, `edit.lua` (edits and `@@ai` templates), `chat.lua`, `command.lua` (command cards and their safety check), `nav.lua` (`open_file`).
- `sidecar/src/`: the Agent SDK process. `engine.ts` is the only file that talks to Claude, `tools.ts` defines the tools Claude can call, `main.ts` holds the system prompt and the request handlers.

The sidecar is started with `jobstart(..., { rpc = true })`: stdin/stdout carry msgpack-rpc both ways. Lua sends requests as notifications; the sidecar answers by calling `require('tsugai.sidecar').on_event(...)`.

## Setup

```sh
cd sidecar && npm install    # includes dev dependencies, unlike ./build.sh
npm run typecheck
```

Node runs the `.ts` files directly; there is no build output.

## Trying changes

`bin/dev-nvim` starts Neovim with your usual config plus this checkout on the runtimepath. The sidecar is started on the first request and runs until Neovim exits, so restart Neovim after changing sidecar code.

Start it inside the directory you want Claude to work on: the sidecar's working directory is Neovim's, and that is where Claude searches.

## End-to-end checks

Drive a real Neovim in tmux and read the screen:

```sh
tmux new-session -d -s tsg -c <dir> "<repo>/bin/dev-nvim -n file.rb"
tmux resize-window -t tsg -x 130 -y 30
tmux send-keys -t tsg '7GV' ' fe'
tmux capture-pane -p -t tsg        # -e keeps colors
tmux kill-session -t tsg
```

- Poll the screen until the progress float (`to cancel` in its title) is gone instead of sleeping a fixed time; Claude takes 5 to 30 seconds.
- To check state, send `:lua print(...)` and read the last line, or inspect extmarks with `nvim_buf_get_extmarks`.
- A startup message that ends in "Press ENTER" swallows the first key. Send `Enter` first.

What Claude actually did (prompts, tool calls, results) is in the SDK's session log: `~/.claude/projects/<working directory with / replaced by ->/*.jsonl`. Stderr of the sidecar goes to `~/.local/state/nvim/tsugai.log`.

## Pitfalls

- Never write to stdout in the sidecar: it is the RPC channel. `console.log` is redirected to stderr for that reason.
- A field that is `undefined` on the sidecar side reaches Lua as `vim.NIL`, which is truthy. Leave the key out instead.
- Visual-mode mappings go through `:<C-u>lua ...<CR>` so that `'<` and `'>` are set when the Lua runs.
- The echo area is cleared when a mapping leaves visual mode. Echo after the mapping returns (`vim.schedule`).
- Virtual lines never wrap and have no line numbers, and the cursor cannot sit on them. Anything that must stay readable on a narrow window goes elsewhere.
- In tmux tests, sending `Escape` immediately followed by another key arrives as an Alt chord. Pause between them.
- Killed test instances leave swap files that make the next run stop at a prompt. Start test instances with `nvim -n`.
- Claude's Grep uses ripgrep, which skips gitignored directories when searching from above them. The system prompt tells Claude to search inside the working directory for this reason.
