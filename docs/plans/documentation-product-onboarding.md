# Product documentation and onboarding redesign

## Status

Active implementation plan. Remove this file after the approved slices land and
their durable contracts have moved into the documentation guidelines, retained
references, schemas, module documentation, and executable examples.

This branch implements the layer-owned paths, reference extraction, README and
guide rewrite, package usage rules, terminology policy, and focused
documentation checks. As approved for the imminent release, the documentation
assumes a verified macOS arm64 archive is available from GitHub Releases. The
published container image and generated first-agent scaffold remain
distribution/product prerequisites and are not presented as available.

## Objective

Make the root README and published documentation present PtcRunner as a secure,
replaceable, observable agent harness with the foundations for controlled
improvement from run evidence.

The ordinary user path starts with a one-command standalone installation or a
published container image, creates and runs a useful agent without installing
Python, Node.js, a language toolchain, or a separate sandbox, and does not ask
the user to write PTC-Lisp. The model writes the bounded mission program; you
normally configure the task, model, approved tools, data, limits, and shipped
agent components.

User guides remain short and task-oriented. Exhaustive commands, fields,
schemas, options, error taxonomies, state machines, and security contracts live
in retained reference pages. Repository and implementation material lives under
an explicitly maintainer-owned path.

## Current problem

The implemented behavior is documented, but the layers and primary journey are
blurred:

- the README opens with a source-checkout command path and spends more space on
  architecture and repository development than on running a useful agent;
- `docs/guides/` mixes end-user workflows with maintainer procedures;
- several guides have become exhaustive reference documents, including the
  command, REPL, host-configuration, and failed-run pages;
- public prose exposes implementation-language concepts even where the public
  contract is JSON, PTC-Lisp, a process command, or an immutable artifact;
- model-selection guidance is mixed with adapter and source maintenance
  concerns;
- the standalone artifact and local container scaffold exist, but the
  one-command installer and published container route required by the desired
  README journey are not complete public installation paths; and
- the shipped package does not yet provide its own concise `usage-rules.md` for
  coding models integrating the public package API.

The latest documentation additions are useful evidence of implemented
behavior. This plan relocates and edits that content; it does not discard it.

## Documentation ownership contract

Use the files and documentation layers readers actually encounter instead of
inventing reader categories:

| Surface | Owns | Documentation home |
| --- | --- | --- |
| `ptc.json` | Tasks, input, agent selection, prompts, components, and narrower limits | `docs/guides/` and `docs/reference/` |
| `ptc-host.json` | Installed models and tools, credentials, outer policy, and deployment settings | `docs/installation/`, `docs/guides/`, and `docs/reference/` |
| PTC-Lisp | Optional custom components, preludes, and complete agent loops | Language and component references |
| Published package API | Host integration | API documentation and the distributed `usage-rules.md` |
| Repository checkout | Runtime implementation, architecture, gates, conformance work, and releases | `docs/maintainers/` and `AGENTS.md` |
| A running model | The frozen prompt, mission inventory, signatures, and capability descriptions assembled for one run | Shipped or application-selected components, not repository documentation |

Every hand-written guide and installation page starts with a short outcome
summary. Reference pages start with a scope statement. Generated references
identify their owning catalog or schema instead.

## Documentation structure

The target structure is:

```text
README.md
docs/
  installation/
    standalone.md
    docker.md
    source.md
  guides/
    quickstart.md
    first-agent.md
    connecting-tools.md
    customizing-agents.md
    inspecting-runs.md
    debugging-failures.md
    evaluating-improvements.md
    using-models.md
  reference/
    cli.md
    application-manifest.md
    host-installation.md
    project-files.md
    models.md
    mcp.md
    agent-library.md
    component-contracts.md
    repl.md
    viewer.md
    diagnostics.md
    artifacts-and-envelopes.md
    traces-and-inspection.md
    replay-and-candidates.md
    limits.md
    ptc-lisp/
  maintainers/
    README.md
    development-setup.md
    releasing.md
    kernel.md
    embedding.md
    documentation.md
    coding-agent-review.md
    duplication-gate.md
    conformance/
  plans/
usage-rules.md
AGENTS.md
```

The final filenames may reuse current stable names where doing so keeps a
generated owner or a normative specification clearer. The directory and
content boundaries are the contract; the illustrative filenames are not a
reason to duplicate an existing retained reference.

## Public terminology

