import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";

const [url, token] = process.argv.slice(2);
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
  process.stdout.write(JSON.stringify({ discover, listing, read, write, contractFailure }));
} finally {
  await client.close();
}
