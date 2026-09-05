# Project-configuration reference

This is the complete local path, artifact, override, and Viewer-preference
contract.

Use one explicitly named `ptc-project.json` to remember stable local paths and
development preferences:

```console
ptc run ptc-project.json
ptc doctor ptc-project.json
ptc doctor ptc-project.json --connect
ptc repl --project ptc-project.json
ptc repl --project ptc-project.json --mission review
ptc viewer ptc-project.json
```

`ptc init DIRECTORY` generates this file alongside `ptc.json`, `main.clj`, and
an `AGENTS.md` routing card for coding agents. PtcRunner never searches parent
directories or guesses a project from its filename; the `"kind": "ptc-project"`
discriminator identifies the document.

The kernel tutorial ships one project document per runnable example. A
credential-free run and its Viewer need only the same JSON path:

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc run kernel-tutorial/01-orders.ptc-project.json
ptc viewer kernel-tutorial/01-orders.ptc-project.json
```

Provider-backed Examples 02 through 04 additionally reference the shared host
document and `kernel-tutorial/.env` from their project files. Example 06 uses a
dedicated host document so its deliberate cost ceiling cannot affect the
successful examples. After creating the explicitly named environment file,
their run commands have the same single-argument shape:

```console
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

## Keep the three files separate

| File | What it holds |
| --- | --- |
| `ptc.json` | workflow, components, input, provider selections, and narrower limits |
| `ptc-host.json` | installed providers, credential references, commands, endpoints, and outer limits |
| `ptc-project.json` | paths to those files, local artifact policy, and Viewer preferences |

Credential values and provider declarations do not belong in the project
file. Project choices do not become part of application content identity.

## Document shape

```json
{
  "$schema": "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
  "kind": "ptc-project",
  "version": 1,
  "application": {"path": "ptc.json"},
  "host": {
    "path": "ptc-host.json",
    "env_file": {"path": ".env"}
  },
  "artifacts": {
    "root": ".ptc",
    "trace": true,
    "inspection": false,
    "result": false,
    "envelope": true
  },
  "viewer": {
    "port": 0,
    "open": true,
    "repl": true,
    "private": false
  }
}
```

`kind`, `version`, and `application` are required. `host`, `artifacts`, and
`viewer` are optional. A document that declares `"kind": "ptc-project"` and
then fails this schema reports `project/project_schema_invalid`. The diagnostic
names a bounded schema rule and the deepest project-schema-authorized JSON
Pointer; it does not retain the rejected value, an unknown property name, or
the filesystem path. If bounded schema validation times out or exceeds its
resource bound, the retryable `project/schema_validation_unavailable`
diagnostic reports the unavailable validation instead of claiming that the
document is invalid. A syntactically valid `run`, `validate`, `doctor`, or
`models` invocation still publishes a requested `--envelope` before any project
reference or provider is opened. Malformed command syntax remains an argument
rejection and publishes no envelope.

