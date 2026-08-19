# Friction sweep — 2026-08-19

Branch `fix/friction-sweep-2026-08-19`, three commits, eight issues from the
2026-08-18b/c end-user smoke passes.

## Review status

Two codex rounds, session `01a01bee-8fcc-7d23-b190-955f960aa4ec`.

**Round 1** — 17 findings. Fifteen were checkable against source and all
fifteen held, including four that contradicted this plan's original root
causes. The original commit 2 was not implementable and was re-scoped.

**Round 2** (against commit `8f8581ff`) — the architecture errors are fixed;
four new findings, all verified and applied:

- `agent.native/normalize` has a branch this plan's grouping missed
  (`:invalid-response`, `agent.native.clj:39`, before `prose` is bound), and
  `:multiple-or-missing-tool-calls` covers two different situations.
- `agent_protocol_errors` is not reachable as a usage key without authenticated
  plumbing — counting annotations recreates the provenance hole. Reached
  independently here before the round-2 answer arrived.
- `command_contract.ex:1247` forces every **null-source** row to the catalog
  constant, so a dynamic message with no source needs an explicit branch there
  and in the generated schema.
- Two deferred items were over-deferred; corrected estimates below.

What this plan used to say is recorded where the difference matters, so the same
wrong turn is not taken twice.

Items that left commit 2 are enumerated at the end, split into **blocked on a
decision** and **ready, just not in this sweep** — round 2 showed two had been
over-deferred.

| Commit | Theme | Issues |
| --- | --- | --- |
| 1 | Behaviour and packaging — the run is wrong, not just the message | #1496, #1497, #1498 |
| 2 | The agent-config diagnostic, and the docs that point at a dead command | #1456, #1502 (docs half) |
| 3 | Live spend | #1488 |

Commits 1 and 3 are independent of each other and of commit 2. Delete this file
before the final PR.

---

## Issue hygiene to land with the sweep

1. **#1502's verification comment reports a false regression.** It states
   `--project` no longer resolves `agent.core/run` and that the issue is "worse
   than filed". Verified against this branch's tip:

   ```console
   $ mix ptc repl --project <tutorial>/04-multi-turn-agent.ptc-project.json -e '(doc "agent.core/run")'
   agent.core/run
   (agent.core/run task cfg)
     (task :string, cfg {model :string?, …}) -> :any
     Runs the agent loop as a terminal workflow entry.
   $ … -e '(apropos "agent")'
   ["agent.core/run" "agent.core/run-outcome" … 16 entries]
   ```

   The tester used a freshly-scaffolded project. `CommandInitializer`'s manifest
   (`lib/ptc_runner/kernel/command_initializer.ex:31`) declares one `main.clj`
   component and **no** `library` selection, so nothing agent-related is
   attached and the behaviour is exactly as originally filed.

2. **#1478's residual list is stale on one row.** `workflow_heap_words` is
   already named — `lib/ptc_runner/kernel/runner.ex:878` — landed by #1525
   (`c19ebfdc`) after that comment was drafted. #1478 is **closed**, so its
   remaining ceilings are in no open issue. File them (see Deferred 5).

---

## Commit 1 — `fix(agent,cli,examples): correct the recovery turn, the closed pipe, and the materialized tutorial`

### 1.1 #1496 — the protocol-error correction turn omits the model's own response

**Root cause, verified.** `priv/preludes/kernel/agent.core.clj:549` calls
`continuation-state` with `action` = `nil` on the `:protocol-error` branch, so
`append-agent-feedback` (`:147`) falls through to
`(conj messages {"role" "user" …})` and the model's turn is never appended.
`agent.native/normalize` (`agent.native.clj:16`) builds
`{:kind :protocol-error :reason reason}` and discards everything else.

