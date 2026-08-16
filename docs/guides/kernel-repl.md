# Kernel REPL

`mix ptc repl` has three deliberately separate session modes:

- direct or manifest-backed workflow sessions;
- `run-analysis-v1` over immutable canonical traces; and
- `private-run-analysis-v1` over correlated canonical and private inspection
  evidence.

Successful definitions and exact `*1`, `*2`, and `*3` history persist for one
command. A failed form preserves the previously committed state. Profile and
manifest modes are mutually exclusive because they carry different authority.

Run `mix ptc help repl` for the exact switch grammar, including option
combinations and JSON Lines records.

## Use a workflow scratchpad

Start interactively, repeat expressions, load setup code, or evaluate one
script:

```console
mix ptc repl
mix ptc repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc repl -l setup.clj
mix ptc repl script.clj
mix ptc repl - < script.clj
```

A successful `return` prints its value, including when it is the final form in
a loaded setup file. The evaluator's internal return control wrapper is never
part of REPL output.

Attach the same frozen workflow bundle, input, limits, labels, event policy,
and workflow capabilities as `mix ptc run`:

```console
mix ptc repl --manifest ptc.json
mix ptc repl --manifest ptc.json --host-config ptc-host.json
mix ptc repl --manifest ptc.json -e '(workflow/helper data/input)'
mix ptc repl --project ptc-project.json -e '(workflow/helper data/input)'
```

`--project` supplies the project's application, host, and lazy environment
defaults while preserving the manifest REPL input grammar. It conflicts with
`--manifest`, `--profile`, and `--describe-profile`; an explicit
`--host-config` or `--env-file` overrides the matching project reference.

A provider-bearing manifest requires `--host-config`. The session performs the
same audited-local checks, acquires one provider session, and reuses it for
every expression. Direct and profile modes reject host configuration.

Interactive meta-commands are:

```text
:doc <name>       Show core function documentation
:find <pattern>   Search the available function surface
:help             List session commands
```

See the [PTC-Lisp specification](../ptc-lisp-specification.md) and
[function reference](../function-reference.md) for the language.

Persist canonical session events with `--trace`:

```console
mix ptc repl --trace trace.jsonl
mix ptc repl --manifest ptc.json --trace trace.jsonl
```

A private manifest requires an attached terminal and
`--private-terminal` before provider activity. It rejects scripts, stdin,
`--eval`, `--load`, JSON Lines, and detached execution; private values and
prints may reach only that authorized terminal. Private traces use the reserved
`.private.jsonl` suffix and owner-only permissions.

