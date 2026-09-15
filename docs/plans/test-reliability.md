# Test reliability

Tracking issue: #1968. Related: #1967 (merged separately), #1970.

Nine test failures were observed between 2026-09-01 and 2026-09-15 across CI,
the nightly flake hunt, the integration suite and local pre-push runs. They are
not nine problems. Three of them were not flakes at all, and the remaining six
fall into three shapes, each with one repair that fixes every member.

This plan covers the three shapes. #1970 (pre-push lane contention) stays
separate because its failing command is still unidentified, and the macOS-Intel
launcher teardown stays in #1968 because two observations are not yet enough to
name a mechanism.

## What was already true and is not a flake

Recorded here so the next person does not re-diagnose them as timing.

- **#1967, soak.** `AnalysisSessionSoakTest` seeded a `run-stopped` event with no
  `usage`, which the trace validator has refused since `fe903047f` (2026-08-26).
  `setup_all` raised and invalidated all four tests, so the weekly `Soak`
  workflow was red from 2026-08-31 and the suite had not run for three weeks.
  Reproduces in 0.1s. Fixed by PR #1969.
- **Locale.** `inspection_preflight_test.exs:729` asserts a spawned runtime's
  output equals `":ok"` exactly. With no UTF-8 locale the child VM prepends its
  latin1 warning and the match fails. Deterministic in that environment, and it
  blocked a push from the managed worker until `LANG=C.utf8` was set.

The lesson both share: a failure that reproduces on the first try is not a
flake, and "rerun it" is the wrong first move when the error names a value
rather than a timeout.

## Shape 1: a monitor established after the process already exited

`Process.monitor/1` on a dead pid delivers `:DOWN` with `:noproc` immediately,
so a test that monitors late cannot distinguish "exited for the wrong reason"
from "already gone". The assertion fails with a reason the test never
anticipated and the real cause is invisible.

| Test | Expected | Received |
| --- | --- | --- |
| `test/ptc_runner/kernel/bounded_worker_test.exs:286` | `:killed` | `:noproc` |
| `test/ptc_runner/kernel/analysis_session_test.exs:1100` | `:normal` | `:noproc` |

**`bounded_worker_test.exs:286`** is fully understood. The worker announces
itself and then blocks:

```elixir
assert_receive {:cancelled_worker, worker}
worker_ref = Process.monitor(worker)          # the gap
Process.exit(cancellation_owner, :kill)
assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
```

The test immediately above it, `caller kill propagates to an opted-in bounded
worker` at `:251`, already hit this and carries the diagnosis in a comment:

> This case isolates caller cancellation, not heap enforcement. A 10k-word
> worker can hit its heap limit before the test installs its monitor under
> full-suite scheduler pressure and report `:noproc` instead of the
> cancellation reason being asserted.

It closes the gap three ways: `timeout_ms: 60_000`, `max_heap_words: 100_000`,
and a `startup_fault_hook` handshake so the worker does not proceed until the
test says it has been monitored.

```elixir
startup_fault_hook: fn worker ->
  send(test, {:bounded_worker_starting, worker})
  receive do: (:worker_monitored -> :ok)
end
```

`:286` has `timeout_ms: 5_000` and `max_heap_words: 10_000` — both of the
values that comment warns about — and no handshake. Apply the same three
mitigations. The precedent, the rationale and the mechanism are already in the
file; this test was simply never given the same treatment.

**`analysis_session_test.exs:1100`** is not fully understood. It monitors four
owners, calls `:sys.get_state/1` on each to serialise, kills the builder, and
expects a specific exit reason from each. `run_state` returned `:noproc`. The
`:sys.get_state/1` call should already have raised if that owner were dead, so
the ordering is not yet explained.

Do not guess at it. Assert liveness immediately before each monitor, with a
message naming the owner, so the next occurrence says whether the owner died
early or the monitor raced. This is the approach already used for
`RunCoordinator`: it converts an opaque `:noproc` into a lead. If the assertion
fires, that is a real bug in owner cleanup, not a test defect.

## Shape 2: the private-directory substrate

Three failures sit in private-trace and inspection capture:

| Test | Symptom |
| --- | --- |
| `test/ptc_runner/kernel/run_catalog_snapshot_test.exs:90` | `{:error, :private_directory_unavailable}` in `PrivateInspectionFixture.start_sink!/2` |
| `test/ptc_runner/kernel/selected_canonical_set_snapshot_test.exs:227` | nightly flake hunt, 1 of 10, seed 864820 |
| `test/ptc_runner/kernel/dispatcher_effect_test.exs:729` | nightly flake hunt, 1 of 10, seed 695268 |

