# Phase 6 — manual integration procedure

This file documents the **manual** integration tests required by
`Plans/ptc-runner-mcp-server.md` § 15 Phase 6 ("live tests against
MCP Inspector and at least one production MCP client") for the GUI
clients that cannot be scripted reliably from CI: Claude Desktop,
Cursor, Cline, and the MCP Inspector web UI.

The scripted parts of Phase 6a — handshake, tools/list, unknown_tool
D1 deviation, args_error, exit, cross-language Python smoke — are
all in `test/integration/release_stdio_test.exs` and
`test/integration/cross_language_test.exs`. This file covers
**only what the scripted suite cannot reach.**

Run all of these against a freshly-built release:

```bash
cd mcp_server/
MIX_ENV=prod mix release --overwrite
```

The release binary is at
`mcp_server/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp`.

> **Phase 6a finding (open):** the release artifact does not bundle
> `:crypto`, so any `tools/call name: "lisp_eval"` whose
> `arguments.program` is set raises
> `:crypto.hash/2 is undefined` inside the per-call worker and never
> emits a reply. Skip the success-path manual cases below until that
> bug is fixed (it is out of scope for Phase 6a per § 20.5 risk 2 /
> Phase 6 scope guards). The handshake and unknown-tool cases work
> fine in every client — those are the D1 gate.

## 1. MCP Inspector (web UI)

The Inspector CLI is exercised by `inspector_test.exs`. The web UI
is the supported manual gate for visual rendering of tool results.

```bash
npx @modelcontextprotocol/inspector \
  /absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp \
  start
```

Inspector opens a browser tab. Verify:

- [ ] **Connect succeeds.** The status indicator goes green; no
      red banner. (If you see "Request timed out" — known
      cold-start limitation; reload and try again.)
- [ ] **Tools tab shows exactly one tool:** `lisp_eval`,
      with the long description (PTC-Lisp authoring card) and an
      input schema with `program`, `context`, `signature` fields.
- [ ] **Unknown-tool D1 gate.** In Inspector's "Tools" tab, edit
      the tool name field to `nope_no_such_tool` (or use Inspector's
      raw-frame mode to send
      `tools/call name="nope"`). The reply renders as a tool result
      with an `isError: true` indicator and `reason: unknown_tool`.
      Inspector does NOT show a JSON-RPC `-32601`.
- [ ] **Notifications panel** shows the structured stderr log
      lines (`event: initialize`, `event: tools_call_start`,
      `event: tools_call_stop`, ...).
- [ ] **Disconnect / Reconnect** cleanly. The release exits;
      a fresh `Connect` boots a new instance.

## 2. Claude Desktop (macOS / Windows)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS:

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"]
    }
  }
}
```

Restart Claude Desktop. Verify:

- [ ] **The hammer / tool icon shows `ptc-runner` connected** with
      one tool (`lisp_eval`).
- [ ] **No red error banner** at the bottom of the conversation.
- [ ] **Unknown-tool D1 gate.** Ask Claude in the conversation:
      "Use the `nope` tool from ptc-runner with no arguments."
      Claude attempts the call; the tool result renders as a
      structured error (`reason: unknown_tool`). The conversation
      remains functional — no panic, no UI breakage. The error is
      visible to the user as "tool returned an error" or similar.
      (This is the production-client side of the D1 verification
      gate.)
- [ ] **Quit / restart Claude Desktop:** the `ptc_runner_mcp`
      subprocess terminates cleanly (`pgrep -af ptc_runner_mcp`
      shows nothing 5 s after quit).

## 3. Cursor

Place at `~/.cursor/mcp.json` (or `<project>/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"]
    }
  }
}
```

Restart Cursor. Verify:

- [ ] **Settings → MCP** shows `ptc-runner` as Connected (green dot).
- [ ] **Tool palette** lists `lisp_eval`.
- [ ] **Unknown-tool D1 gate** as above.
- [ ] **Cursor restart** terminates the subprocess cleanly.

## 4. Cline (VS Code extension)

Open the Cline settings file (Command Palette → `Cline: Open MCP
Settings`):

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"],
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

Reload VS Code. Verify the same checklist as Claude Desktop.

## Reporting

If any checkbox above fails on a real production client, the
unknown-tool deviation **D1** must fall back to JSON-RPC `-32602`
per § 7.4 — file an issue and link this file. All of the green
checkboxes constitute the production-client side of the D1
verification gate.
