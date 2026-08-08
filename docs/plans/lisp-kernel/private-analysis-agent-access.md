# Private analysis: agent access and the capability-memory fix

**Status:** proposed. No PR open yet. No GitHub issue tracks either defect
below — checked 2026-08-08 via `gh issue list -R andreasronge/ptc_runner
--search "private-unattended|inspection-analysis|memory_exceeded|capability
memory|repl private"`. The closest neighbors are #1129 (closed — shipped
`inspection-analysis-v1`, the terminal-only design this plan amends) and #1172
(closed — private-diagnostics fixes; its author explicitly declined to add
this flag, see Non-goals).

Two independent defects on the `inspection-analysis-v2` REPL profile, found
and fixed on the unmerged experiment branch `worktree-incident-evidence-compiler`
(commits `355f2146` and `784fe18f`, rebased copies of `ba983f95`/`f8d7cea9`).
Neither commit is portable to `main` as-is; both need re-deriving. This plan
records what each PR does, why, and how it does — and does not — interact with
the in-flight [stable CLI plan](stable-cli-contract.md).

## Problem

**1. A coding agent cannot use `inspection-analysis-v2` at all.** The profile
requires `--private-terminal`, which requires `stdin`/`stdout` to both be
`isatty` (`lib/ptc_runner/kernel/analysis_terminal.ex:6-8`,
`lib/mix/tasks/ptc.repl.ex:197`) and admits only `:interactive` input
(`lib/ptc_runner/kernel/analysis_profile_registry.ex:76-79`). A non-interactive
caller — `-e`, `--load`, a script, stdin, or `--format jsonl` — is rejected
before either source directory opens
(`lib/ptc_runner/kernel/analysis_session_builder.ex:134-150`).

That check was never access control, and the experiment branch proved it:
running under `script -q /dev/null` makes an agent's non-interactive shell
report both streams as terminals, and the profile opens. Two independent
routes already read the same private records non-interactively and fully
validated — the Viewer's `GET /api/inspection/runs/:run_id`
(`ViewerAdapter.pin_inspection/2`) and direct same-UID filesystem access to the
inspection artifact. The check's only real effect is accident prevention:
it stops a private value from reaching a log or transcript by mistake. A
five-draft design for a real owner-only sink was written on the experiment
branch and deleted — it defended against an adversary outside the trust
boundary the rest of the runtime already assumes.

**2. Even with authorization, the profile cannot evaluate anything.** Every
capability callback in `mission_tools/5`, `workflow_tools/2`, and `tools/1`
closes over the *whole* environment, not its own capability:

| Site | Evidence |
| --- | --- |
| `lib/ptc_runner/kernel/evaluation.ex:671-690` | `mission_tools/5`: `environment.capabilities \|> Map.new(fn {name, _} -> {name, fn args -> Dispatcher.dispatch(state, :mission, environment, name, args, ...) end} end)` |
| `lib/ptc_runner/kernel/runner.ex:280-301` | `workflow_tools/2`: identical shape over `config.workflow_environment` |
| `lib/ptc_runner/kernel/repl_session.ex:519-547` | `tools/1`: identical shape over `session.config.workflow_environment` |
| `lib/ptc_runner/kernel/dispatcher.ex:100-109` | `dispatch/8`'s only use of that argument is the pattern `%{capabilities: capabilities}` — no other field of `environment` is read anywhere in the module |

`spawn` does not preserve term sharing, so each closure's captured
`environment` is copied flat into the sandbox process on every evaluation. A
profile with N capabilities pays for the whole environment N times before the
program runs — `O(capabilities²)` in the capability count. For
`inspection-analysis-v2`'s twelve capabilities and 16,214-word frozen bundle,
that is a 552,708-word (4.4 MB) pre-eval baseline. Because BEAM heaps grow
multiplicatively while `max_heap` is additive headroom above the *measured*
baseline (`lib/ptc_runner/sandbox.ex:21-31`), that baseline alone crosses
`baseline + evaluation_heap_words` within two or three heap generations —
`(+ 1 1)` dies with `:memory_exceeded` regardless of what the program does. A
tool-rich MCP environment (30+ capabilities) blows the setup ceiling before
evaluation starts at all.

`Dispatcher.dispatch/8` never reads anything but the one capability it is
given (confirmed above), so the fix is a narrowing, not a restructuring: hand
each callback a single-capability view instead of the whole environment.

## Verified basis

