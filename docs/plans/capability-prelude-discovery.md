# Capability Preludes and Profiles — Discussion Notes

**Status:** V1 capability preludes are implemented on `main` as of 2026-06-05.
This document is now discussion material for the next design step. The
user-facing V1 guide is
[`docs/guides/capability-prelude.md`](../guides/capability-prelude.md).

The old V1 requirements are intentionally compressed here. The useful question
now is how to evolve from "preludes wrap configured upstream tools" toward a
more general capability model without blurring the security boundary.

## Implemented Baseline

V1 shipped a stateless, deployment-authored prelude mechanism:

- compiled prelude artifacts and export records:
  `PtcRunner.Lisp.Prelude`, `PtcRunner.Lisp.Prelude.Export`, and
  `PtcRunner.Lisp.Prelude.Compiler`;
- direct attachment through `PtcRunner.Lisp.run/2` with `prelude:`;
- SubAgent attachment through `runtime_prelude:`;
- REPL attachment through `mix ptc.repl --prelude`;
- protected namespace/export analysis, evaluator resolution, private helper
  isolation, prompt inventory rendering, and trace summaries;
- discovery through `doc`, `dir`, `meta`, `apropos`, `ns-publics`, `all-ns`,
  and `ns-name`;
- upstream-backed `requires` validation when a selected upstream runtime is
  attached, including the multi-turn SubAgent upstream bridge.

The V1 contract is deliberately narrow:

- preludes define curated Lisp-facing namespaces, constants, functions,
  docstrings, and metadata;
- preludes do not define upstream endpoints, credentials, grants, or sandbox
  authority;
- public exports may wrap existing tool surfaces such as `(tool/call ...)` and
  typed `tool/name` calls;
- `requires` entries such as `"upstream:crm/get_user"` are validated against the
  selected upstream runtime at attach time;
- prelude metadata is advisory. Runtime facts and host policy are authoritative.

## Current Shape

Today there are two separate ideas that are easy to conflate:

1. **Capability prelude:** a non-secret, user-facing API layer. It gives the
   agent curated functions such as `crm/get-user`, protects those namespaces, and
   makes them discoverable.
2. **Upstream runtime:** a concrete provider runtime under
   `PtcRunner.Upstream.*`. It owns configured OpenAPI/MCP upstreams,
   credentials, transport clients, catalog data, redaction, limits, and per-run
   `RunContext` wiring.

`PtcRunner.Upstream.Eval.run_lisp/3` and `run_subagent/3` are upstream adapters
around the lower-level `Lisp.run/2` / SubAgent runner paths. They create a
per-run upstream context, expose `tool/call` and discovery hooks, thread the
runtime into prelude attachment, and drain upstream call records.

This is useful, but it should not be mistaken for a generic runtime abstraction.
It is the first concrete provider integration.

## Proposed Direction: Capability Profiles

Introduce a separate **Capability Profile** concept for authority-bearing
configuration.

The split would be:

```text
Capability Profile
  declares providers, credentials refs, grants, effects, limits, cache policy

Capability Runtime
  materializes a profile into live provider state and per-run contexts

Capability Prelude
  exposes curated Lisp-facing functions that require capabilities

User Program
  calls the curated functions or any lower-level forms the host exposes
```

The key boundary:

- a **profile** defines what capabilities exist and how they are backed;
- a **prelude** defines how those capabilities are presented to user-space Lisp;
- a **runtime** enforces the selected profile and host policy for a run.

This keeps API curation separate from authority and infrastructure. A prelude
can be prompt-visible and trace-safe; a profile can reference secrets, endpoint
configuration, grants, and deployment policy without becoming agent-visible.

## Capability Providers

A profile can become extensible through provider modules. Upstream would be the
first provider, backed initially by the existing upstream JSON/config machinery.

Possible provider families:

- `upstream`: OpenAPI and external MCP upstream operations;
- `local`: host functions or native BEAM tools with custom config;
- `sandbox`: filesystem, process, network, or resource affordances;
- `subagent`: SubAgent-as-tool definitions;
- future providers for caches, memory, vector stores, queues, or deployment
  services.

A provider module might eventually contribute:

- profile-time forms or a profile schema;
- validation and normalization;
- descriptor records for discovery;
- runtime startup/teardown;
- per-run context hooks;
- `requires` validation;
- effect classification;
- redaction and trace-safe summaries.

The exact behaviour API is open. The important part is that provider extension
should happen at profile/runtime boundaries, not by giving ordinary user Lisp new
authority.

## Profile-Time Forms

If the profile language is PTC-Lisp-shaped, forms such as `cap/upstream` should
be **profile-time forms**, not functions available in normal user programs.

Example sketch:

```clojure
(cap/upstreams-from-json {:path "upstreams.json"})

(cap/upstream "crm"
  {:transport :openapi
   :schema {:path "priv/crm.openapi.json"}
   :base-url {:env "CRM_BASE_URL"}
   :auth {:bearer {:env "CRM_TOKEN"}}})

(cap/grant "upstream:crm/get_user"
  {:effect :read
   :visibility :discoverable})
```

