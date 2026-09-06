# Kernel inspection lab

This credential-free maintainer lab runs from a source checkout; it is not a
shipped example. It drives the shipped `agent.core` loop against
a scripted model, the published `ptc-fs-mcp@0.3.0` filesystem MCP server, one
host-native read capability, and a protocol-faithful stateless MCP 2026-07-28
server. The remote fixture exposes structured, text, and `isError: true`
results. The scripted model first emits an invalid PTC-Lisp program, receives
evaluation feedback, then calls every fixture successfully. Each journey
produces both a sanitized canonical trace and an opt-in `0600` private
inspection artifact with two LLM calls and the complete recovery dialogue.
Node.js and npm are required to install and launch the pinned filesystem
package.

The same domain-neutral task runs twice. The `direct` journey exposes the five
capabilities directly in the frozen mission inventory. The `wrapper` journey
adds a small prompt-visible PTC-Lisp wrapper while keeping the same underlying
authority. Comparing the private LLM-request records shows the exact inventory
and generated-program difference.

Run it from the repository root:

```console
mix run scripts/labs/inspection-lab/run.exs
```

The command prints its temporary artifact directory, writes one project
document per journey beside it, and prints an exact `mix ptc viewer` command
for the `direct` journey. Those project documents grant the Viewer the private
inspection artifacts, so treat the browser tab as a private sink. To keep
artifacts at a chosen location, pass one new empty directory:

```console
mix run scripts/labs/inspection-lab/run.exs /tmp/ptc-inspection-lab
```

Each journey writes canonical artifacts under `artifacts/traces/` and private
artifacts under `artifacts/inspection/`, the conventional owner-only project
artifact root. Those sibling directories can be passed directly to
`mix ptc transcript`; create a third directory outside the root for
`--private-output`.

Inspection artifacts contain full model requests/responses, generated source,
and capability payloads. They are not sanitized traces and should not be
shared as such.