The README, end-user guides, and public runtime references describe the product
through its executable, JSON documents, PTC-Lisp boundary, capabilities,
limits, and artifacts. They do not explain behavior through the implementation
language.

Implementation-language discussion is allowed only in:

- installation material where a source build or package installation genuinely
  requires it;
- `docs/maintainers/`;
- API and module documentation;
- the distributed `usage-rules.md` for package integrators; and
- source code and tests.

Rewrite public terms such as "Elixir boundary" or a host struct name as the
actual public contract: JSON boundary, host value, UTC timestamp, command
envelope, capability, or another implementation-neutral term. Split the
current signature and language pages where public behavior and host API
projection are interleaved.

PTC-Lisp is introduced only after the first user journey establishes that the
model normally writes it. The README calls it a small purpose-built language
for bounded data processing and tool calling. Its Clojure compatibility target
belongs in the language reference, not the product opening.

## Slice 0: finish the journey that the README will promise

Do not publish aspirational installation commands as current behavior. Complete
or explicitly gate the following product work before the README uses it as the
default path.

### One-command standalone installation

- Define the stable installation command and download origin.
- Select the asset by supported operating system and architecture.
- Verify the adjacent checksum before installing the executable.
- Preserve the release documentation's exact signing and notarization claims.
- Fail clearly for unsupported targets; do not fall back to a source build.
- Document the installed path, upgrades, version pinning, and removal.
- Exercise the documented command from a clean supported runner in CI.

The installer is a distribution surface and must be reviewed with the same
care as the packaged artifact. This plan consumes, rather than redefines, the
artifact and provenance contract retained in the standalone distribution plan
and release documentation.

### Published container image

- Publish the verified runtime image to the chosen registry and target matrix.
- Define immutable version tags and the policy for any moving convenience tag.
- Verify the standalone command inside the final runtime image.
- Run the exact README `docker run` commands in CI.
- Keep volume, credential, user, result, trace, and Viewer exposure behavior
  explicit in the Docker installation reference.

Until publication is complete, documentation may show how maintainers build
the local `ptc:dev` image but must not present it as an end-user installation.

### Self-contained first-agent scaffold

Add or approve an equivalent to:

```console
ptc init --agent DIRECTORY
ptc run DIRECTORY/ptc-project.json
```

The scaffold:

- uses the shipped agent library rather than asking the user to author a loop;
- includes a small task and bounded structured input that demonstrate a model
  generating and evaluating a mission program;
- needs no external MCP process and therefore no Python, Node.js, or additional
  runtime for the first run;
- records a trace and a command envelope under the project artifact
  root;
- keeps private inspection disabled by default and explains how to opt in;
- names the one credential or model choice the user must supply; and
- is covered by deterministic command tests plus a scheduled real-model probe.

The generated project may contain PTC-Lisp components, but the README does not
display or require the user to edit them. Later documentation explains how to
inspect or replace those components.

## Slice 1: establish purpose-owned paths

Perform the path migration before rewriting prose so links and ExDoc groups
have one stable destination.

Move maintainer material out of `docs/guides/`, including:

- the Kernel maintainer guide;
- coding-agent review workflow;
- duplication gate;
- documentation guidelines;
- development setup;
- release procedure;
- embedding and host-API guidance;
- conformance review program; and
- conformance classification log.

Keep generated conformance dashboards and audits in their public retained
reference area. Rewrite isolated implementation-language descriptions in those
public reports without moving the complete reports into maintenance docs.

Update in the same slice:

- every repository link and script diagnostic naming a moved page;
- ExDoc extras, navigation groups, and assets;
- the package file list;
- executable-guide and doctest registries;
- `AGENTS.md` links;
- documentation tests; and
- generated-document owners whose output path changes.

Do not leave compatibility copies of moved pages. This is a 0.x project and
the repository policy prefers deletion over documentation shims.

## Slice 2: extract reference contracts from guides

Each guide retains one task and links to the owning reference for exhaustive
detail.

