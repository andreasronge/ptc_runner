# Agentic `ptc_task`: SubAgent-Backed MCP Tool

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-10 |
| Related | `Plans/agentic-mcp-aggregator.md`, `Plans/agentic-aggregator-spike.md`, `docs/guides/subagent-concepts.md` |

## Summary

`ptc_task` is the agentic MCP tool exposed by `ptc_runner_mcp`. It
accepts a plain-English task and runs an internal `PtcRunner.SubAgent`
session whose generated PTC-Lisp executes through the existing MCP
aggregator sandbox. The host MCP client sees a single tool call. The
server runs an internal agent loop with prompt assembly, generated
program, sandboxed execution, and turn feedback.

`ptc_task` is opt-in (`--agentic`), supplements but does not replace
`ptc_lisp_execute`, and follows the interface contract defined in
`Plans/agentic-mcp-aggregator.md`. This document specifies how that
interface is implemented on top of SubAgent: the adapter shape, the
SubAgent config forwarding contract, the system-prompt assembly, the
compact capability summary generation, the auto-logged upstream
ledger, the terminal contract, and the safety contract for write-
capable agentic execution.

## Decision And Motivation

The earlier draft of this document weighed four options for adding
multi-turn behavior: a local repair loop in `PtcRunnerMcp.Agentic`, a
direct `SubAgent.run/2` call, an extended SubAgent profile, or a
shared loop extracted below SubAgent. The decision is to **reuse
SubAgent as the loop runtime and adapt MCP upstream access through a
normal SubAgent tool surface first**.

Two findings drove the decision:

1. The desired behavior is an autonomous agent session, not a repair
   loop. Multi-turn execution earns its keep precisely because it
   lets the model observe upstream response shape, store
   intermediates, and recover from feedback — capabilities SubAgent
   already implements and tests.
2. Where `ptc_task` differs from generic SubAgent (error
   classification, MCP envelope shape, aggregator policy enforcement,
   ledger collection) the cost is in policy and translation, not in
   the loop itself.

The MCP layer owns aggregator policy, the upstream ledger, envelope
projection, error classification, capability-summary generation, and
the safety contract. SubAgent owns the prompt → generate → execute →
feedback loop.

## Core Principles

- `ptc_task` is opt-in and operator-configured.
- Single-shot (`max_turns = 1`) is the default. Multi-turn is opt-in
  and changes the safety posture.
- The host MCP client describes outcomes in plain English. The
  server-side planner owns upstream call planning.
- Generated PTC-Lisp executes only through the existing aggregator
  sandbox. No new direct upstream, network, or filesystem access.
- All upstream MCP calls made by the agent are recorded to an
  in-memory ledger and returned to the host as `upstream_calls`. The
  ledger is built by the runtime, not by generated code.
- `(return …)` and `(fail …)` are the only terminal forms in v1. The
  ledger surfaces partial work in either case.
- Cancellation stops future work. It does not roll back completed
  upstream side effects.
- Repair is conservative. In the absence of reliable upstream
  read/write annotations, repair stops after the first upstream call.
  Operators who want broader runtime-error repair should use upstreams
  that populate read-only/destructive annotations or run the
  aggregator in read-only mode.
- Operators configure SubAgent details through one JSON file under a
  documented allowlist. Reserved keys are rejected loudly at boot.
- The MCP-controlled middle of the system prompt (PTC-Lisp rules,
  terminal contract, aggregator authoring card, upstream catalog) is
  not operator-overridable. Operators get prefix and suffix slots.
- Secrets and raw upstream payloads must not appear in traces unless
  full payload tracing is explicitly enabled.

## Configuration

### CLI Flags And Env Vars

