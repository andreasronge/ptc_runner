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

The resolved closure includes `agent.failure`, `agent.feedback`, `agent.machine`,
`agent.native`, `agent.prompt`, `agent.retry`, `kernel`, `llm`, `result`, and
`workflow.event`. `agent.failure` is a generated `:discoverable` classifier over
the existing bounded LLM envelope; it does not change public outcomes or
fail-fast evidence. `agent.machine` is a `:discoverable` pure constructor/advance
reducer for the shipped loop. Discoverable visibility is not an authority
boundary; the exports remain callable and are not an application customization
API.

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
The exact value this entry returns is the application result: a manifest
`result_schema` describes that envelope by default, or the raw object when
`result_envelope` is false. Invalid candidates receive bounded correction
feedback while a turn remains; exhausting correction reports authenticated
`result_contract_failed` for that same projected value.

### `agent.core/run-value`

```clojure
(agent.core/run-value task config)
```

Returns the application value to its PTC-Lisp caller without completing the
outer workflow and without validating it against the manifest result contract.
A subject failure or provider failure calls `fail`, so use this entry when the
caller should continue only after a successful agent result.

By default the returned value is raw and unvalidated. Set `return_contract` to
the name of one application-declared `phase_return_schemas` entry to constrain
the value crossing back to workflow code. The selected contract is rendered in
the initial prompt, and each invalid explicit return consumes a turn and
receives bounded correction feedback while another turn remains. Exhausting
correction propagates an authenticated `phase_return_contract_failed` error;
it does not expose the rejected value.

### `agent.core/run-outcome`

```clojure
(agent.core/run-outcome task config)
```

Represents model-attributable completion or failure as data. The outcome
remains workflow data; this entry does not validate against the manifest
result contract:

```clojure
{:status :returned :value application-value}

{:status :subject-failure
 :kind failure-kind
 :error bounded-error}

{:status :provider-failure
 :error bounded-llm-envelope
 :model resolved-alias}
```

Subject failures include model-program failure, exhausted turns, and a
non-retryable generated-program error. Prompt, transcript,
evaluation-admission, provider-callback crashes, and other host
failures still fail the outer workflow.
Typed LLM provider envelopes, named capability-quota refusals, and
alias-resolution protocol errors return as `:provider-failure` so the caller
can inspect the closed `kind` and `reason`. `:model` is the resolved
installation alias after routing, including when the caller omitted `model`
and a manifest default selected it. It is omitted only when no alias was
resolved and none was requested.

`run-outcome` also defaults to raw, non-validating returns. Its optional
top-level `return_contract` selects one named `phase_return_schemas` entry for
this standalone loop. A valid return keeps the existing `:returned` shape. An
invalid final-turn return becomes candidate-free `:subject-failure` data with
kind `:phase-return-contract-failed`; an ordinary turn limit remains
`:turn-limit`. Selection is explicit: PtcRunner does not infer a contract from
the mission name, the registry contents, or the application result schema.

Set `retain_programs` to an integer from 1 through 128 to attach admitted
generated programs on that returned outcome. Omitted or `nil` keeps the shapes
above. When set, every returned outcome — including subject and provider
failures after earlier evaluations — also includes `:programs` and
`:programs-omitted`. Entries are ordered by one-based global turn and contain
`:turn`, `:mission`, exact `:source`, and a bounded `:execution` summary. A
continued execution includes its model-visible observation preview and whether
that preview was truncated; a returned execution records only `:returned`
because the outcome already carries its value. Failed executions retain their
closed outcome, a bounded message, and the `:kind` and `:reason` classifiers
of the evaluation or of the closed error envelope an explicit or capability
failure carries as its value. A classifier is retained only when its name is 1 to
128 characters of letters, digits, `.`, `_`, `:`, `/`, or `-`, whether it
arrives as a keyword or a string; anything else is omitted rather than
disclosed, and the raw evaluation value is never retained. Each retained
observation is independently capped at 2,048 characters.

Enabling retention explicitly discloses these model-visible observations to
the calling workflow. A later reviewer may omit rolled-back failures when all
granted effects are read-only, as in the DABStep example. A workflow with write
or otherwise irreversible effects must not assume that a failed evaluation had
no external effect.

Retention keeps the newest complete entries that fit both the requested count
and a fixed 2,000,000 UTF-8-byte source ceiling; an individual admitted program
larger than that ceiling is omitted in full. Protocol errors and source
rejected before evaluation are not retained. Host and infrastructure failures
that abort the outer workflow still have no outcome to annotate.