| Fact | Location |
| --- | --- |
| `AnalysisTerminal.attached?/0` is exactly `isatty(:stdin) and isatty(:stdout)` | `lib/ptc_runner/kernel/analysis_terminal.ex:6-16` |
| `inspection-analysis-v2` declares `input_modes: [:interactive]`, and the registry enforces exactly the declared list | `lib/ptc_runner/kernel/inspection_analysis_profile.ex:110`; enforcement in `lib/ptc_runner/kernel/analysis_profile_registry.ex:76-90` (current `authorize_input`/`authorize_output`, no `unattended` parameter) |
| Two more capability-discovery closures capture the whole environment, not just `mission_tools`/`workflow_tools`/`repl_session.tools` | `lib/ptc_runner/kernel/runtime_tools.ex:432-436` — `route_callback(:capability_list, ...)` and `route_callback(:capability_description, ...)` each close over `environment` directly |
| The private-destination check lives in `AnalysisSessionBuilder`, not the Mix task, so an embedding host inherits the same restriction | `lib/ptc_runner/kernel/analysis_session_builder.ex:130-151` |
| `dispatch/8`'s third argument is used only via the `%{capabilities: capabilities}` pattern; no other field is read in `dispatcher.ex` | `lib/ptc_runner/kernel/dispatcher.ex:100-147` (grep for `environment\.` in the module returns nothing) |
| All three tool-building sites duplicate the same whole-environment closure | `evaluation.ex:671-690`, `runner.ex:280-301`, `repl_session.ex:519-547` |
| The two capability-discovery routes (not per-callback dispatch) are the only callers that need the *whole* capability map | `runtime_tools.ex:45` (`RuntimeTools.tools/4`), called once per tool-building site, not once per capability |
| The experiment branch's fix (`784fe18f`) is **not** a clean cherry-pick: it assumes an `evaluation_id`/context-map refactor of `mission_tools`/`workflow_tools` that never shipped to `main` | confirmed by test cherry-pick on 2026-08-08: conflicts in `evaluation.ex`, `repl_session.ex`, `runner.ex`; `main`'s `mission_tools/5` has no `evaluation_id` parameter |
| The experiment branch's `--private-unattended` commit (`355f2146`) applies to `main` with only a one-hunk doc conflict (a section got renamed) | confirmed by test cherry-pick on 2026-08-08; `ptc.repl.ex`, `analysis_profile_registry.ex`, `analysis_session_builder.ex`, and their tests apply cleanly |
| Checkpoint D (`codex/stable-cli-checkpoint-d`, unmerged) touches none of the files this plan changes, except 5 lines of `repl_session_test.exs` | `git diff main...codex/stable-cli-checkpoint-d --stat`, 2026-08-08 |

## Non-goals

- Do not port the experiment branch's `evaluation_id`/turn-history/context-map
  plumbing (`d9526b65`, `5111f0d1`, and related commits). That is separate,
  larger, unreviewed work with its own tradeoffs; re-derive the memory fix
  against `main`'s current, simpler function signatures instead.
- Do not build a real owner-only private sink file. The experiment branch
  wrote and deleted five drafts of this; it defends against an adversary the
  trust boundary already excludes (same-UID filesystem access and the Viewer
  both already reach the same data non-interactively).
- Do not reopen #1172 (private-diagnostics redaction) or change its behavior.
  That work is shipped and unrelated to authorization or memory.
- Do not touch anything in the in-flight Checkpoint D branch
  (`codex/stable-cli-checkpoint-d`) — destination preflight and publication
  are a different boundary. See Interaction, below, for why the two are safe
  to land in either order.

## PR 1 — narrow the capability grant (memory fix)

Re-derive `784fe18f` against `main`'s actual signatures — no `evaluation_id`,
no context map.

- Add `Environment.capability_view/1` (whole map, for the two discovery
  routes) and `Environment.capability_view/2` (single capability, for a
  dispatch callback). The single-capability form must return
  `%{capabilities: %{name => capability}}` — not a bare capability or a
  differently-shaped map — because that is the only pattern `dispatch/8`
  matches against.
- Extract one shared helper — e.g. `ToolGrant.capability_callbacks/4` — used by
  `evaluation.ex`, `runner.ex`, and `repl_session.ex`. This is not optional
  polish: the same closure is duplicated three times today, and
  `.duplication-baseline.json` plus `mix precommit`'s duplication gate will
  flag three independent narrowings as new duplication unless they share one
  definition (see `docs/guides/duplication-gate.md`).
- Callback shape per site stays exactly what it is today (`fn arguments ->
  Dispatcher.dispatch(...) end`); only the captured value changes from the
  whole environment to `Environment.capability_view(name, capability)`.