Existing aggregator flags from `Plans/agentic-mcp-aggregator.md`
(`--agentic`, `--agentic-model`, timeouts, budgets, tracing) carry
through unchanged. This spec adds:

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--agentic-max-turns` | `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS` | `1` | Forwarded as SubAgent `max_turns`. `1` uses SubAgent's existing single-shot behavior. |
| `--agentic-retry-turns` | `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS` | `0` | Forwarded as SubAgent `retry_turns`. Semantics are SubAgent's existing retry-turn semantics. |
| `--agentic-allow-writes` | `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES` | `false` | Permit write-capable upstream calls inside the agent session. Required for multi-turn against write-capable upstreams. |
| `--agentic-subagent-config` | `PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG` | unset | Path to a JSON file with forwarded SubAgent options. See "SubAgent Config File" below. |
| `--agentic-capability-summary-max-bytes` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES` | `800` | Total byte budget for the auto-generated capability summary advertised in the `ptc_task` external description. |
| `--agentic-capability-summary` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY` | unset | Path to a UTF-8 file whose contents replace the auto-generated capability summary verbatim. Boot error if oversize. |

Boot validation:

- if `--agentic-max-turns > 1`, `--aggregator-read-only` is unset,
  and `--agentic-allow-writes` is unset, the server fails to boot
  with a clear error explaining that multi-turn agentic execution is
  either read-only or explicitly write-capable;
- if `--agentic-allow-writes=true` is set without `--agentic`, the
  server fails to boot;
- `max_turns` and `retry_turns` are validated by SubAgent's existing
  option validation after layered config is resolved. The MCP adapter
  does not redefine their arithmetic or clamp one based on the other;
- if `--agentic-subagent-config` points to an unreadable or malformed
  file, the server fails to boot with a clear error;
- if the SubAgent config contains a reserved or unknown key, the
  server fails to boot with the allowed-key list in the error;
- if `--agentic-capability-summary` exceeds
  `--agentic-capability-summary-max-bytes`, the server fails to boot.

### SubAgent Config File

`--agentic-subagent-config` points to a JSON file whose keys are
forwarded to SubAgent under a strict allowlist. JSON is used for
ecosystem fit (MCP, host clients, container deployments) and
operator portability (no Elixir knowledge required).

Allowed keys (v1):

| Key | Type | MCP default | Forwarded to SubAgent as |
|---|---|---|---|
| `max_turns` | integer | `1` | `max_turns` |
| `retry_turns` | integer | `0` | `retry_turns` |
| `mission_timeout_ms` | integer, milliseconds | aggregator task budget | `mission_timeout` |
| `system_prompt` | object | `null` | `system_prompt` (see below) |
| `cache` | boolean | `false` | `cache` |
| `thinking` | boolean | `false` | `thinking` |

The `system_prompt` object accepts only `prefix` and `suffix`:

```json
{
  "system_prompt": {
    "prefix": "Free-text operator preamble.",
    "suffix": "Free-text operator coda."
  }
}
```

Each of `prefix` and `suffix` is capped at 4096 bytes. Setting
`language_spec` or `output_format` inside `system_prompt` is rejected
— those slots are MCP-controlled.

Reserved keys (rejected at boot):

- `tools` — MCP owns the upstream tool surface.
- `signature` — fixed by the `(return …)` / `(fail …)` terminal
  contract.
- `output` — locked to `:ptc_lisp`.
- `ptc_transport` — locked for v1.
- `trace_context` — set by the MCP adapter so MCP traces and the
  upstream ledger stay correlated. It carries the MCP `request_id`
  and trace id so SubAgent traces and the MCP envelope's `trace_id`
  refer to the same internal run.
- Any key whose name begins with `_` — SubAgent-internal.
- Any key not in the allowlist — rejected with the allowed-key list
  in the error.

### Layered Precedence

For each SubAgent option, the effective value is resolved in this
order (highest wins):

1. Specific CLI flag or env var (`--agentic-max-turns`,
   `--agentic-model`, …);
2. SubAgent config file (`--agentic-subagent-config`);
3. MCP built-in default for `ptc_task` (e.g. `max_turns: 1`, not
   SubAgent's library default of `5`).

The MCP adapter pins SubAgent's per-Lisp `timeout` to the existing
aggregator sandbox cap (1 s). It is not exposed through the config
file in v1.

The meaning of `max_turns: 1`, `max_turns > 1`, and `retry_turns` is
inherited from SubAgent. `ptc_task` does not introduce a separate
"single-shot" or "repair" loop. It only changes the prompt profile and
the MCP tool surface available inside SubAgent.

## SubAgent Adapter

`PtcRunnerMcp.Agentic.run/2` constructs a SubAgent run using the
normal SubAgent loop plus an MCP-owned tool function:

```elixir
SubAgent.run(agent,
  llm: planner_llm,
  max_turns: max_turns,
  retry_turns: retry_turns,
  system_prompt: assembled_system_prompt,
  tools: %{
    "mcp-call" => &PtcRunnerMcp.Agentic.ToolCall.call/1
  },
  trace_context: PtcRunnerMcp.Agentic.Trace.context(request_id)
)
```

The MCP layer owns:

- prompt assembly (see "System Prompt Assembly");
- the `mcp-call` tool implementation that performs
  aggregator-policy-bounded upstream MCP calls and appends to the
  ledger;
- envelope translation from SubAgent `Step` to the `ptc_task`
  response shape.

SubAgent owns:

- the planner call, including timeout and token cap;
- output extraction (Markdown fence stripping, empty-output
  rejection, non-program rejection);
- parsing and static validation against the existing sandbox;
- executing generated PTC-Lisp;
- turn state, memory, `return` / `fail`, and retry-turn behavior;
- turn feedback assembly for the next planner call;
- per-turn budget accounting against the overall task budget.

No new general-purpose `executor`, `error_policy`, or `trace_adapter`
API is required for v1. The first implementation should prove the
SubAgent-backed shape with a normal SubAgent tool function plus MCP
envelope projection. If later evidence shows that SubAgent cannot
cleanly express the needed behavior through tools and existing trace
context, add the smallest possible extension point in a follow-up
spec.

### MCP Integration Contracts

#### `mcp-call` Tool

The MCP adapter injects exactly one SubAgent tool in v1:
`"mcp-call"`. Generated PTC-Lisp calls it as:

```clojure
(tool/mcp-call {:server "github"
                :tool "search_issues"
                :args {:query "is:issue auth"}})
