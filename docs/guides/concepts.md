# PtcRunner concepts

Use this page as a quick lookup for the names that appear in PtcRunner files,
commands, and results. You can run the Quickstart without reading it first.

## What do these names mean?

| Name | Meaning |
| --- | --- |
| Application | The code and configuration in `ptc.json`. |
| Project | A `ptc-project.json` file that remembers local paths and artifact settings. |
| Host file | A `ptc-host.json` file that installs credentials, models, tools, and outer limits. |
| Provider | A model, MCP server, replay fixture, or trace source installed under a stable name. |
| Alias | The stable provider name selected by `ptc.json`. |
| Workflow | Trusted PTC-Lisp code that coordinates the run, including model calls and agent policy. |
| Mission | The smaller environment where a model-authored program runs with selected data, components, and tools. |
| Component | One immutable PTC-Lisp module with a namespace and declared dependencies. |
| Prelude | A library of components shipped with PtcRunner, such as the replaceable `agent.core` loop. |
| Limits | Enforced ceilings for time, memory, calls, events, and result sizes. |
| Effect | A tool declaration of `read` or `write`; write tools require an explicit `allow` list. |
| Trace | The bounded operational record created by a run. It excludes prompts, responses, generated source, and tool payloads. |
| Private inspection | Optional sensitive records that may include the data excluded from a trace. |
| Command envelope | A stable JSON summary of a command's status, result or error, usage, and artifacts. |

The two main configuration files have different reach. `ptc-host.json` decides
what is available and holds credential references. `ptc.json` picks from that
installed set and can ask for less, but it cannot add credentials, endpoints,
commands, or wider limits. On a team, different people may maintain the files;
on one machine, you may maintain both.

Start with the [Quickstart](quickstart.md), then [understand the generated
project](getting-started.md). The reference pages own the complete contracts.