| Current topic | Guide retains | Reference owns |
| --- | --- | --- |
| Running and debugging | Run, inspect, and diagnose one project | Complete commands, switches, exits, envelopes, artifact publication, diagnostics, and Viewer options |
| Kernel REPL | Explore one workflow or mission interactively | Session modes, selectors, profiles, previews, scripts, private authority, and cleanup |
| Application manifests | Configure one application safely | Complete fields, semantic validation, environment assembly, and schemas |
| Host configuration | Install one model and one MCP provider | Credentials, sources, transports, mappings, ceilings, OAuth, and error outcomes |
| Project configuration | Remember stable local paths | Complete project document, artifacts, Viewer preferences, and precedence |
| Building agents | Move from a task to the shipped bounded agent | Loop options, missions, retries, continuation, concurrency, feedback, and turn protocol |
| Connecting tools | Grant one narrowly mapped MCP tool | Protocol, transports, authentication, effects, mapping, lifecycle, and diagnostics |
| Failed-run analysis | Follow one failure from a trace | Collections, typed links, resources, schemas, pagination, and private inspection |
| Replay evaluation | Compare one baseline and candidate | Replay fixtures, request identities, candidate descriptors, digests, and promotion gates |
| Components and preludes | Decide when and how to customize | Component schema, namespaces, dependencies, signatures, visibility, and authority |

Reference pages are exhaustive and noun-oriented. Guides are outcome-oriented.
Do not copy a field table, option inventory, limit catalog, or state machine
between them.

Prefer generation from the owning schema, declaration, or catalog. Extend the
existing generators rather than hand-maintaining a second inventory. Generated
pages continue to carry a visible owner and edit warning.

## Slice 3: rewrite the root README

Keep the README approximately 150–220 lines and make the first screen about the
product outcome, not the implementation or repository checkout.

### Opening

Use an outcome-led promise equivalent to:

> Build AI agents that are bounded in what they can do, easy to change,
> observable in operation, and designed to improve from evidence.

Follow it with the missing-middle problem statement:

- tool-by-tool agents pay a model round trip and context cost for every step;
- full coding agents use a general-purpose language and need a strong external
  sandbox for complex work; and
- PtcRunner lets the model write a small bounded program that calls several
  approved tools, processes their results, and returns only what matters.

State immediately that the user normally does not write that program. The user
provides the task, model, approved tools, data, limits, and selected agent
components; the model writes the mission program.

### Hands-on path

Show, in order:

1. the verified one-command standalone installation;
2. the model credential or explicit model choice;
3. `ptc init --agent`;
4. `ptc run` and a compact representative result; and
5. the equivalent published-container command.

Do not use `mix`, a repository checkout, PTC-Lisp source, Python, or JavaScript
in the initial walkthrough.

### Four product promises

- **Constrain** — explicit capabilities and enforced execution limits.
- **Compose** — replace prompts, loops, tools, policies, or the whole agent
  framework without changing the enforcement Kernel.
- **Observe** — structured traces plus explicit private inspection
  for sensitive model, source, and tool records.
- **Improve** — analyze run evidence, replay fixed model responses, compare
  candidate preludes, and promote deliberately.

### Security claims

Say precisely that generated mission code has no ambient filesystem, network,
process, shell, package, or host-language access. It can reach an external
effect only through a capability explicitly installed in `ptc-host.json` and
selected for the mission. A granted filesystem or network tool still performs
the granted effect; do not turn "no ambient access" into an absolute claim that
configured capabilities cannot access the operating environment.

Describe a container as a deployment option and defense in depth, not the
primary language boundary.

### Replaceability and improvement

Present the shipped agent loop as a useful replaceable library, not hard-coded
runtime behavior. Most users select and configure it. Advanced users can
replace prompts, retry and continuation policy, completion rules, specialist
composition, or the entire loop.

Say that every run produces a structured trace. Sensitive prompts,
responses, generated source, and tool payloads are retained only through
explicit private inspection. PtcRunner can analyze its own immutable evidence
and replay recorded model responses. Call these the foundations for controlled
self-improvement loops; do not claim automatic promotion while promotion
remains an explicit decision.

End with short links to installation, the first-agent guide, customization,
tool connection, run inspection, improvement evaluation, and retained
references. Keep source development behind one maintainer link.

## Slice 4: rewrite end-user guides

Use this shape for every guide:

1. a short promised outcome;
2. prerequisites;
3. one complete copy-and-paste workflow;
4. the result and how to inspect it;
5. relevant security or authority consequence;
6. links to exact reference contracts; and
7. one or two next steps.

Use a soft target of 50–150 lines. A longer walkthrough must still avoid
exhaustive option and field inventories.

The intended guide set covers:

- install and run the first agent;
- understand the generated project without requiring PTC-Lisp edits;
- select and verify a model;
- connect one MCP tool safely;
- customize the shipped agent behavior;
- inspect a successful run;
- diagnose one failed run; and
- evaluate one prompt or prelude change with replay.

