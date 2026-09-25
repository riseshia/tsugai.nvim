import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import type { NeovimClient } from "neovim";
import { z } from "zod";

export type Selection = {
  bufnr: number;
  path: string;
  start_line: number;
  end_line: number;
  text: string;
};

export type Hunk = {
  old_text: string;
  new_text: string;
  reason: string;
};

export type Command = {
  title: string;
  command: string;
  explanation: { token: string; meaning: string }[];
  locations: { path: string; line: number; text: string }[];
};

// State of the request in flight. Requests are single-threaded, so one slot is enough.
export type RequestContext = {
  selection?: Selection;
  hunks?: Hunk[];
  command?: Command;
};

export const SERVER_NAME = "tsugai";

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }] };
}

function failure(value: string) {
  return { ...text(value), isError: true };
}

function numbered(lines: string[], firstLine: number): string {
  return lines.map((line, i) => `${firstLine + i}\t${line}`).join("\n");
}

export function createTools(nvim: NeovimClient, context: () => RequestContext) {
  return createSdkMcpServer({
    name: SERVER_NAME,
    tools: [
      tool(
        "get_selection",
        "The range the user selected when making this request, captured at request time.",
        {},
        async () => {
          const selection = context().selection;
          return text(selection ? JSON.stringify(selection) : "No selection for this request.");
        },
        { annotations: { readOnlyHint: true } },
      ),
      tool(
        "list_buffers",
        "Buffers open in Neovim, with whether each has unsaved changes.",
        {},
        async () => {
          const buffers = await nvim.lua(
            `return vim.tbl_map(function(b)
              return { bufnr = b.bufnr, path = b.name, modified = b.changed == 1 }
            end, vim.fn.getbufinfo({ buflisted = 1 }))`,
          );
          return text(JSON.stringify(buffers));
        },
        { annotations: { readOnlyHint: true } },
      ),
      tool(
        "get_cursor",
        "The current buffer and cursor position.",
        {},
        async () => {
          const cursor = await nvim.lua(
            `local pos = vim.api.nvim_win_get_cursor(0)
            return { bufnr = vim.api.nvim_get_current_buf(), path = vim.api.nvim_buf_get_name(0), line = pos[1], col = pos[2] + 1 }`,
          );
          return text(JSON.stringify(cursor));
        },
        { annotations: { readOnlyHint: true } },
      ),
      tool(
        "get_buffer",
        "Contents of an open buffer, including unsaved changes, as `line<TAB>text`. Prefer this over Read for files open in Neovim.",
        {
          bufnr: z.number().int(),
          start_line: z.number().int().min(1).optional(),
          end_line: z.number().int().min(1).optional(),
        },
        async ({ bufnr, start_line, end_line }) => {
          const first = start_line ?? 1;
          const lines = (await nvim.request("nvim_buf_get_lines", [bufnr, first - 1, end_line ?? -1, false])) as string[];
          return text(numbered(lines, first));
        },
        { annotations: { readOnlyHint: true } },
      ),
      tool(
        "propose_edit",
        "Propose changes to the selected code. Call exactly once per edit request. The user reviews each hunk and accepts or rejects it.",
        {
          hunks: z.array(
            z.object({
              old_text: z.string().describe("Complete lines copied verbatim from the buffer, without line-number prefixes. Must not be empty."),
              new_text: z.string().describe("Replacement lines. Empty string deletes the lines."),
              reason: z.string().describe("One short line explaining why."),
            }),
          ),
        },
        async ({ hunks }) => {
          context().hunks = hunks;
          return text(`Recorded ${hunks.length} hunk(s) for review.`);
        },
      ),
      tool(
        "open_file",
        "Open a file in the user's editor window and put the cursor on a line, e.g. to show the code you are explaining.",
        {
          path: z.string(),
          line: z.number().int().min(1),
        },
        async ({ path, line }) => {
          const opened = await nvim.lua("return require('tsugai.nav').open(...)", [path, line]);
          return opened === true ? text(`Opened ${path}:${line}.`) : failure(String(opened));
        },
      ),
      tool(
        "propose_command",
        "Propose one Neovim Ex command for the user to run, shown on a card with an explanation. Use it for rule-based changes such as bulk replaces. Call at most once per request.",
        {
          title: z.string().describe("Intent and scope, e.g. `fetchUser → loadUser (12 matches / 5 files)`."),
          command: z.string().describe("A single Ex command without the leading colon and without saving (no `update`/`w`)."),
          explanation: z
            .array(z.object({ token: z.string(), meaning: z.string() }))
            .describe("The command split into pieces, each with a short meaning."),
          locations: z
            .array(z.object({ path: z.string(), line: z.number().int().min(1), text: z.string() }))
            .describe("Every place the command will change. Filled into the quickfix list, which `cfdo`/`cdo` iterate over."),
        },
        async (command) => {
          const problem = await nvim.lua("return require('tsugai.command').check(...)", [command.command]);
          if (problem) return failure(`Rejected: ${problem}. Propose a different command.`);
          context().command = command;
          return text("Recorded the command for the user to review.");
        },
      ),
    ],
  });
}
