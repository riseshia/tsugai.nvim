# tsugai.nvim — Spec

> Goal: write code faster with AI while keeping my own understanding of the code.

## Background

- An always-available companion that never interrupts the main work leads to more questions, and mixing in questions (write) builds understanding faster than only reading (read-only).
- Why Cursor-style tools felt off: the AI proposes first. Here, it acts **only when I ask**.

## Principles

1. **Explicit triggers only.** Code generation and questions happen only on request. No as-you-type suggestions.
2. **Changes are proposals.** The AI never edits buffers directly. Every change goes through my acceptance: per-hunk preview for a single file, per-plan acceptance for multi-file scaffolds (feature 5).
3. **Claude fetches the context it needs.** I don't hand-pick context; buffers are exposed as tools. No LSP tools (no guarantee they improve quality).

## Features

### 1. Code generation (in-file templates)

No insert-mode trigger (both Ctrl and Alt chords are uncomfortable). Instead, write what you want as a template line in the file and process it from normal mode.

```ruby
def total_price(items)
  # @@ai sum of qty * unit price; treat nil qty as 1
end
```

- Template marker (tentative): `@@ai`. It almost never appears in real code and is easy to type. Detection is based on the fixed marker, so it works inside or outside comments (normally write it in a comment; in formats without comments, such as JSON, write it on a bare line).
- `<Space>fe` in normal mode → find and process every template in the current file. It shares the key with feature 3: normal mode reads the instructions from the file, visual mode edits the selection. A selection that contains templates processes just those, without asking for an instruction.
  - Only template detection is done in Lua with a regex (deterministic). Stripping comment syntax and replacing the template with code is left to Claude, since the result is reviewed as a diff.
  - Results are shown as an inline diff, same as feature 3. One template = one hunk. Accepting a hunk replaces the template line with the generated code.
- Manual trigger (`<Space>fe`) is the default, prioritizing writing several templates and processing them in a batch. Writing the intent down first is itself a "write", which helps keep understanding.

### 2. Questions (chat buffer)

- `<Space>fa` → open a chat buffer in a right split and ask.
  - Normal mode: ask without a selection. Claude fetches what it needs via `get_cursor` / `get_buffer` etc.
  - Visual mode: attach the selection as context (to make clear what "this" refers to).
- The chat buffer is a regular buffer (search, yank, scroll all work). It opens without taking focus, so the code window stays where you type; `<Space>ft` toggles it.
- Tool calls show up in the chat as one line each (`▸ Grep fetch_user`), followed by the streamed answer.
- Claude can move the code window with `open_file` to show what it is explaining.
- The session persists (an always-available companion).

### 3. Change proposals for existing code (inline diff)

- Select a range, `<Space>fe` → type an instruction ("use early return") → inline diff.
  - Shown like Copilot: only the part that changes is ghost text over the original code; unchanged text keeps its highlighting. Extra lines are `virt_lines`; removed lines turn red with strikethrough (red alone where the terminal cannot draw strikethrough).
  - The reason and key hint for the hunk under the cursor appear in the command-line area, keys first, cut to the window width.
  - Move between hunks with `]g` / `[g`; accept or reject per hunk, which moves on to the next hunk; `<Space>fY` accepts every hunk in the buffer
  - Each hunk carries a one-line reason
  - `<Space>fr` gives a follow-up instruction for the hunk under the cursor and redraws it with the revision
  - Accepting a hunk whose lines were edited after the proposal is refused (`<Space>fY` skips such hunks), so the edits are not silently overwritten
- Scattered proposals, such as a whole-file review, come back as a quickfix list; each item is applied via the inline diff.

### 4. Command proposals (bulk replace, etc.)

For changes expressible as a rule, such as a bulk replace, the LLM does not generate per-file edits; it **proposes a vim command** instead. It is deterministic, and one command line is easier to read than 30 diffs.

Flow:

1. Ask in the chat (`<Space>fa`): "rename `fetchUser` to `loadUser` everywhere". There is no separate key; Claude decides to answer with a command, like any other tool use.
2. Claude finds the targets with rg and calls `propose_command`; the targets fill the quickfix list.
3. A proposal card (float) opens when the chat answer finishes.
4. `<CR>` (ok) → Lua runs it as is with `vim.cmd(command)`.

```
┌ Proposal: fetchUser → loadUser  (12 matches / 5 files) ┐
│ :cfdo %s/\<fetchUser\>/loadUser/g                       │
│                                                         │
│  cfdo       for each file in the quickfix list          │
│  %s/../../  substitute across the whole file            │
│  \< \>      word boundary → skips fetchUserList         │
│  g          every match on a line                       │
│                                                         │
│ <CR> run   e edit in cmdline   p preview   q cancel     │
└─────────────────────────────────────────────────────────┘
[quickfix window: the 12 targets]
```

- Card contents: intent and scope (title), the command, a per-token explanation, key hints. The quickfix window opens alongside.
- `p` preview: Lua computes the substitution without applying it and shows per-match before/after in a scratch buffer.
- `e`: put the command in the cmdline (an escape hatch to tweak before running).
- Saving is not part of the command (no `| update`). Save with `:wa` after checking.
- Remember the target buffers before running; `<Space>fu` undoes the whole run.
- No `c` flag by default (the card already confirmed it). Claude adds it only when targets are ambiguous.
- Renames also use a `cfdo` command proposal instead of LSP rename, which is why showing targets in quickfix first matters.
- The same pattern applies to `:g`, `:normal`, macros, etc.
- Only Ex commands that stay inside Neovim are proposed. Anything that reaches the shell (`:!`, `system()`, `:terminal`, etc.) is forbidden.
  - Enforced in Lua before the card is shown: `!` and `\=` are refused anywhere, and every command name (including the ones after `cfdo`/`cdo`/`bufdo`, `:g/pat/` and `|`) must be on an allowlist of text-editing commands (`s`, `d`, `m`, `t`, `j`, `normal`, `sort`, ...). The `propose_command` tool runs the same check so Claude can revise a refused command.

