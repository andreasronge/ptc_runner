# Model identity observability (#1299)

Branch: `codex/issue-1299-model-identity-observability`.

## Goal brief

> Implement the reviewed plan in
> `docs/plans/issue-1299-model-identity-observability.md`. Make the locally
> resolved adapter model visible in canonical LLM provider snapshots only when
> the active model registry explicitly attests that the exact resolved value is
> safe to publish. Ensure acquisition uses that same resolved value without a
> second registry lookup. Extend `log/counters` with deterministic usage grouped
> by published model plus an unattributed-call count, while preserving existing
> alias/revision usage. Keep private inspection, analysis preludes, capability
> events, Viewer, profile IDs, and event schema versions unchanged. Write
> failing tests first, update durable API and user documentation, run the full
> repository gates, use at most three fresh independent Codex reviews (resume a
> review session for fixes), and open a draft PR that closes #1299.

## Observable change

For a live LLM installation, one authoritative acquisition resolution produces
the exact adapter target and, optionally, the same byte string as a public
identity. The existing provider snapshot records that public identity as
`acquisition.resolved_model`; private targets omit the field. Existing snapshot
hashes cover the new field.

`log/counters` keeps `llm_usage` unchanged and adds:

- sorted `llm_usage_by_model` rows with the same call, success, token, cost,
  and missing-usage metrics;
- `unattributed_model_calls`, counting existing `llm_usage`-eligible calls that
  do not have exactly one valid public snapshot mapping.

The following invariant holds for every filtered counters result:

```text
sum(llm_usage_by_model[*].calls) + unattributed_model_calls
  == sum(llm_usage[*].calls)
```

## Public identity boundary

`PtcRunner.LLM.Registry` gains an optional `public_model/1` callback. A composite
resolution operation fetches one registry implementation, resolves once, then
asks that same implementation for publication consent. Publication succeeds
only when the callback returns the exact adapter model as valid UTF-8 between 1
and 256 bytes. Missing, invalid, oversized, mismatched, or raising callbacks
make the model private without failing execution.

`DefaultRegistry` publishes only normalized targets in its finite built-in
cloud-model table. Aliases and an exact direct spelling of one of those targets
publish the same resolved target. Arbitrary direct cloud IDs, `openai-compat`,
Ollama, local, and unknown targets remain private.

## Acquisition and snapshot contract

`HostInstallation` captures the resolved adapter model, optional public model,
and adapter during acquisition preflight. Callback construction and provider
application readiness receive the captured adapter model unchanged; neither
may resolve it again. The independently executed phase-7 local preflight is not
part of this acquisition-resolution guarantee.

The LLM acquisition projection remains the existing map, extended only when
public:

```json
{
  "source": "llm",
  "resolved_model": "openrouter:anthropic/claude-sonnet-4"
}
```

`ProviderSnapshot` owns a closed, non-raising extractor for current LLM
snapshots. It validates the complete top-level, declaration, and acquisition
shapes; matching provider/name; both `source` fields; bounded model text; lack
of LLM-inapplicable content identity; and recomputed acquisition and snapshot
hashes. Invalid or legacy snapshots remain loadable but cannot attribute a
model. Hashes are consistency checks, not signatures.

## Counter correlation

After selecting runs, `TraceLog` builds a run-scoped multimap from every
selected run's `run-started.connector_snapshots` before mission filtering. The
key is `{run_id, alias, installation_revision}`. A call is attributable only
when exactly one valid current LLM snapshot claims its key; duplicates are
unattributed even when their model strings match.

The existing eligible stopped `llm-request` events are reduced once through
shared row-update logic. Failed calls retain current semantics. Replay/custom
routes, private models, missing snapshots, legacy shapes, malformed values,
hash tampering, inconsistent sources, and duplicates contribute to
`unattributed_model_calls`, never a query failure. Model rows sort by exact
`resolved_model`. Existing result byte limits still apply.

## Explicit non-goals

- No fingerprint, configured selector, alias duplication, endpoint, or
  credential enters canonical evidence.
- No model field is added to capability events.
- No private-inspection correlation or analysis prelude is added.
- No Viewer, README, HostConfig schema, generated function reference, event
  schema, or fixed-profile version changes are required.
- Manifest `labels.model` remains an unrelated author label and is never used
  as execution identity.

## Tests and documentation

Write failing coverage for registry call count and attestation failures;
DefaultRegistry's finite allowlist; exact adapter/readiness target; snapshot
identity and hash drift; private target stability; unchanged capability events;
multi-model and cross-run aggregation; duplicate, missing, legacy, tampered,
unsafe, replay/custom, and failed calls; filters; deterministic ordering; the
accounting invariant; unchanged `llm_usage`; and small result limits.

Update module documentation for `PtcRunner.LLM`, its registries,
`HostInstallation`, and `ProviderSnapshot`, plus:

- `docs/guides/host-configuration.md`
- `docs/guides/embedding-in-elixir.md`
- `docs/guides/building-agents.md`
- `docs/trace-log-contract.md`

Run focused tests, formatting, compilation with warnings as errors, Credo,
`MIX_ENV=dev mix docs --warnings-as-errors`, and `mix precommit`. Do not
regenerate `priv/semantic_build_projection.json` on this feature branch.

Use one fresh implementation review and focused follow-ups. Before publishing,
use one fresh cumulative `origin/main` review. A third fresh review is reserved
only for a materially expanded scope or an advanced base; never exceed three.
