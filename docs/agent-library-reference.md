# Agent library reference

This reference defines the shipped `agent.core` and `agent.main` PTC-Lisp
interfaces. For a guided workflow, see
[Building agents](guides/building-agents.md).

The libraries implement a provider-neutral loop: request one
`run_ptc_lisp` action, evaluate its program in a named mission, and either
finish or send bounded feedback for another turn. The Kernel continues to own
execution, authority, effects, and resource limits.

## Install the library

A local workflow component must declare `agent.core` as a dependency and the
manifest must select the shipped library:

```json
{
  "id": "my.agent",
  "path": "agent.clj",
  "dependencies": ["agent.core"]
},
{"library": "agent.core"}
```

The resolved closure includes `agent.feedback`, `agent.native`, `agent.prompt`,
`agent.retry`, `kernel`, `llm`, `result`, and `workflow.event`.

Select `{"library": "agent.main"}` when the manifest entry is
`agent.main/run`; its dependency closure includes `agent.core`.

## Entry functions

All `agent.core` entries take a task string and configuration map.

### `agent.core/run`

```clojure
(agent.core/run task config)
```

Runs the loop as a terminal workflow entry. By default it completes the outer
program with:

```clojure
{:ok true :value application-value}
```

Set `"result_envelope"` to `false` to complete with the raw application value.

### `agent.core/run-value`

```clojure
(agent.core/run-value task config)
```

Returns the application value to its PTC-Lisp caller without completing the
outer workflow. A subject failure calls `fail`, so use this entry when the
caller should continue only after a successful agent result.

### `agent.core/run-outcome`

```clojure
(agent.core/run-outcome task config)
```

Represents model-attributable completion or failure as data:

```clojure
{:status :returned :value application-value}

{:status :subject-failure
 :kind failure-kind
 :error bounded-error}
```

Subject failures include model-program failure, exhausted turns, and a
non-retryable generated-program error. Provider, prompt, transcript, quota,
evaluation-admission, and other host failures still fail the outer workflow.
This prevents an evaluator from scoring a provider outage against the subject.

### `agent.core/run-result-value`

```clojure
(agent.core/run-result-value task config)
```

Runs the same loop, validates every model-authored terminal candidate against
the manifest result contract, and returns the contract-valid value to its
PTC-Lisp caller. Invalid candidates receive bounded correction feedback while
a turn remains. If correction is exhausted, the Kernel reports an authenticated
`result_contract_failed` diagnostic with the effective turn count, the final
schema constraint, and an attested contract path when one is available. That
authenticated cause is retained when the call is composed through sequential
or parallel higher-order functions such as `map`, `pmap`, and `pcalls`.

This is the composable result-contract entry used by `agent.main/run`.

### `agent.core/run-phased-result-value`

```clojure
(agent.core/run-phased-result-value task config)
```

Runs ordered mission phases while retaining the exact correlated assistant and
tool transcript. Each phase requires `mission` and `max_turns`, and may provide
an `instruction`, delivered when its phase begins: the first phase's
instruction is appended to the initial task, and at each later boundary the
host rebuilds the system prompt from the next mission's authority and appends
that phase's instruction as a user message. A
`return` in a non-final phase closes that phase and is retained as bounded
observation evidence; only the final phase can satisfy the application result
contract.

Set a phase's `terminal_only` to `true` when it may only make the final
decision; only the final phase may declare it, because an earlier phase that
exhausted without a terminal action would hand off to the next phase and void
the obligation. PtcRunner parses each generated program before evaluation and
accepts only one top-level `return` or `fail` form. A nonterminal program is
not evaluated and receives bounded correction feedback while a phase turn
remains; exhausting the phase this way reports the `terminal-source-required`
turn-limit reason.

`run-phased-result-value` replaces `mission` and `max_turns` with a non-empty
`phases` vector of at most eight maps. Each phase accepts `mission` (non-empty
string), `max_turns` (integer, 1–128), optional `instruction` (non-empty
string), and optional `terminal_only` (boolean). The sum of phase turn budgets
must not exceed 128; an invalid vector fails with
`invalid-agent-config/invalid-phases` before any provider request.

### `agent.main/run`

Set the manifest entry to `agent.main/run` and supply:

```json
{
  "task": "Complete the requested analysis.",
  "agent": {
    "max_turns": 8
  }
}
```

`agent.main/run` delegates to `agent.core`, validates each terminal candidate
against the manifest result contract while a correction turn remains, and
returns the raw contract-valid value. It is a domain-blind convenience entry;
it does not add task-specific prompt policy.

