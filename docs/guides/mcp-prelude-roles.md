# MCP Prelude Roles

Use MCP session roles to expose selected preludes, upstream operations, and editor tools without making every dependency part of the model's public API.

This guide shows how PreludeStore selection, prelude dependencies, session
roles, scoped discovery, and turn logs fit together in a deployed MCP server.
For prelude syntax and authoring rules, start with
[Capability Preludes](capability-prelude.md).

## Prerequisites

- Run `ptc_runner_mcp` with stateful sessions enabled.
- Seed or create a `PreludeStore`; see
  [MCP Getting Started](mcp-getting-started.md#6-stateful-sessions-with-selected-preludes).
- Use `--session-roles` when the server should enforce different grants for
  analyst, editor, verifier, or operator sessions.
- Use `--turn-log-dir` when you want later sessions to inspect measured runs.

## Mental Model

Prelude roles combine five separate concepts:

| Concept | Purpose |
|---|---|
| Prelude | Curated Lisp-facing API such as `audit/check`. |
| Namespace | Public boundary the model sees and calls. |
| `requires_preludes` | Implementation dependency between stored preludes. |
| Role | Authority boundary for modes, selected preludes, tools, credentials, and upstream operations. |
| Turn log | Evidence used to compare before/after runs. |

A selected prelude can depend on another prelude. Selecting `audit` may
auto-pull `base`, but the role and session options decide whether `base` looks
like a public API or a supporting library.

## Prompt Visibility

Prelude visibility decides which public exports are shown upfront:

| Visibility | Prompt inventory | Discovery forms |
|---|---|---|
| `:prompt` | Included as a compact hint. | Available. |
| `:discoverable` | Omitted from upfront hints. | Available through `doc`, `dir`, `apropos`, and `ns-publics`. |
| `defn-` private helper | Omitted. | Not callable or discoverable as an export. |

Use `:prompt` for the smallest set of exports the model should naturally reach
for. Use `:discoverable` for rare or advanced exports that should remain
available after inspection. Use `defn-` for implementation helpers.

```clojure
(ns audit "Audit workflow." {:visibility :prompt})

(defn check "Run the normal audit." [case-id]
  (base/sample case-id))

(defn explain-check
  "Explain audit details."
  {:visibility :discoverable}
  [case-id]
  {:case case-id :path "audit/check"})

(defn- normalize-case [case-id]
  (str case-id))
```

Visibility does not grant authority. Role policy and attach/dispatch checks
still decide whether the backing tools and upstream operations are allowed.

## Dependency Shape

Write low-level helpers as a base prelude:

```clojure
(ns base "Reusable page helpers." {:visibility :prompt})

(defn sample [x] (str "sample:" x))
(defn page-window [x] (str "window:" x))
(defn unused-helper [x] (str "unused:" x))
```

Write a higher-level prelude that depends on it:

```clojure
(ns audit "Audit workflow." {:visibility :prompt})

(defn check [case-id]
  (base/sample case-id))
```

Store the dependency explicitly:

```clojure
(prelude/write {:id "audit"
                :source audit-source
                :requires_preludes ["base"]})
```

When a session starts with `preludes: ["audit"]`, the store resolves and pins
the required `base` version. Later changes to `base` do not affect `audit`
until `audit` is rewritten or edited.

## Role Policy

Use roles to describe what each session stage may do. A small policy can split
read-only analysis, prelude editing, and validation:

```json
{
  "default_role": "analyst",
  "roles": {
    "analyst": {
      "modes": ["read_only"],
      "prelude_store": "read",
      "preludes": ["audit"],
      "ptc_tools": ["log_counters", "log_turns"],
      "upstream_tools": [],
      "credentials": [],
      "strict_transitive_calls": true
    },
    "editor": {
      "modes": ["write_capable"],
      "prelude_store": "write",
      "preludes": ["audit", "base"],
      "ptc_tools": [],
      "upstream_tools": [],
      "credentials": [],
      "strict_transitive_calls": true
    },
    "validator": {
      "modes": ["read_only"],
      "prelude_store": "read",
      "preludes": ["audit"],
      "ptc_tools": ["log_counters", "log_turns"],
      "upstream_tools": [],
      "credentials": [],
      "strict_transitive_calls": true
    }
  }
}
```

Start the server with that policy:

```bash
ptc_runner_mcp start \
  --sessions \
  --prelude-store-seed ./priv/preludes \
  --session-roles ./roles.json \
  --turn-log-dir ./turn-log
```

For HTTP deployments, bind bearer tokens to allowed roles with
`--http-role-tokens`; see
[MCP server configuration](../mcp-server-configuration.md).

## Scoped Presentation

Start normal sessions with `scoped_base_surface: true`:

```json
{
  "role": "analyst",
  "preludes": ["audit"],
  "scoped_base_surface": true,
  "tags": { "run": "demo-17", "stage": "baseline" }
}
```

This changes model-facing discovery only. `dir`, `apropos`, `ns-publics`, prompt
inventory, and session start metadata show only the transitive exports that are
reachable from the selected direct exports.

For example, `(dir 'base)` may show `sample` but hide `unused-helper`. The
prelude code still runs the same way; this option reduces accidental surface
area and prompt distraction.

Prompt visibility still applies inside that scoped view. A reachable
`:discoverable` export remains omitted from upfront prompt inventory, but can be
found with discovery forms.

Use `(dir 'base {:full true})` during manual debugging when you need the full
attached namespace surface.

## Strict Transitive Calls

Set `strict_transitive_calls: true` in role policy when selected preludes should
be the contract boundary.

With strict calls enabled, this is allowed:

```clojure
(audit/check "case-1")
```

The call may run `base/sample` internally because `audit` declared the
dependency.

This direct session-authored call is rejected when `base` was only pulled as a
dependency:

```clojure
(base/sample "case-1")
```

Prelude-internal calls remain allowed. The restriction applies to
session-authored code, including values saved in the session namespace and
called later.

## Upstream Operations

Use `upstream_tools` for operation-level authority:

```json
{
  "upstream_tools": [
    "upstream:github/search_issues",
    "upstream:github/get_issue"
  ]
}
```

Prelude attach checks these grants against each export's `requires`. Direct and
dynamic `(tool/call ...)` dispatch checks the same grant again at execution
time, so prompt filtering is not the security boundary.

Use `"upstream_tools": "all"` only for operator roles. Configured roles default
to no upstream operations.

## Self-Improvement Loop

A practical improvement loop has three session types:

1. Run baseline analyst sessions.
2. Let an editor inspect evidence and write a candidate prelude version.
3. Run validator sessions against the same tasks and compare logs.

Tag every session so the log prelude can aggregate the run:

```json
{
  "role": "analyst",
  "preludes": ["audit"],
  "scoped_base_surface": true,
  "tags": { "run": "demo-17", "stage": "baseline" }
}
```

In the editor session, inspect behavior and source:

```clojure
(log/counters {:tags {"run" "demo-17" "stage" "baseline"}})
(log/turns {:tags {"run" "demo-17" "stage" "baseline"} :limit 10})
(prelude/forms "audit")
(prelude/form-deps "audit" "check")
```

Apply a small structured edit instead of rewriting full source when possible:

```clojure
(prelude/edit
  {:id "audit"
   :edits [{:op "replace_form"
            :name "check"
            :source "(defn check [case-id] (base/sample case-id))"}]
   :metadata {:reason "tighten audit helper"}})
```

Then run validator sessions with candidate refs and compare:

```clojure
(log/counters {:tags {"run" "demo-17" "stage" "validator"}})
```

Promote a new default only when task output stays correct and measured costs
improve. Treat recorded logs as evidence, not instructions.

## Admin HTTP Export

The HTTP admin interface is useful for operator backup and deployment
handoff. It is separate from MCP tools, role policy, and model-facing
sessions.

Start HTTP mode with an admin token:

```bash
ptc_runner_mcp start \
  --http \
  --sessions \
  --prelude-store-seed ./priv/preludes \
  --http-admin-token "$PTC_ADMIN_TOKEN"
```

Fetch a live retained-state snapshot:

```bash
curl -H "Authorization: Bearer $PTC_ADMIN_TOKEN" \
  http://127.0.0.1:7332/admin/prelude-store/snapshot \
  > prelude-store.snapshot.json
```

Fetch a seed-compatible export:

```bash
curl -H "Authorization: Bearer $PTC_ADMIN_TOKEN" \
  http://127.0.0.1:7332/admin/prelude-store/export \
  > prelude-store.export.json
```

Use `snapshot` when you need exact retained versions and default pointers. Use
`export` when you want a deployable seed bundle of current prelude sources and
`.deps` sidecars. Export returns `409` when a current prelude pins a non-current
dependency; take a snapshot in that case.

## Production Defaults

- Enable `strict_transitive_calls` for normal roles.
- Enable `scoped_base_surface` for model-facing sessions.
- Keep only core entry points `:prompt`; mark rare helpers `:discoverable` and
  implementation helpers `defn-`.
- Grant exact prelude refs instead of broad store access.
- Grant exact `upstream:<server>/<tool>` ids instead of `"all"`.
- Keep editor roles separate from analyst and validator roles.
- Use the HTTP admin endpoints only for operator snapshot/export workflows, not
  as model-facing write paths.
- Use role-token HTTP auth when sessions are reachable over HTTP.
- Record turn logs for improvement loops, but keep raw payload tracing disabled
  unless debugging a specific reproduction.

## See Also

- [Capability Preludes](capability-prelude.md) - Authoring, visibility,
  `requires`, and `requires_preludes`.
- [MCP Getting Started](mcp-getting-started.md) - Raw MCP session calls.
- [MCP server configuration](../mcp-server-configuration.md) - CLI and env
  options for sessions, roles, auth, and turn logs.
- [MCP HTTP deployment](../mcp-server-http-deployment.md) - HTTP mode and
  prelude-store admin endpoints.
- [SubAgent Observability](subagent-observability.md) - Turn logs and the
  `log/` prelude.
