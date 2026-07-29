# MCP exact-resource authority gate

**Status:** future, trigger-gated. The first-party trigger was audited on
2026-07-29 and is not satisfied. Revisit against the final MCP `2026-07-28`
schema at
`modelcontextprotocol/modelcontextprotocol@5f5440bb26a62e2cf3440b92da5a667efa03b267`.

PtcRunner implements bounded MCP tools and permanently refuses
server-initiated sampling, elicitation, and roots. MCP resources remain
unimplemented because no current first-party application needs their
resource-native semantics.

## Trigger

Start an authority-design slice only when a concrete first-party application
needs MCP resources and an ordinary mapped MCP tool would lose an important
capability. A resource-only interoperability goal is not enough without the
application that consumes it.

The 2026-07-29 audit rejected the slice:

- `repo-analyst` needs dynamic directory, filename, text-search, and line-range
  operations over a frozen workspace. A finite set of exact resource URIs
  cannot replace that discovery flow.
- `examples/viewer-demo` reads known files, but the mapped
  `read_text_file` tool already supplies every behavior the demo uses.
- `examples/kernel-tutorial/03-file-agent` reads one known `brief.txt`, and its
  mapped `read_text_file` tool already supplies the complete application
  behavior.
- `examples/kernel-inspection-lab` exercises varied MCP tool/result exchanges;
  it has no resource-native requirement.
- trace and inspection analysis intentionally use host-native immutable
  snapshots, not MCP server namespaces.

Do not infer a trigger from narrower authority alone. First identify the
application behavior that resources preserve and a mapped tool cannot.

## Required authority shape

When the trigger is met, resources must not expose a generic URI argument or a
raw list operation to mission code. The design starts from these invariants:

- the host maps exact upstream resource URIs to bounded public zero-argument
  read capabilities;
- the manifest may only narrow those fixed mappings, model visibility, and the
  common installed `timeout_ms` and `max_result_bytes` ceilings;
- resource reads inherit those selection-narrowable timeout and decoded-result
  ceilings in addition to resource catalog and page bounds;
- `resources/list` is assembly-time validation, while `resources/read` is
  reachable only through a frozen mapping;
- every returned `ResourceContents.uri` exactly equals the granted URI;
- URI prefixes grant nothing, and sub-resources require separate mappings;
- returned text is inert untrusted result data and is never automatically
  spliced into a workflow or system prompt;
- binary/blob content remains rejected until it has its own bounded
  representation; and
- URI templates, prompts, completion, subscriptions, and progress stay out of
  the slice.

The specification must decide the host grammar, manifest selection,
resource-only installation rule, catalog/page ceilings, duplicate and catalog
change behavior, safe snapshot identity, private cache semantics, and
`Mcp-Name` emission for `resources/read` over HTTP.

Every paginated catalog operation must preserve the first page's `cacheScope`
and reject a later different scope; page `ttlMs` values may vary.
`cacheScope: "private"` restricts cache reuse to one authorization context and
does not change PtcRunner `data_class` or `accepts_data`.

## Future slices

1. Write the authority specification with one allowed URI, one unlisted URI, a
   catalog change, duplicate aliases, a private result, and a resource-only
   server. Prove no generic URI or raw list operation reaches mission code.
2. After clean review, implement exact mappings, text normalization, safe
   snapshots, resource-only installations, and stdio plus Streamable HTTP
   interoperability.

Each implementation slice must update generated host schemas and durable
module/guide documentation, carry unsafe-default regressions, pass
`mix precommit`, and receive a clean independent review.
