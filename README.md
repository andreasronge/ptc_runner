# PtcRunner

**Build AI agents that are bounded in what they can do, easy to change,
observable in operation, and designed to improve from evidence.**

- **A language for agents** — small, typed, and limited to the tools you
  approved, discovered in a REPL rather than listed in the prompt.
- **A runtime for agent services** — built for bounded, traceable jobs and many
  concurrent requests, without a desktop, workspace, or container for every
  agent.

> PtcRunner is a 0.x project under active development. Breaking changes are
> expected.

## Try it

Install `ptc` from the [standalone
archive](https://ptc-runner.dev/installation/standalone/) for macOS arm64, or
the [container image](https://ptc-runner.dev/installation/docker/) for Linux
AMD64 and ARM64.

```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

That runs without an API key and leaves a structured trace. From there `ptc
help` lists every command, and `ptc docs` lists the specification and references.

`ptc init kernel-tutorial --example kernel-tutorial` materializes the first of
the [runnable examples](https://ptc-runner.dev/reference/examples/).

## Documentation

See  **[ptc-runner.dev](https://ptc-runner.dev/)**:
installation routes, guides, references, and the language specification.

## In this repository

See [maintainer documentation](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/README.md)

## License

See [LICENSE](LICENSE).
