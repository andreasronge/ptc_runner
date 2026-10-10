# Gateway conformance checks

> **Audience:** maintainers validating the gateway HTTP boundary.

The official suite is pinned in
`ptc_gateway/test/support/mcp_conformance/package.json` at
`@modelcontextprotocol/conformance@0.2.0-alpha.11`. Applicable server scenario
IDs are `server-stateless`, `tools-list`, `dns-rebinding-protection`, `caching`,
`http-header-validation`, and `http-custom-header-server-validation`.
The remaining listed server scenario IDs are
excluded: `tools-call-*` require diagnostic tools and content families not
provided by configured workflows; `completion-complete`, `resources-*`, `prompts-*`, and
`sep-2164-resource-not-found` require unsupported feature families;
`server-sse-multiple-streams` requires GET/session streams;
`json-schema-2020-12` exercises a tool call; and `input-required-result-*`
requires server requests and multi-round tool execution. The gateway does not claim the complete server suite.

The checked-in expected-failures baseline narrows mixed scenarios to this
profile. It excludes server-stateless checks requiring diagnostic tools, response
streams, logging tools, or optional server identity; caching checks for prompts
and resources. Both header-validation scenarios execute without a baseline,
including Base64/literal custom parameter decoding and mismatch rejection.
All applicable checks execute through the authenticated conformance proxy in
the gateway CI gate. Gateway boundary tests additionally enforce every critical
header duplicate and the exact parser and application header ceilings.
Integration boundaries also exercise exact and excessive body,
metadata, JSON depth/node, ID, normalized-schema, static-catalog, and encoded
response sizes.