Every object rejects unknown and duplicate keys. Paths are portable relative
paths resolved beneath the project document's directory; absolute paths and
`..` traversal are rejected. The generated schema is served as `ptc docs schema-project`
([`priv/schemas/ptc-project-config.schema.json`](https://github.com/andreasronge/ptc_runner/blob/main/priv/schemas/ptc-project-config.schema.json)
in the repository).

Inspection requires traces because private records must correlate with a
matching run. `viewer.private` is a separate explicit local grant: creating a
private artifact does not automatically expose it to Viewer. `viewer.repl`
independently enables the browser REPL, including when `viewer.private` is
`true`. REPL evaluations remain fixed to the public `run-analysis-v1` profile
and its immutable normal-trace snapshot; they cannot query the private evidence
displayed elsewhere in the Viewer.

## Artifact layout

For `run`, enabled project artifacts derive from the command run reference:

```text
.ptc/traces/<run-ref>.jsonl
.ptc/traces/<run-ref>.private.jsonl
.ptc/inspection/<run-ref>.ptcins
.ptc/results/<run-ref>.json
.ptc/results/<run-ref>.private.json
.ptc/envelopes/<run-ref>.json
```

The root and its fixed child directories are owner-only. The first project run
creates the complete layout atomically; an existing incomplete, permissive, or
symlinked layout is refused. When a pre-existing directory fails the owner-only
(0700) check, a run that publishes an envelope names the path and the
`chmod 700` remedy rather than reporting a bare publication failure; the
conditions for that are in the table below. Artifact files retain the normal
no-replace and privacy rules.

The run creates the root and its four children, and nothing above them. A
directory above the root is yours, so its mode and ownership are not the
command's to choose; `artifacts.root` may name a path several levels deep, but
every level above the root must already exist.

Ancestors are held to a weaker rule than the root itself: each one must be
owned by you or by root, and must not be writable by group or other unless it
carries the sticky bit. A sticky world-writable directory such as `/tmp` is
therefore accepted, while an ordinary `0775` directory is not. The root and its
four children remain owner-only (0700).

The refusals below name the directory that earned them; anything else falls
back to the generic publication failure:

| Cause | Reported as | Remedy |
| --- | --- | --- |
| an ancestor of the root does not exist | `envelope/destination_parent_unavailable` | `mkdir -p` the root's parent, or point `artifacts.root` at an existing directory |
| an ancestor is group- or world-writable and not sticky | `envelope/destination_parent_unsafe` | `chmod go-w PATH` |
| an ancestor is owned by another user | `envelope/destination_parent_unsafe` | point `artifacts.root` under a directory you own |
| the root or a child exists at a wider mode | `envelope/publication_failed` | `chmod 700 PATH` |
| the root exists without its four children | `envelope/publication_failed` | remove the root and let `ptc` recreate it |
| any other refusal, such as a parent you own but cannot write to | `envelope/publication_failed` | make the parent writable, or point `artifacts.root` elsewhere |

The missing-ancestor message names the shallowest missing directory and offers
`mkdir -p` on the resolved parent, so one command creates every level rather
than only the first. Where a symlink stands in the ancestry the two differ: the
message names the link's target, because creating the link's own name would
fail on a path that already exists.

Every path is printed quoted and escaped, since a symlink target is filesystem
content rather than something you typed, and a suggested command is offered
only when its path holds no control characters. These arrive on stderr with
exit 74, because the envelope that would normally carry a diagnostic is the
artifact that could not be written.

That last-resort channel is what carries the directory name, so the table above
describes a run that publishes an envelope — the `ptc init` default, and any
run given `--envelope`. With `artifacts.envelope` set to `false` the same
refusals still stop the run before it executes, reported through the ordinary
destination phase as `destination/invalid_destination` at exit 7 without the
path. `ptc viewer` reports the named sentences as
`viewer/artifact_root_unusable`.

The trace filenames are also the canonical directory-discovery contract. Each
file contains exactly the run ID named by its stem and one trace identity;
arbitrary aggregate filenames and split histories remain supported only when a
caller explicitly selects one file, not when Viewer or run analysis discovers a
directory. Stable damaged components are isolated without hiding unrelated
valid runs.

## Overrides and lazy environment loading

An explicit command value wins over the corresponding project default for host,
environment, and trace/inspection/result destinations:

```console
ptc run ptc-project.json --host-config deployment/staging-host.json
ptc run ptc-project.json --trace-dir tmp/one-off-traces
ptc repl --project ptc-project.json --env-file deployment/staging.env
ptc repl --project ptc-project.json --mission review
ptc viewer ptc-project.json --env-file deployment/staging.env
```

`--envelope FILE` is different: it adds a convenience copy for the invocation
and does **not** suppress the project ledger under `.ptc/envelopes/` when
`artifacts.envelope` is enabled. Trace, inspection, and result overrides still
replace their project defaults.

Mission selection, input, and component-override switches remain
invocation-only. Mission names stay in the application manifest rather than
being duplicated as project defaults. An environment file explicitly selected
by the project or `--env-file` is loaded only when inert preparation proves that
a selected mission provider or its dependency uses an environment-backed
credential. Unrelated providers do not cause environment-backed credentials to
be read. Runs without providers, passive doctor, Viewer startup, and file- or
literal-backed credentials do not read it.
Viewer-started workflows and missions read the selected file lazily through
their ordinary command preparation. When the file is loaded, assigned keys
override process values, including with empty values, while omitted keys retain
their process values.

Direct manifest invocation remains the low-level form for automation:

```console
ptc run ptc.json \
  --host-config ptc-host.json \
  --trace-dir build/traces \
  --envelope build/command.json
```

## Viewer

`ptc viewer ptc-project.json` uses the project's trace root, port,
browser-opening preference, REPL setting, and private-data authorization. Trace
and correlated inspection directories are captured before the listener starts;
HTTP requests select only a run ID and never a filesystem path. Revoking
`viewer.private` takes effect on the next request and drops held private
evidence. Turning the grant on, and discovering runs that finished after
startup, require Refresh on the Runs list. Other project fields stay boot-read.
Browser opening
is a bounded convenience, and additionally requires an attached terminal:
missing or failing platform openers do not stop Viewer.

The Viewer port defaults to `0`, which asks the operating system for a free
port; startup prints the selected address before opening a browser. Set a fixed
port only when another process needs a stable address. If that port is occupied,
the command probes loopback and names the project when another PTC Viewer owns
it. The Live project header exposes the exact project
document path, so a working page cannot silently look like the project whose
startup just failed.

The REPL and private-data settings are orthogonal. Enabling both presents the
public-trace REPL alongside the private evidence panels without adding private
inspection authority to the evaluation session.

Because `artifacts.inspection` and `viewer.private` must both hold, granting the
Viewer access to an existing inspection artifact needs no re-run. The artifact
on disk is already usable once the Viewer refreshes after the grant. Revoking
the grant takes effect on the next request without Refresh. For headless access
to the same reconstructed conversation, use
`ptc repl --profile private-run-analysis-v2`; run `ptc docs repl` for the
complete invocation.

Viewer-started workflows and missions use the project's `host.env_file` when
one is declared. `ptc viewer ptc-project.json --env-file FILE` supplies an
invocation-time override instead. PtcRunner never searches implicitly for
`.env`; without either form, credentials must already be present in the Viewer
process environment or use another trusted host binding.

The listener binds `127.0.0.1`. The project document deliberately cannot change
that: exposure is an invocation-time decision made with `--listen 0.0.0.0`,
where it stays visible in the command line rather than stored in a file. See
the [Viewer exposure reference](viewer.md#exposing-it).

The Viewer ships in the standalone release and container image and is absent
from the published package.
