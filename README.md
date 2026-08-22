# PtcRunner

**Build AI agents that are bounded in what they can do, easy to change,
observable in operation, and designed to improve from evidence.**

- **A language for agents** — small, typed, and limited to the tools you
  approved, discovered in a REPL rather than listed in the prompt.
- **A runtime for agent services** — built for bounded, traceable jobs and many
  concurrent requests, without a desktop, workspace, or container for every
  agent.

## Why not a coding agent?

An agent's results come from the model *and* the harness around it, in roughly
equal measure. The best harnesses anyone ships today are coding agents, so that
is what non-coding work gets run on, whether or not it fits.

Capability is not what decides it. How does it run behind your own interface,
inside a service you already have? What happens when a thousand requests arrive
at once, and what stops any one of them spending an hour, or a gigabyte? What do
you show someone who asks, three weeks later, why it did that?

Here those are properties of the runtime, not a project: ceilings on time,
memory, and tool calls enforced by the VM, a structured trace from every run,
and thousands of runs on one machine. You call it from your own code, or run it
as a command and read back JSON.

## The loop is a library, not the runtime

A system that improves itself has to be able to change itself. In most
frameworks the agent loop is host code, so changing the agent means editing
privileged code, and self-modification and privilege escalation become the same
act.

Here the loop is an ordinary library, written in the same bounded language the
model writes its own programs in. Everything about the agent is replaceable,
and replacing it does not add permissions. You can change what the agent does
without expanding what it may do.

That language is also how tools get called: the model writes one small program
instead of taking twenty turns, the part usually called code mode. Every run
leaves a structured trace. Replay holds the model fixed, so a change can be
measured against its baseline instead of guessed at. A candidate arrives with
evidence, and a human decides whether it ships.

One executable, with its own runtime inside. No language to install, no sandbox
to stand up.

> PtcRunner is a 0.x project under active development. Breaking changes are
> expected.

## Try it

Download the self-contained macOS arm64 archive and its checksum from [GitHub
Releases](https://github.com/andreasronge/ptc_runner/releases), then follow the
[standalone installation](docs/installation/standalone.md). Starting with the
next root release, Linux AMD64 and ARM64 users can instead use the image
described in [Docker installation](docs/installation/docker.md).

Once `ptc` is installed, create and run a project that needs no API key:

```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

This verifies the executable and creates a structured trace without contacting
a model. The same `ptc run` command drives agentic projects.

The executable documents itself: `ptc help` lists every command, and `ptc docs`
lists the language specification, references, and JSON Schemas embedded for
that exact version. Coding agents should start at `ptc docs agent-guide`.

## Documentation

Everything is published at **[ptc-runner.dev](https://ptc-runner.dev/)**:
installation routes, guides, references, and the language specification.

## In this repository

Changing PtcRunner itself starts at the
[maintainer documentation](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/README.md):
development setup, kernel architecture, host embedding, documentation
guidelines, and the repository gates.

## License

See [LICENSE](LICENSE).
