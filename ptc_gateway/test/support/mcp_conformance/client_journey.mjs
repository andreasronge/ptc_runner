import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";
import { readFile } from "node:fs/promises";

const [url, token, disconnectTool, dispatchPath] = process.argv.slice(2);
const client = new Client(
  { name: "ptc-gateway-interoperability", version: "1.0.0" },
  { versionNegotiation: { mode: { pin: "2026-07-28" } } },
);
const transport = new StreamableHTTPClientTransport(new URL(url), {
  authProvider: { token: async () => token },
});

try {
  await client.connect(transport);
  const discover = client.getDiscoverResult();
  const listing = await client.listTools();
  const read = await client.callTool({ name: "a", arguments: { query: "read" } });
  const write = await client.callTool({ name: "write", arguments: { query: "write" } });
  const contractFailure = await client.callTool({ name: "a", arguments: { query: "invalid", extra: true } });
  let disconnectCancellation = null;
  if (disconnectTool) {
    const controller = new AbortController();
    const pending = client.callTool({
      name: disconnectTool,
      arguments: { city: "nyc", delay_ms: 30000 },
    }, { signal: controller.signal });
    let settled;
    pending.then(value => { settled = { value }; }, error => { settled = { error }; });
    const deadline = Date.now() + 10000;
    while (true) {
      const dispatches = await readFile(dispatchPath, "utf8").catch(() => "");
      if (dispatches.split("\n").filter(Boolean).length >= 1) break;
      if (settled) throw new Error(`disconnect call settled before provider dispatch: ${JSON.stringify(settled.value ?? String(settled.error))}`);
      if (Date.now() >= deadline) throw new Error("disconnect call never reached provider dispatch");
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    controller.abort();
    try {
      const cancelled = await pending;
      disconnectCancellation = cancelled.isError === true;
    } catch (_) {
      disconnectCancellation = true;
    }
  }
  process.stdout.write(JSON.stringify({ discover, listing, read, write, contractFailure, disconnectCancellation }));
} finally {
  await client.close();
}