**Correction from review — this plan previously said "a protocol error has no
`:public-tool-call` by definition". That is false for 7 of the 10 branches.**
Only `:assistant-text-without-tool-call`, `:missing-tool-call`, and
`:multiple-or-missing-tool-calls` arise before a call is selected
(`agent.native.clj:56-61`). `:wrong-tool-name`, `:invalid-tool-call-id`,
`:invalid-json-arguments`, `:extra-or-missing-arguments`, `:program-not-string`,
`:program-empty`, and `:program-too-large` all arise *after* `(first calls)`,
from a response that **does** carry `tool_calls` — and in the
`:program-too-large` case the call is otherwise well-formed and correlatable.
Appending narration alone would still discard the model's actual response for
most of the class.

**Fix — one explicit policy, three branch groups.**

- `agent.native.clj`: carry what the branch actually has. Always
  `:narration prose`. For post-selection branches also `:offending-call call`,
  and for `:program-too-large` additionally `:limit max-program-chars` and
  `:size (count program)`.
- `agent.core.clj`, new `append-protocol-error`. **Four groups, and one
  attribution rule that governs all of them: the assistant turn carries only
  what the model itself produced. Kernel-authored text goes in the `user`
  correction turn, never in the assistant turn — otherwise the loop attributes
  its own words to the model, which is the same class of mistake as the
  original bug.**
  - **(a) well-formed call, rejected on size** (`:program-too-large`): append
    the authentic correlated assistant + `tool` pair using the real `id`,
    exactly as `append-correlated` does. The call is valid; only its payload
    was too big.
  - **(b) malformed call present** (`:wrong-tool-name`,
    `:invalid-tool-call-id`, `:invalid-json-arguments`,
    `:extra-or-missing-arguments`, `:program-not-string`, `:program-empty`):
    assistant turn carries the model's bounded narration only. The structural
    summary of what was wrong with the call goes in the user correction. Never
    replay the raw `tool_calls` array — a malformed array can invalidate the
    next request, and an assistant turn with `tool_calls` and no matching
    `tool` reply is rejected by strict providers.
  - **(c) no call selected** (`:assistant-text-without-tool-call`,
    `:missing-tool-call`, and the zero-calls and >1-calls halves of
    `:multiple-or-missing-tool-calls` — one predicate, two situations):
    assistant turn with narration only; omit it entirely when narration is
    blank.
  - **(d) `:invalid-response`** (`agent.native.clj:39`): the response is not a
    map, so it is raised **before** `prose` is bound and there is no narration
    to preserve. Correction turn only. This branch is why "narration is always
    available" is false.
- `agent.feedback/protocol-error` (`agent.feedback.clj:60`): render `:limit` and
  `:size` when present — *"your program was 1523 characters; the limit is 40"*.
  A correction turn that omits the measurement fails the same way as one that
  omits the response.

**Tests.** One case per *branch*, not per group — every selected-call rejection
reason, plus zero-calls, multiple-calls, and `:invalid-response`. Assert the
next request's `messages` through the StubPlanner seam. Group (b) needs an
assertion that no raw `tool_calls` array is replayed, and every group needs an
assertion that no Kernel-authored sentence appears in an assistant turn.

**The counter half — scope changed on review.** `usage.protocol_errors` counts
`Dispatcher` capability-call violations only
(`run_state.ex:876`, `dispatcher.ex:113,185,196,207,238,1116`); the agent loop
never reports to it.

