# MCP write support and client-surface coverage

**Status:** proposed; no approved work. Written 2026-07-28 against MCP draft
`2026-07-28` at `modelcontextprotocol/modelcontextprotocol@main`.

PtcRunner installs MCP sources read-only. Every mapped tool must declare
`effect: "read"`, and the source rejects writes outright. This plan covers what
it would take to allow write-effect tools, how much of the remaining MCP client
surface is worth implementing, and which parts must stay refused.

Backward compatibility is not a constraint anywhere in this plan. The read-only
lock is a schema `const`, not a compatibility shim; the effect vocabulary
already exists throughout the Kernel; and 0.x deletes rather than deprecates.
The costs here are semantic (idempotency and retry) and architectural
(server-initiated model access), and breaking compatibility relieves neither.

## Goals

- Allow an operator to install a write-effect MCP tool, with retry and
  reporting semantics that stay correct when a call mutates the world.
- Complete the read-oriented MCP client surface: prompts, resources, and
  completion.
- Add request cancellation, which is missing today regardless of writes.

## Non-goals

- **Server-initiated model access will not be supported.** See section 5. This
  is a permanent design position, not deferred work.
- No change to who declares authority. Effect stays operator-declared in the
  host document; server-supplied tool annotations stay untrusted.
- No change to the frozen-catalog model. Discovery still happens once per run
  build.

## Current state

Established by reading the implementation on 2026-07-28. Recorded so a later
slice does not re-derive it.

The Kernel already models writes end to end:

| Fact | Location |
| --- | --- |
| Effect vocabulary is `:read \| :write \| :unknown`, default `:unknown` | `capability.ex:30`, `:43` |
| Anything not `:read` counts as unsafe activity and forbids evaluation retry | `evaluation.ex:527`, `:535`, `:462` |
| Prelude metadata accepts all three effects, and `:write` wins a join | `compiler.ex:47`, `:1509` |
| Effect already appears in the safe provider snapshot | `mcp_source.ex:834` |

Read-only is enforced at exactly six sites, all in the MCP installation path:

| Site | Lock |
| --- | --- |
| `priv/schemas/ptc-host-config.schema.json` | `"effect": {"const": "read"}` |
| `host_config.ex:699` | `"read" <- value["effect"]` |
| `host_config.ex:90`, `:708` | type and struct fixed to `:read` |
| `mcp_source.ex:301` | normalization pattern-matches `effect: :read` |
| `mcp_source.ex:317`, `:807`, `:834` | capability and snapshot hardcode read |
| `docs/guides/host-configuration.md` | documents effect as always `read` |

Of the draft's seventeen methods, three are implemented: `server/discover`,
`tools/list`, and `tools/call`.

## 1. Unlock write effects

Widen the six sites above from a fixed `:read` to the declared effect. The
schema `const` becomes an enum of `read` and `write`; `:unknown` stays
unavailable to a host document, because an operator installing a tool must say
what it does.

Acceptance: an operator can install a write tool, `--check` reports its effect,
the safe snapshot records it, and a manifest can select it without gaining any
ability to change it.

## 2. Make effect inference correct

`compiler.ex:1028` infers `[:read]` for any prelude export that references a
tool:

```elixir
inferred_effects = if requires == [], do: [], else: [:read]
```

With `validate_effect(nil) -> {:ok, nil}` (`:1465`) and the join order at
`:1509`, an export that wraps a tool but declares no effect joins to `:read`.
That is sound only while every MCP tool is read-only. Once write tools exist, an
undeclared wrapper around one will report `:read` and become retryable after
mutating.

This must land with section 1, not after it. The inference must resolve the
backing tool's installed effect, and must fall back to `:unknown` rather than
`:read` when it cannot.

Acceptance: a prelude export wrapping a write tool reports `:write` when it
declares nothing; a regression test covers the undeclared case specifically,
because that is the path that silently degrades.

## 3. Make retryability effect-aware

`mcp_source.ex:1470` reports `mcp_timeout` as `retryable?: true`, and `:1485`
does the same for transport failures. Both are correct for reads and wrong for
writes: a timed-out write may already have been applied, and PtcRunner cannot
distinguish that from one that never arrived.

