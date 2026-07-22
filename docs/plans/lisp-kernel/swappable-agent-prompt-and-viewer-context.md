# Prelude-owned agent prompts and trustworthy model-context inspection

Status: implemented and verified. Updated 2026-07-17 from live inspection
of recovery run
`sha256:48f77757268258a09675dd5f8837dec9deb868d948444cd30f81dc7e81b200ac`,
an audit of the current Kernel and Viewer, and an independent Codex review.

This implementation closes two related developer-experience gaps:

1. the shipped agent no longer teaches the model enough PTC-Lisp to reliably
   write valid programs, and prompt policy is mixed into `agent.core`; and
2. the Viewer makes correctly captured private model context look absent or
   contradictory by hiding it behind disclosures and showing independent
   sanitized/private warnings without explaining their relationship.

The planned outcome is a domain-blind `agent.prompt` prelude that owns prompt
construction independently of the agent control loop, leaves a bounded state
seam for future prompt evolution, and produces deterministic model context. The
Viewer will make private-overlay provenance, completeness, system prompts,
generated programs, and feedback obvious without weakening canonical
sanitization.

Within this plan, configurable/evolvable means that `agent.prompt` is separate
PTC-Lisp code that can be edited and recompiled without changing
`agent.core`, and that its renderer is driven by bounded policy state. It does
not mean that a manifest can replace an installed component ID with an
application component. Per-manifest implementation binding would require a
separate explicit component-slot design and is not needed for this work.

## Why this work is needed

### The current agent prompt does not teach the language

`priv/preludes/kernel/agent.core.clj` currently tells the model to call
`run_ptc_lisp`, end with `return` or `fail`, avoid prose, and then appends the
frozen mission-inventory JSON. The V2 inventory teaches exact call forms for
prompt-visible exports and bare capabilities, but it does not teach the general
PTC-Lisp language:

- that the language is a bounded Clojure-like language;
- supported binding, function, conditional, loop, collection, string, JSON,
  and parallel forms;
- string-key behavior for decoded JSON maps;
- the difference between value symbols and function calls;
- the fixed supported namespace set;
- unavailable declarations, user-defined macros, and general host access; or
- small idiomatic examples of `let`, `get`, `map`, `filter`, `reduce`,
  `tool/…`, `return`, and `fail`.

This guidance existed before the minimal Kernel cutover in two forms. The
legacy SubAgent composed `priv/prompts/reference.md` into its system prompt,
and an earlier Kernel experiment shipped `priv/preludes/agent/prompt.clj` as
prompt policy. Those surfaces were deleted with the legacy agent/discovery
systems. The new `agent.core` restored the loop and later added the mission
inventory, but did not restore a compact language reference.

The omission matters for correctness, not just documentation. A model cannot
infer the supported PTC-Lisp subset from JSON capability schemas. It may use
familiar but unavailable functions, invent namespaces or invocation forms,
treat values as functions, or fail to terminate with the required signal.
Evaluation feedback can repair some mistakes, but every repair spends latency,
tokens, quota, and one of the bounded turns.

### Prompt policy is mixed with agent control flow

`agent.core/system-message` currently owns prompt text in the component that
also owns retries, action normalization, evaluation, feedback, and completion.
The code is editable, but changing prompt wording unnecessarily changes the
same source and source hash as the audited control loop.

Separating the prompt into its own prelude provides a clean ownership boundary:

- `agent.core` owns the model/evaluation loop;
- `agent.prompt` owns prompt content, rendering, and prompt-policy state;
- `agent.native` owns the current model action schema and normalization;
- `agent.feedback` owns bounded correction messages; and
- the Kernel continues to own authority and hard resource limits.

This is an ordinary installed dependency, not runtime dependency injection.
Both components remain editable and are frozen into each compiled bundle. A
newly compiled run sees new source; a running bundle remains immutable.

### The frozen inventory is trustworthy but expensive as prompt text

The inspected recovery run sent the same 1,472-byte system prompt on both LLM
requests. The Viewer's estimate attributes 62% of total input tokens to the
mission inventory and 82% to the repeated system prompt plus native tool
schema.

The exact run contains inventory schema V2 with four prompt-visible exports,
one bare `fs-read` capability, and execution limits. Trace and inspection
envelope versions are separate contracts and must not be confused with the
mission-inventory version.