```

The tool argument contract:

- `:server` / `"server"` — required upstream server name;
- `:tool` / `"tool"` — required upstream tool name;
- `:args` / `"args"` — optional map, default `{}`;
- all other keys are ignored in v1 and may produce warnings later.

The tool implementation normalizes keyword and string keys, enforces
the existing aggregator policy, appends a ledger entry, and returns
the tagged PTC-Lisp value described in "Tool Errors As Data".

The MCP adapter builds the `mcp-call` closure with a captured
per-call ledger reference, such as an Agent or task-local holder.
SubAgent does not know about the ledger; it only calls the injected
tool function.

#### Step Projection

`ptc_task` translates the final SubAgent result to the MCP envelope:

- `{:ok, step}` with a SubAgent return value becomes
  `status: "ok"`;
- `{:error, step}` caused by `(fail value)` becomes
  `status: "error"`, `reason: "agent_failed"`;
- `{:error, step}` caused by parser, validation, budget, timeout,
  cancellation, or planner failure maps to the existing
  aggregator-spec error taxonomy;
- `step.return` or `step.fail` is rendered through the deterministic
  `ptc_task` renderer;
- the MCP ledger becomes `upstream_calls`;
- the compact response includes the last generated program when
  `include_program` is enabled (defined in
  `Plans/agentic-mcp-aggregator.md`); full turn detail lives in
  trace storage.

## System Prompt Assembly

The agentic system prompt is **assembled** at run time from
MCP-controlled fragments plus operator-supplied slots. Operators get
prefix and suffix slots only; the MCP-controlled middle cannot be
removed or reordered.

Layout (top to bottom):

```
┌─ operator prefix ────────────  (system_prompt.prefix, optional)
│  free text supplied by the operator config
├─ agentic preamble ───────────  (MCP-controlled)
│  - role
│  - tagged-result rule
│  - terminal contract (return / fail)
│  - multi-turn guidance (only when max_turns > 1)
│  - write-mode safety wording (only when allow_writes)
├─ aggregator authoring card ──  (reused: Tools.aggregator_authoring_card/0)
│  - (tool/mcp-call …) syntax
│  - response-shape helpers
│  - world-fault behavior
├─ upstream catalog ───────────  (reused: Upstream.Catalog.frozen/0)
│  - per-server tool list + signatures
└─ operator suffix ────────────  (system_prompt.suffix, optional)
   free text supplied by the operator config

USER message, per ptc_task call:
  - task        (plain English from the host MCP client)
  - context     (optional JSON)
  - constraints (optional JSON)