These forms would compile into a profile artifact. They should not run during
agent execution and should not be callable from user-space Lisp. Secret values
should remain references, not literal prompt/trace data.

For the first slice, a profile facade over the current upstream JSON is safer
than replacing the JSON format:

```clojure
(cap/upstreams-from-json {:path "upstreams.json"})
```

The JSON can remain the source of truth while the provider/profile boundary is
tested.

## Prelude Layer Over Profiles

The user-facing prelude would continue to curate Lisp APIs:

```clojure
(ns crm
  "CRM helpers."
  {:visibility :prompt})

(defn get-user
  "Return a CRM user by id."
  {:requires ["upstream:crm/get_user"]}
  [id]
  (tool/call {:server "crm"
              :tool "get_user"
              :args {:id id}}))
```

Longer term, profile-defined stable capability IDs could decouple the prelude
from provider-specific operation names:

```clojure
(defn get-user
  {:requires ["cap:crm.user.read"]}
  [id]
  ...)
```

The profile would bind `"cap:crm.user.read"` to one or more concrete provider
operations, for example `"upstream:crm/get_user"`. That indirection may be worth
it once multiple providers exist, but the current provider-qualified
`"upstream:server/tool"` form is a good V1 substrate.

## Discovery and Descriptors

V1 export records are enough for protected prelude functions. A generic
capability model likely needs a descriptor registry that can describe different
things uniformly:

- prelude exports;
- upstream operations;
- typed native tools;
- SubAgent tools;
- sandbox affordances;
- cacheable resources;
- profile-level grants.

Deferred catalog APIs such as `cap/list`, `cap/search`, and `cap/meta` should be
designed against that descriptor model, not just as wrappers over today's
upstream catalog.

Open question: whether `cap/*` is only a profile-time namespace, only a
user-facing discovery namespace, or two separate namespaces with explicit names.
Avoid one namespace that both grants authority and exposes discovery inside
ordinary programs.

## Safety Principles

The next design should preserve these boundaries:

- user programs and LLM-authored code must not define endpoints, credentials, or
  grants at runtime;
- prelude metadata can declare requirements but must not broaden authority;
- host policy and runtime facts remain authoritative over effects, grants,
  visibility, limits, and backing providers;
- credentials never appear in prelude source, prompts, traces, descriptors, or
  error messages;
- profile compilation should be deterministic and auditable;
- per-run state stays separate from long-lived provider state so concurrent runs
  do not share counters, ledgers, or transient caches accidentally.

## Deferred Work to Re-evaluate

The old deferred list is still plausible, but should be re-read through the
profile/provider split:

- hidden append-only prelude events and pmap merge semantics;
- stateful prelude wrappers;
- cache policy declarations in profile or export metadata;
- moving existing `tools_meta` cache flags into descriptors;
- generic capability catalog APIs such as `cap/list`, `cap/search`, and
  `cap/meta`;
- migration or removal of `(tool/servers)`;
- full descriptor taxonomy with `descriptor_type`, `provider_kind`, and facets;
- SubAgent-as-tool, native tool, upstream operation, and sandbox capability
  unification under one registry;
- profile-time forms such as `defcap`, `defsandbox`, or `defagent`;
- LLM-authored profile/prelude proposal workflows with explicit approval;
- agent-published capabilities;
- expanded REPL LLM/model/credential configuration;
- benchmark-gated prompt/discovery comparisons.

## Open Questions

- Is the first profile artifact a Lisp-shaped file, structured data, or both?
- Does `cap/upstreams-from-json` become the first bridge, keeping upstream JSON
  as source of truth, or do we add native profile declarations immediately?
- What is the smallest provider behaviour needed for upstream without
  overgeneralizing around one provider?
- Should stable `cap:*` IDs exist now, or should V1 provider refs remain the only
  requirement identifiers until a second provider exists?
- Where should effect classification live: provider descriptors, host policy, or
  both with host override?
- Are profile descriptors visible to user programs directly, or only through
  curated prelude exports and bounded discovery APIs?
- Should ordinary user programs ever get a `cap/*` namespace, or should that
  name be reserved for profile-time forms?
- How do capability profiles compose across parent/child SubAgents without
  accidentally granting a child the parent's authority?
- What trace artifact is sufficient to reproduce a run's capability environment
  without leaking secrets?

## Possible First Slice

Do not replace the current upstream runtime yet. A conservative next slice would
be:

1. Define terminology in docs: capability profile, capability provider,
   capability runtime, and capability prelude.
2. Add a small profile artifact that can import existing upstream JSON:
   `(cap/upstreams-from-json {:path ...})` or an equivalent structured form.
3. Implement an upstream provider facade over the existing
   `PtcRunner.Upstream.Config` and `PtcRunner.Upstream.Runtime`.
4. Keep `PtcRunner.Upstream.*` as the concrete provider implementation; add the
   generic layer above it only where the profile needs it.
5. Leave user-facing preludes unchanged except for documenting that
   `"upstream:..."` requirements are provider-specific capability requirements.

This would test the abstraction without changing the execution path or making
preludes authority-bearing.