- **Also narrow `RuntimeTools`'s two discovery-callback routes**, not just the
  three dispatch sites above:
  `route_callback(:capability_list, state, environment)` and
  `route_callback(:capability_description, state, environment)`
  (`lib/ptc_runner/kernel/runtime_tools.ex:432-436`) each still close over the
  whole `environment` directly. These two *do* legitimately need every
  capability's metadata (they are the discovery routes
  `Environment.capability_view/1` exists for) — but today each is its own
  full-environment copy, on top of the twelve per-capability ones. Route them
  through `capability_view/1` explicitly rather than leaving them as
  unnarrowed, so the "two discovery routes" language above is actually true of
  the code and not just the comment.
- Tests: reuse the experiment branch's `tool_grant_memory_test.exs` shape —
  shape (exact equality against environments differing only in bundle and
  granted data), scaling (linear growth in capability count, not quadratic),
  and budget (concrete ceiling for `inspection-analysis-v2`'s twelve
  capabilities). Measure with `PtcRunner.Lisp.RetainedSize.bytes/1`, which
  counts what the sandbox actually bills, not `:erts_debug.flat_size/1` on the
  struct.
- Regression: `inspection-analysis-v2` evaluates a trivial form
  (`(+ 1 1)`) under `mix run`, not just `mix test` — the experiment branch's
  bug was specifically marginal enough to hide in the full suite (GC
  generation boundary) and reproduce alone.