### 5. Multi-file scaffolds

Multi-file creation/edits are requested from the chat (`<Space>fa`). There is no per-file preview; **acceptance is per plan**. Detailed review happens afterwards via git diff or similar.

1. Ask in the chat: "scaffold a users resource: controller, model, spec"
2. Claude does not write files; it returns a plan via `propose_scaffold`.
3. A proposal card opens.

```
┌ Proposal: users scaffold  (create 3 / edit 1) ─────┐
│ Users CRUD skeleton. User model (name, email),      │
│ controller index/show/create, model spec, route     │
│                                                     │
│  + app/controllers/users_controller.rb             │
│  + app/models/user.rb                              │
│  + spec/models/user_spec.rb                        │
│  ~ config/routes.rb      add resources :users      │
│                                                     │
│ <CR> accept   q cancel                              │
└─────────────────────────────────────────────────────┘
```

4. On accept, Lua writes and saves the files, then opens them as buffers. The touched files go into the quickfix list (`]q` to walk them).

- If a target file is open in a buffer with unsaved changes, refuse instead of overwriting.

## Execution model

- **One session per nvim process.** Chat, generation, and proposals share it. Long sessions rely on the SDK's compaction; a reset command is added only if needed.
- **Single-threaded.** No parallel requests; one request at a time.
- **Everything is synchronous, chat included.** The editor waits while a request runs, with cancel available. Revisit async only if blocking turns out to be painful.
- **Live progress.** While waiting, render what Claude is doing in real time (tool calls, files being read, streamed text), like the `claude` CLI does.
- **Model split.** Requests I make run on Sonnet or Opus. If background work turns out to be needed, it runs on Haiku to keep it cheap. Candidates: preloading the code in open buffers, or preparing context the current buffer's work is likely to need. Not in scope until proven necessary.

## Architecture

```
Neovim (Lua plugin) ──jobstart──▶ sidecar (TypeScript, resident Claude Agent SDK)
      ▲                                   │
      └──── msgpack-rpc (stdio) ◀─────────┘  tools call the nvim API directly
```

- **Lua side**: key input → request to the sidecar, rendering (inline diff, chat buffer, proposal cards), accept/reject handling.
- **Sidecar**: keeps the Claude session via the Agent SDK. Started with `jobstart(..., { rpc = true })`, so stdin/stdout carry msgpack-rpc both ways; tools call the nvim API over the same channel.
- **Own system prompt** instead of Claude Code's preset, which is written for an agent that carries a task through on its own. The project's CLAUDE.md is still loaded (`settingSources: ["project"]`); the user's global Claude Code settings are not.
- **Engine: Claude Agent SDK or the `claude` CLI.** Authentication is whatever those two support. The engine call site is isolated in one file so switching between them touches only that file.

### Tools

| Category | Tools | Policy |
|---|---|---|
| Read | `get_selection`, `get_cursor`, `get_buffer(bufnr)` (includes unsaved content), `list_buffers` | allowed |
| Navigate/display | `open_file(path, line)` (Claude picks the location via Grep), line highlight, fill quickfix, open split | allowed (easy to undo; useful for "look here" while explaining) |
| Command proposal | open a proposal card | allowed (I run it with `<CR>`) |
| Scaffold | `propose_scaffold(summary, files)` | allowed (Lua writes and saves after acceptance, feature 5) |
| Direct buffer edits | `set_lines` etc. | forbidden (inline diff proposals only) |
| Arbitrary commands | `nvim_command`, `exec_lua` | forbidden (`:!` opens up the shell) |

- The SDK's built-in Read/Grep/Glob stay on (for exploring the repo). Buffer tools are for the current editing state.
- The SDK's built-in Edit/Write are off.

## Prior art

| Project | Notes |
|---|---|
| [douglasjordan2/claudecode.nvim](https://github.com/douglasjordan2/claudecode.nvim) (MIT) | UI reference: `chat.lua`, `diff.lua` (per-hunk accept), `inline_edit.lua`. Its `bridge.lua` (Rust bridge + `claude -p`) is replaced by the sidecar; `context.lua` is unnecessary with tool-based lookup. No updates since 2026-05, so borrow structure rather than fork. |
| [codecompanion.nvim](https://codecompanion.olimorris.dev/) | Chat and inline editing. No per-hunk accept. |
| [aider watch mode](https://aider.chat/docs/usage/watch.html) | In-file `AI!` / `AI?` comment markers; reference for templates and the auto trigger. |

## Open questions

- Whether the confirmation prompt of `:s///c` works when run via `vim.cmd`.
- Finalize the template marker (`@@ai` tentative). Leftover templates are the user's responsibility; no commit guard.
- Auto trigger: add it if batch processing turns out to be rare. Idea: if a `@@ai!` line exists, collect the file's `@@ai` lines on `InsertLeave` and process them (like aider watch mode). Don't re-trigger templates that are in flight or currently shown as proposals.
- Resume: continue the previous session after restarting nvim. Deferred until needed.
- Command card `p` preview is not built yet.
- Proposal list management: a new request currently drops the buffer's earlier proposals. Keep them and list pending proposals in a location list if that turns out to hurt.

## Measured

- Latency with one long-lived session (streaming input): about 6 s for a simple edit, around 20 s when Claude explores other files.