A write whose outcome is unknown must surface as non-retryable, with a
classification that says the state is indeterminate rather than implying the
call did not happen. The alternative — deriving idempotency from the server's
`idempotentHint` — is rejected: the hint is server-supplied, defaults to
`false`, and PtcRunner deliberately reads no tool annotations today
(`mcp_protocol.ex` validates schemas, never annotations).

Acceptance: a write tool that times out yields a non-retryable indeterminate
classification; the same timeout on a read tool stays retryable.

## 4. Complete the read surface and add cancellation

Additive, no architectural tension:

- `prompts/list`, `prompts/get`
- `resources/list`, `resources/read`, `resources/templates/list`
- `completion/complete`

Most of the cost is content blocks, not methods. PtcRunner supports only exact
text and embedded text resources; binary and blob content are unsupported, and
`resources/read` makes that limitation user-visible rather than theoretical.
`MRTR` also permits `InputRequiredResult` on `prompts/get` and `resources/read`,
so each must reject that result cleanly — see section 5.

Cancellation (`notifications/cancelled`) is worth doing on its own account. A
run that exhausts its deadline abandons the request today while the server keeps
working; with writes, that gap is the difference between an abandoned read and
an unattributed mutation.

Deferred rather than refused: `subscriptions/listen`,
`notifications/resources/updated`,
`notifications/subscriptions/acknowledged`, and `notifications/progress`. These
need push delivery into a bounded, deadline-scoped run built around frozen
captures. Draining at call time is probably the shape, but it is unscoped design
work with no current demand.

Acceptance: each added method has its own installed ceiling, appears in the safe
snapshot, and is selectable and narrowable by manifest exactly as tools are.

## 5. Why server-initiated model access stays refused

In `2026-07-28`, server-initiated requests are removed and replaced by Multi
Round-Trip Requests. A server answers `tools/call` with an `InputRequiredResult`
carrying an `ElicitRequest`, `CreateMessageRequest`, or `ListRootsRequest`, and
the client is expected to fulfil it and retry.

Supporting `CreateMessageRequest` — sampling — would let an MCP server reached
by a tool the model itself chose to call make the workflow's LLM generate text.
The invariant that mission code cannot reach the model capability is the
property the two-environment split exists to enforce. This is an authority
inversion, and no compatibility break resolves it.

`ElicitRequest` needs a human, and missions are deliberately non-interactive.
`ListRootsRequest` presumes ambient filesystem scope, which PtcRunner replaces
with explicit grants.

Two facts make this cheap to hold:

- PtcRunner declares `@client_capabilities %{}` (`mcp_source.ex:42`), and MRTR
  forbids a server from sending input requests for capabilities the client has
  not declared. The current posture is already an explicit refusal.
- Roots, sampling, and logging are marked `@deprecated` as of `2026-07-28`
  (SEP-2577) in the schema PtcRunner pins — `roots` at `schema.ts:732`,
  `logging` at `:808`, `sampling/createMessage` at `:2173`, `roots/list` at
  `:2706`. Implementing them would mean implementing features already scheduled
  for removal.

What this plan does require is that every request type able to return
`InputRequiredResult` — `tools/call`, `prompts/get`, `resources/read` — treats
it as a closed protocol error rather than falling through validation. That is a
correctness obligation of section 4, not a step toward support.

Trigger to revisit: a first-party need for host-mediated elicitation, where the
*host* — never mission code, never the model — supplies the response. Sampling
has no trigger.

## Delivery and acceptance

Sections 1 through 3 are one slice and must ship together; section 1 alone
introduces the inference and retry defects that 2 and 3 close. Section 4 is
independent and can be split per method. Section 5 is a documented position with
one enforcement obligation.

Every slice must:

- keep effect operator-declared and annotations untrusted;
- state the effect in `--check` output and the safe provider snapshot;
- carry a regression test for the unsafe-by-default path, not only the happy
  path; and
- pass `mix precommit`.

On landing sections 1 through 3, the durable contract moves into
`PtcRunner.Kernel.MCPSource` and `PtcRunner.Kernel.HostConfig` module
documentation plus the write-effect and retryability sections of
[Host configuration](../guides/host-configuration.md) and
[Building agents](../guides/building-agents.md); this plan is then deleted.
