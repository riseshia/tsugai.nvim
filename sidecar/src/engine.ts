// The only file that talks to Claude. Swapping the Agent SDK for the `claude` CLI happens here.
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { McpSdkServerConfigWithInstance, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

export type ProgressEvent =
  | { kind: "text"; text: string }
  | { kind: "tool_start"; name: string }
  | { kind: "tool"; name: string; input: unknown };

export type Session = {
  send(prompt: string, onProgress: (event: ProgressEvent) => void): Promise<string>;
  interrupt(): Promise<void>;
};

const MODEL = "sonnet";
const READ_TOOLS = ["Read", "Grep", "Glob"];
const WRITE_TOOLS = ["Edit", "Write"];

// Returns why writing `path` is not allowed right now, or undefined to allow it.
export type WritePolicy = (path: string) => string | undefined;

export function startSession(
  cwd: string,
  server: McpSdkServerConfigWithInstance,
  systemPrompt: string,
  mayWrite: WritePolicy,
): Session {
  const queued: SDKUserMessage[] = [];
  let wake: (() => void) | undefined;

  // A single long-lived query in streaming-input mode keeps one session per nvim process.
  async function* inbox(): AsyncGenerator<SDKUserMessage> {
    while (true) {
      const message = queued.shift();
      if (message) {
        yield message;
      } else {
        await new Promise<void>((resolve) => (wake = resolve));
      }
    }
  }

  const q = query({
    prompt: inbox(),
    options: {
      cwd,
      model: MODEL,
      tools: [...READ_TOOLS, ...WRITE_TOOLS],
      // Reads and tsugai's own tools never ask. Writes always come to canUseTool, which
      // allows them only while an accepted plan is being carried out.
      allowedTools: [...READ_TOOLS, `mcp__${server.name}`],
      mcpServers: { [server.name]: server },
      permissionMode: "default",
      canUseTool: async (toolName, input) => {
        if (!WRITE_TOOLS.includes(toolName)) {
          return { behavior: "deny", message: `${toolName} is not available in tsugai.` };
        }
        const reason = mayWrite(String(input.file_path));
        return reason ? { behavior: "deny", message: reason } : { behavior: "allow", updatedInput: input };
      },
      includePartialMessages: true,
      settingSources: ["project"],
      systemPrompt,
    },
  });

  let onMessage: ((message: SDKMessage) => void) | undefined;
  let onFailure: ((error: Error) => void) | undefined;

  (async () => {
    try {
      for await (const message of q) onMessage?.(message);
      onFailure?.(new Error("session ended"));
    } catch (error) {
      onFailure?.(error instanceof Error ? error : new Error(String(error)));
    }
  })();

  return {
    send(prompt, onProgress) {
      return new Promise((resolve, reject) => {
        onFailure = reject;
        onMessage = (message) => {
          // Subagent traffic (parent_tool_use_id set) is not the answer to this request.
          if (message.type === "stream_event" && !message.parent_tool_use_id) {
            const event = message.event;
            if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
              onProgress({ kind: "text", text: event.delta.text });
            } else if (event.type === "content_block_start" && event.content_block.type === "tool_use") {
              // Announce the tool as soon as it starts; its input only arrives with the full assistant message.
              onProgress({ kind: "tool_start", name: event.content_block.name });
            }
          } else if (message.type === "assistant" && !message.parent_tool_use_id) {
            for (const block of message.message.content) {
              if (block.type === "tool_use") onProgress({ kind: "tool", name: block.name, input: block.input });
            }
          } else if (message.type === "result") {
            onMessage = undefined;
            onFailure = undefined;
            if (message.subtype === "success") {
              resolve(message.result);
            } else {
              reject(new Error(message.subtype));
            }
          }
        };
        queued.push({ type: "user", message: { role: "user", content: prompt }, parent_tool_use_id: null });
        wake?.();
      });
    },
    async interrupt() {
      await q.interrupt();
    },
  };
}