The first is the informative one, because it failed with the capture layer's own
error rather than a timeout. `PrivateDirectory.read_authority_uid/1` maps any
failure or timeout of `id -u` to exactly `:private_directory_unavailable`.

`PrivateDirectory.create/1` spawns three subprocesses for every directory it
makes — `id -u`, `id -G`, then `mkdir -m 700` — each through
`SystemCommand.run/3`, which wraps it in `BoundedWorker.run/2` under a 10s
bound. Nothing is cached: `read_authority_uid/1` and `read_authority_groups/1`
are called from twelve sites in that module, and `lib/` has 48 call sites into
this path. Every trace-capturing test therefore spawns subprocesses, and
`BoundedWorker` — the substrate under all of them — is itself shape 1 above.

Measured on an idle machine:

| Command | Cost |
| --- | --- |
| `id -u` | 4.63 ms |
| `id -G` | 7.63 ms |
| `mkdir -m 700` | 4.91 ms |
| **one `PrivateDirectory.create/1`** | **23.13 ms** |

**The repair: cache the authority identity for the VM's lifetime.** A BEAM
process cannot change its own uid or supplementary groups after start, so
re-reading them is pure cost. Caching removes two of the three spawns and more
than half the wall time of every private-directory operation, and removes the
two failure surfaces that map to `:private_directory_unavailable`.

Cache in `:persistent_term` behind a single accessor, populated on first use;
`command_contract.ex`, `semantic_revision.ex` and `attestation.ex` already use
it in this kernel, so the mechanism is not new here.
It must stay a cache of a genuinely immutable fact, not a convenience: the
directory-ownership checks that compare a stat's uid against the authority uid
keep their meaning, because the value they compare against cannot have changed.

This is a lead for the other two rows, not a proof. They are in the same area
and share this substrate, but only the first failed with this error. Land the
caching, then see whether the nightly flake hunt stops finding them. If it does
not, they need their own diagnosis.

## Shape 3: a fixed budget on `assert_receive`

| Test | Budget | Symptom |
| --- | --- | --- |
| `test/ptc_runner/kernel/dispatcher_bounded_schema_test.exs:130` | 5000ms | no matching `{:in_callback, worker}` |
| `test/ptc_runner/live_status_test.exs:692` | `Task.await(run, 5000)` | `limit_exceeded` arrived as a value, not an error |
| `test/ptc_runner/kernel/project_command_test.exs:186` | 60s per-test | `ExUnit.TimeoutError` |

`project_command_test.exs:186` is the clearest and the least interesting: the
whole file takes 58.0s against a 60s per-test timeout on an idle machine. It is
not marginally over budget under load, it is marginally under budget at rest.
Either the test does less work or it states why it needs that long.

`live_status_test.exs:692` is the one that deserves care and should not be
treated as a timing fix. It asserts a run deadline surfaces as
`{:error, %{kind: :limit_exceeded}}`; CI observed `{:ok, %Result{}}` whose value
carried `limit_exceeded`/`run_closed` with `remaining_ms: 0, closed?: true`. The
deadline did trip. The question is whether a capability may return the limit as
a value instead of failing the run, and that is a contract question about
`park`, not a budget. Answer it before touching the assertion; widening the
timeout would hide a real ambiguity.

## Work items, in order

1. **Shape 1, `bounded_worker_test.exs:286`.** Apply the handshake already used
   in the same file. Self-contained, no production change.
2. **Shape 2, authority identity caching.** `PrivateDirectory` gains a cached
   accessor for uid and groups. Production change with the widest blast radius
   in this plan, and the only one that can make the suite faster as well as
   steadier.
3. **Shape 3, `dispatcher_bounded_schema_test.exs:130` and
   `project_command_test.exs:186`.** Budget and workload decisions per test.
4. **Shape 1, `analysis_session_test.exs:1100`.** Liveness assertions that turn
   the next occurrence into a lead. Diagnostic, not a fix.
5. **`live_status_test.exs:692`.** Settle the contract question first.
6. **#1970**, once the gate reports which command failed.
7. **macOS-Intel launcher teardown**, once there is a third observation.

Items 1 to 3 are one pull request. The rest are separate because each needs a
decision this plan does not contain.

## How this gets verified

`scripts/ci/flake-hunt.sh 10` already produces the tabulation and the nightly
workflow uploads it as an artifact. That artifact is the measurement: two nights
of hunting found one failure each. The honest success criterion is that the
tests named in shapes 1 and 2 stop appearing in it, not that a single run is
green.

The gap worth noting separately: nothing turns that artifact into tracked work,
which is why these accumulated unnoticed. The same is true of `Soak`, red for
three weeks with nobody looking.
