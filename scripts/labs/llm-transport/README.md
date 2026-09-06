# LLM transport baseline probe

Run from a prepared checkout in a fresh Mix VM:

```bash
mix run scripts/labs/llm-transport/run.exs /tmp/ptc-llm-baseline.json
```

Omit the output argument to print JSON. This maintainer probe loads shared
test fixtures, disables dependency dotenv loading, uses a dummy credential,
and sends requests only to its loopback server. It refuses an already-running
ReqLLM application because it owns this VM's provider configuration.

The probe configures one HTTP/1 Finch pool with two connections, warms the
prepared OpenRouter path, observes normal responses and Kernel budget
settlement, occupies both connections, and compares a queued request through
Dispatcher with a direct adapter call. Both carry a 250 ms LLM deadline.
It then kills the two holding callers, observes peer socket closure within
a shared one-second window, and sends recovery traffic. The direct call can
take Finch's default five-second checkout timeout, so a run takes several
seconds. Synchronization uses socket events and process monitors.

The JSON contains outcomes, latency samples, usage/reservation and ledger
projections, process/port snapshots, dependency versions, and source hashes.
An exception from the direct adapter is recorded by class without provider
text. Successful warmup, successful normal Kernel dispatch, and both holding
requests arriving are prerequisites; a failure there stops the probe.

This is a local characterization, not a performance acceptance benchmark.
The server closes successful connections and uses no TLS; it cannot measure
connection reuse, public HTTPS, sustained leaks, or whole-workflow capacity.
The observation windows are provisional diagnostic bounds. A direct adapter
deadline is not evidence about the Dispatcher-owned whole-call cutoff.
No runtime defaults are changed by adding this lab.