The envelope keys are PTC-Lisp keywords. The values of `:status`, `:kind`, and
`:reason` are also keywords; the value of the `:retryable?` field is a boolean.
The table spells keyword values with their leading `:` to preserve their
in-workflow types. Comparing one of these values with its JSON-projected name
string is false: use `(= :limit_exceeded (get response :kind))`, not
`(= "limit_exceeded" (get response :kind))`.

`:kind` and `:reason` are facts. This entry does not add a runtime
`recovery: retry | choose-alternate | abort` axis; the workflow chooses a
disposition. Restarting with another alias starts another agent loop. It does
not resume the previous transcript.

| Observation | Envelope `:kind` value | Envelope `:reason` value | Typical policy |
| --- | --- | --- | --- |
| Transient transport or provider failure | `:provider_error` | `:timeout`, `:unavailable`, `:rate_limited`, or `:transport_error` with boolean `:retryable?` value `true` | retry the same alias |
| Whole-call live LLM deadline | `:timeout` | `:llm_request_timeout` with boolean `:retryable?` value `true` | retry the same alias or choose another |
| Permanent per-alias provider refusal | `:provider_error` | `:authentication_failed`, `:payment_required`, `:denied`, `:not_found`, `:invalid_request`, `:tool_calling_unsupported`, and other non-retryable provider reasons | try another alias or abort |
| Per-alias `max_calls` exhaustion | `:limit_exceeded` | `:capability_quota` with `:details` field `:limit` value `:max_calls` | another alias may still run |
| Global LLM capability quota | `:limit_exceeded` | `:capability_quota` with a workflow or mission capability-call limit | no selected alias can run |
| Aggregate LLM token or cost budget | `:limit_exceeded` | `:llm_total_tokens` or `:llm_cost_microusd` with the refused reservation | inspect remaining, raise the limit, or abort |
| Invalid or unknown alias | `:protocol_error` | `:unknown_model_alias`, `:invalid_model_alias`, or `:model_alias_required` | correct the request; no provider attempt occurred |

A spent per-alias `max_calls` is a named quota refusal, not a subject failure
and not a transport error. `run-value`, `run-result-value`, `run-phased-result-value`,
`agent.core/run`, and `agent.main` still fail-fast on every `:provider-failure`.
When one of those fail-fast paths propagates an installation `max_calls` or a
workflow or mission capability-call quota to the command boundary, it reports
`execution/capability_quota_exceeded` while retaining the bounded quota message.
An authenticated aggregate `llm_total_tokens` or `llm_cost_microusd` reservation
refusal stays a recoverable capability value until the workflow aborts it;
fail-fast entries then report `execution/runtime_limit_exceeded` naming the
refused reservation, not `workflow_failed`. `agent.core/run-outcome` still
returns that envelope as a provider-failure value. Do not infer the terminal
cause from `llm_budget.refused > 0`: a later unrelated failure is not the
earlier budget refusal.

### `agent.core/run-result-value`

```clojure
(agent.core/run-result-value task config)
```

Runs the same loop, validates every raw model-authored terminal candidate
against the manifest result contract, and returns the contract-valid value to
its PTC-Lisp caller. Use this when that raw value is itself the final
contract-shaped application result. Invalid candidates receive bounded
correction feedback while a turn remains. If correction is exhausted, the
Kernel reports an authenticated `result_contract_failed` diagnostic with the
effective turn count, the final schema constraint, and an attested contract
path when one is available. That authenticated cause is retained when the call
is composed through sequential or parallel higher-order functions such as
`map`, `pmap`, and `pcalls`.

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

A non-final phase may also select an application-declared named handoff schema
with `return_contract`. Its complete contract is shown only in that phase's
system prompt. Invalid explicit returns receive bounded correction feedback
while a local turn remains; an invalid final-turn return or exhaustion without
an explicit return fails instead of transitioning. The final phase rejects
`return_contract` and uses the optional application result schema.