> This plan previously proposed reporting the loop's errors into that same
> counter. **Dropped.** The two sources would compete for one global budget, so
> an earlier capability violation could terminate a later agent correction; and
> crossing the ceiling sets `closed?: true` with
> `terminal_failure: %{kind: :limit_exceeded, reason: :protocol_errors}`
> (`run_state.ex:875-889`), closing the whole run — the trusted tool would
> return a tool *failure*, not an ordinary loop value. That is a limits-model
> change wearing a diagnostic's clothes.
>
> **Instead:** surface the loop's own count under its own name
> (`agent_protocol_errors`). Two counters with two names answers the tester's
> complaint — that one name means two things — without touching the limits
> model. If the shared budget is wanted, it is a separate issue with
> mixed-source, boundary, and terminal-event tests.
>
> **Round 2: this key is not reachable from commit 1, and it moves to commit
> 2.** Envelope usage comes from `RunState.usage/1` (`run_state.ex:1639`) via
> `CommandRunOutcome.usage_projection/2` (`command_run_outcome.ex:630`);
> neither consults agent-local loop state nor the returned workflow value.
>
> Deriving it from the `"agent-action"` annotations the loop already emits
> **does not work**, and the reason is worth recording because it looks like it
> should: `RuntimeTools.annotate/3` (`:1046-1063`) emits them as canonical
> `workflow-annotation` events carrying `provenance: :workflow`, and they land
> in the same terminal batch `llm_usage_projection/1` reduces. But any workflow
> can emit that annotation, so a usage field derived from it lets application
> code write its own counter into the Kernel-attested `usage` block — the exact
> provenance hole `19a4deb9` reverted, one level down. The emit path already
> stamps `provenance: :workflow`, so the Kernel distinguishes the two; the
> usage projection would be throwing that distinction away.
>
> So the counter needs a private trusted tool incrementing a new
> **non-limiting** `RunState` counter — no effect on limits, retries, closure,
> or leases. That is the same machinery commit 2 builds, so the counter ships
> there as a second tool rather than dragging the plumbing into commit 1.
> Commit 1 stays purely about the conversation history.

### 1.2 #1498 — `ptc docs ptc-lisp | head` crash-dumps

**Root cause, verified.** `StandaloneCLI.main/1`
(`lib/ptc_runner/standalone_cli.ex:38-43`) writes the page in one
`IO.write(:stdio, …)`. `IO.binwrite/2` raises `ErlangError :terminated`
(`elixir 1.20.2 lib/io.ex:308`) on a closed pipe; Logger's default handler then
reports it, fails to stdout, retries stderr, and emits the pending payload.

**Measured** — 40 MB into `| head -c 5`, this toolchain:

| variant | stderr |
| --- | --- |
| unguarded | 4.6 KB stacktrace containing the payload |
| `rescue` → halt | 99 bytes (`Writer crashed (:epipe)`) |
| `rescue` **then** `remove_handler` | 99 bytes — too late, 3/3 |
| `remove_handler` **before** the write, then `rescue` | **0 bytes**, 3/3 |

**Fix — two entry points, two different treatments.** This plan previously
proposed one shared helper for both. That is wrong:
`MixCommandAdapter.run_task/2` (`lib/ptc_runner/mix_command_adapter.ex:42-58`)
**returns** the presentation on success and `Mix.raise`s on failure — it never
halts the VM. Removing the global `:default` handler there would silence
Mix and BEAM logging for everything that runs after, and a helper that always
calls `System.halt/1` would change Mix task semantics outright.

- **`StandaloneCLI.main/1`** — safe to remove the handler, because nothing runs
  after: `_ = :logger.remove_handler(:default)`, then write inside `try`, then
  `System.halt/1`. This is the path that produces the dump.
- **`MixCommandAdapter.write_output/2`** — narrow rescue only, preserving
  `run_task/2`'s normal return/raise contract. No handler removal, no halt.
  **It will not be silent**: the measurement above shows Logger emits the
  writer's `:epipe` line before any rescue body runs, and the Mix path cannot
  remove the handler. The rescue buys the contract and drops the
  payload-bearing stacktrace; it does not buy a clean stderr. Do not claim
  otherwise, and treat `mix ptc … | head` as explicitly out of scope for the
  quiet-exit guarantee.
- **Match the reason, not the exception class.** Rescuing every `ErlangError`
  would relabel unrelated I/O defects as a clean exit. Match `:terminated` /
  `:epipe` and re-raise anything else.

**Test.** Against the **packaged** CLI, not `mix ptc`. The release wrapper is
`exec "$release_root/bin/ptc_runner" eval 'PtcRunner.StandaloneCLI.main(System.argv())'`
(`rel/overlays/bin/ptc:5`), so an uncaught exception terminates through the
release VM's `eval` command — a different shape from `elixir -e`, which is why
the local repro produced no dump while the release binary dumps 3/3. The
packaged entry point is the only meaningful regression target.

Make it deterministic:

