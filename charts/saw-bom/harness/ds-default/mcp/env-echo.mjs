// Throwaway live-test server for handoff item 4 (stdio MCP secret).
// Tool: env_echo. Returns the value of SAW_TEST_API_KEY so the agent turn
// visibly confirms the Secret reached the server. NOT for production.
import { createInterface } from "node:readline";

const TOOLS = [{
  name: "env_echo",
  description: "Report the SAW_TEST_API_KEY value (live secret test).",
  inputSchema: { type: "object", properties: {} },
}];

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function fail(id, code, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

createInterface({ input: process.stdin }).on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.id === undefined) return;
  if (msg.method === "initialize") {
    reply(msg.id, {
      protocolVersion: msg.params?.protocolVersion || "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "saw-env-echo", version: "0.0.0" },
    });
  } else if (msg.method === "tools/list") {
    reply(msg.id, { tools: TOOLS });
  } else if (msg.method === "tools/call") {
    const v = process.env.SAW_TEST_API_KEY;
    const text = v ? `SAW_TEST_API_KEY=${v}` : "SAW_TEST_API_KEY is NOT SET";
    reply(msg.id, { content: [{ type: "text", text }] });
  } else if (msg.method === "ping") {
    reply(msg.id, {});
  } else {
    fail(msg.id, -32601, `method not found: ${msg.method}`);
  }
});