Validating entries render the active application result schema in the final
phase. Raw-result entries state that the exact returned value is validated.
Envelope-producing `agent.core/run` states that the host validates the success
envelope and tells the model to return only its value, avoiding double
wrapping. `run-value` and `run-outcome` render no application result obligation.
When either raw standalone entry selects `return_contract`, it renders only
that named handoff contract with standalone-loop wording. A top-level selector
is incompatible with `run-result-value`, `run-phased-result-value`, and
`agent.core/run`; those entries reject it before provider or mission activity.

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
| `return_contract` | omitted | declared contract name or `nil` | On `run-value` and `run-outcome`, selects one named `phase_return_schemas` contract for standalone in-loop validation. |
| `max_turns` | `4` | integer, 1–128 | Bounds provider requests and generated programs in this loop. |
| `max_program_chars` | `64000` | integer, 1–1,000,000 | Bounds one `run_ptc_lisp` program string. |
| `max_observation_chars` | `2048` | integer, 1–65,536 | Bounds the untrusted structural preview and `println` body of one successful observation. |
| `max_transcript_chars` | `262144` | integer, 1–1,000,000 | Bounds the JSON-encoded prospective provider request. |
| `consolidate_at_turns_remaining` | omitted | integer, 1–effective `max_turns` | Adds generic consolidation guidance at and below this remaining-turn count. |
| `retain_programs` | omitted | integer, 1–128 | On `run-outcome` only, attaches admitted generated programs on the returned outcome. |
| `result_envelope` | `true` | boolean | Changes only `agent.core/run`; `false` returns the raw value and validates that raw value against the result contract. |

For the four `max_*` options, an omitted or `nil` value selects the documented
default. `retain_programs` is `run-outcome` only: omitted or `nil` means no
retention, and a present value is an integer from 1 through 128. An
out-of-range integer or a non-integer fails with `invalid_agent_config` before
any provider request or mission evaluation. The command diagnostic names the
option, its inclusive range, and the entry it belongs to, plus either the
rejected integer or the received type — never the original non-integer
content. Signature validation still rejects unknown configuration keys.
`consolidate_at_turns_remaining` fails the same way with
`invalid-agent-config/invalid-consolidation-threshold` when set outside `1` to
the effective `max_turns`.

Omitted or `nil` `mission` selects `default`. An empty, non-string, or unknown
mission fails; the loop never falls back to a different environment.

Omitted or `nil` `return_contract` preserves raw standalone behavior. A
malformed name fails as `invalid-agent-config/invalid-return-contract`; a valid
but undeclared name fails as
`invalid-agent-config/unknown_phase_return_contract`. Both are resolved before
provider or mission activity. Caller-authored projections, schemas, and
validation objects are ignored as authority and cannot enter the prompt or
validator.

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
`execution/turn_limit_exceeded` and name the effective turn ceiling.

What the message recommends depends on how the final turn ended, because only
some of these endings are answered by buying more turns:

| Reason | Final turn produced | Reported remedy |
| --- | --- | --- |
| `intermediate_result` | a successful program that did not `return` | raise `max_turns`, or reduce the work per turn |
| `evaluation_error` | a program that failed | raise `max_turns`, or simplify the work per turn |
| `protocol_error` | no usable `run_ptc_lisp` call | check tool-calling support and any configured `max_tokens` first |

Provider-reported output truncation is terminal when it prevents a usable
action. A response ending in `length` still executes a complete, admissible
`run_ptc_lisp` call. Without one, the shipped non-streaming tool loop fails
immediately as `execution/model_output_truncated` (exit 6) without spending a
protocol-error count or another model turn. The provider subject names the
selected router alias. When the adapter can authenticate the effective
`max_tokens` request cap after provider request normalization, the diagnostic
also names that cap and its bindings. It describes the cap as request metadata:
a provider may silently enforce a lower ceiling. If ReqLLM rewrites, removes,
or ambiguously resolves the cap, the response and terminal diagnostic omit the
unprovable cap metadata while preserving the terminal truncation result.

The cap's `bindings` list is closed and canonically ordered. Live Kernel
requests preserve `application_limit` for the effective
`limits.llm_request_output_tokens`,
`installation_param` for installation `params.max_tokens`, or both when their
values tie. Direct adapter callers use `configured`; computed defaults use
`adapter_default`, `model_output_limit`, and `remaining_context`. Every tied
constraint is retained. The remedy follows the binding: raise the manifest
limit (and its installed host ceiling if lower), the installation parameter,
or both; increase the direct adapter option for `configured`; choose a model
with a larger output/context limit when catalog metadata binds; or reduce the
requested output or retained transcript.

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
attached prelude exports. `apropos` and `doc` cover those exports plus installed
callable capabilities, fixed built-ins, and the bounded Java surface. They do
not enumerate data values. At Kernel boundaries, `doc` can identify an exact
indexed public export and its unattached owning shipped library. The index is
not searched by `apropos` and grants no documentation or call authority. When the inventory is empty, the prompt
says so explicitly
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
| `(return value)` | Completes as `:returned`; validating entries (`agent.core/run`, `run-result-value`, `run-phased-result-value`, and `agent.main`) first check the result contract. |
| Ordinary value | Sends a bounded success observation and continues if a turn remains. |
| `(fail value)` | Becomes a subject failure, except for the proven read-only capability case below. |
| Retryable evaluation error | Sends bounded correction feedback if a turn remains. |
| `:busy` or `:limit_exceeded` admission | Fails the workflow as `evaluation-unavailable`; correcting source cannot clear a host condition. |
| Terminal provider-originated mission failure | Becomes a model-program subject failure. |
| Host input or output validation unavailable | Fails the workflow as `capability-unavailable/input-validation-unavailable` or `capability-unavailable/output-validation-unavailable`. |