- fresh temporary working directory per run;
- set `ERL_CRASH_DUMP` to an explicit path inside it, and assert that path is
  absent afterwards — do **not** set `ERL_CRASH_DUMP_SECONDS=0`, which would
  make the assertion vacuous by suppressing all dumps;
- invoke through `bash` explicitly if using `PIPESTATUS`;
- assert the **producer's** status is 141 — a bare `cmd | head` reports
  `head`'s status and would pass vacuously — plus empty stderr.

`@tag :nightly`, per the OS-subprocess rule.

### 1.3 #1497 — the materialized kernel-tutorial cannot run

**Root cause, verified.** `ExampleLibrary`
(`lib/ptc_runner/kernel/example_library.ex:36`) excludes `.env` from the
embedded tree — correct, it is per-machine — and embeds with
`Path.wildcard(match_dot: false)`, so no dotfile ships. Every tutorial project
declares `"env_file": {"path": ".env"}`, so 02/03/04 fail on
`local_preflight/environment_file_not_found` immediately after `ptc init`.

**Fix.** Insertion point is `ExampleLibrary.fetch/1` + `created/1`, consumed by
`CommandInitializer.documents/1` (`command_initializer.ex:213`), which returns a
plain `path => content` map — the staging and no-replace commit path needs no
change.

- **Generate** a `.env` stub for an example tree that declares an `env_file`.
  Derive the variable names from the tree's **host credential declarations**,
  not from a hardcoded `OPENROUTER_API_KEY` — that key is right for this
  tutorial and wrong as a rule, and the other two embedded trees
  (`debug-a-failed-run`, `llm-replay`) must not inherit it.
- **Generate** `.gitignore` too. Flipping `match_dot: true` ships nothing:
  verified, no `.gitignore` exists in `examples/kernel-tutorial/`.
- **Do not** make `env_file` fall back to the ambient environment. An explicit
  file that silently accepts ambient state makes runs non-reproducible and would
  have hidden exactly this bug.
- **`03-file-agent`:** `examples/kernel-tutorial/ptc-host.json:18-21` points
  `node` at `../mcp/filesystem/dist/server.js`, outside the materialized tree.
  Switch to `ptc-fs-mcp`, **pinned to `@0.1.0`** — the repository's own
  integration test pins that version
  (`test/ptc_runner/kernel/ptc_fs_mcp_stdio_test.exs:71`), and an unpinned
  `npx -y` makes a supposedly self-contained example network-dependent and
  non-reproducible. Bump `installation_revision` with the change, and budget
  cold `npx` startup against the install's `transport.start_timeout_ms`. This is
  the tutorial's slice of #1528; leave the rest of that issue alone.
- **README:** rewrite `../../docs/guides/*.md` as `ptc docs <page>`, and rewrite
  the 03 paragraph, which currently claims a committed bundle needs no install.

**Test.** Materialize into a temp directory; assert `.env` and `.gitignore`
exist, that every `env_file` path each project declares exists, and that the
README contains no `../../docs/` reference. Filesystem only — default suite.

**File separately.** `ptc doctor` reports `provider/workspace/local: pass` for
the missing `server.js`.

---

## Commit 2 — `fix(agent,docs): name the rejected agent option, count the loop's protocol errors, and point the docs at a command that works`

Re-scoped. The schema-diagnostic, envelope-publication, REPL-limit, and
introspection items that were here are blocked — see Deferred.

### 2.1 #1456 — the out-of-range rejection names nothing

Body already shipped: `bounded-option` refuses before any provider request and
the failure value carries `:option`, `:min`, `:max`. Missing: the command
diagnostic. `19a4deb9` reverted the version that read those fields out of an
ordinary `fail` value, because any workflow could return the same map.

**The trusted-tool route is sound.** Private-tool authorization checks both the
attested `agent.core` origin and the caller's declared `tool_refs`
(`lib/ptc_runner/lisp.ex:2542`), so workflow code cannot forge it.

**Fix.** Template is `runtime_limit_failure/2` (`runtime_tools.ex:161`), whose
`%{"max_transcript_chars" => limit}` arm is the closest sibling:

