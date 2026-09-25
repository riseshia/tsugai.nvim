import { attach } from "neovim";
import { startSession } from "./engine.ts";
import type { ProgressEvent } from "./engine.ts";
import { createTools } from "./tools.ts";
import type { Hunk, RequestContext, Selection } from "./tools.ts";

// stdout carries msgpack-rpc to nvim; anything else written there corrupts the channel.
console.log = console.error;

const INSTRUCTIONS = `
You are running inside Neovim through the tsugai.nvim plugin. The user writes the code; you help only when asked.
- Never modify files. File-writing tools are unavailable on purpose.
- Files open in Neovim may have unsaved changes: read them with get_buffer, not Read. Use list_buffers to find them.
- For an edit request, call propose_edit exactly once. Each hunk's old_text must be complete lines copied verbatim from the current buffer. Keep hunks small and focused, and give each a one-line reason in the language of the user's instruction.
- After calling propose_edit, reply with at most one short sentence.
`.trim();

type EditRequest = {
  instruction: string;
  selection: Selection;
};

type RefineRequest = {
  instruction: string;
  bufnr: number;
  path: string;
  hunk: Hunk;
};

const nvim = attach({ reader: process.stdin, writer: process.stdout });
let context: RequestContext = {};
const session = startSession(process.cwd(), createTools(nvim, () => context), INSTRUCTIONS);

function emit(event: Record<string, unknown>) {
  nvim.lua("require('tsugai.sidecar').on_event(...)", [event]).catch((error) => console.error(error));
}

function onProgress(event: ProgressEvent) {
  if (event.kind === "text") {
    emit({ kind: "progress", text: event.text });
  } else if (event.kind === "tool_start") {
    emit({ kind: "progress", tool: event.name });
  } else {
    emit({ kind: "progress", input: JSON.stringify(event.input) });
  }
}

async function edit({ instruction, selection }: EditRequest) {
  context = { selection };
  const prompt = [
    `Edit request for ${selection.path} lines ${selection.start_line}-${selection.end_line} (bufnr ${selection.bufnr}).`,
    `Instruction: ${instruction}`,
    "Selected code:",
    selection.text,
  ].join("\n");
  const message = await session.send(prompt, onProgress);
  return { hunks: context.hunks ?? [], message };
}

async function refine({ instruction, bufnr, path, hunk }: RefineRequest) {
  context = {};
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

const HANDLERS: Record<string, (params: never) => Promise<unknown>> = { edit, refine };

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
