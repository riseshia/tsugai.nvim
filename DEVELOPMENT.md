# Development

The design and its reasons live in [spec.md](spec.md). Keep it in sync when behavior changes.

## Layout

- `plugin/tsugai.lua`: sets the default key mappings on startup.
- `lua/tsugai/`: the Neovim side. `init.lua` holds `setup()`, the config and the global mappings, `sidecar.lua` starts the sidecar and blocks on requests, `diff.lua` draws and accepts proposals, `edit.lua` (edits and `@@ai` templates), `chat.lua`, `command.lua` (command cards and their safety check), `nav.lua` (`open_file`), `help.lua` (`:Tsugai help`), `health.lua` (`:checkhealth tsugai`), `card.lua` (the proposal float shared by `command.lua` and `plan.lua`).
- `sidecar/src/`: the Agent SDK process. `engine.ts` is the only file that talks to Claude, `tools.ts` defines the tools Claude can call, `main.ts` holds the system prompt and the request handlers.

The sidecar is started with `jobstart(..., { rpc = true })`: stdin/stdout carry msgpack-rpc both ways. Lua sends requests as notifications; the sidecar answers by calling `require('tsugai.sidecar').on_event(...)`.

## Setup

```sh
cd sidecar && npm install    # includes dev dependencies, unlike ./build.sh
npm run typecheck
```

Node runs the `.ts` files directly; there is no build output.

## Tests

```sh
mise run test        # typecheck, test:unit and test:e2e; the same as CI
mise run lint        # actionlint and pinact for the workflows
```

- `tests/unit.lua` exercises the Lua side alone (command safety check, proposal rendering and accepting, templates, prefix and help) with the sidecar replaced by a recorder.
- `tests/e2e.lua` runs the real path: Neovim, the sidecar, the Agent SDK and the Claude Code binary, against `tests/mock_api.mjs`, a stand-in for the Anthropic Messages API. Each scenario is a rule: when the latest user message contains a keyword, the mock calls a tsugai tool with scripted input (or answers with text). `CLAUDE_CONFIG_DIR` points at an empty directory so no real login is used, and nothing leaves the machine. Set `MOCK_API_LOG=<file>` to record the requests the mock receives.
- Both run with `nvim --clean -l`, so your config and installed plugins stay out.

Whether Claude's answers are any good still needs a manual run with the real API (below).

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

What Claude actually did (prompts, tool calls, results) is in the SDK's session log: `~/.claude/projects/<working directory with / replaced by ->/*.jsonl`. `:Tsugai log` opens `~/.local/state/nvim/tsugai.log`: sidecar start and exit, each request with its duration and error, and the sidecar's stderr.

## README GIFs

`demo/` holds a minimal Neovim config, a small Ruby project and one [vhs](https://github.com/charmbracelet/vhs) tape per GIF. vhs needs `ttyd` and `ffmpeg`. Record from the repository root; each run calls Claude for real, so the result differs a little every time:

```sh
vhs demo/edit.tape
```

The tapes wait for text on the screen (`Wait+Screen`) rather than a fixed time. `demo/init.lua` pins the answers to English so the README reads consistently.

## Pitfalls

- Never write to stdout in the sidecar: it is the RPC channel. `console.log` is redirected to stderr for that reason.
- A field that is `undefined` on the sidecar side reaches Lua as `vim.NIL`, which is truthy. Leave the key out instead.
- Visual-mode mappings go through `:<C-u>lua ...<CR>` so that `'<` and `'>` are set when the Lua runs.
- The echo area is cleared when a mapping leaves visual mode. Echo after the mapping returns (`vim.schedule`).
- Virtual lines never wrap and have no line numbers, and the cursor cannot sit on them. Anything that must stay readable on a narrow window goes elsewhere.
- In tmux tests, sending `Escape` immediately followed by another key arrives as an Alt chord. Pause between them.
- Killed test instances leave swap files that make the next run stop at a prompt. Start test instances with `nvim -n`.
- When tsugai is also installed through a plugin manager, `bin/dev-nvim` loads this checkout first and the installed copy's `plugin/tsugai.lua` is skipped by the `loaded_tsugai` guard. A Lua module deleted here, though, still loads from the installed copy.
- Claude Code merges streamed replies that share a message id, and puts system-role reminders after the user's turn. A mock API has to give each reply its own id and look for the last user message, not the last message.
- Claude Code walks up from the working directory for CLAUDE.md files, and under `$HOME` that reaches `~/.claude/CLAUDE.md`, the user's personal Claude Code instructions. `engine.ts` excludes the config directory through `claudeMdExcludes`; check the session log (`Contents of ... CLAUDE.md`) when something personal shows up in answers.
- Claude's Grep uses ripgrep, which skips gitignored directories when searching from above them. The system prompt tells Claude to search inside the working directory for this reason.
