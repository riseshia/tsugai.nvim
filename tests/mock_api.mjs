// A stand-in for the Anthropic Messages API, so the sidecar and the Claude Code binary run
// for real while the model's answers are scripted.
//
// Usage: node tests/mock_api.mjs <rules.json> <port file>
// Each rule is { match, tool?, input?, text? }. When the latest user message contains
// `match`, the reply calls `tool` (the tsugai tool name, e.g. propose_edit) with `input`,
// or answers with `text`. `tool` is a tsugai tool name (propose_edit) or a built-in one
// (Edit). Once a tool result comes back, the turn ends with a short text.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";

const [rulesPath, portFile] = process.argv.slice(2);
const rules = JSON.parse(readFileSync(rulesPath, "utf8"));

// Claude Code merges streamed messages that share an id, so every reply needs its own.
let replies = 0;

function stream(res, blocks, stopReason) {
  replies += 1;
  const events = [
    ["message_start", { message: { id: `msg_mock_${replies}`, type: "message", role: "assistant", model: "mock", content: [], stop_reason: null, usage: { input_tokens: 1, output_tokens: 1 } } }],
  ];
  blocks.forEach((block, index) => {
    if (block.type === "text") {
      events.push(["content_block_start", { index, content_block: { type: "text", text: "" } }]);
      events.push(["content_block_delta", { index, delta: { type: "text_delta", text: block.text } }]);
    } else {
      events.push(["content_block_start", { index, content_block: { type: "tool_use", id: block.id, name: block.name, input: {} } }]);
      events.push(["content_block_delta", { index, delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) } }]);
    }
    events.push(["content_block_stop", { index }]);
  });
  events.push(["message_delta", { delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 1 } }]);
  events.push(["message_stop", {}]);

  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const [type, data] of events) res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
  res.end();
}

function reply(request) {
  // Claude Code appends system-role reminders after the user's turn, so look for the last
  // user message rather than the last message.
  const last = JSON.stringify(request.messages.findLast((m) => m.role === "user") ?? {});
  if (last.includes('"tool_result"')) return [[{ type: "text", text: "Done." }], "end_turn"];

  const rule = rules.find((r) => last.includes(r.match));
  if (!rule) return [[{ type: "text", text: "No rule matched." }], "end_turn"];
  if (rule.text) return [[{ type: "text", text: rule.text }], "end_turn"];

  const name = request.tools.map((t) => t.name).find((n) => n === rule.tool || n.endsWith(`__${rule.tool}`));
  return [[{ type: "tool_use", id: `toolu_mock_${replies}`, name, input: rule.input }], "tool_use"];
}

// MOCK_API_LOG=<file> records each request, for debugging a scenario.
const log = (line) => process.env.MOCK_API_LOG && appendFileSync(process.env.MOCK_API_LOG, line + "\n");

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    log(`${req.method} ${req.url} ${body}`);
    if (req.method === "POST" && req.url.startsWith("/v1/messages") && !req.url.includes("count_tokens")) {
      const [blocks, stopReason] = reply(JSON.parse(body));
      return stream(res, blocks, stopReason);
    }
    // Health checks and anything else Claude Code probes.
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ input_tokens: 1 }));
  });
});

server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