```

The v1 role string is:

> You are an agent that writes PTC-Lisp programs to fulfill
> plain-English tasks via the configured upstream MCP servers.

Reuse properties:

- The aggregator authoring card and upstream catalog are the same
  strings advertised in the `ptc_lisp_execute` tool description.
  Single source of truth for "how MCP upstream tools are described
  to LLMs," whether the LLM is the host model or the internal
  planner.
- `Upstream.Catalog.frozen/0` is read once per `ptc_task` call from
  `:persistent_term`. No live re-fetch in v1.
- The operator-supplied `prefix`/`suffix` are concatenated with
  blank-line separators; the operator cannot remove the MCP middle.

## Compact Capability Summary

The `ptc_task` tool description advertised in `tools/list` carries a
compact capability summary — not the full upstream catalog. This
keeps the host MCP client at intent level (see
`Plans/agentic-mcp-aggregator.md` "Client-Facing Capability
Surface").

In v1 the summary is auto-generated from the frozen upstream catalog
at boot, with an optional operator-supplied override.

### V1 Generation Algorithm

The v1 auto-summary deliberately uses a simple deterministic renderer:

1. Sort upstreams by name.
2. Sort tool names within each upstream.
3. Render each upstream as one bullet:
   `- <server>: <tool1>, <tool2>, …`.
4. Append bullets until the total byte budget would be exceeded.
5. If a bullet's tool list is clipped, append `(+N more)` for that
   upstream when it fits.
6. If entire upstream bullets are omitted, append one final
   `- (+N more upstreams)` marker when it fits.
7. Log the final summary once at boot with byte count and hash.

Required invariants:

- deterministic output for the same frozen catalog and budget;
- no raw schemas or response-shape hints;
- no silent over-budget output;
- no LLM-generated prose.

The simple fill-in-order algorithm can omit later alphabetical
upstreams when an earlier upstream consumes most of the budget. This
is acceptable for v1 because omission is signaled by
`(+N more upstreams)`. Operators can raise
`--agentic-capability-summary-max-bytes` or supply a verbatim summary
override when that tradeoff is poor for a deployment.

Example output (budget `800`, three upstreams):

```text
- docs: search, get_page
- fs: list_dir, read_file
- github: get_issue, get_pull, list_pulls, search_code,
  search_issues (+12 more)
```

### Operator Override

`--agentic-capability-summary=<path>` replaces the auto-generated
summary verbatim with the file's contents. The override:

- counts against `--agentic-capability-summary-max-bytes` but is
  never truncated;
- fails the boot if it exceeds the cap (operator chose this content
  deliberately; silent truncation would lie);
- is logged at boot with byte count and a hash.

### Deferred

- per-upstream operator override (e.g. `upstreams.<server>.summary`
  in upstreams config);
- LLM-generated summary at boot or on tool-list change.

Both stay in `Plans/agentic-mcp-aggregator.md` "Future Capability
Summary Generation" and are not v1.

## Auto-Logged Upstream Ledger

Every `(tool/mcp-call …)` invocation is handled by the MCP-owned
SubAgent tool implementation, which appends an entry of the form:

```elixir
%{
  server: "github",
  tool: "search_issues",
  args_hash: "a3f2…",
  status: :ok,            # | :error
  effect: :read,           # | :write | :unknown
  result_bytes: 412,      # nil on error
  error_reason: nil,      # or "upstream_error" / "timeout" / …
  duration_ms: 412,
  turn: 1,
  started_at: ~U[2026-05-10 12:00:01Z]
}
```

Properties:

- the ledger is owned by the MCP runtime, not by generated PTC-Lisp;
- generated programs cannot write to it;
- entries are appended on call completion regardless of outcome;
- the ledger is the source of truth for `upstream_calls` in the
  response envelope;
- the ledger lives in memory only and is discarded when the
  `ptc_task` call returns;
- args are hashed for the ledger; raw args remain available only in
  full-payload traces under existing trace controls.
- `effect` is derived from aggregator read-only posture and upstream
  tool annotations when available. If the runtime cannot prove a call
  is read-only, it records `:unknown`, which is treated like `:write`
  for retry safety.

Effect classification algorithm:

- if `--aggregator-read-only=true`, every permitted upstream call is
  recorded as `:read`;
- otherwise, if the upstream tool annotation has `readOnlyHint=true`
  and not `destructiveHint=true`, record `:read`;
- otherwise, if the upstream tool annotation has
  `destructiveHint=true`, record `:write`;
- otherwise, record `:unknown`.

MCP annotations are inconsistently populated by upstream servers in
the wild. For unannotated deployments, `:unknown` may be the dominant
classification, which means `retry_turns > 0` mostly helps
parse/validation/pre-call runtime failures after the first upstream
call. This is intentional conservatism for v1.

## Tool Errors As Data

Inside the `ptc_task` SubAgent tool surface, `tool/mcp-call` returns
tagged values rather than raising for upstream/world faults. The
Lisp-facing shape uses PTC-Lisp keyword keys:

```clojure
;; success
{:ok true :value <result>}