Structured deterministic JSON is the right authoritative frozen projection,
but it is not automatically the best model-facing explanation. Repeating full
input/output schemas for capabilities that should be reached only through
documented mission wrappers adds cost and competing invocation surfaces.

The existing `Capability.model_visible` flag already separates discovery from
authority for programmatically constructed capabilities. The shipped
`file-read` manifest provider and MCP selection cannot currently set it. Adding
a prompt-visible wrapper therefore does not remove the underlying raw
capability schema from model context.

Visibility remains discovery policy, not authorization. A capability with
`model_visible: false` is still callable by exact name when the host granted it
to the active environment. This is intentional and must remain explicit in
documentation and tests.

### The Viewer obscures evidence that it successfully joined

The inspected recovery artifact is internally complete:

- both canonical LLM calls have matching private input and output records;
- both private inputs contain the full 1,472-byte system prompt;
- both outputs contain generated PTC-Lisp tool calls;
- the second input contains the first generated program plus tool-role
  evaluation feedback; and
- private records match canonical correlation IDs.

The live Viewer renders those values, but its presentation initially makes
them appear absent:

- the first system prompt is inside a closed “Exact request sent to the model”
  disclosure;
- “Sanitized trace” is rendered unconditionally even when a private overlay is
  active;
- a second “Sensitive inspection data” warning appears farther down beside the
  raw record dump;
- tests require both messages, codifying the confusing presentation;
- raw compact JSON uses `pre-wrap` plus `break-word`, producing apparent splits
  inside identifiers even though the captured bytes contain no such breaks;
  and
- there are no well-defined joined/expected counts.

The label “Exact request sent to the model” also overstates the capture
boundary. Inspection records contain the exact provider-neutral
`llm-request` capability input. An adapter may transform it before transport;
for example, the Ollama text path flattens messages into a text prompt. The
Viewer should call it “Captured model request.”

## Design decisions

1. **`agent.core` calls `agent.prompt` directly.** Prompt policy is a normal
   installed prelude dependency, not a function or rendered string passed by
   the application entry.
2. **The public agent entry remains stable.** `agent.core/run` keeps the current
   `(task, cfg)` signature.
3. **Prompt code and prompt state are different things.** Prelude source is
   immutable for one frozen bundle. Bounded state may affect rendering and can
   later accept model-proposed updates.
4. **The default remains domain-blind.** It may explain PTC-Lisp and the generic
   mission API, but not benchmark data, expected answers, or application-domain
   patterns.
5. **The existing inventory hash retains its meaning.** It continues to hash
   the exact deterministic structured inventory. It is never redefined as a
   prompt hash.
6. **Visibility does not change authority.** Hidden granted capabilities remain
   callable by exact name.
7. **Canonical and private provenance never blur.** Exact prompts, responses,
   generated source, feedback, and payloads remain private.
8. **Missing or corrupt joins are explicit.** Invalid artifacts are rejected
   server-side; accepted but incomplete overlays are labeled in the Viewer.
9. **Raw means raw.** Raw request/record views preserve captured text and use
   horizontal scrolling rather than visual token splitting.

## Planned prompt-policy contract

### Installed dependency graph

Add one shipped component with ID and namespace `agent.prompt`:

```text
agent.prompt
└── kernel

agent.core
├── agent.feedback
├── agent.native
├── agent.prompt
├── agent.retry
├── kernel
├── llm
├── result
└── workflow.event
```

`agent.prompt` depends on `kernel` so it can call
`kernel/mission-model-context`. `agent.core` still depends on `kernel` for
subordinate evaluation. Installed dependency expansion remains deterministic,
local IDs still cannot shadow installed IDs, and no collision rule is
weakened.

Editing `agent.prompt` changes that component's source hash and the frozen
workflow bundle hash without changing `agent.core` source. Editing
`agent.core` remains possible when the control protocol itself changes.

### Prompt API and state lifecycle

The first implementation will expose these stable functions:

```clojure
(agent.prompt/initial-state cfg)
(agent.prompt/render state)
(agent.prompt/transition state event)
```

`agent.core/run` will:

1. create prompt state once with `initial-state`;
2. call `render` immediately before each LLM request;
3. require a non-blank string;
4. use that exact string as the provider-neutral request's `system` value;
5. pass bounded protocol/evaluation events through `transition`; and
6. use the returned state for the next turn.

The initial shipped transition may keep state unchanged. Threading state now
creates the extension seam for later policy evolution without moving the loop
or prompt content back into `agent.core`.

