# PtcRunner

**Build AI agents that are bounded in what they can do, easy to change,
observable in operation, and designed to improve from evidence.**

## The loop is a library, not the runtime

A system that improves itself has to be able to change itself. In most
frameworks the agent loop is host code, so changing the agent means editing
privileged code, and self-modification and privilege escalation become the same
act.

Here the loop is an ordinary library, written in the same bounded language the
model writes its own programs in. Everything about the agent is replaceable,
and nothing replaceable carries authority. You can change what the agent does
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

The public one-command installer and published container image are not available
yet. The command interface is stable enough to try today through a locally built
standalone executable or the verified local container. See
[Availability](#availability) before choosing a route.

Once `ptc` is installed, create and run a credential-free project:

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

### Run a model-authored program

The repository includes a self-contained agent example that needs one model
credential but no Python, JavaScript, or separate sandbox:

```console
git clone --depth 1 https://github.com/andreasronge/ptc_runner.git
cd ptc_runner
cp .env.example examples/kernel-tutorial/.env
chmod 600 examples/kernel-tutorial/.env
```

Add your `OPENROUTER_API_KEY` to that exact `.env` file, then run:

```console
ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

```json
{"ok":true,"value":42}
```

The example gives the shipped agent loop a task. The model writes and evaluates
a bounded program over two turns, then returns the final value. You do not need
to read or edit the generated program to use the agent.

If you prefer Docker, the repository can build and verify the current local
image before running the same project:

```console
./scripts/build_container_image.sh ptc:dev
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  ptc:dev \
  run /work/examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

Matching the container process to the host user lets it read the owner-only
credential file and write project artifacts without making either world-readable.
The image is local development scaffolding, not a published distribution image.

## The agentic workflow

```text
task + data + approved tools + limits
                  |
                  v
       model writes a small program
                  |
                  v
  PtcRunner executes it with only those capabilities
                  |
                  v
          result + structured trace
```

This approach is often called programmatic tool use or **code mode**. A mission
program can call several tools, filter or join their results, branch, and loop
inside one bounded evaluation. Intermediate data stays out of the model context
unless the program deliberately returns it.

Model-authored programs are written in PTC-Lisp. Application authors normally
select the shipped agent components and configure them; writing PTC-Lisp
yourself is an advanced option, not an onboarding requirement.

## Will the model write it?

Yes, and it is not a new language to learn. PTC-Lisp is a bounded Clojure with
type signatures, checked on the way in and on the way out.

The job is also narrower than writing an application: short programs, one turn
at a time in a REPL-style loop, against typed signatures. Narrow it that way
and the ranking of languages changes.

Models handle niche languages better than their share of the training data
suggests. PtcRunner itself is a large codebase, written mostly by models over
half a year, in a language well outside the popular ones.

The tutorials here run on a small, cheap model by default. Point it at your own
tasks and measure.

## Constrain

Bounded means there is no way out of the language. No `import`, no `open`, no
`fetch`, no shell. A program can use what you passed in and the tools you
approved, and nothing else. A sandbox works the other way round: it starts with
a language that can do anything and takes the dangerous parts away one by one.
Miss one and you have a breach. Here there is nothing to miss.

Generated mission code has no ambient access to the filesystem, network,
processes, a shell, package installation, or a general-purpose host language.
It can create an external effect only through a capability that the operator
installed and the application selected for that mission.

That distinction is important: if you explicitly grant a filesystem or network
tool, the tool can perform its declared effect. The mission still receives no
broader access than the granted interface.

The runtime enforces deadlines, memory, tool-call counts, result sizes, and
event budgets. Application configuration may select installed capabilities and
narrow their limits, but cannot add credentials, endpoints, commands, or raise
an operator ceiling.

Containers remain useful for deployment and defense in depth. PtcRunner does
not depend on a container to make an unrestricted language safe; the language,
capability grant, and enforced limits form the primary boundary.

## Compose

The shipped agent loop is a useful default library, not behavior hard-coded
into the runtime. Most applications configure that loop. When the application
needs something different, you can replace:

- system, task, and correction prompts;
- retry, continuation, and completion policy;
- model and tool selection;
- mission data and execution limits;
- sequential, parallel, or specialist composition; or
- the complete agent loop.

The Kernel continues to enforce capability and resource boundaries while the
agent layer evolves. This separation makes PtcRunner a meta-harness: teams can
change the framework around a model without rebuilding the trusted execution
boundary.

See [Building agents](docs/guides/building-agents.md) for the shipped loop and
[Components and preludes](docs/guides/components-and-preludes.md) for deeper
customization.

## Observe

Every run produces a canonical structured trace containing outcomes, errors,
tool activity, evaluations, enforced limits, and resource usage. Prompts, model
responses, generated source, and tool payloads are sensitive, so they are kept
out of the public trace. They can be retained separately through explicit
private inspection.

Open a project's runs in the local read-only Viewer:

```console
ptc viewer PROJECT.json
```

PtcRunner can also analyze its own immutable run evidence through a bounded
analysis profile. The analysis receives a frozen evidence capture rather than
ambient access to the artifact directory:

```console
ptc repl --project PROJECT.json --profile run-analysis-v1
```

See [Running and debugging](docs/guides/running-and-debugging.md) for the normal
run-to-trace workflow and [Debug a failed run](docs/guides/debugging-a-failed-run.md)
for evidence-guided diagnosis.

## Improve

Reliable improvement needs evidence, not anecdotes. PtcRunner can:

- analyze successful and failed runs with the same bounded execution model;
- replay recorded model responses so model drift is not confused with a prompt
  or framework change;
- evaluate a hash-checked candidate prelude without installing it; and
- compare results, traces, usage, and limit behavior before promotion.

Together these are the foundation for controlled self-improvement loops. A
workflow can use prior runs to propose better prompts, policies, or preludes,
then evaluate them against frozen evidence. Promotion remains an explicit
decision rather than an automatic mutation of the running system.

Start with [Evaluate changes with replay](docs/guides/evaluating-with-replay.md).

## Availability

| Route | Status | Command |
| --- | --- | --- |
| [Standalone executable](docs/installation/standalone.md) | Buildable and verified locally | `ptc` |
| [Local container](docs/installation/docker.md) | Buildable and verified locally | `docker run ... ptc:dev` |
| Public one-command installer | Planned | `ptc` |
| Published container image | Planned | `docker run ...` |

The runtime-included standalone executable does not require a separate language
runtime on the target machine. The local container is built and tested by
`scripts/build_container_image.sh`; it is deliberately not presented as a
published image.

## Documentation

Rendered at **[ptc-runner.dev](https://ptc-runner.dev/)**; the same pages
as Markdown below.

- [Installation](docs/installation/standalone.md) — current standalone, Docker,
  and source routes with their exact availability.
- [Quickstart](docs/guides/quickstart.md) — configure a model and run the first
  model-authored program.
- [Building agents](docs/guides/building-agents.md) — configure or replace the
  shipped agent loop.
- [Connecting tools with MCP](docs/guides/connecting-tools-with-mcp.md) — grant
  narrowly mapped external tools.
- [Running and debugging](docs/guides/running-and-debugging.md) — inspect
  results, traces, diagnostics, and private evidence.
- [PTC-Lisp specification](docs/ptc-lisp-specification.md) — optional language
  reference for custom components and model-generated programs.
- [Maintainer setup](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/development-setup.md)
  — change the runtime itself and run its repository gates.

## License

See [LICENSE](LICENSE).