1. New tool `kernel-agent-config-failure`, installed beside
   `maybe_put_runtime_limit_failure` (`:297`), registered in the `case` at
   `:533` with `prelude_namespaces: ["agent.core"], visibility: :private`.
2. **Register it in three places, not one.** `environment.ex:16` `@reserved`
   **and** `implicit_capabilities(:workflow, bundle)` (`environment.ex:131`),
   which lists the three existing kernel tools when `agent.core` is shipped.
   Omitting the second makes bundle requirement validation reject `agent.core`
   as missing a capability it requires — the tool would break every agent run.
3. Accepts a closed argument map over the four bounded option names; an
   unrecognised option is refused the way `agent_turn_limit_failure/2` refuses
   an unrecognised reason (`runtime_tools.ex:204`), not collapsed.
4. Returns `%TrustedError{reason: :invalid_agent_config, …}`, threaded through
   `Helpers.sanitize_private_error/1` (`lisp/eval/helpers.ex:327`),
   `Runner.workflow_error_details/4` (`runner.ex:823`), and
   `CommandRunOutcome`'s diagnostic path — primarily `failure_diagnostic/2`,
   not the `/3` clause this plan cited earlier (`command_run_outcome.ex:276`).
5. Catalog row, builder, validator, published pattern branch — recover from
   `git show 19a4deb9^ -- lib/ptc_runner/kernel/`. That module was correct; only
   its producer's provenance was not.
6. **`command_contract.ex:1247` needs an explicit branch.**
   `diagnostic_message_schema(row, %{"type" => "null"})` pins every
   **null-source** row to `%{"const" => row.message}`. This message has no
   source — `max_turns` belongs to one `agent.core/run` call rather than to a
   host or manifest document, the same reason the agent turn-limit message has
   none — so without a branch the published schema would fix it to the catalog
   constant and the dynamic text could never validate. Regenerate
   `priv/schemas/ptc-command-envelope-v2.schema.json` with it.

**Second tool in this commit — `agent_protocol_errors`.** Same shape,
`kernel-agent-protocol-error`: private, `prelude_namespaces: ["agent.core"]`,
registered in `@reserved` *and* `implicit_capabilities/2`, incrementing a new
**non-limiting** `RunState` counter that never closes the run. Surface it
through `RunState.usage/1` and `usage_projection/2`, and extend the usage
contract and generated schema. See commit 1.1 for why it cannot be derived from
annotations.

**Expected file surface** (round 2 — check nothing here is missing before
starting):

`agent.core.clj` · `runtime_tools.ex` · `environment.ex` (both registration
points) · `run_state.ex` · `helpers.ex` · `runner.ex` · `command_run_outcome.ex`
· `diagnostic_catalog.ex` · `command_diagnostic.ex` · `command_contract.ex` ·
restored `agent_config_diagnostic.ex` ·
`priv/schemas/ptc-command-envelope-v2.schema.json` ·
`docs/guides/agent-cli-usage.md` · `command_initializer.ex` · the generated site
guide · probably the generated CLI diagnostic/exit-status catalog · agent-
library, runtime-tool, setting-diagnostic and end-to-end envelope tests.

**Bounded value rendering — decided, not offered.** `bounded-option` rejects
arbitrary JSON, not only out-of-range integers (`agent.core.clj:30`), so the
rejected value can be a caller-controlled string of any length; interpolating
it recreates an injection and size problem inside a Kernel-authored sentence.
Round 2 is right that "policy A or policy B" is not implementable, because the
published ECMA-262 pattern has to match exactly one shape. **The policy is:**

- **integer**, in `int64` range → render the value:
  `max_turns 129 is outside the supported range 1–128 for agent.core/run; lower it`
- **anything else** → render only the *type*, never the content:
  `max_turns must be an integer in 1–128 for agent.core/run; received a string`

Two message shapes, two pattern branches, no caller-controlled text in either.

