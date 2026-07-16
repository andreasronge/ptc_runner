# Kernel inspection lab

This credential-free developer lab runs the shipped `agent.core` loop against
a scripted model, the installed `file-read` provider, one host-native read
capability, and a protocol-faithful loopback MCP 2025-11-25 server. It produces
both a sanitized canonical trace and an opt-in `0600` private inspection
artifact.

The same domain-neutral task runs twice. The `direct` journey exposes the three
capabilities directly in the frozen mission inventory. The `wrapper` journey
adds a small prompt-visible PTC-Lisp wrapper while keeping the same underlying
authority. Comparing the private LLM-request records shows the exact inventory
and generated-program difference.

Run it from the repository root:

```console
mix run examples/kernel-inspection-lab/run.exs
```

The command prints its temporary artifact directory and an exact `mix
ptc.viewer` command. To keep artifacts at a chosen location, pass one new empty
directory:

```console
mix run examples/kernel-inspection-lab/run.exs /tmp/ptc-inspection-lab
```

Inspection artifacts contain full model requests/responses, generated source,
and capability payloads. They are not sanitized traces and should not be
shared as such.
