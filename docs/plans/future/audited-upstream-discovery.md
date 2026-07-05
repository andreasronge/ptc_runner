# Audited Upstream Discovery

**Status:** future direction, prompted by the composable-prelude demo Stage 2
run in `ptc-bench-comparison`.

## Problem

MCP-only stages need to discover approved evidence paths and upstream artifacts
through the same audited surface they are allowed to use for reading evidence.

In the composable-prelude demo, the evidence upstream exposed
`evidence/read_jsonl`, but it did not expose a bounded way to list approved file
paths. The analyst therefore had two bad choices:

- guess filenames through repeated failed reads; or
- reach for host-side discovery tools exposed by the launcher.

Several Stage 2 attempts were rejected because the host CLI exposed tools such
as filesystem search, shell commands, extra MCP tools, tool search, or resource
listing while the model was trying to find evidence paths. The eventual accepted
run used a neutral manifest file as a workaround.

That workaround is acceptable for one run, but it is not a durable capability.
The runner should let a session discover approved upstream paths in-band,
bounded, and turn-log-visible.

## Boundary Clarification

This request is not "let the host CLI resource browser into gated runs."

The rejected Stage 2 attempts failed because host-level tools were visible
outside the stage's allowlist. A `ptc_runner` discovery surface is a different
trust boundary:

- it is scoped to upstreams configured for the run;
- it is callable through the same Lisp/MCP session surface as evidence reads;
- it can be bounded by the upstream adapter;
- it can be recorded in turn logs.

The fix should reduce the pressure to use host discovery tools, while launcher
hardening still prevents those tools from being exposed to gated model stages.

## Direction

Support two complementary discovery paths.

### 1. Protocol-Native Resource Listing

Where an upstream MCP server exposes resources, `ptc_runner` should be able to
ask that upstream for resources and present the result through a bounded Lisp
surface.

This should not be silent transport plumbing only. The runner needs an explicit
session-visible operation, for example:

```clojure
(tool/resources "evidence")
```

or:

```clojure
(tool/call {:server "evidence" :tool "list_resources" :args {:limit 100}})
```

The exact shape is open. The important properties are:

- scoped to the configured upstream server;
- bounded and pageable;
- does not expose unrelated host or connector resources;
- appears in the turn log with enough detail to audit discovery behavior.

### 2. Conventional List/Glob Tool Shape

MCP resources are optional, and many upstreams will not implement them.

For file-like evidence lanes, support or document a conventional bounded tool
shape such as:

```json
{"tool": "list", "args": {"path": ".", "limit": 100}}
```

or:

```json
{"tool": "glob", "args": {"pattern": "*.md", "limit": 100}}
```

The convention should be explicit enough that fixture and evidence upstreams
can expose directory/path discovery without each run inventing a manifest file.

## Logging Requirements

Discovery operations must be recorded at least as clearly as regular tool
calls. For each discovery operation, turn logs should include:

- operation kind (`resources`, `list`, `glob`, or equivalent);
- server/upstream name;
- bounded input arguments;
- result count and truncation/page cursor;
- outcome and duration;
- failure reason when denied or unsupported.

This is load-bearing for methodology. If a model stage claims it used only
approved evidence, the run artifact must show how it found that evidence.

## Relationship To Capability Namespaces

Distinguish this from role-scoped tool-catalog filtering
([`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slice C and Slice E, implemented): that axis controls which
*tools* a role's catalog shows. This doc is about a different axis — once a
tool is granted, enumerating which *paths/artifacts* are approved to read
through it. Both get called "discovery"; a fixture upstream needs both.

This pairs with selected capability namespaces.

Launcher-level process flags are invisible to the session turn log. A
session-declared discovery capability would make the visible surface auditable
from the run artifact itself:

```json
{
  "preludes": ["tool/read", "tool/discovery"]
}
```

The capability name is illustrative. The design point is that a stage should
declare whether it can discover upstream artifacts, and the turn log should show
that declared surface.

## Non-Goals

- Do not expose host filesystem listing directly to model stages.
- Do not expose resources from unconfigured connectors or user-global MCP
  servers.
- Do not make discovery unbounded.
- Do not treat host CLI allowlists as a substitute for in-band upstream
  discovery.

## Acceptance Sketch

A future smoke should be able to run a read-only session with only evidence
read/discovery authority and prove:

1. The model/session can list the approved files for an evidence upstream.
2. The model/session can read one of those files.
3. The turn log records both the discovery operation and the file read.
4. No host filesystem, host resource-listing, or unrelated connector discovery
   is required.