Merge the useful parts of the current getting-started page into the Quickstart
and first-agent journeys rather than retaining two introductions with different
assumptions.

The model guide covers only application configuration: model alias selection,
credential binding, connectivity checks, tool-call support, cache choice,
usage evidence, and common failures. Adapter boundaries and source maintenance
belong in API or maintainer documentation.

## Slice 5: add model-facing package guidance

Create a concise root `usage-rules.md` and include it in the published package.
It serves coding models helping package integrators use the public API. It may
link to API documentation and describe implementation-language calls because
that is its explicit scope. It does not contain repository worktree, CI,
release, or internal architecture procedures.

Keep `AGENTS.md` as the canonical source-maintenance instruction file. Improve
the repository's `usage_rules` configuration so the small main rules explaining
`mix usage_rules.docs` and `mix usage_rules.search_docs` are visible rather
than hidden behind an unfetched dependency link. Keep larger language and OTP
rules linked or generate an agent skill after validating a location shared by
the supported coding agents.

Do not confuse either document with runtime model context. Runtime models see
the frozen prompt, component documentation, mission inventory, signatures, and
capability descriptions selected for a run.

## Automated enforcement

Add focused checks rather than relying only on review:

- reject implementation-language mentions in `README.md`, `docs/guides/`, and
  `docs/reference/`, with deliberate exceptions kept outside those paths;
- ensure each hand-written published page opens with a complete summary and
  avoids invented reader categories;
- keep every visible install and primary workflow command in an executable
  documentation test where practical;
- run the standalone installer probe on clean supported targets;
- run the documented container commands against the published image;
- validate all ExDoc and repository-relative links;
- retain generated-artifact staleness checks;
- fail when a moved page remains in ExDoc extras, test registries, scripts, or
  repository instructions; and
- keep the README first-agent example in the scheduled real-model probes while
  using replay or a scripted provider for deterministic fast tests.

Do not enforce the guide line target mechanically. Enforce ownership,
terminology, links, and executable behavior; review guide length and focus as
editorial criteria.

## Verification

For each slice, run focused documentation and command tests. Before each
commit, run the checks required by the files changed. Before the final commit,
run:

```console
MIX_ENV=dev mix docs --warnings-as-errors
mix precommit
```

When generators or owning catalogs change, run `mix ptc.gen_docs` and stage
their complete output. Verify installer and container commands on every target
they claim rather than inferring portability from a local build.

## Landing sequence

Keep reviews bounded with four coherent changes:

1. **Distribution and first-agent prerequisites** — installer, published
   container, scaffold, and clean-environment probes.
2. **Documentation structure and reference extraction** — moves, navigation,
   generated owners, and exhaustive contract relocation without deleting
   behavior documentation.
3. **README and guide rewrite** — hands-on product journey and short user
   workflows against the now-stable references.
4. **Model guidance and enforcement** — distributed usage rules, repository
   usage-rule behavior, terminology checks, executable examples, and final
   link/render gates.

Each intermediate commit must leave repository links and documentation gates
green. Do not leave a move and its link repair for separate commits.

## Acceptance criteria

The redesign is complete when:

- a new user can install PtcRunner with one documented command or use the
  published container image;
- the README's first useful agent runs without Python, Node.js, a source
  checkout, a language toolchain, or a separately installed sandbox;
- the README explains the missing-middle problem, ordinary no-PTC-Lisp user
  path, security boundary, replaceable agent layer, observability, and
  controlled-improvement foundation before linking into architecture;
- `docs/guides/` contains only end-user, outcome-oriented workflows;
- complete commands, fields, schemas, options, errors, and state machines have
  one owning reference rather than copies in guides;
- public prose is implementation-neutral under the defined path policy;
- end-user model guidance contains no adapter or repository-maintenance view;
- package integrators receive a useful `usage-rules.md`, while source agents
  continue to receive repository instructions through `AGENTS.md`;
- sensitive logging claims distinguish traces from opt-in private
  inspection;
- improvement language distinguishes evaluation and evidence from explicit
  promotion;
- all documented installation and primary workflow commands are verified;
- documentation rendering, link checks, generated staleness checks, focused
  tests, and `mix precommit` pass; and
- this plan is deleted after its remaining durable rules have moved into the
  documentation guidelines and owning references.
