# tsugai.nvim

A Neovim plugin for writing code faster with Claude while keeping your own understanding of the code.
Claude acts only when you ask, and every change is a proposal you review before it lands.

The design lives in [spec.md](spec.md). This is an early proof of concept: only edit proposals work so far.

## Requirements

- Neovim 0.11+
- Node.js that runs TypeScript directly (22.18+; developed on 26)
- Claude authentication that the [Claude Agent SDK](https://docs.claude.com/en/docs/agent-sdk/overview) accepts (a logged-in `claude` CLI or `ANTHROPIC_API_KEY`)

## Setup

```sh
cd sidecar && npm install
```

Then add the repository to your plugin manager, e.g. with packer:

```lua
use "~/repos/riseshia/tsugai.nvim"
```

## Usage

1. Select lines in visual mode and press `<Space>ae`.
2. Type an instruction such as `implement this` and press Enter. A float shows what Claude is doing; `<C-c>` cancels.
3. Proposals appear as ghost text over the code they replace. Removed lines turn red.

While proposals are shown, the key hint and the reason for the hunk under the cursor appear in the command-line area.

| Key | Action |
|---|---|
| `<Space>ay` | Accept the hunk under the cursor and move to the next one |
| `<Space>an` | Reject the hunk under the cursor and move to the next one |
| `<Space>ar` | Give a follow-up instruction to revise the hunk under the cursor |
| `<Space>aY` | Accept every hunk in the buffer |
| `<Space>aq` | Reject every hunk in the buffer |
| `]g` / `[g` | Next / previous hunk |

Accepting changes the buffer but does not save it.

## Development

`bin/dev-nvim` starts Neovim with your usual config plus this checkout on the runtimepath:

```sh
bin/dev-nvim path/to/file.rb
```

Sidecar logs go to `~/.local/state/nvim/tsugai.log`. Type-check the sidecar with `npm run typecheck` in `sidecar/`.