> **Phase and exit status — decided.** `{:execution, :invalid_agent_config, 5,
> false, "…"}`. The reopen comment asks for `application/invalid_agent_config`,
> but `:application` is a pre-execution phase exiting 3 and this fails inside
> the loop; exit 5 is what the failure already produces, so no script breaks,
> and a distinct code finally separates it from `workflow_failed`. Reusing
> `:runtime_limit_exceeded` is wrong — the value is out of range, not exceeded.
> **Overturn this here if you disagree; it must not stay open, because the
> published pattern cannot be written until it is settled.**

**Do not** add a static `ptc validate` check. It can only fold a literal map, so
a computed config would pass while claiming to have been checked.

**Test.** `SettingDiagnosticTest` is the gate and already enforces the contract.
Add the row to its sweep, plus an `AgentLibraryTest` case asserting the envelope
carries option and range and that no provider request was made.

### 2.2 #1502 — the docs half

The two agent-guide command lines (`docs/guides/agent-cli-usage.md:17` and
`:51`, whose inline comment *"search built-ins and prelude exports"* is false as
written) and the AGENTS.md scaffold
(`lib/ptc_runner/kernel/command_initializer.ex:92-93`) all print a form that
answers "not found" as printed. Add `--project`. Both are generated surfaces —
run `mix ptc.gen_docs` and stage the result.

The message half is deferred (see Deferred 3): `Introspection`
(`lib/ptc_runner/lisp/introspection.ex:13`) deliberately exposes only callable
attached exports and its context holds no manifest selection or dependency
graph, so it cannot tell "library not selected" from "component omitted the
dependency". The unknown-namespace message it would need to fix is produced
during compilation, in a different module entirely.

---

## Commit 3 — `feat(viewer): show spend on the live run card`

**Where the gap is, verified.** `Reporter.frame/2`
(`lib/ptc_runner/live_status/reporter.ex:384`) takes six keys from
`RunState.usage/1`, which carries no token or cost fields
(`run_state.ex:1640`). The `capability-stopped` **event** does carry usage via
`maybe_put_usage/3` (`dispatcher.ex:413`), but `:telemetry.execute` at `:424`
forwards only name, environment, capability_id, status, and live_run. The data
exists; it is not routed.

**Three constraints the original plan got wrong.**

1. **Cost is terminal-only and all-or-nothing by design.**
   `LLMUsageSummary.totals/1` returns `%{}` unless the batch carries
   `run-stopped` and no `events-dropped` (`llm_usage_summary.ex:82-90`), and
   `complete_total/2` halts to `nil` if any successful call lacks priced usage
   (`:100-110`). A live tile must accumulate through the `alias_rows/1` seam
   (`:63` — the `doctor --connect` path, which exists precisely for calls with
   no event stream) and adopt the same withhold rule. It must never show `0` for
   unknown, and it must distinguish *unpriced* from *missing or invalid* usage.
2. **Field names.** The existing keys are `input`, `output`, `total_cost`
   (`llm_usage_summary.ex:12`) — not `input_tokens` / `output_tokens` / `cost`.
   Reuse the real names or the live tile and the completed-run card will drift.
3. **There is a terminal race.** Capability telemetry is sent from the
   dispatching process; `Reporter.complete/4` is a `handle_call` from the run
   owner (`reporter.ex:139`). Mailbox ordering between two senders is not
   guaranteed, so completion can post the final frame and set `stopping?: true`
   while a last usage event is still in flight. For the activity list a dropped
   entry is cosmetic; for a **total** it is a wrong number on the last frame.
   A barrier between two different senders does not establish ordering, so
   **account the totals in owner state**. A plain reporter unit test will not
   expose this — the test has to force the interleaving.

**Fix.** Forward the usage projection into the `capability :stop` telemetry
metadata — **plus the alias and `installation_revision`**, which `alias_rows/1`
takes as `{alias_name, revision, usage}` and which the telemetry payload does
not currently carry — accumulate in owner-held state, expose on the frame under
the existing field names with an explicit state for withheld totals, and render
the tile in
`ptc_viewer/priv/static/js/live.js` beside the existing four, formatted as the
Runs list already does. Viewer tests and styles are part of this commit; format
Viewer edits from `ptc_viewer/`.

---

## Deferred

