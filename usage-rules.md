# PtcRunner package usage rules

These rules are for coding agents integrating the published `ptc_runner` Hex
package into a host application. They are not instructions for models running
inside PtcRunner, and they do not replace the repository-maintenance rules in
`AGENTS.md`.

To drive the `ptc` executable instead of embedding the package, run
`ptc docs agent-guide` — an installed executable serves the guide and every
reference for its own version.

## Consult the public contracts

- Use `mix usage_rules.docs PtcRunner.Kernel` and
  `mix usage_rules.docs Module.function/arity` before relying on a remembered
  API. Do not infer supported behavior from internal modules or struct fields.
- Start with the [PtcRunner API documentation](https://hexdocs.pm/ptc_runner/),
  the [embedding guide](https://hexdocs.pm/ptc_runner/embedding.html), and the
  [`PtcRunner.Kernel`](https://hexdocs.pm/ptc_runner/PtcRunner.Kernel.html)
  module documentation.
- Treat documented constructors, return tuples, ownership rules, and limits as
  contracts. PtcRunner is a 0.x package, so recheck them when upgrading.

## Choose one construction path

- Prefer `PtcRunner.Kernel.ApplicationPackage` followed by
  `PtcRunner.Kernel.RunBuilder` when a frontend accepts application manifests.
  This preserves the CLI's bounded acquisition, provider resolution,
  environment assembly, event, result-projection, and cleanup behavior.
- Use the direct `PtcRunner.Kernel` path only when a trusted host must assemble
  native components, capabilities, workflow and mission environments, limits,
  and sinks itself.
- Do not create a second manifest loader, provider lifecycle, or event path in
  a controller, job, or transport adapter.

## Preserve authority and ownership

- Construct authority-bearing inputs and validated configuration through their
  documented `new` or acquisition functions; do not bypass validation with
  struct literals.
- Keep workflow and mission environments separate. A mission receives only
  the data and capabilities explicitly placed in that mission.
- Create a fresh run configuration and event sink for every run. They are
  one-shot values.
- Keep credentials, endpoints, native handles, processes, and cleanup
  functions on the host side. Never project them into PTC-Lisp data, prompts,
  events, or inspection records.
- The shipped LLM adapter is `PtcRunner.LLM.ReqLLMAdapter`. To trial
  `ptc_llm_http` `0.1.0`, add `{:ptc_llm_http, "== 0.1.0"}` and set
  `config :ptc_runner, :llm_adapter, PtcRunner.LLM.PtcLlmHttpAdapter`. Do not
  select that adapter without the optional dependency, and do not author a
  manifest adapter module. Keep ReqLLM as the control until deterministic
  loopback, live non-stream, and live streaming coverage have all succeeded
  against the exact published pin.
- The process that opens a stateful REPL session must drive and close or abort
  it. Passing its public struct to another process does not transfer ownership.

## Extend through the supported boundaries

- Resolve the complete dependency closure of shipped components with
  `PtcRunner.Kernel.Library.resolve_components/1` before compiling a bundle.
- Define host tools with `PtcRunner.Kernel.Capability.new/1`, including bounded
  input schemas and accurate effects. Return JSON-like success values or a
  documented `PtcRunner.Kernel.ProviderError`; do not raise for expected
  provider failures.
- A host that installs custom providers owns their application lifecycle,
  credentials, resource registration, and idempotent cleanup.
- Keep prompts, model-turn logic, retries, delegation, and task orchestration in
  replaceable PTC-Lisp components. Native host code should establish authority
  or enforce a boundary, not become a second hard-coded agent framework.
- `PtcViewer` ships with the standalone release, not the Hex package. An
  embedded host must treat it as optional and check that it is loaded before
  calling it.
