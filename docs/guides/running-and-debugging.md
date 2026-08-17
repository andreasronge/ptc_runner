# Run and inspect a project

> **Audience:** application authors and operators running, validating, and
> inspecting PtcRunner applications through the `ptc` executable.

Create a provider-free project and run it:

```console
ptc init hello-ptc
ptc validate hello-ptc/ptc-project.json
ptc run hello-ptc/ptc-project.json
```

The result is written to standard output. The project document remembers its
artifact root, so traces and optional envelopes or results stay beside the
project rather than depending on the caller's current directory.

Before a credentialed run, check configuration without network activity:

```console
ptc doctor ptc-project.json
ptc models ptc-project.json
```

Use `--connect` only when an active provider probe is intended:

```console
ptc doctor ptc-project.json --connect
```

Browse completed runs locally:

```console
ptc viewer ptc-project.json
```

The Viewer binds to loopback by default and has no authentication. Do not expose
it to a network, especially when a project grants access to private inspection
records.

For automation, request a command envelope instead of parsing human-readable
diagnostics:

```console
ptc run ptc-project.json --envelope command-envelope.json
```

Use the [CLI reference](../reference/cli.md) for the complete command grammar,
exit statuses, envelopes, artifact publication, diagnostics, transcripts,
Viewer behavior, and process contract. Continue with [Debug a failed
run](debugging-a-failed-run.md) when a trace needs deeper investigation.
