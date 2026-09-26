import { isAbsolute, relative, resolve } from "node:path";
import { attach } from "neovim";
import { startSession } from "./engine.ts";
import type { ProgressEvent } from "./engine.ts";
import { createTools, SERVER_NAME } from "./tools.ts";
import type { Hunk, Plan, RequestContext, Selection } from "./tools.ts";

// stdout carries msgpack-rpc to nvim; anything else written there corrupts the channel.
console.log = console.error;

// Our own prompt instead of the claude_code preset: the preset is written for an agent that
// carries a task through on its own, which fights "only what was asked, as proposals".
// The project's CLAUDE.md still arrives through settingSources.
const SYSTEM_PROMPT = `
You are a coding assistant inside Neovim, reached through the tsugai.nvim plugin. The user writes the code and understands it; you help only with what they ask, and every change you make is a proposal they review.

# Environment
- Working directory (the user's project): ${process.cwd()}
- Platform: ${process.platform}

# How to work
- Do what the request asks and no more. No unrequested refactors, extra files, or follow-up tasks.
- Look before you answer: read the relevant code instead of guessing. Keep the exploration proportional to the request.
- Be brief and concrete. Refer to code as path:line relative to the working directory. No filler, no emojis.
- Write in the language the user's request is written in, including the text fields you pass to tools (reasons, titles, explanations). Code identifiers alone do not count; if the request has no natural-language words, use English.
- Never address the user by name.

# Tools
- Buffers open in Neovim may have unsaved changes: read them with get_buffer, not Read. list_buffers shows what is open; get_cursor and get_selection show where the user is.
- Use Grep and Glob to find code, and Read for files that are not open. Search inside the working directory (pass it as the path), even when it sits inside a larger git repository: files under a gitignored directory are skipped when searching from above it.
- You cannot modify files, except while carrying out a plan the user accepted. Otherwise changes go through propose_edit, propose_command or propose_plan, which the user accepts or runs.

# Requests
- Edit request: call propose_edit exactly once. Each hunk's old_text must be complete lines copied verbatim from the current buffer. Keep hunks small and focused, each with a one-line reason. Then reply with at most one short sentence.
- Chat question: answer in a few sentences, leading with the answer itself. Add detail, alternatives or caveats only when the user asks or when they change the answer. You may call open_file to show the code you are talking about.
- Chat request for changes within one file (fixes found while reviewing it, a local refactor): call propose_edit with that file's path on every hunk. The user reviews them in the buffer. Then reply with at most one short sentence.
- Chat request for changes across files (a refactor, a new feature, a scaffold): first find what is affected and agree on the approach in the chat, e.g. "fetch_user is used in app.rb and 12 other places; I would add X and update them like Y. OK?". Skip the question only when the user already fixed the approach. Once agreed, call propose_plan. Then reply with at most one short sentence.
- Execute request (the user accepted your plan): carry it out with Edit and Write, inside the working directory, changing only what the plan needs. When finished, reply with a short summary of what changed.
- Chat request for a change a rule can express (a rename, a bulk replace, deleting matching lines): call propose_command instead of describing edits; the user sees a card and runs it. Use a single Ex command that stays inside Neovim. Never use anything that reaches the shell or evaluates code (\`!\`, system(), :terminal, :lua, :execute, \`\\=\`). Find the targets with Grep first and pass all of them as locations; use cfdo or cdo for multi-file changes. End the command with \`| update\` so the changed files are saved (e.g. \`cfdo %s/\\<old\\>/new/ge | update\`); the user reviews the result with git diff. Then reply with at most one short sentence.
`.trim();

// Either an instruction for the selection, or @@ai templates written in the file.
type EditRequest = {
  bufnr: number;
  path: string;
  instruction?: string;
  selection?: Selection;
  templates?: Template[];
};

type AskRequest = {
  question: string;
  selection?: Selection;
};

type Template = {
  start_line: number;
  end_line: number;
  text: string;
};

type ExecuteRequest = {
  plan: Plan;
};

type RefineRequest = {
  instruction: string;
  bufnr: number;
  path: string;
  hunk: Hunk;
};

const USER_INSTRUCTIONS = process.env.TSUGAI_INSTRUCTIONS?.trim();

function systemPrompt() {
  if (!USER_INSTRUCTIONS) return SYSTEM_PROMPT;
  return `${SYSTEM_PROMPT}\n\n# User preferences\nThese take precedence over the defaults above.\n${USER_INSTRUCTIONS}`;
}

const nvim = attach({ reader: process.stdin, writer: process.stdout });
let context: RequestContext = {};
// Writes are allowed only while carrying out an accepted plan, and only inside the project.
function mayWrite(path: string) {
  if (!context.executing) {
    return "Editing files is only allowed while carrying out a plan the user accepted. Use propose_edit or propose_plan instead.";
  }
  const file = relative(process.cwd(), resolve(process.cwd(), path));
  if (file.startsWith("..") || isAbsolute(file)) return "Only files inside the working directory may be written.";
  context.changed?.add(file);
  return undefined;
}