Malformed prompt state, a non-string/blank render, or an invalid transition
result fails deterministically before another provider call. The authoritative
UTF-8/retained-size bounds remain the existing Dispatcher
`capability_argument_bytes` limit and `LLMCapability.max_request_bytes`, both
validated before the requester callback. The prompt prelude may impose a
smaller policy limit, but it cannot weaken host limits. Tests must include a
multibyte oversized prompt and prove that the requester is not invoked.

`agent.core` must not prepend or append hidden prompt content. Everything the
model sees in `system` comes from `agent.prompt/render` and is present in the
private captured request when inspection is enabled.

### Prompt format and compact language card

The shipped renderer will emit a version marker and stable semantic sections,
for example:

```text
PTC_AGENT_PROMPT_V1

Instructions
...

PTC-Lisp
- bounded Clojure-like language
- use let, fn, def/defn, if, loop/recur, map/filter/reduce
- decoded JSON maps use string keys; use get/get-in
- value references are values; call only function references
- finish with (return value) or (fail value)
- no ns/require/refer/import or user-defined macros
- use only fixed built-in namespaces and exact qualified exports shown below

Mission API
...

Limits
...
```

The wording must distinguish unavailable namespace declarations and
user-defined macros from supported fixed namespaces and built-in threading
forms. It must not embed the complete generated function reference.

The version marker is a presentation contract, not a provider feature. The
Viewer may decode supported shipped versions into readable sections. Unknown
or edited formats fall back to the exact captured prompt without claiming a
successful structured decode.

### Future model-driven prompt evolution

This implementation establishes state and transition boundaries but does not
add a model action that edits the prompt. A later change may add an explicit
`revise_prompt` action to `agent.native` and pass a structured proposal to
`agent.prompt/transition`.

That future action must:

- update data, not the frozen prelude source;
- take effect only on the next LLM request;
- have separate update-count and size ceilings;
- preserve the fixed action protocol and essential PTC-Lisp bootstrap unless a
  host explicitly opts into full replacement;
- record accepted/rejected revision provenance privately; and
- require a host-owned store and a new frozen component/state revision for
  persistence across runs.

The model must never write directly to `priv/preludes/` or mutate the active
bundle. Model-authored replacement code, if ever supported, is compiled as a
new component for a later run.

### Prompt acceptance criteria

1. `agent.core/run` retains its current public arity and calls
   `agent.prompt` for every system message.
2. Editing only `agent.prompt` changes captured system text and its component
   source hash while `agent.core` source remains unchanged.
3. Retry turns call the renderer with the current transition state.
4. The exact render result equals the captured provider-neutral `system`
   string.
5. Non-string, blank, invalid-state, and oversized renders fail before the
   requester callback.
6. Prompt tests reject benchmark/domain hints.
7. A scripted-model integration test requires the compact PTC-Lisp facts rather
   than silently assuming them.
8. No model prompt-update action or cross-run persistence is implied by the
   initial implementation.

## Planned deterministic model context

### Preserve structured inventory ownership

`MissionInventory` remains the owner of the authoritative V2 structured
projection and `mission_inventory_hash`. Add a separate deterministic compact
model-facing rendering during `RunConfig` construction rather than asking
runtime PTC-Lisp to re-encode maps in unspecified order. `MissionInventory`
will retain it as `model_rendered`, `model_hash`, and `model_bytes` alongside
the existing `rendered`, `hash`, and `bytes` fields.

The new fields have distinct names and meanings, for example:

```text
mission_inventory_hash        hash of authoritative structured JSON
mission_inventory_bytes       bytes of authoritative structured JSON
mission_model_context_hash    hash of compact model-facing mission rendering
mission_model_context_bytes   bytes of compact model-facing mission rendering
```

These canonical metadata names and struct fields are part of the planned
contract rather than placeholders. Existing fields do not change meaning. Both
renderings are created before `run-started`; no runtime-rendered full prompt is
represented by canonical metadata.

Expose the compact rendering through the reserved
`kernel-mission-model-context` runtime route and
`kernel/mission-model-context` prelude function. Keep the current
`kernel-mission-inventory` / `kernel/mission-inventory` full structured route.
The exact system prompt remains private and is captured only at the LLM
boundary.

The compact mission rendering must:

- list prompt-visible wrapper exports first with exact call forms and concise
  docs;