The session owner retains the continuation, event sink, and provider resources.
Normal close, abort, caller death, worker failure, and deadline failure converge
on bounded cleanup before final trace persistence. Elixir embedding hosts can
use the public session API described in
[Embedding PtcRunner in Elixir](embedding-in-elixir.md#drive-repl-sessions-from-one-process).

## Query public traces

Select the fixed public profile and its required resource:

```console
mix ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {})'
```

`--project` derives `traces` from the configured artifact root. The equivalent
explicit form is useful for a copied capture or a project without trace
artifacts:

```console
mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=tmp/tutorial-traces
```

The `traces` resource must be a directory containing ordinary canonical JSONL
files at its own level. Capture is immutable and one level deep. Empty capture
is refused so a mispointed directory cannot look like a real empty result. A
started session reports its admitted file and run counts.

The profile installs three navigation functions:

```clojure
(analysis/runs {"limit" 50})
(analysis/open "run-id")
(analysis/read "run-id" {"collection" "activity" "limit" 100})
```

`analysis/open` advertises every collection with its filters, order, authority,
and availability. Public sessions expose `activity`; private collections return
`evidence_unavailable` here. Pages are bounded and report `truncated`,
`omitted_count`, and an opaque `next_cursor` for explicit navigation.

One session can build an investigation incrementally:

```clojure
(def runs (analysis/runs {"limit" 50}))
(def items (get runs "items"))
(def slowest (first (sort-by #(get % "duration_ms") > items)))
(def run-id (get slowest "run_id"))
(analysis/open run-id)
(analysis/read run-id {"collection" "activity" "limit" 100})
```

Loaded files, repeated expressions, scripts, stdin, and interactive forms use
one serialized mission continuation and aggregate budget. Each source input is
bounded before evaluation. The profile contains no filesystem, network, LLM,
agent, workflow, MCP, private-inspection, or nested-evaluation authority.

Inspect its complete safe static contract without opening any resource:

```console
mix ptc repl --describe-profile run-analysis-v1
mix ptc repl --describe-profile run-analysis-v1 --format jsonl
```

The description includes fixed resources, components, namespaces,
capabilities, limits, and policies, but no paths, source, processes, callbacks,
or credentials.

## Query private inspection evidence

Interactive private analysis requires an attached terminal and explicit sink
authorization:

```console
mix ptc repl \
  --profile private-run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --resource inspection=tmp/tutorial-inspection \
  --session-trace-dir tmp/analysis-traces \
  --load analysis.clj \
  --private-terminal
```

`--load` evaluates one bounded local setup file, then opens the authorized
interactive terminal with those definitions available. `--eval`, scripts, and
stdin remain unattended input and require `--private-unattended` instead.

The trace, inspection, and analysis-trace directories must be physically
separate, including through ancestors and symlink aliases. Capture validates
every private artifact against its canonical run. A malformed, changed,
uncorrelated, oversized, or unsupported artifact rejects the complete private
source. Use the PtcRunner build matching the artifact's reported schema when
versions differ.

Private authority adds collections to the same three operations rather than
adding smart diagnosis APIs:

```clojure
(def runs (analysis/runs {"limit" 20}))
(def run-id (get (first (get runs "items")) "run_id"))
(analysis/open run-id)
(analysis/read run-id {"collection" "turns" "limit" 20})
(analysis/read run-id {"collection" "generated_sources"
                       "prelude_call" "workspace/read"})
(analysis/read run-id {"collection" "prelude_sources"
                       "component_id" "workspace"})
(analysis/read run-id {"collection" "execution_errors"})
```

An execution error carries the workflow `evaluation_id`. Follow its exact
children without comparing collection-local sequence numbers:

```clojure
(def error (first (get (analysis/read run-id {"collection" "execution_errors"})
                       "items")))
(def workflow-evaluation-id (get error "evaluation_id"))
(analysis/read run-id {"collection" "generated_sources"
                       "parent_evaluation_id" workflow-evaluation-id})
(analysis/read run-id {"collection" "turns"
                       "parent_evaluation_id" workflow-evaluation-id})
```

`parent_evaluation_id` proves that the workflow evaluation launched the
subordinate evaluation. It does not claim that every child caused the eventual
workflow error.

When the retained evaluator ledger proves that a successful `kernel-eval`
result reached the workflow boundary unchanged, the error also provides typed
relations. Follow the supplied collection and filters rather than rebuilding
the join:

```clojure
(def relations (get error "relationships"))
(def producer
  (first (filter (fn [relation]
                   (= (get relation "rel") "direct_boundary_producer"))
                 relations)))
(analysis/read run-id
               (assoc (get producer "filters")
                      "collection" (get producer "target_collection")))
```

Relations distinguish `causation`, validated evaluation `nesting`, and static
or source-match `association`. Their state is `complete`, `incomplete`,
`ambiguous`, or `unavailable`; a relation with null filters is descriptive and
must not be followed. `analysis/open` reports the snapshot/sequence domain and
identifier paths for every collection, so canonical `activity.sequence` is
never compared with an inspection or reconstructed-turn sequence.

Results may include exact model messages, generated programs, effective
component source, capability payloads, prints, failure details, and terminal
values. `turns` reconstructs cumulative model requests once when the immutable
snapshot opens. Each item exposes one individual turn and matching generated
source; page-level evidence reports incomplete or ambiguous reconstruction
without guessing. The repeated system prompt is omitted from turns and remains
available in the raw `model_exchanges` collection.

For one complete conversation, use the simpler one-shot command:

```console
mkdir -p tmp/tutorial-transcript
mix ptc transcript RUN_ID \
  --traces tmp/tutorial-traces \
  --inspection tmp/tutorial-inspection \
  --private-unattended \
  --private-output tmp/tutorial-transcript/conversation.private.json
```

The destination is reserved at owner-only mode before capture. Incomplete or
ambiguous evidence fails without publication. The trace, inspection, and
output directories must be pairwise physically separate: none may equal or
contain another. A rejection names the two conflicting switches and how they
overlap, without disclosing any path:

```text
directories for --traces and --inspection must be physically separate;
--traces contains --inspection
```

### Private analysis without a terminal

`--private-unattended` authorizes the command's own streams as the private
sink. It admits expressions, setup files, scripts, stdin, and JSON Lines and is
mutually exclusive with `--private-terminal`:

```console
MIX_QUIET=1 mix ptc repl \
  --profile private-run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --resource inspection=tmp/tutorial-inspection \
  --session-trace-dir tmp/analysis-traces \
  --private-unattended \
  --format jsonl \
  -e '(analysis/read "run-id" {"collection" "turns" "limit" 100})' \
  >tmp/private-analysis.jsonl
```

Use `MIX_QUIET=1` in a checkout so Mix build progress does not share stdout.
The packaged command has no Mix build stream.

Both private switches are accident guards, not access control. A same-UID
caller can read the source artifacts, and a pseudo-terminal can satisfy the
terminal check. Unattended output may enter shell logs, coding-agent
transcripts, or provider logs. Authorize every downstream sink for the same
private data.

Private evaluation diagnostics never forward arbitrary evaluator text that
could quote captured evidence. Safe diagnostics may rebuild names found
verbatim in the operator's submitted source; otherwise the message is visibly
redacted while the fault kind, continuation effect, and usage remain exact.

## Keep analysis traces separate

Profile sessions write a separate safe canonical trace, never into their input
tree:

```console
mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --session-trace-dir tmp/analysis-traces \
  -e '(analysis/open "run-id")'
```

Without `--session-trace-dir`, PtcRunner creates a private temporary directory
and reports the final trace path on close. The file is atomically published and
contains safe profile identity, hashes, sizes, timing, outcomes, and usage. It
does not contain evaluated source, exact query payloads, private values, prints,
or REPL history.

The output directory cannot equal, contain, or be contained by a resource
directory or by the parent of `--output`/`--private-output`, including through
physical aliases. A rejection names the first conflicting pair by the option or
resource that supplied each directory, and the physical relationship between
them:

```text
directories for --resource traces and --session-trace-dir must be physically
separate; --resource traces contains --session-trace-dir
```

Two spellings that reach one directory through a symbolic link report that they
`resolve to the same physical directory`. Without `--session-trace-dir` the
conflicting role is `the auto-created session trace directory`. Diagnostics
never disclose supplied paths, resolved paths, or symlink targets.

## Use JSON Lines in automation

Profile JSON Lines mode is non-interactive:

```console
MIX_QUIET=1 mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --session-trace-dir tmp/analysis-traces \
  --format jsonl \
  -e '(def runs (analysis/runs {}))' \
  -e '(count (get runs "items"))'
```

When their lifecycle stages are reached, records appear in this order:

1. one `session-started` after construction;
2. one `evaluation` per accepted source;
3. one `session-closed` after successful close and trace publication;
4. a final `command-error` when the command is unsuccessful.

Validation or setup can therefore emit only `command-error`; persistence
failure follows earlier records without claiming `session-closed`. Records use
schema version 1. Evaluation records contain the bounded mission result and no
extra raw-source copy.

A `command-error` rejecting a physical-separation conflict adds a
`directory_conflict` object beside the existing `category` and `message`, so
automation does not parse prose:

```json
{
  "schema_version": 1,
  "type": "command-error",
  "category": "cli",
  "message": "directories for --resource traces and --session-trace-dir must be physically separate; --resource traces contains --session-trace-dir",
  "directory_conflict": {
    "left_role": "resource.traces",
    "right_role": "session_trace",
    "relation": "left_contains_right"
  }
}
```

Roles are `resource.NAME`, `session_trace`, `session_trace_auto`, `output`, and
`private_output`. `relation` is `same`, `left_contains_right`, or
`right_contains_left`; `same` covers both an identical directory and distinct
spellings that reach one directory through a symbolic link. The object carries
no path.

By default, one failed expression stops later ones. Continue requested
expressions while preserving the final nonzero status with:

```console
MIX_QUIET=1 mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --format jsonl \
  --continue-on-error \
  -e '(def runs (analysis/runs {}))' \
  -e 'missing-name' \
  -e '(count (get runs "items"))'
```

`--output` and `--private-output` may atomically publish the value of exactly
one non-interactive public or private profile evaluation. They do not replace
existing files.

## Next steps

- [Running and debugging](running-and-debugging.md) covers run artifacts and
  the Viewer.
- [Manifests and capabilities](manifests-and-capabilities.md) covers attached
  manifests and snapshot providers.
- [Components and preludes](components-and-preludes.md) explains the profile's
  bundled analysis components.
- [Embedding in Elixir](embedding-in-elixir.md) covers programmatic session
  ownership.
