// Throwaway live-test server for the provider-keys secret model.
// Tool: brave_probe. Reports whether BRAVE_API_KEY arrived and its
// sha256 (never the value). NOT for production.
import { createInterface } from "node:readline";
import { createHash } from "node:crypto";

const TOOLS = [{
  name: "brave_probe",
  description: "Report BRAVE_API_KEY arrival (sha256, live secret test).",
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
      serverInfo: { name: "saw-brave-probe", version: "0.0.0" },
    });
  } else if (msg.method === "tools/list") {
    reply(msg.id, { tools: TOOLS });
  } else if (msg.method === "tools/call") {
    const v = process.env.BRAVE_API_KEY;
    const text = v
      ? `BRAVE_API_KEY=SET sha256:${createHash("sha256").update(v).digest("hex")}`
      : "BRAVE_API_KEY is NOT SET";
    reply(msg.id, { content: [{ type: "text", text }] });
  } else if (msg.method === "ping") {
    reply(msg.id, {});
  } else {
    fail(msg.id, -32601, `method not found: ${msg.method}`);
  }
});