**Done when:** capability count in a granted environment no longer changes the
per-callback captured size, at all five narrowed sites (three dispatch, two
discovery); `inspection-analysis-v2` evaluates `(+ 1 1)` under `mix run`
deterministically — a regression test that reproduces the *current* failure
first (per this repository's bug-fix convention) must establish whether
today's failure is in fact deterministic under `mix run` at this profile's
capability count, since the experiment branch's writeup called it both
unconditional ("regardless of what the program does") and marginal enough to
pass in the full suite and fail alone; if it turns out genuinely marginal
rather than deterministic, the fixed test must still assert a hard baseline
ceiling, not merely "did not crash this run". `mix precommit`'s duplication
gate stays green with the three dispatch call sites sharing one helper.

## PR 2 — `--private-unattended`

Port `355f2146` (near-verbatim; one doc-heading conflict to resolve by hand).
Depends on PR 1 landing first — not for authorization correctness, but because
the original commit's own gate could not be verified end-to-end
(`:memory_exceeded` blocked every evaluation), and this plan is not repeating
that.

- `AnalysisProfileRegistry.authorize_frontend/2` gains an optional
  `private_unattended` context key. Exactly one of `private_terminal` or
  `private_unattended` may be true; both is `:private_destination_conflict`;
  neither keeps today's `:private_terminal_required`.
- Under `private_unattended`, admit `:eval`/`:load`/`:script`/`:stdin` input
  and `:clojure`/`:jsonl` output — the same non-interactive surface
  `log-analysis-v2` already has. `continue_on_error` stays forbidden for the
  private profile either way.
- `AnalysisSessionBuilder.authorize_private_profile/2` gets the matching
  branch, and its moduledoc states the accident-guard framing directly (verbatim
  from the experiment branch, since this is exactly the lesson to keep visible
  for the next person who touches this code — see Interaction, below).
- `mix ptc.repl` adds `--private-unattended` as a boolean option, mutually
  exclusive with `--private-terminal`, documented in the task's own `@moduledoc`.
- Docs: `docs/guides/kernel-repl.md` gets the "Private analysis without a
  terminal" section from `355f2146`, and `docs/guides/running-and-debugging.md`
  gets a one-line pointer to it from its debugging-methods list.
- `AGENTS.md` (this repository's `CLAUDE.md` symlink target) gets a short entry
  under a debugging-methods list pointing at the new guide section, so a coding
  agent working in this repo discovers the flag without being told about it in
  chat first.
- Behavior at an attached terminal used with `--private-unattended` (rather
  than `--private-terminal`) is not ambiguous, but state it explicitly so a
  reviewer does not have to re-derive it: `unattended` widens which
  *input/output modes* are authorized; it does not change where a private
  value is printed. Interactive typing at a real terminal under
  `--private-unattended` still just prints to that terminal, same as
  `--private-terminal` would — the flag only decides which authorization
  branch runs, not the sink.

**Done when:** `mix ptc.repl --profile inspection-analysis-v2 --private-unattended --format jsonl -e '(inspection/runs {})'` returns real inspection records end-to-end (not just an authorization pass); `mix precommit` green; `AGENTS.md` documents the flag.

## Interaction with the stable-cli-contract plan

No file overlap with in-flight work. Neither PR touches anything Checkpoint D
(`codex/stable-cli-checkpoint-d`) changes, and neither PR touches the provider-session, deadline, or publication machinery Checkpoints A–D built. `inspection-analysis-v2` never opens a provider session — it is one of the two profile-backed REPL modes that stay entirely outside phases 7–12.

**One real interaction, and it is worth Checkpoint E reading this plan before
it starts, not after.** The stable CLI plan's Slice 9 (Checkpoint E) commits to
building the *exact same* pattern this plan just proved is not access control.
From `docs/guides/kernel-repl.md:77-87`:

> The planned stable manifest-backed frontend will treat a private manifest
> result as interactive authority, not ordinary stdout. It will require an
> attached terminal and the explicit `--private-terminal` grant... It will
> reject `--eval`, `--load`, positional scripts, stdin, `--format jsonl`, and
> detached execution at that same boundary...

And `stable-cli-contract.md:2109-2113` (Slice 9 gate) and `:2211-2212`
(required acceptance properties) both restate the same terminal-only,
`isatty`-gated design for a **private manifest REPL** — a different data class
(manifest results, not inspection records) but the identical mechanism this
plan just demonstrated is an accident guard, not a boundary, under
`script(1)`/`tmux`/`ssh -t`.

This is not a blocker for either PR here — Slice 9 is unstarted, and neither
PR changes manifest REPL code. But it means Slice 9 should not rediscover this
the hard way. Two options for whoever picks up Slice 9:

1. Design the private-manifest-REPL gate with the same explicit
   `--private-unattended`-equivalent from the start, referencing this plan and
   `AnalysisSessionBuilder`'s moduledoc as precedent; or
2. Explicitly decide the manifest case has a different threat model (e.g., a
   manifest can carry a caller-supplied private *input*, not just runtime
   telemetry, which may justify a stricter default) and document why the same
   escape hatch does not apply — but decide that on purpose, not by silently
   repeating the pre-fix design.

Recommend amending `stable-cli-contract.md`'s Slice 9 section with a forward
pointer to this plan when Slice 9 is picked up, the same way earlier
checkpoints cross-reference their own residuals.

## GitHub issues

Recommend opening two issues before or alongside the PRs, referencing this
plan file (existing convention — see #1172's plan cross-reference):

1. "`inspection-analysis-v2` cannot evaluate anything: capability closures
   duplicate the whole environment" — PR 1.
2. "Coding agents cannot use private inspection analysis non-interactively" —
   PR 2, referencing #1129 (the original feature) as the issue whose scope
   this amends.

## Risks

- **PR 1's shared helper touches three hot call sites.** `evaluation.ex`,
  `runner.ex`, and `repl_session.ex` are exercised by nearly every Kernel test.
  Mitigate by keeping the callback's external behavior byte-identical (same
  dispatch call, same arguments) — only the captured closure value narrows.
- **`--private-unattended` makes it easier to pipe private data somewhere
  public by mistake**, which is exactly what the terminal check existed to
  prevent, on purpose. The flag is opt-in and named for greppability, matching
  the existing repository convention of explicit unattended flags rather than
  ambient permissiveness (see `docs/guides/kernel-repl.md`'s "JSON Lines for
  coding agents" precedent on `log-analysis-v2`, which already has no
  terminal gate at all because it carries no private data).
- **The specific new exposure this plan enables is agent-transcript/provider-log
  leakage, not just shell redirection.** PR 2's whole point is that a coding
  agent will use this routinely — meaning real model exchanges, generated
  source, and MCP request/response bodies from `inspection-analysis-v2` will
  routinely flow into that agent's own conversation transcript and, from
  there, into whatever LLM provider logs that agent's own requests. That is a
  materially different — and arguably larger — exposure than "a human
  redirects stdout to a file by mistake," and it is not a hypothetical
  mistake but the expected, endorsed usage pattern this PR ships. Say so in
  `docs/guides/kernel-repl.md`'s "Private analysis without a terminal"
  section, not just in "redirect it somewhere owner-only": an agent using this
  flag is choosing to hand private runtime records to whatever consumes its
  own output, and that choice should be visible where the flag is documented,
  not only inferred from the general private-data warning already there.
- **Re-deriving `784fe18f` without its prerequisite plumbing risks subtly
  different behavior** than what the experiment branch tested. Mitigate with
  the shape/scaling/budget test trio from that branch, run against `main`'s
  actual call sites, not copied assertions.

## Open questions

1. Should the shared helper live under `PtcRunner.Kernel.ToolGrant` (matching
   the experiment branch's name, easing any future comparison) or a more
   Kernel-idiomatic name? Leaning `ToolGrant` — no reason to invent a second
   name for the same concept.
2. Does Slice 9 (Checkpoint E) need this plan linked from
   `stable-cli-contract.md` now, or only when someone actually starts Slice 9?
   Leaning: link now, since the cost is one paragraph and the alternative is
   relying on someone remembering this conversation.