- retain full input/output schemas only for bare capabilities the model must
  call directly;
- group limits separately;
- be stable across map ordering and runtime processes; and
- carry an explicit rendering version.

Measure bytes and provider-reported tokens before and after. Smaller prompts
are not sufficient by themselves: correct generated programs and recovery
behavior remain the primary gate.

### Capability visibility configuration

Freeze these provider configuration shapes:

```json
{"name":"file-read","config":{"root":"files","model_visible":false}}
```

For MCP, `model_visible` is a list of public names and must be a subset of the
already-authorized `allow` list:

```json
{
  "name":"docs-mcp",
  "config":{
    "allow":["docs.search","docs.read","transport.debug"],
    "model_visible":["docs.search","docs.read"]
  }
}
```

Defaults preserve current behavior: `file-read` is visible and every allowed
MCP capability is visible. Visibility never adds a capability to `allow`.

Tests must prove that:

- a hidden capability is absent from mission model context and
  `cap-list`/`cap-describe` metadata;
- a prompt-visible wrapper over it remains visible;
- the wrapper can invoke the granted hidden capability;
- a direct exact-name call remains possible because visibility is not
  authority; and
- an absent capability remains denied regardless of visibility settings.

## Inspection integrity before Viewer joins

Join summaries are trustworthy only if the server rejects ambiguous artifacts.
Strengthen `InspectionArtifact` correlation validation before adding counts:

- reject duplicate input, output, evaluation-source, or prelude-source records
  for the same record type and correlation identity;
- reject a capability output without its corresponding input;
- allow input without output only as an interrupted attempt;
- require private capability `name` and `environment` to match the canonical
  capability event carrying that ID;
- retain exact evaluation source hash/byte matching; and
- never let the browser silently choose one of two conflicting records.

Add tampered-artifact tests for every rejection. Invalid artifacts fail during
pinning and never become a partial UI overlay.

## Planned Viewer privacy state

### Separate startup failures from browser states

An invalid, unavailable, changed, oversized, or mismatched inspection source
may prevent `PtcViewer.start/1` from pinning the artifact. That is a startup
error, not a browser notice, and remains fail-closed.

For a running Viewer, preserve inspection HTTP status/reason instead of
collapsing every non-2xx response to `null`. Distinguish:

- no inspection artifact configured;
- pinned artifact does not contain the selected run;
- inspection fetch/parse failure;
- accepted artifact with zero relevant records;
- accepted input-only interrupted attempts;
- accepted partial joins; and
- complete joins.

### One state-aware provenance notice

Canonical-only example:

```text
Sanitized canonical trace. Prompts, responses, generated source and capability
payloads are not present. Start the Viewer with a matching local inspection
artifact to inspect model context.
```

Complete-overlay example:

```text
Private inspection overlay loaded. Canonical events remain sanitized; model
requests, responses, generated programs, feedback and capability payloads
shown below come from the pinned local artifact.
```

Incomplete-overlay example:

```text
Private inspection overlay is incomplete: 0/2 LLM calls joined. Canonical
events are available, but captured model dialogue cannot be associated with
this run.
```

Render exactly one top-level notice. An in-section sensitivity label may remain
inside the advanced raw-record disclosure.

### Define denominators before displaying ratios

Use these exact definitions:

- **LLM calls expected:** canonical `capability-started` events named
  `llm-request`.
- **LLM calls joined:** expected IDs with one valid private input and, when a
  canonical stop exists, the corresponding private output. An input-only call
  is explicitly interrupted, not complete.
- **Dispatch capability calls expected:** canonical capability attempts whose
  names are not reserved Kernel runtime routes and therefore cross Dispatcher.
  The excluded set is
  `kernel-eval`, `kernel-mission-inventory`,
  `kernel-mission-model-context`, `runtime-usage`, `runtime-remaining`,
  `cap-list`, `cap-describe`, and `workflow-annotate`.
- **Dispatch capability calls joined:** expected IDs with valid private input
  and the output required by their canonical completion state.

Do not put a generated-program ratio in the top summary. A model response may
contain source that protocol normalization correctly rejects before
evaluation. Show an exact evaluation-source match beside a program when one
exists; do not infer that every textual `run_ptc_lisp` occurrence required an
evaluation.

Never label an overlay complete when:

- the canonical run has no terminal event;
- canonical events were dropped;
- the Viewer stopped at its turn-page budget; or
- an expected join is absent.

