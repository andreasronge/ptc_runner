import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";
import { readFile, writeFile } from "node:fs/promises";

const [url, token, disconnectTool, dispatchPath, cleanupStartedPath, cleanupReleasePath] = process.argv.slice(2);
const client = new Client(
  { name: "ptc-gateway-interoperability", version: "1.0.0" },
  { versionNegotiation: { mode: { pin: "2026-07-28" } } },
);
const transport = new StreamableHTTPClientTransport(new URL(url), {
  authProvider: { token: async () => token },
});

// A tools/call holds its run reservation through audit and provider cleanup after
// the response settles. With max_concurrent_runs: 1 the next call can see -31999
// while that slot is still releasing. Bounded retry matches the in-process
// await_run_release/2 poll (100 × 10 ms) used by gateway_test.exs.
async function callWhenAdmitted(invoke) {
  const attempts = 100;
  const delayMs = 10;
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await invoke();
    } catch (error) {
      const busy =
        error?.code === -31999 ||
        String(error).includes("Server busy") ||
        String(error).includes("-31999");
      if (!busy || attempt === attempts - 1) throw error;
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, delayMs));
    }
  }
  throw lastError;
}

try {
  await client.connect(transport);
  const discover = client.getDiscoverResult();
  const listing = await client.listTools();
  const read = await callWhenAdmitted(() =>
    client.callTool({ name: "a", arguments: { query: "read" } }));
  const write = await callWhenAdmitted(() =>
    client.callTool({ name: "write", arguments: { query: "write" } }));
  const contractFailure = await callWhenAdmitted(() =>
    client.callTool({ name: "a", arguments: { query: "invalid", extra: true } }));
  let disconnectCancellation = null;
  if (disconnectTool) {
    const controller = new AbortController();
    const pending = callWhenAdmitted(() => client.callTool({
      name: disconnectTool,
      arguments: { city: "nyc", delay_ms: 30000 },
    }, { signal: controller.signal }));
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
    if (cleanupStartedPath) {
      const cleanupDeadline = Date.now() + 10000;
      while (!(await readFile(cleanupStartedPath).then(() => true).catch(() => false))) {
        if (Date.now() >= cleanupDeadline) throw new Error("disconnected call did not reach its held audit cleanup");
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      let overloaded = false;
      let overloadDetail;
      try {
        // Deliberately no admission wait: this call must see -31999 while cleanup
        // still holds the single run slot.
        const result = await client.callTool({ name: "a", arguments: { query: "blocked" } });
        overloadDetail = result;
        overloaded = result.isError === true;
      } catch (error) {
        overloadDetail = String(error);
        overloaded = error?.code === -31999 || String(error).includes("Server busy");
      }
      if (!overloaded) throw new Error(`admission was released while disconnected-call cleanup was held: ${JSON.stringify(overloadDetail)}`);
      await writeFile(cleanupReleasePath, "release\n");
    }
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