## Configuration

| Key | Default | Accepted value | Effect |
| --- | --- | --- | --- |
| `model` | selected installation default | string | Selects a manifest-installed workflow model alias. |
| `mission` | `"default"` | non-empty string | Selects the mission whose API is rendered and whose environment evaluates programs. |
| `max_turns` | `4` | integer, 1–128 | Bounds provider requests and generated programs in this loop. |
| `max_program_chars` | `64000` | integer, 1–1,000,000 | Bounds one `run_ptc_lisp` program string. |
| `max_observation_chars` | `2048` | integer, 1–65,536 | Bounds the untrusted structural preview and `println` body of one successful observation. |
| `max_transcript_chars` | `262144` | integer, 1–1,000,000 | Bounds the JSON-encoded prospective provider request. |
| `consolidate_at_turns_remaining` | omitted | integer, 1–effective `max_turns` | Adds generic consolidation guidance at and below this remaining-turn count. |
| `result_envelope` | `true` | boolean | Changes only `agent.core/run`; `false` returns the raw value. |

For the four `max_*` options, an omitted or `nil` value selects the documented
default. An out-of-range integer or a non-integer fails with
`invalid_agent_config` before any provider request or mission evaluation. The
command diagnostic names the option and its inclusive range, and either the
rejected integer or the received type — never the original non-integer
content. Signature validation still rejects unknown configuration keys.
`consolidate_at_turns_remaining` fails the same way with
`invalid-agent-config/invalid-consolidation-threshold` when set outside `1` to
the effective `max_turns`.

Omitted or `nil` `mission` selects `default`. An empty, non-string, or unknown
mission fails; the loop never falls back to a different environment.

When one model installation is selected, `model` may be omitted. With several,
omission uses the selection marked `"default": true`. Otherwise the request
fails and lists the available aliases. A `model` value is an installation
alias, never a raw provider model ID. An unknown or `null` alias does not fall
back.