In those cases show available counts plus “canonical evidence incomplete.”

## Planned Viewer model-context layout

Place model context immediately after the run summary and frozen context,
before the execution transcript.

### Model context

- Show the first system prompt in a dedicated “System prompt” disclosure, open
  by default when a private overlay is present.
- Label the surrounding structure “Captured model request.”
- Decode known `PTC_AGENT_PROMPT_V*` formats into instructions, PTC-Lisp,
  mission API, schemas, and limits.
- Fall back to an opaque exact prompt for unknown/edited formats.
- Keep the untouched provider-neutral request behind “Raw captured request.”
- If later calls have an identical system prompt, show “same as call 1.” If it
  changes, show the new prompt and make the revision prominent.

### Model dialogue

- Keep each generated PTC-Lisp program directly visible under its response.
- Label evaluation feedback as “Feedback sent to LLM call N.”
- Show the prior assistant tool call with feedback in actual conversation
  order.
- Show evaluation status and exact source/hash match beside evaluated source.
- Preserve partial-page labeling when later canonical events were not fetched.

### Advanced private records

- Move the raw inspection dump into one closed “Advanced/private records”
  disclosure after the readable dialogue.
- Display record counts by type before expansion.
- Preserve exact JSON formatting with `white-space: pre`, normal word breaking,
  and horizontal scrolling.
- Human-readable views may wrap at semantic boundaries; raw views must not
  visually insert whitespace into tokens.

## Acceptance criteria

1. A generated current-code V2 recovery fixture contains two LLM calls, one
   failed first evaluation, feedback, and one successful second evaluation.
2. Canonical-only, complete, zero-join, input-only, partial, fetch-failure, and
   selected-run-mismatch fixtures render exactly one correct provenance notice.
3. Tampered duplicate, output-only, and name/environment-mismatch artifacts are
   rejected before rendering.
4. The recovery fixture reports `2/2` LLM calls joined.
5. The first system prompt is visible without global “Expand all.”
6. Both generated programs are visible without opening raw records.
7. First-evaluation feedback is labeled as input to LLM call 2.
8. Raw prompt DOM text equals the captured string exactly.
9. Long identifiers acquire no apparent mid-token whitespace; raw blocks
   scroll horizontally.
10. The raw record dump is closed by default.
11. Incomplete, dropped-event, and page-budget traces cannot claim a complete
    overlay.
12. Automated markup/router tests pass, followed by manual in-app browser QA at
    one desktop and one narrow viewport with no console errors.

## Implementation-entry investigation gate

No unresolved architectural choice blocks implementation. Complete these
bounded evidence checks first because their results freeze ceilings and
fixtures used by later tests:

1. Generate the current-code V2 two-turn recovery artifact and confirm its
   joins, prompt bytes, programs, and feedback independently of the external
   `sha256:48f…` artifact.
2. Render compact context for the normal fixture and a worst-case bounded
   inventory, then freeze the compact-context ceiling and verify that the final
   system prompt plus messages/tools remains beneath both host request limits.
3. Prototype the `PTC_AGENT_PROMPT_V1` decoder against one supported prompt and
   one edited/unknown format to confirm that structured rendering fails safely
   to the opaque exact prompt.

These are measurement and fixture-generation tasks, not open product-design
questions. Per-manifest prompt implementations and model-authored prompt
updates remain explicitly outside the first implementation.

## Test-first implementation order

### 1. Freeze reproducible evidence and baselines

1. Add a deterministic generator for a current V2 two-turn recovery fixture.
2. Check in its canonical metadata/turns and private inspection projection.
3. Assert IDs, request sizes, response programs, feedback, and source hashes.
4. Record current prompt bytes, compact-context bytes, and provider token
   measurements.
5. Freeze the compact rendering version and its installed size ceiling from
   those measurements before changing the agent.

The external `sha256:48f…` artifact remains diagnostic evidence, but checked-in
acceptance tests must not depend on an external local file.

### 2. Extract `agent.prompt`

1. Add failing integration tests for the dependency graph, unchanged
   `agent.core/run` arity, and initial/render/transition lifecycle.
2. Add `agent.prompt` to `Kernel.Library` with a direct `kernel` dependency.
3. Make `agent.core` depend on and call it directly.
4. Add the versioned compact language card and stable section rendering.
5. Test non-string, blank, invalid-transition, and multibyte oversized cases
   before requester invocation.