An ordinary successful turn commits definitions and adds its native value to
the bounded `*1`/`*2`/`*3` history. A terminal return commits definitions but
does not add the returned value. Failed turns preserve the previously committed
definitions and history.

## Feedback bounds and disclosure

Successful observations contain a heap-proportional value preview and
chronological `println` output. Preview traversal has independent collection,
depth, node, string, character, and UTF-8 byte ceilings; it does not first
serialize the complete value. The default pass preserves sibling shape under a
small per-string ceiling. When the shape pass reports truncation only from
implicit ceilings, one bounded greedy pass raises the item and depth ceilings
to larger internal traversal bounds and the node and string ceilings to the
output budget. It replaces the preview only when the complete compact
representation fits every active ceiling; an incomplete retry is discarded in
favor of the original shape-preserving preview. Explicit traversal ceilings
never trigger this adaptive pass.

Feedback distinguishes value-preview truncation from `println` output omitted
while assembling the bounded observation. For an ordinary successful result,
the exact retained value is available as `*1`, so feedback advises reusing it
instead of repeating a capability call. An explicit return does not advance
history; feedback for a non-final phased return therefore refers only to
persisted definitions and never claims that the returned result is in `*1`.
Omitted print output is not stored in `*1`. The earlier per-call
`max_print_length` bound remains separate and carries its own visible
`... (kept/total chars)` marker.

Truncated previews continue to report the ceilings hit and sampled map keys
(including bounded nested samples). The body is marked as untrusted and escapes
its closing marker. Closures and other executable values cross only as inert
display labels.

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

When a validating agent entry rejects a returned value, feedback may identify permitted
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
trace events, or ordinary logs. Existing authorized private inspection can
still contain the model response and generated source that produced it.

An outer `fail` value is not copied into the public Kernel error or trace.
Framework failure kinds remain readable; application-defined scalar
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
| `schema` | optional JSON Schema object for structured output |
| `cache` | optional boolean preference; host-fixed policy wins |
| `model` | optional manifest installation alias |

A request may include `schema` or a non-empty `tools` list, not both. Successful
text responses contain `content` and may contain `tool_calls`, `tokens`,
`finish_reason`, `output_limit`, and the router-authenticated `model` alias.
A schema request succeeds only as `structured_output` plus optional `tokens`
and `model`; there is no encoded `content` duplicate. Normalized tool calls
use `id`, `name`, and `args`. Invalid provider
arguments may include a bounded `args_error` classification. Token usage may
include `input`, `output`, `cache_creation`, `cache_read`, and fixed-point
`total_cost` as a USD currency and integer microunits object. When provider
pricing is unavailable, `total_cost` is absent; a present zero-microunit object
is a measured zero-cost response.

For non-streaming ReqLLM tool calls, `finish_reason` uses ReqLLM's normalized
vocabulary rather than raw provider stop metadata. A `length` response carries
the effective request `output_limit` when the adapter can authenticate it after
provider normalization; it never claims the provider's actual internal
ceiling. Text, structured-output, and streaming responses do not inherit the
shipped agent loop's fail-fast truncation policy.

Provider failures remain bounded capability error envelopes so workflow policy
can decide whether to fail or recover. After alias resolution, those envelopes
include the public `model` installation alias. Credentials, endpoints, sampling,
timeouts, and byte ceilings remain host-owned and are never supplied through
the PTC-Lisp configuration map.

Built-in adapters classify expected HTTP and transport failures into the closed
`ProviderError` reasons: retryable `timeout`, `unavailable`, `rate-limited`, and
`transport-error`; permanent `authentication-failed`, `payment-required`,
`denied`, `not-found`, `invalid-request`, and `tool-calling-unsupported`.
Unclassified requester failures become retryable `unavailable`. The Dispatcher
preserves that classification in the Lisp envelope.

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