Agent options do not raise Kernel limits. Source size, subordinate evaluations,
provider calls, memory, results, events, parallel work, and the run deadline
remain bounded independently. See
[Application-manifest reference](reference/application-manifest.md#narrow-installed-limits).

## Turn and transcript protocol

The model receives exactly one function tool:

```json
{
  "name": "run_ptc_lisp",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["program"],
    "properties": {"program": {"type": "string"}}
  }
}
```

A valid action contains exactly one tool call with:

- a non-empty string ID;
- the name `run_ptc_lisp`;
- exactly one `program` string argument;
- a non-blank program within `max_program_chars`.

Assistant narration may accompany the tool call and is retained with it. Text
without a call, several calls, a wrong name, malformed arguments, or an invalid
program produces a protocol correction while a turn remains. The correction
retains what the model produced: bounded assistant narration (at most 2000
characters), and, when the call was well-formed except for program size, the
authentic assistant/tool pair. Malformed `tool_calls` are not replayed. Kernel
guidance belongs in the user correction, never in an assistant turn.

The initial task and every retained feedback message state the number of turns
remaining, including the next program. With one turn left, the message requires
the next program to call `return` or `fail`. A configured consolidation
threshold adds domain-blind synthesis guidance before the final turn.

If the loop spends its effective `max_turns` without returning, `run-outcome`
returns bounded subject-failure data. Entries and callers that propagate that
failure through `run`, `run-value`, or `run-result-value` report
`execution/runtime_limit_exceeded` and name the effective turn ceiling.

What the message recommends depends on how the final turn ended, because only
some of these endings are answered by buying more turns:

| Reason | Final turn produced | Reported remedy |
| --- | --- | --- |
| `intermediate_result` | a successful program that did not `return` | raise `max_turns`, or reduce the work per turn |
| `evaluation_error` | a program that failed | raise `max_turns`, or simplify the work per turn |
| `protocol_error` | no usable `run_ptc_lisp` call | check tool-calling support and any configured `max_tokens` first |

A `max_tokens` too small for the model to emit a complete tool call produces
`protocol_error` on every turn, so raising `max_turns` only buys more of the
same failure. The remedy names the agent configuration rather than
`agent.core/run`, because a manifest that declares `agent.main/run` never
mentions the inner entry.

The canonical failed `run-stopped` event retains the bounded `agent_turns`
limit name, its value, and the same `limit_reason`, so trace consumers can
present the same cause.

Before dispatch, the loop JSON-encodes the complete prospective request:
system prompt, accumulated messages, tool schema, and optional model alias. A
request larger than `max_transcript_chars`, or one that cannot be encoded,
fails without calling the provider. Earlier assistant/tool pairs are never
silently discarded to make the request fit. The provider may enforce a lower
request limit.

Exceeding `max_transcript_chars` reports itself the way the turn ceiling does:
`execution/runtime_limit_exceeded` naming the limit and its effective value,
with the canonical failed `run-stopped` event retaining
`failure_kind: transcript-limit` plus the bounded limit name and value. A
request that cannot be encoded at all remains a workflow failure, because no
ceiling was reached.

## Prompt and mission API

`agent.prompt/initial-state`, `agent.prompt/render`, and
`agent.prompt/transition` form the replaceable prompt-policy seam. Each must
return the documented state or text shape; invalid results fail the workflow
as prompt errors.

The default prompt renders one deterministic `Available API` for the selected
mission. If any prompt-visible PTC-Lisp facade functions exist, raw `tool/...`
entries are suppressed. Otherwise direct capabilities are shown. Function
signatures, schema constraints and descriptions, effect metadata, and bounded
documentation are rendered when available.

Top-level mission `data` keys are rendered as `data/<name>` values with their
bounded structural types, but never their values. The inventory is the complete
prompt-visible mission surface. `dir` and `export-meta` inspect visible
attached prelude exports. `apropos` and `doc` cover those exports plus fixed
built-ins and the bounded Java surface. None enumerate data values or direct
tool capabilities. When the inventory is empty, the prompt says so explicitly
instead of leaving a blank heading.
The generic examples do not name `data/input`; an agent sees that reference
only when the selected mission actually grants an `input` data key.

Numeric Kernel limits remain enforced but are not copied into the default
prompt. Trusted workflow code can read the exact frozen structured inventory
with `kernel/mission-inventory`.

Agent prompts must remain domain-blind: they may describe the language,
available API, task, budgets, and correction policy, but not fixture values,
benchmark domains, or expected answer patterns.

## Evaluation outcomes

The loop interprets mission evaluation outcomes as follows:

| Outcome | Loop behavior |
| --- | --- |
| `(return value)` | Completes as `:returned`; `agent.main` first validates the result contract. |
| Ordinary value | Sends a bounded success observation and continues if a turn remains. |
| `(fail value)` | Becomes a subject failure, except for the proven read-only capability case below. |
| Retryable evaluation error | Sends bounded correction feedback if a turn remains. |
| `:busy` or `:limit_exceeded` admission | Fails the workflow as `evaluation-unavailable`; correcting source cannot clear a host condition. |
| Terminal provider-originated mission failure | Becomes a model-program subject failure. |
| Host input validation unavailable | Fails the workflow as `capability-unavailable/input-validation-unavailable`. |

An ordinary successful turn commits definitions and adds its native value to
the bounded `*1`/`*2`/`*3` history. A terminal return commits definitions but
does not add the returned value. Failed turns preserve the previously committed
definitions and history.

## Feedback bounds and disclosure

Successful observations contain a heap-proportional structural preview and
chronological `println` output. Preview traversal has independent collection,
depth, node, string, character, and UTF-8 byte ceilings; it does not first
serialize the complete value. When truncated, feedback reports the ceilings
hit, sampled map keys (including bounded nested samples), and reminds the model
that the complete committed value remains in `*1`. The body is marked as
untrusted and escapes its closing marker. Closures and other executable values
cross only as inert display labels.

The preview is non-authoritative presentation work: a preview failure cannot
turn a committed evaluation into a failure. A retained-memory or `*1` history
commit rejection instead rolls the candidate continuation back and reports
actionable guidance. Programs with only read effects may be corrected and
retried; after a write or unknown effect, the loop tells the model not to
repeat the program because the external effect cannot be rolled back.

Heap and compile-heap feedback explicitly says that the failed program was
rolled back, earlier definitions remain available, and a corrected program
should filter, page, project, or reduce before collecting a large result.

Evaluation-error feedback contains a bounded outcome, error code, and safe
message. A correctable capability error contains its public `kind` and
`reason`. Input-schema feedback may name up to three schema-declared paths,
violated constraints, and small declared numeric, length, or item bounds. It
does not echo submitted values, enum or const literals, undeclared property
names, opaque validator reasons, or provider details.

When `agent.main` rejects a returned value, feedback may identify permitted
and missing keys at retained closed-object paths, only the count of undeclared
submitted keys, and small schema-declared numeric, length, or item bounds.
Open objects report missing required keys without treating extension keys as
invalid. Candidate values, tagged-union matches, enum literals, and const
literals are omitted from model feedback. Result-contract diagnostics are
capped at 32,768 characters, then the whole request is checked against
`max_transcript_chars`.

The terminal exhaustion transition is fail-only and available only to the
shipped `agent.core` prelude. It revalidates the final candidate against the
host's frozen result contract and creates no additional candidate-bearing
record. The candidate does not enter public errors, command envelopes,
canonical events, or ordinary logs. Existing authorized private inspection can
still contain the model response and generated source that produced it.

An outer `fail` value is not copied into the public Kernel error or canonical
trace. Framework failure kinds remain readable; application-defined scalar
kinds become stable fingerprints. Exact failure values, prompts, generated
source, and capability payloads require an authorized private inspection
artifact. Built-in LLM adapters retain only a bounded provider status and
human-readable reason there; request bodies, raw response bodies, headers, and
transport causes are not retained as provider-error details.

## Retry and effect safety

The loop retries only while another turn remains. Retryability also depends on
whether repeating a program could repeat an effect the Kernel cannot undo:

| Observed activity before failure | Retry policy |
| --- | --- |
| No capability call | Correctable. |
| Only declared `read` capabilities | Correctable. |
| Only reserved mission runtime routes | Correctable. |
| Any declared `write` capability | Do not repeat. |
| Any capability with missing effect metadata | Do not repeat. |

Runtime routes such as capability discovery and usage queries are treated as
safe reads. A resource kill after reads remains correctable because it commits
no Lisp state and repeats no external mutation.

Read failures preserve their provider retry classification. Once a write may
have been dispatched, every non-success is non-retryable and may report
`mutation_state: indeterminate`; cancellation does not prove rollback.
Provider callback crashes and process deaths are unclassified and therefore
non-retryable. MCP `input_required` exchanges are terminal even on a read
route.

An explicit `fail` is terminal by default. It becomes correctable only when
the evaluator proves all of the following:

1. the failed value is the exact last recorded capability result, preserved
   through a direct call, simple lexical binding or helper forwarding, or
   `cap/unwrap!`;
2. the capability failure is marked retryable by the evaluator;
3. every observed capability effect was declared `read`.

Rebuilding, copying, or destructuring an equal error-shaped map does not
qualify. Neither does an error-shaped value after an unrelated read.

After an unsafe evaluation failure, the loop never repeats that program. If a
turn remains, it offers one closing turn that asks the model to decide from
evidence already gathered. A second unsafe failure, or no remaining turn,
becomes a `non-retryable-evaluation` subject failure.

## Provider-neutral requests

`agent.core` calls the `llm/request` wrapper. Its request supports:

| Key | Shape |
| --- | --- |
| `system` | optional string |
| `messages` | role/content message array |
| `tools` | optional provider-neutral tool definitions |
| `cache` | optional boolean preference; host-fixed policy wins |
| `model` | optional manifest installation alias |

Successful responses contain `content` and may contain `tool_calls` and
`tokens`. Normalized tool calls use `id`, `name`, and `args`. Invalid provider
arguments may include a bounded `args_error` classification. Token usage may
include `input`, `output`, `cache_creation`, `cache_read`, and `total_cost`.
When provider pricing is unavailable, `total_cost` is absent; a present zero is
a measured zero-cost response.

Provider failures remain bounded capability error envelopes so workflow policy
can decide whether to fail or recover. Credentials, endpoints, sampling,
timeouts, and byte ceilings remain host-owned and are never supplied through
the PTC-Lisp configuration map.

## Concurrency and admission

A run has one subordinate-evaluation lease. Agent loops under `pcalls` can
overlap provider calls, then their evaluations queue in FIFO order. The wait is
bounded by `evaluation_admission_timeout_ms` and the run deadline. Exhausted
`subordinate_evaluations` or an expired admission wait fails the workflow
without spending another agent turn or model call.
When `subordinate_evaluations` is exhausted, the command error names that
limit and its configured ceiling and recommends either raising the applicable
manifest or host ceiling, or reducing total subordinate evaluations or agent
turns.

Set enough `parallel_timeout_ms` headroom for the complete parallel phase. The
Kernel limit reference, not the agent configuration, defines these ceilings.

Use `pcalls` for a fixed heterogeneous fan-out of zero-arity tasks and `pmap`
for a runtime-sized homogeneous collection. Both resolve as callable values,
so a workflow may store them, pass them through a helper, or invoke them with
`apply`; direct and indirect calls consume the same worker budget and deadline.