6. Update shipped examples and tutorial text.

### 3. Add deterministic compact mission context

1. Preserve existing inventory golden tests and hash semantics.
2. Add a separately versioned host-built compact rendering and hash/byte
   metadata.
3. Add the dedicated Kernel runtime/prelude route used by `agent.prompt`.
4. Test deterministic ordering and byte ceilings.
   The compact projection uses the same 256 KiB installed ceiling as the
   authoritative inventory, so constructing it cannot reject an inventory
   that was previously valid merely because prompt policy is installed.
5. Compare generated-program correctness and recovery with the baseline.

### 4. Add manifest visibility controls

1. Add failing `file-read` and MCP-selection schema tests for the frozen JSON
   shapes.
2. Thread `model_visible` through `FileCapability` and MCP capability
   construction.
3. Add wrapper-over-hidden-capability integration coverage.
4. Test discovery versus direct exact-name authority explicitly.
5. Update module docs, maintainer guide, and manifest examples.

### 5. Strengthen inspection correlation

1. Add failing tampered-artifact tests.
2. Reject duplicate, output-only, and canonical name/environment mismatches.
   Reject duplicate canonical capability-start IDs before joining as well.
3. Preserve valid input-only interrupted attempts.
4. Make browser indexing reject rather than overwrite conflicts defensively.

### 6. Make the Viewer state-aware

1. Replace contradictory-notice tests with the complete state matrix.
2. Preserve inspection fetch status/reason in `app.js`.
3. Compute ratios using the frozen denominators above.
4. Account for incomplete runs, dropped events, and page-budget exhaustion.
5. Render one top-level provenance notice.

### 7. Rework model-context presentation

1. Add the default-open first system-prompt panel.
2. Decode supported prompt versions with opaque fallback.
3. Keep generated programs and next-call feedback visible.
   Preserve canonical LLM ordinals and evaluation windows when an earlier
   private request is absent; do not describe later full message history as a
   delta from an unavailable request.
4. Move raw records to the advanced disclosure.
5. Fix raw wrapping and overflow behavior.
6. Rename “Exact request sent to the model” to “Captured model request.”

### 8. Verify end to end

Run focused Kernel and Viewer tests, then:

```bash
(cd ptc_viewer && mix format --check-formatted)
mix precommit
```

Launch the Viewer against the generated recovery fixture and manually verify in
the in-app browser at desktop and narrow widths:

- one provenance notice and correct join counts;
- default-open system prompt and decoded sections;
- generated programs and feedback direction;
- raw request equality and horizontal scrolling;
- opaque fallback for an unknown prompt version;
- advanced record disclosure;
- canonical-only, zero-join, and input-only states; and
- no browser console errors.

Before push run `mix prepush` as required by the repository workflow. When
touching live LLM integrations, verify current model IDs and `.env` overrides.

## Documentation updates when implemented

Move durable contracts out of this plan as they land:

- `agent.prompt` dependency, API, state lifecycle, and prompt format into
  `Kernel.Library`, prelude source docs, and the Kernel tutorial;
- structured/compact inventory ownership and hashes into `MissionInventory`,
  `RunConfig`, and the maintainer guide;
- provider visibility into `Kernel.Manifest`, `ProviderRegistry`,
  `FileCapability`, `MCPSource`, and the maintainer guide;
- canonical/private provenance, artifact integrity, and join denominators into
  `docs/trace-log-contract.md`; and
- Viewer states and operation into `ptc_viewer/README.md`.

No code documentation should link back to this plan. Remove the plan after all
contracts and acceptance evidence have moved to their durable owners.

## Non-goals

- Do not add per-manifest prompt implementation slots in this work.
- Do not add a model `revise_prompt` action or cross-run prompt persistence yet.
- Do not mutate prelude source or a frozen bundle during a run.
- Do not put private prompts, responses, generated source, feedback, or
  capability payloads into canonical traces.
- Do not make model visibility an authorization control.
- Do not add benchmark-, fixture-, or domain-specific hints to the shipped
  prompt.
- Do not embed the full PTC-Lisp function reference into each request.
- Do not promise byte-for-byte provider wire capture from the existing
  provider-neutral inspection boundary.
- Do not weaken installed/local component collision checks.
- Do not change PTC-Lisp syntax or evaluation semantics as part of this work.