const session = startSession(process.cwd(), createTools(nvim, () => context), systemPrompt(), mayWrite);

function emit(event: Record<string, unknown>) {
  nvim.lua("require('tsugai.sidecar').on_event(...)", [event]).catch((error) => console.error(error));
}

function toolName(name: string) {
  return name.replace(`mcp__${SERVER_NAME}__`, "");
}

// One short line per tool call: the argument that says what it touches, not the whole input.
function describeInput(input: unknown) {
  if (typeof input !== "object" || input === null) return "";
  const fields = input as Record<string, unknown>;
  const key = ["pattern", "file_path", "path", "command"].find((k) => fields[k] !== undefined);
  if (!key) return "";
  const value = String(fields[key]);
  const shown = value === process.cwd() || value.startsWith(process.cwd() + "/") ? relative(process.cwd(), value) || "." : value;
  return typeof fields.line === "number" ? `${shown}:${fields.line}` : shown;
}

function onProgress(event: ProgressEvent) {
  if (event.kind === "text") {
    emit({ kind: "progress", text: event.text });
  } else if (event.kind === "tool_start") {
    emit({ kind: "progress", tool: toolName(event.name) });
  } else {
    const input = describeInput(event.input);
    if (input) emit({ kind: "progress", input });
  }
}

async function edit({ bufnr, path, instruction, selection, templates }: EditRequest) {
  context = { mode: "edit", selection };
  const lines = [`Edit request for ${path} (bufnr ${bufnr}).`];
  if (templates) {
    lines.push(
      "Generate code for the @@ai templates below. A template is a line (or run of lines) containing the @@ai marker, usually inside a comment, describing the code the user wants there.",
      "Give one hunk per template. Its old_text must include the template lines verbatim and may include neighbouring lines when the generated code has to reshape them. new_text replaces them with the code, without the template comment.",
      ...templates.map((t) => `Template at lines ${t.start_line}-${t.end_line}:\n${t.text}`),
    );
  }
  if (instruction && selection) {
    lines.push(`Instruction: ${instruction}`, `Selected lines ${selection.start_line}-${selection.end_line}:`, selection.text);
  }
  const message = await session.send(lines.join("\n"), onProgress);
  return { hunks: context.hunks ?? [], message };
}

async function refine({ instruction, bufnr, path, hunk }: RefineRequest) {
  context = { mode: "edit" };
  const prompt = [
    `Refine one hunk you proposed for ${path} (bufnr ${bufnr}). The user has not accepted it yet.`,
    `Instruction: ${instruction}`,
    "Call propose_edit with exactly one hunk whose old_text is identical to this original code:",
    hunk.old_text,
    "Your current proposal for it:",
    hunk.new_text,
  ].join("\n");
  const message = await session.send(prompt, onProgress);
  return { hunks: context.hunks ?? [], message };
}

async function ask({ question, selection }: AskRequest) {
  context = { mode: "chat", selection };
  const lines = [`Question: ${question}`];
  if (selection) {
    lines.push(`About ${selection.path} lines ${selection.start_line}-${selection.end_line} (bufnr ${selection.bufnr}):`, selection.text);
  } else {
    lines.push("No selection. Use get_cursor and get_buffer if the question is about the code being edited.");
  }
  const message = await session.send(lines.join("\n"), onProgress);
  // An undefined field would reach Lua as vim.NIL, which is truthy, so absent ones are left out.
  return {
    message,
    ...(context.command && { command: context.command }),
    ...(context.hunks?.length && { hunks: context.hunks }),
    ...(context.plan && { plan: context.plan }),
  };
}

async function execute({ plan }: ExecuteRequest) {
  context = { mode: "execute", executing: true, changed: new Set() };
  const prompt = [
    "The user accepted this plan. Carry it out now.",
    JSON.stringify(plan, null, 2),
  ].join("\n");
  try {
    const message = await session.send(prompt, onProgress);
    return { message, changed: [...(context.changed ?? [])] };
  } finally {
    context.executing = false;
  }
}

const HANDLERS: Record<string, (params: never) => Promise<unknown>> = { edit, refine, ask, execute };

nvim.on("notification", (method: string, args: unknown[]) => {
  if (method === "cancel") {
    session.interrupt().catch((error) => console.error(error));
    return;
  }
  const handler = HANDLERS[method];
  if (!handler) return;

  handler(args[0] as never)
    .then((result) => emit({ kind: "done", result }))
    .catch((error) => emit({ kind: "error", message: String(error) }));
});

process.stdin.on("end", () => process.exit(0));
