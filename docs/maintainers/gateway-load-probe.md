# Gateway load probe

Two tools measure the MCP gateway under concurrency. They answer different
questions and only one of them is a gate.

| Command | From | Answers |
| --- | --- | --- |
| `mix soak` | `ptc_gateway/` | Do the ceilings hold, is every slot returned, does a call leave anything behind? Asserted. |
| `mix run bench/gateway_load.exs` | `ptc_gateway/` | How fast is it, where does it stop scaling, and which owner is the ceiling? Reported. |

`mix test` excludes `:soak`. Neither tool needs a network, a provider or a
credential beyond the fixture's own token.

## What the gate asserts

`ptc_gateway/test/gateway_load_test.exs` drives a real listener with concurrent
raw-socket clients. `PtcGatewayTest` already covers the contract one request at
a time; everything here needs requests to overlap.

- **Ceilings.** `max_inflight_requests` and `max_concurrent_runs` are asserted
  at the peak of a burst that fills them.
- **Slot return.** Every path that is not the happy one: saturation, a reset
  peer, a half-open peer, a reused connection, and a client that never finishes
  its request.
- **Residue.** A fitted byte slope over four batches of calls, because a
  per-call residue small enough to pass a single-cycle assertion is what
  accumulates over a host's lifetime. `PTC_GATEWAY_SOAK_CYCLES` sets the batch
  size.
- **Write durability.** Every call that returned 200 has a matching record on
  disk, with unique call IDs. Read back from the audit files rather than from
  the owner: a record the owner believes it wrote and a record that survives the
  process are different claims, and only the second is what an audit is for.

## Read a ceiling from the owner, never from the client

A client timestamps a marker when its own process is scheduled to read the
socket, not when the server wrote it. Under a burst that jitter is most of the
measurement, and it inflates every interval in the same direction.

Both client-side readings were tried as ceilings here and both were wrong.
Sixty-four simultaneous calls against a bound of eight in-flight requests
produced twenty-three client intervals each spanning the same forty-six
milliseconds, because every one of them was sent at the same instant and
finished at the same instant whatever the server did in between. The same burst
against a run bound of two measured a peak of thirty-nine overlapping runs,
while `RunAdmission`'s own accounting never held more than one reservation.

So a ceiling is sampled from the owner that enforces it, and the client-side
overlap is reported beside it and asserted on nothing. The gap between the two
is worth reading: it is how much of a call's latency was waiting rather than
working.

A sampler can only under-report a peak it missed, which makes `peak <= bound`
sound and `peak == bound` a coin toss on a burst that clears in twenty
milliseconds. That the bound was *reached* is proved from the refusals instead —
a 429 is returned only when capacity is full — with the other bound configured
out of reach so the refusal is unambiguous.

## Two traps in the fixture

Contract compilation injects `additionalProperties: false`, so the default
`{"type": "object"}` schema accepts `{}` and nothing else. A call carrying a
payload against it returns a contract error inside an HTTP 200, and a test that
only checks the status will not notice. Declare the properties through
`GatewayFixture.fixture/3`'s `:schema` option.

A write deployment cannot put its audit directory under the system temporary
directory on macOS: the private audit refuses a symbolic link anywhere in the
hierarchy and `$TMPDIR` reaches the user's folder through `/var`, which is one
(#1985). The benchmark uses a project-local scratch directory; the gate uses
ExUnit's `:tmp_dir`, which is already project-local.

The default workflow returns its input unchanged, in microseconds. That is too
fast to observe concurrently, which is what made the client-side reading
useless. `:body` replaces it with something slow enough to overlap.

## Reading the benchmark

`tools/list` does everything a call does except run a workflow — connection,
header validation, authentication, admission, dispatch, response — so its
plateau is the gateway's own cost. `tools/call` adds the run, and the gap
between the two is the workflow's.

The mailbox table names the ceiling. An owner whose mailbox stays at zero is not
the bottleneck however slow the endpoint looks; one whose depth grows with
concurrency is. Measured on a ten-scheduler darwin/arm64 machine, the trivial
echo workflow plateaus near 1,100 calls per second at concurrency 16, after
which latency grows linearly with no throughput gained, and `RunAdmission` is
the owner that queues — `RequestAdmission` stays near zero throughout.

Numbers are machine- and scheduler-specific, so a comparison is only meaningful
against another run on the same machine. There is no committed baseline.

## The write path collapses under load, and adding capacity makes it worse

Every write call appends one record to the private audit, durably, from inside a
single owner — `:file.write` then `:file.sync` — and the call keeps its run
capacity until that append returns. One append measures 0.44 ms, so the whole
write path is serialized behind roughly 2,280 appends per second no matter what
`max_concurrent_runs` says.

What that produces is not a plateau. Goodput measured on a ten-scheduler
darwin/arm64 machine, 200 calls per level:

| concurrency | offered req/s | goodput req/s | refused | audit mailbox (peak/mean) |
| --- | --- | --- | --- | --- |
| 8 | 931 | 931 | 0% | 53 / 24 |
| 16 | 1995 | 918 | 54% | 60 / 55 |
| 32 | 2665 | 840 | 69% | 59 / 56 |
| 64 | 3230 | 727 | 78% | 58 / 54 |

Useful work *falls* as offered load rises. The audit queue deepens, every run in
it holds its capacity while it waits, run capacity fills, and the overflow is
refused rather than queued — so raising `max_concurrent_runs` admits more runs
into the same queue and lowers goodput further. The read path over the same
sweep plateaus at ~1,190 calls per second and refuses nothing.

Read the offered column carefully: at concurrency 64 it looks like the write
path is three times faster than the read path. It is counting refusals, which
are cheap. Only the goodput column is throughput.

## Other operational properties

A request holds one of `max_inflight_requests` from before its body is read
until the response completes, so how long the transport waits for body bytes is
how long one stalled client can hold a slot. That was 15 seconds — the default —
and the raised timeout reached the client as `500 Internal Server Error` with
`-32603`. It is now a two-second budget answered with HTTP 408
`{"error":"request_timeout"}`. `max_inflight_requests` stalled clients still
starve the endpoint for that budget, and `/health/ready` still stays 200
throughout, because readiness reports on the warm runtime rather than on request
admission. A peer that keeps dribbling bytes renews the budget by definition;
the loopback binding and the bearer requirement are what bound that residue.

Connection reuse is worth roughly four times the throughput of one connection
per call at the same concurrency, so a client that opens a socket per tool call
is paying more for TCP than for the workflow.

The gateway itself is not the expensive part. A trivial `tools/call` spends
0.79 ms on connection, parsing, authentication, admission and reservation, and
4.36 ms on activation, the run and publication — and the same call made
in-process through `ServingTemplate.call/3`, with no HTTP at all, costs 3.79 ms.
`tools/list`, which is the whole request path minus the run, completes in
0.47 ms and sustains ~6,700 per second.