Each of these was in commit 2 and came out. Round 2 corrected two of the
estimates: they are not blocked, only out of this sweep. The distinction
matters — a blocked item needs an answer before anyone can start; a ready one
just needs a slot.

### Blocked on a decision

1. **#1501(a) — publish an envelope for a rejected project document.**
   `ProjectResolver.parse/3` (`project_resolver.ex:16`) resolves and loads the
   **project first**, then calls `CommandParser.parse/2`. So on a project-
   document failure argv has not been parsed at all — `--envelope` has not even
   been recognised — and `CommandEntry.rejected/3` (`command_entry.ex:339`)
   deliberately erases `arguments`, `envelope_path`, and `destinations`. The
   original plan's claim that "the destination is known at that point" is false
   twice over. Delivering this needs either a parser/resolver reordering or a
   narrowly validated preliminary destination extraction, and both change where
   the `envelope_destination_exists` and distinctness checks can run. Decide the
   architecture, then implement.

2. **#1502 message half — distinguish "not attached" from "does not exist".**
   `Introspection` (`lisp/introspection.ex:13`) exposes only callable attached
   exports by contract and has no manifest graph; the unknown-namespace message
   is emitted by the compiler. The **full** diagnosis — naming the unselected
   library *or* the omitted `dependencies` entry — is a design change. A cheaper
   partial fix exists and is worth taking first: when an attached lookup fails,
   consult a shipped-export index and answer *"shipped, but not available in
   this session; check the library selection and the component's
   dependencies"*. That removes the false negative, which is the damaging half.
   **Do not broaden `apropos`** — that would change its attached-environment
   contract.

3. **#1501(c) — `error.source.name` is a constant.**
   `CommandSource.fixed(:host)` hardcodes `"ptc-host.json"`
   (`command_source.ex:112`) and `valid_name?/2` enforces it (`:127`). Carrying
   the real filename means widening that type and deciding what a path outside
   the project directory may reveal — a disclosure-policy question.

### Ready — over-deferred, just not in this sweep

4. **#1501(b) — name the violated rule.** Two corrections to what this plan
   said. First, `HostConfig` is **not** a hand-written decoder: it validates
   with JSV (`host_config.ex:485`), already holds the failing keyword, and
   discards it in `command_validation_path/1`. Second, `notes` is unusable —
   `CommandDiagnostic` pins it to `[]` and the published V2 schema encodes
   `{"const": []}`. **But a V3 envelope is not required**: embedding the rule in
   a closed set of dynamic messages stays inside the existing contract, the way
   every other dynamic row does. The real work is defining precedence for nested
   combinators (`oneOf`, `not`) when JSV reports several candidate errors, and
   the six-rule vocabulary is too small — the host schema also uses `const`,
   `enum`, `minLength`, `maxLength`, item and property counts, and
   `uniqueItems`.

5. **#1478 REPL residuals.** The false-attribution risk is real, but the fix is
   local rather than blocked. `RunState` **already** distinguishes
   `:deadline_expired` (`run_state.ex:703,727`); the bug is that
   `evaluation_reservation_failure/2` (`repl_session.ex:1011`) maps
   `:run_closed` onto `:run_deadline` and loses it. Map the actual deadline
   reason, keep `:run_closed` distinct, and use the reservation reason and limit
   values already in hand. No command-envelope diagnostics needed — REPL
   failures are `Native.error` results and want their own mechanism. File the
   open issue #1478's closing comment never got.

---

## Gates

```console
mix precommit                     # before the first commit and after the last
MIX_ENV=dev mix docs --warnings-as-errors
mix ptc.gen_docs                  # commit 2 touches generated surfaces
```

`mix precommit` does not run Dialyzer. Commit 2 adds a `%TrustedError{}` reason
across five modules, so run `MIX_ENV=test mix dialyzer` explicitly — a
too-narrow `@spec` there hides caller branches.

Resume session `01a01bee-8fcc-7d23-b190-955f960aa4ec` after commit 1 rather
than reviewing cold — rounds 1 and 2 are already in its context. Take one fresh
review against a refreshed base before merge; a resumed session is never the
final gate.
