# Capability Preludes and Profiles — Discussion Notes

**Status:** V1 shipped (see guide); this doc is forward-looking design for
capability profiles/credentials/providers.

V1 capability preludes have SHIPPED; see the guide
[`docs/guides/capability-prelude.md`](../guides/capability-prelude.md)
(implemented under `lib/ptc_runner/lisp/prelude/*`). This doc covers the next
design step: how to evolve from "preludes wrap configured upstream tools" toward
a more general capability model without blurring the security boundary.

## Proposed Direction: Capability Profiles

Introduce a separate **Capability Profile** concept for authority-bearing
configuration.

The split would be:

```text
Capability Profile
  declares providers, credential refs, model aliases, grants, effects, limits,
  cache policy

Capability Runtime
  materializes a profile into live provider state, resolved clients, and
  per-run contexts

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

## Credentials and Secret References

Credentials should be a profile/runtime concern, not ordinary user-space
PTC-Lisp. Runtime programs may use granted capabilities, but they should not
mint new capabilities by reading credentials, defining upstreams, or configuring
providers during a run.

Possible split:

```text
CredentialStore
  owns secret sources, resolution, redaction, audit records

CredentialRef
  references a secret without exposing material, e.g. env/file/provider chain

CapabilityProfile
  references credential refs by ID

CapabilityRuntime
  resolves refs into live provider clients

Prelude/User Program
  sees descriptors such as credential? true, never secret values
```

Credential references might be profile-time data such as:

```clojure
(cap/credential "openrouter-key"
  {:env "OPENROUTER_API_KEY"})

(cap/credential "crm-token"
  {:file {:path "secrets/crm-token"}})

(cap/credential "bedrock-default"
  {:provider :aws-default-chain})

(cap/credential "bedrock-ci"
  {:env {:access-key-id "AWS_ACCESS_KEY_ID"
         :secret-access-key "AWS_SECRET_ACCESS_KEY"
         :session-token "AWS_SESSION_TOKEN"}})
```

Descriptors can disclose that a capability is credential-backed without
disclosing material:

```clojure
{:ref "crm/get-user"
 :requires ["cap:crm.user.read"]
 :effect :read
 :credential? true
 :auth "bearer"
 :secret-visible? false}
```

JSON loading for config is useful, but it belongs at profile time or behind an
explicit sandbox filesystem capability. Profile-time JSON should support schema
validation so configuration fails before a run starts:

```clojure
(profile/load-json {:path "upstreams.json"
                    :schema "upstreams.schema.json"})

(cap/upstreams-from-json {:path "upstreams.json"
                          :schema "upstreams.schema.json"})
```

Runtime forms such as `(fs/read-json ...)` may be useful for ordinary data, but
only when the selected sandbox profile grants access to specific paths or
resources. They should not be the mechanism for loading credentials.

## Capability Providers

A profile can become extensible through provider modules. Upstream would be the
first provider, backed initially by the existing upstream JSON/config machinery.

Possible provider families:

- `upstream`: OpenAPI and external MCP upstream operations;
- `llm`: LLM providers, model aliases, default model roles, and model policy;
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

## LLM Providers and Registry

LLM configuration fits naturally as a capability provider. The current
`PtcRunner.LLM` adapter/registry model can be lifted into profiles without
making credentials visible to runtime Lisp.

Conceptual split:

```text
CredentialStore
  owns OpenRouter, Bedrock, OpenAI-compatible, and other provider credentials

LLMProviderProfile
  provider type, base URL, region, auth refs, provider-specific options

LLMRegistry
  aliases, defaults, tags, model metadata, and call policy

CapabilityProfile
  grants which aliases/models a participant or sandbox may use

Runtime PTC-Lisp
  calls aliases such as :haiku or :code, never provider secrets
```

Profile-time sketch:

```clojure
(cap/credential "openrouter-key"
  {:env "OPENROUTER_API_KEY"})

(cap/credential "bedrock-default"
  {:provider :aws-default-chain})

(llm/provider :openrouter
  {:type :openrouter
   :api-key {:credential "openrouter-key"}})

(llm/provider :bedrock
  {:type :bedrock
   :region {:env "AWS_REGION"}
   :auth {:credential "bedrock-default"}})

(llm/alias :haiku
  {:provider :openrouter
   :model "anthropic/claude-haiku-4.5"
   :tags [:fast :cheap]})

(llm/alias :sonnet
  {:provider :openrouter
   :model "anthropic/claude-sonnet-4"
   :tags [:reasoning :code]})

(llm/alias :bedrock-haiku
  {:provider :bedrock
   :model "anthropic.claude-haiku-4-5-20251001-v1:0"})

(llm/default :chat :haiku)
(llm/default :code :sonnet)
(llm/default :extract :haiku)

(cap/grant "llm:haiku"
  {:effect :llm-call
   :visibility :discoverable
   :limits {:max-output-tokens 2000}})

(cap/grant "llm:sonnet"
  {:effect :llm-call
   :visibility :hidden
   :limits {:max-output-tokens 4000}})
```

Runtime PTC-Lisp would use the aliases:

```clojure
(llm/call {:model :haiku
           :messages [{:role :user
                       :content "Summarize this"}]})

(agent/run {:prompt "Analyze this"
            :llm :code
            :output :text})
```

If a sandbox/profile grants only `llm:haiku`, calls to `:sonnet` should fail
before provider invocation. Discovery can expose safe descriptors:

```clojure
{:alias :haiku
 :provider :openrouter
 :model "anthropic/claude-haiku-4.5"
 :credential? true
 :secret-visible? false
 :effects [:llm-call]
 :limits {:max-output-tokens 2000}
 :tags [:fast :cheap]}
```

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
   :auth {:bearer {:credential "crm-token"}}})

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
- LLM providers, aliases, defaults, and model grants;
- typed native tools;
- SubAgent tools;
- sandbox affordances;
- cacheable resources;
- credential-backed provider bindings without secret values;
- profile-level grants.

Deferred catalog APIs such as `cap/list`, `cap/search`, and `cap/meta` should be
designed against that descriptor model, not just as wrappers over today's
upstream catalog.

Open question: whether `cap/*` is only a profile-time namespace, only a
user-facing discovery namespace, or two separate namespaces with explicit names.
Avoid one namespace that both grants authority and exposes discovery inside
ordinary programs.

## Relationship to Conversation Control Plane

[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
explores the runtime UX side: using PTC-Lisp to inspect and operate REPL
sessions, LLM chats, SubAgent runs, and historical debug artifacts.

This document is the authority/model side. Capability profiles, providers,
runtimes, and descriptors answer what capabilities exist, how they are backed,
what grants/effects they carry, and what metadata can be exposed safely.

The conversation/control-plane surface should consume this descriptor model for
`apropos`, `doc`, `meta`, `dir`, `ptc/inspect`, and `ptc/invoke` style APIs. It
should not define endpoints, credentials, grants, provider configuration, or
authority-bearing profile state. Historical sessions, live conversation
handles, and SubAgent debug artifacts are consumers of the descriptor registry,
not the core profile system itself.

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
