# Filesystem MCP sample server

**Non-production sample.** It exists so PtcRunner tutorials and integration
tests have a deterministic MCP server in another language, demonstrating that a
new capability arrives through host configuration rather than Elixir. Do not
deploy it.

## What it does

Streams one host-supplied root into an immutable private disk snapshot at
startup, then answers five read-only tools from that snapshot. File contents
are not retained or capped in the Node heap. The source filesystem is never
read again, so later changes cannot alter a result.

| Tool | Returns |
| --- | --- |
| `list_directory` | Sorted, paginated entries directly under a relative prefix |
| `search_files` | Sorted, paginated paths containing a literal substring |
| `search_text` | Paginated literal matches with path and line evidence |
| `read_text_file` | Paginated exact UTF-8 byte chunks |
| `snapshot_info` | Content hash and inventory statistics, never the host root |

All four data tools accept optional `cursor` and `limit` arguments and return
exactly `snapshot_hash`, `items`, and `next_cursor`. Start without a cursor and
follow the opaque `next_cursor` until it is null. Cursors are bound to the
snapshot, tool, and query/path arguments; replay in another traversal fails.
For `read_text_file`, concatenating item `text` reconstructs the file exactly.
Every page carries the same `snapshot_hash`, so a citation binds to the bytes
actually queried.

## Why it freezes

Serving live bytes is what a filesystem server normally does, and PtcRunner
never requires otherwise. This sample freezes for three reasons of its own:

- **Repeatability.** Tutorials and integration tests run against it. A server
  reading the live working tree would make their results depend on whatever the
  tree happened to contain at the time.
- **A hashable set of bytes.** A digest can only cover a bounded capture, never
  "the filesystem". Freezing is what makes a content identity possible, not a
  consequence of having one.
- **Bounded runtime memory.** Startup and queries use fixed-size buffers; file
  size consumes private temporary disk rather than Node or BEAM heap.

## Publishing the content identity

A host installation may publish this server's digest by adding
`snapshot_identity`, naming the tool that reports it and the field that carries
it:

```json
"snapshot_identity": {"tool": "snapshot_info", "field": "snapshot_hash"}
```

PtcRunner then calls `snapshot_info` once during provider assembly and publishes
the value as `content_snapshot_hash` in the safe provider snapshot. Two things
consume it. Snapshot-backed capability results carry it, so a citation stays
bound to the exact bytes queried. And an evaluation harness can require it to
match before treating two runs as comparable. Install the field when a run's
conclusions will be cited or compared against another run, and omit it
otherwise.

[Host configuration](../../../docs/guides/host-configuration.md#mcp-servers) is
the full reference.

## Running

```console
node dist/server.js --root ./workspace --include 'lib/**' --include 'docs/**' --exclude '**/secrets/**'
```

`--include` is mandatory and repeatable; the default is **no files**, so a
server started without it exposes nothing. `--exclude` may only narrow what the
includes selected. Excluded paths are skipped before any stat or open, so they
are never inventoried. Optional `--max-file-bytes` and `--max-total-bytes`
positive-integer limits can reduce the capture budget for a deployment.

## Confinement

- Relative paths only. Absolute paths, `.`/`..` segments, NUL bytes, and
  Windows separators are rejected rather than resolved.
- Symbolic links are skipped, not followed, so a link inside the root cannot
  reach bytes outside it.
- Non-regular files and files that are not valid UTF-8 are not captured.
- File count, directory depth, visited directories, and visited entries are
  bounded at startup. Exceeding a bound fails instead of publishing a partial
  snapshot. File bytes are streamed to private temporary disk. By default the
  byte ceiling is the available temporary-volume capacity minus a 64 MiB safety
  reserve; the command-line limits above can lower it. There is no fixed 1 MiB
  per-file ceiling.
- Results are fitted against the full decoded MCP result, and text search also
  has a scan-byte budget. An empty search page can therefore carry a progress
  cursor when a sparse file requires more scanning.
- Errors are short actionable text — no stacktraces, no host paths.
- Nothing is written, no subprocess or network is used, and no Roots, Sampling,
  Logging, MRTR, or Tasks capability is advertised.
- stdout carries protocol messages only; diagnostics go to stderr.

The selected root must be trusted and quiescent while startup capture runs.
Portable Node path APIs cannot descriptor-confine every ancestor against a
privileged actor swapping directories during that short window. The server
rejects observed symlinks and uses a no-follow final open where supported; it
does not claim to defend an actively hostile source root. Graceful close and
catchable signals remove the temporary snapshot. `SIGKILL`, native crash, or
power loss can leave an operating-system temporary-directory orphan.

## Building and testing

```console
npm install      # maintainers only; the tutorial runs the committed bundle
npm run build    # regenerates dist/server.js
npm run typecheck
npm test
```

`dist/server.js` is committed so a clean checkout or a release-installed
tutorial can run the server without installing or downloading anything. CI
regenerates the bundle and fails on a diff.

## Licensing

The sample's own source is MIT, matching the repository. `dist/server.js` is a
bundle that inlines its dependencies, so `NOTICE` reproduces their upstream
license texts and travels with the artifact. `REUSE.toml` annotates the bundle
as a combined work.

## Dependency pin

`@modelcontextprotocol/server` is pinned to an exact version, and the lockfile
is committed. The capability platform plan requires the official TypeScript SDK
v2 after a stable release supporting `2026-07-28`, and permits a pinned beta
only on an experimental branch until then. No stable release exists yet, so
this pins `2.0.0-beta.5`. Re-pin when the stable release lands.