;; world fault (visible to the program as a value)
{:ok false :reason "upstream_error" :message "..."}
{:ok false :reason "timeout" :message "..."}
{:ok false :reason "response_too_large" :message "..."}
```

Generated PTC-Lisp should inspect `:ok` before reading `:value`:

```clojure
(let [r (tool/mcp-call {:server "github"
                        :tool "search_issues"
                        :args {:query "is:issue auth"}})]
  (if (:ok r)
    (return (:value r))
    (fail {:reason (:reason r) :message (:message r)})))
```

When such values are returned through the final MCP JSON envelope,
keyword keys are rendered as JSON object keys without the leading
colon, matching existing PTC-Lisp JSON rendering conventions.

This makes upstream/world faults visible to generated programs as
values, lets the program decide between retry, partial answer, and
`(fail …)`, and lets the MCP adapter classify final failures
consistently. Generated-code faults (parse, validation, sandbox
violations) continue to surface as exceptions and are eligible for
repair turns under the policy below.

The `ptc_lisp_execute` tool keeps its current semantics. Tagged-error
behavior is scoped to the `ptc_task` SubAgent tool surface.

## Error Classification And Repair Policy

`ptc_task` reuses SubAgent's existing retry-turn behavior. The MCP
adapter adds one safety constraint: automatic retry/repair is disabled
after any mutating or unknown-effect upstream call has been attempted.

The runtime decides this from the ledger, not from model cooperation.
`effect: :write` and `effect: :unknown` both disable repair for the
rest of the `ptc_task` call. `effect: :read` does not.

| Failure | Repair eligible? |
|---|---|
| `ptc_parse_error` | yes |
| `ptc_validation_error` | yes |
| `ptc_runtime_error` before any `:write` / `:unknown` ledger entry | yes |
| `ptc_runtime_error` after any `:write` / `:unknown` ledger entry | no |
| `upstream_error` returned as data | no (program decides) |
| `planner_error` / `planner_timeout` | no (terminal) |
| `budget_exceeded` / `cancelled` | no (terminal) |

The important distinction is effect, not success. A mutating call may
have produced a side effect even if its response later classified as
an error, so any `:write` or `:unknown` ledger entry disables
automatic repair.

## Terminal Contract

Generated programs end with one of two forms:

- `(return value)` — the agent believes the requested task is
  complete. `value` is rendered as `answer` / `structured_result`
  per aggregator-spec rendering rules.
- `(fail reason)` — the agent reports it could not complete the
  task. `reason` is rendered as the failure message.

The MCP envelope status is determined by terminal form:

- `(return …)` → `status: "ok"`.
- `(fail …)` → `status: "error"` with `reason: "agent_failed"` and
  the LLM-supplied message.
- planner / parser / validator / runtime / budget / cancel failures
  → `status: "error"` with the corresponding reason from the
  aggregator-spec error taxonomy.

In every case the response includes `upstream_calls` from the ledger.
Hosts that need to detect partial work after a failed call inspect
the ledger.

## Response Shape

```json
{
  "status": "ok",
  "answer": "deterministic compact preview",
  "structured_result": {},
  "program": "(generated ptc-lisp, last turn, when enabled)",
  "transcript": {
    "turns": 2,
    "trace_id": "..."
  },
  "planner": {
    "model": "openrouter:google/gemini-3.1-flash-lite-preview",
    "duration_ms": 1430,
    "prompt_bytes": 12000,
    "output_bytes": 600,
    "turns": 2
  },
  "execution": {
    "duration_ms": 900,
    "result_bytes": 309,
    "truncated": false,
    "max_result_bytes": 4096
  },
  "upstream_calls": [
    {"server": "github", "tool": "search_issues", "status": "ok",
     "duration_ms": 412, "turn": 1}
  ]
}
```

Multi-turn responses include only the last turn's program in
`program`. The full per-turn transcript is available through trace
storage referenced by `trace_id`. The response stays compact enough
to fit in the host MCP client's tool-result context.

## Safety Contract

When `--agentic-allow-writes=true` and aggregator read-only is
disabled, the `ptc_task` tool description advertised in `tools/list`
must explicitly include:

> `ptc_task` may perform write operations against configured upstream
> MCP servers. It may partially complete work before returning an
> error. If `status` is `error` and `upstream_calls` is non-empty,
> partial side effects have occurred. Do not invoke `ptc_task` again
> with the same task without first inspecting `upstream_calls`, as
> doing so may duplicate writes.

When the server is in read-only posture (the default) the safety
wording is replaced with a read-only assertion consistent with the
existing read-only annotation conventions in the aggregator spec.

Cancellation:

- the host MCP client cancelling `ptc_task` stops future work;
- in-flight upstream calls are best-effort cancelled where the
  sandbox supports it;
- completed upstream side effects are not rolled back;
- the response records `cancelled` and includes the partial ledger.

## Planner Prompt Additions

These rules are appended into the agentic preamble of the system
prompt (between operator prefix and the authoring card). The
operator-supplied prefix and suffix cannot remove them.

In all modes:

- "Upstream calls return `{:ok true :value …}` on success and `{:ok
  false :reason …}` on world faults. Inspect the result before
  reading fields."

The multi-turn (`max_turns > 1`) prompt additionally includes:

- "You may take multiple turns. Use earlier turns to observe upstream
  response shape via `(println …)` if you are unsure of the shape."
- "Each turn ends with one expression. End the session with `(return
  …)` when the task is complete or `(fail …)` when you cannot
  complete it."
- "Side effects are real and not rolled back. Do not repeat a
  successful write."

## Operator UX

To keep configuration discoverable:

- **Example file.** Ship `mcp_server/priv/agentic.example.json`
  containing every allowed key at a typical default, with a sibling
  `agentic.example.md` documenting each key.
- **Boot log.** On agentic startup the server emits one structured
  log line:
  ```
  [info] Agentic mode: subagent_config=/etc/ptc/agentic.json
         applied={max_turns: 3, retry_turns: 1,
                  system_prompt.prefix: 742B,
                  cache: true}
         defaulted={mission_timeout_ms: 45000, thinking: false}
         capability_summary={bytes: 612, hash: a3f2…}
  ```
- **Effective-config subcommand.** `ptc_runner_mcp
  --print-effective-config` prints the merged config with provenance
  per key (built-in default / config file / CLI flag) and exits.
  Intended for operator debugging before launch.
- **Reserved-key error.** Misconfigured keys fail the boot with a
  message listing all allowed keys and which reserved keys are off
  limits.

## Testing

Config tests:

- `max_turns` defaults to `1`;
- `retry_turns` defaults to `0`;
- `allow_writes` defaults to `false`;
- `max_turns > 1` without read-only or `allow_writes` fails boot
  with the documented safety error;
- `allow_writes` without `--agentic` fails boot;
- `max_turns` and `retry_turns` are forwarded to SubAgent using
  SubAgent's existing validation and semantics;
- SubAgent config file parses with allowed keys and rejects each
  reserved key with the documented error;
- unknown keys produce an error that includes the allowed-key list;
- CLI flag overrides config-file value; config-file value overrides
  built-in default;
- `--print-effective-config` lists every key with provenance.

Capability summary tests:

- empty upstream set produces an empty summary;
- upstream and tool ordering is deterministic;
- summary respects `--agentic-capability-summary-max-bytes`;
- truncation adds `(+N more)` when a tool list was clipped and
  `(+N more upstreams)` when whole upstream bullets were omitted;
- operator override is forwarded verbatim and fails boot when
  oversize.

Effect classification tests:

- aggregator read-only posture records permitted calls as `:read`;
- `readOnlyHint=true` and not `destructiveHint=true` records `:read`;
- `destructiveHint=true` records `:write`;
- absent or ambiguous annotations record `:unknown`;
- `:unknown` disables repair like `:write`.

Adapter tests (stub planner):

- single-shot run produces aggregator-spec envelope and ledger entry;
- multi-turn run: turn 1 observes shape via `println`, turn 2 calls
  `return`; envelope reports `turns: 2` and full ledger;
- `(return X)` produces `status: "ok"`;
- `(fail Y)` produces `status: "error"` with `reason:
  "agent_failed"` and includes the ledger;
- repair turn is granted on parse and validation failures and
  succeeds;
- repair turn is denied after the first `effect: :write` or
  `effect: :unknown` ledger entry, even with `retry_turns: 1`;
- repair turn remains available after read-only upstream calls when
  SubAgent would otherwise grant it;
- upstream `:ok false` is delivered to the program as a value, not
  raised as an exception;
- operator `system_prompt.prefix` and `suffix` appear in the
  assembled prompt around the MCP-controlled middle, and cannot
  remove the terminal-contract rule;
- cancellation mid-turn returns `cancelled` with the partial ledger.

Renderer and aggregator-policy tests inherit from the aggregator
spec.

Real-provider smoke (`gemini-flash-lite`):

- single-shot fake-GitHub auth task pass rate at least matches the
  aggregator-spec baseline (`3/3` from the initial spike);
- multi-turn fake-GitHub auth task pass rate **with the GitHub-
  specific response-shape rule removed from the prompt** — measures
  whether observability via `println` removes the need for per-server
  prompt hardcoding.

## Out Of Scope For V1

- LLM-emitted plan ledger primitives (`plan/start`, `plan/done`,
  `plan/fail`);
- in-call upstream-call idempotency / dedup cache;
- cross-call session memory or durable resumability;
- a `partial` terminal status or third return form;
- replacement (rather than wrap) of the MCP-controlled system-prompt
  middle by operator config;
- per-upstream operator-supplied capability summaries
  (`upstreams.<server>.summary`);
- LLM-generated capability summary;
- MCP Sampling / host-client-LLM delegation;
- post-execution LLM summarization;
- direct filesystem/network access from generated code;
- replacing or hiding `ptc_lisp_execute`;
- exposing `memory_limit`, `memory_strategy`, or `ptc_transport` as
  CLI flags or SubAgent config-file keys.

## Near-Term Sequencing

1. Land the deterministic aggregator usability fixes from
   `Plans/agentic-mcp-aggregator.md` "Near-Term Sequencing".
2. Ship single-shot `ptc_task` (`max_turns = 1`) backed by SubAgent
   with the auto-logged ledger, the two-state terminal contract, the
   assembled system prompt (operator prefix/suffix + MCP middle +
   reused catalog), and the auto-generated capability summary.
3. Add `--agentic-subagent-config` JSON forwarding and
   `--print-effective-config` for operator UX.
4. Real-provider smoke at `N ≥ 20`. Decide whether `max_turns > 1`
   earns its keep.
5. If yes, enable multi-turn under `--aggregator-read-only` first.
   Add the safety-contract tool description and ship multi-turn
   read-only.
6. If multi-turn read-only is reliable, open `--agentic-allow-writes`
   with the explicit write-mode safety contract.

Each step gates on evidence from the previous step. Skipping steps
requires explicit justification in a follow-up plan.

## Open Questions

- Is the normal SubAgent tool surface plus `trace_context` sufficient
  for `ptc_task`, or does the prototype reveal a need for a small
  SubAgent extension point? Default assumption: no new general
  executor/policy/trace adapter API in v1.
- Do `ptc_lisp_execute` consumers benefit from the tagged-result
  upstream form, or does it stay scoped to `ptc_task`? Decide after
  step 2.
- Should multi-turn budget accounting share one wall-clock budget
  across turns (current spec) or per-turn budgets that re-tick?
  Default is shared until evidence says otherwise.
- SubAgent's namespace tool renderer
  (`lib/ptc_runner/sub_agent/namespace/tool.ex`) and the aggregator
  catalog renderer
  (`mcp_server/lib/ptc_runner_mcp/upstream/catalog.ex`) use
  different stylistic conventions. They do not currently overlap in
  any single prompt — `ptc_task` shows only the aggregator catalog
  because MCP owns the tool surface. Convergence is deferred until
  a real consumer needs both.
