# Plan: PTC Workbench — Interactive Phoenix LiveView App

## Overview

Replace the current static trace viewer (Plug + vanilla JS) with a lightweight Phoenix LiveView application that serves three roles:

1. **Trace Viewer** — port the existing read-only viewer
2. **Plan Editor** — visual graph editor for creating/editing meta planner JSON
3. **Agent Runner** — execute plans or single agents with streaming output

No database. File-based persistence (plan JSON, trace JSONL). Runs on the same BEAM as PtcRunner — `SubAgent.run/2` is called directly from LiveView processes.

## Motivation

- The current viewer is read-only with no server-side state (Plug + vanilla JS)
- Running agents and streaming results requires WebSockets — LiveView provides this natively
- Plan editing requires bidirectional state — vanilla JS DOM manipulation doesn't scale
- The demo CLI (`mix lisp`) is useful for testing but not for interactive exploration
- MCP integration opens access to thousands of existing tool servers

## Design Decisions

### D1: No database

All persistence is file-based:
- Plans: `.json` files in a configurable directory (default: `plans/`)
- Traces: `.jsonl` files in `traces/`
- Tool configs: `.json` or `.exs` files for MCP server definitions
- Session state: LiveView socket assigns (ephemeral)

### D2: Three-tier tool system

| Tier | Source | Config | Examples |
|------|--------|--------|----------|
| **Built-in** | PtcRunner builtins | Checkboxes | `grep`, `grep-n`, `llm-query` |
| **Bundled** | Elixir modules in workbench | Always available | `read_file`, `grep_fs`, `http_fetch` |
| **MCP** | External MCP servers | Server command config | Filesystem, Brave Search, PDF |

All three tiers produce the same `PtcRunner.Tool` format. The agent doesn't know the tool's origin.

### D3: MCP via hermes_mcp

Use `hermes_mcp` (v0.14.1+, Elixir 1.18+, OTP 26+) for MCP client support:
- Stdio transport for local MCP servers (Node.js servers via `npx`)
- Streamable HTTP transport for remote MCP servers
- Each MCP server runs as a supervised GenServer
- `tools/list` maps to PtcRunner tool definitions via a bridge module
- `tools/call` wrapped as tool functions

### D4: D3 visualizations as LiveView JS hooks

The existing D3 code (~950 lines across dag.js, fork-join.js, execution-tree.js, timeline.js) becomes LiveView JS hooks. Data flows from LiveView → hook via `pushEvent`; user interactions flow back via `pushEventTo`. The D3 rendering logic stays largely unchanged.

### D5: Lightweight Phoenix — no generators

Minimal Phoenix setup:
- Phoenix + LiveView (no Ecto, no Mailer, no Dashboard)
- esbuild for JS bundling (D3 + hooks)
- Tailwind for CSS (replace custom CSS gradually)
- No authentication

### D6: Plan editor operates on the Plan JSON format directly

The editor works with the same JSON structure that `MetaPlanner.plan/2` generates and `Plan.parse/1` consumes:

```json
{
  "tasks": [
    {"id": "fetch", "agent": "researcher", "input": "...", "depends_on": []},
    {"id": "compute", "agent": "calculator", "input": "...", "depends_on": ["fetch"]}
  ],
  "agents": {
    "researcher": {"prompt": "...", "tools": ["search"]},
    "calculator": {"prompt": "...", "tools": []}
  }
}
```

No separate editor format — what you edit is what gets executed.

### D7: Replace demo CLI use cases

The workbench replaces the interactive parts of the demo:
- `mix lisp` interactive mode → Agent Runner with PTC-Lisp input
- `mix lisp --test` → could become a "benchmark" view (future)
- `mix lisp --model=X` → LLM selector dropdown
- Manual plan JSON editing → visual Plan Editor

The demo's `SampleData` (products, orders, employees, expenses) becomes selectable context data in the UI.

---

## Architecture

```
ptc_viewer/
├── lib/ptc_viewer/
│   ├── application.ex
│   ├── endpoint.ex
│   ├── router.ex
│   ├── live/
│   │   ├── trace_live.ex           # Trace viewer (ported)
│   │   ├── plan_editor_live.ex     # Visual plan editor
│   │   ├── agent_live.ex           # Single agent runner
│   │   ├── dashboard_live.ex       # Home: list plans, traces, tools
│   │   └── components/
│   │       ├── tool_palette.ex     # Tool selector (all tiers)
│   │       ├── llm_selector.ex     # Model picker from presets
│   │       ├── task_node.ex        # Plan editor task node form
│   │       ├── agent_panel.ex      # Agent definition editor
│   │       └── lisp_editor.ex      # PTC-Lisp code input
│   ├── services/
│   │   ├── plan_store.ex           # Read/write plan JSON files
│   │   ├── trace_store.ex          # Read trace JSONL files
│   │   └── tool_registry.ex        # Unified tool discovery (all tiers)
│   ├── tools/
│   │   ├── file_system.ex          # Bundled: grep_fs, read_file
│   │   └── http.ex                 # Bundled: http_fetch
│   ├── mcp/
│   │   ├── bridge.ex               # MCP tool → PtcRunner.Tool adapter
│   │   ├── server_config.ex        # MCP server definitions (from file)
│   │   └── supervisor.ex           # Supervises MCP client connections
│   └── runner/
│       └── agent_runner.ex         # Wraps SubAgent.run, broadcasts via PubSub
├── assets/
│   ├── js/
│   │   ├── app.js                  # LiveView setup + hook registration
│   │   ├── hooks/
│   │   │   ├── dag_hook.js         # D3 DAG (from existing dag.js)
│   │   │   ├── plan_dag_hook.js    # Editable DAG (click to add/connect)
│   │   │   ├── fork_join_hook.js   # D3 fork-join (from existing)
│   │   │   ├── exec_tree_hook.js   # D3 execution tree (from existing)
│   │   │   ├── timeline_hook.js    # Timeline bar (from existing)
│   │   │   └── lisp_editor_hook.js # CodeMirror for PTC-Lisp
│   │   └── vendor/
│   │       └── d3.v7.min.js
│   └── css/
│       └── app.css
└── mix.exs                         # Phoenix, LiveView, hermes_mcp deps
```

### Data Flow

```
Plan Editor                     Agent Runner
    │                               │
    ├─ save ──→ plan_store ←── load ┤
    │           (JSON files)        │
    │                               │
    │                      ┌────────┤
    │                      │  SubAgent.run/2
    │                      │  (same BEAM)
    │                      │        │
    │                      │    PubSub broadcasts
    │                      │        │
    │                      └──→ LiveView push
    │                               │
    └──────────────────────→ trace_store
                            (JSONL files)
```

---

## Tool System Detail

### Tier 1: Built-in tools

Already implemented in PtcRunner. Exposed as checkboxes:

```elixir
# tool_registry.ex
def builtin_tools do
  %{
    "grep" => %{description: "Regex grep over text string", tier: :builtin, family: :grep},
    "grep-n" => %{description: "Grep with line numbers", tier: :builtin, family: :grep},
    "llm-query" => %{description: "Ad-hoc LLM call", tier: :builtin, family: :llm_query}
  }
end
```

### Tier 2: Bundled tool modules

Elixir modules that ship with the workbench. Each exports a `tools/0` function:

```elixir
defmodule PtcViewer.Tools.FileSystem do
  @moduledoc "File system tools (sandboxed to allowed directories)"

  @allowed_dirs ["/tmp", "~/.ptc_workbench/data"]

  def tools do
    %{
      "read_file" => {&read_file/1,
        signature: "(path :string) -> :string",
        description: "Read file contents (sandboxed)"},
      "grep_fs" => {&grep_fs/1,
        signature: "(pattern :string, path :string) -> [:string]",
        description: "Search files matching regex pattern"}
    }
  end

  def read_file(%{"path" => path}) do
    with :ok <- validate_path(path) do
      File.read!(path)
    end
  end
  # ...
end
```

### Tier 3: MCP tools

MCP server config stored as JSON:

```json
[
  {
    "name": "filesystem",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    "transport": "stdio",
    "enabled": true
  },
  {
    "name": "brave-search",
    "command": "npx",
    "args": ["-y", "@anthropic/mcp-server-brave-search"],
    "transport": "stdio",
    "env": {"BRAVE_API_KEY": "${BRAVE_API_KEY}"},
    "enabled": true
  }
]
```

The MCP bridge converts discovered tools to PtcRunner format:

```elixir
defmodule PtcViewer.MCP.Bridge do
  def tools_from_server(client) do
    {:ok, %{result: %{"tools" => tools}}} = client.list_tools()

    Map.new(tools, fn tool ->
      {tool["name"], {
        fn args -> call_mcp(client, tool["name"], args) end,
        signature: schema_to_signature(tool["inputSchema"]),
        description: tool["description"]
      }}
    end)
  end
end
```

### Unified Tool Palette

The `ToolRegistry` merges all three tiers:

```elixir
defmodule PtcViewer.Services.ToolRegistry do
  def all_tools do
    builtins = builtin_tools()
    bundled = discover_bundled_tools()
    mcp = discover_mcp_tools()

    %{builtin: builtins, bundled: bundled, mcp: mcp}
  end
end
```

The UI renders them in a single palette, grouped by tier. Users check tools on/off per agent.

---

## Plan Editor Detail

### Graph View (D3 hook)

The plan editor reuses the existing DAG visualization but makes it interactive:

- **Click empty space** → add new task node (opens task form)
- **Drag from node to node** → create dependency edge
- **Click node** → open task detail panel (edit id, agent, input, signature, etc.)
- **Click edge** → delete dependency
- **Right-click node** → delete task, duplicate, change type

Data flow:
1. LiveView holds the plan as socket assign (`assign(socket, :plan, plan)`)
2. On change, LiveView pushes updated plan data to the D3 hook via `push_event`
3. D3 hook renders the DAG
4. User interactions in D3 call `this.pushEventTo()` back to LiveView
5. LiveView updates the plan assign and re-pushes to D3

### Task Detail Panel

When a task node is selected, a side panel shows an editable form:

| Field | Input Type | Notes |
|-------|-----------|-------|
| `id` | Text input | Auto-generated, editable |
| `agent` | Dropdown | From agents defined in plan + "direct" + "default" |
| `input` | Text area / Lisp editor | Switches to Lisp editor when agent="direct" |
| `depends_on` | Multi-select | From existing task IDs |
| `output` | Radio: auto / ptc_lisp / json | |
| `signature` | Text input | e.g. `{revenue :float}` |
| `type` | Dropdown: task / synthesis_gate / human_review | |
| `verification` | Lisp editor | PTC-Lisp predicate |
| `on_failure` | Dropdown: stop / skip / retry / replan | |
| `on_verification_failure` | Dropdown: stop / skip / retry / replan | |
| `max_retries` | Number input | Default: 1 |
| `quality_gate` | Checkbox | |
| `critical` | Checkbox | Default: true |

### Agent Definition Panel

Separate panel for editing agents:

| Field | Input Type |
|-------|-----------|
| `name` (key) | Text input |
| `prompt` | Text area |
| `tools` | Tool palette checkboxes |

### Plan Actions

- **Save** → writes JSON to `plans/` directory
- **Load** → reads from file, populates editor
- **Generate** → enter a mission, call `MetaPlanner.plan/2`, load result into editor
- **Validate** → call `Plan.validate/1`, show errors on affected nodes
- **Run** → send to Agent Runner view with selected LLM and tools

---

## Agent Runner Detail

### Single Agent Mode

For running a single `SubAgent` without a full plan:

- Text area for prompt (or PTC-Lisp code)
- Tool palette for selecting tools
- LLM selector (from `LLMClient.presets()`)
- Context data selector (upload JSON, pick sample datasets, or use plan results)
- Signature input (optional)
- "Run" button

### Plan Execution Mode

For running a full plan via `PlanRunner`:

- Load a plan from file or from the Plan Editor
- Select LLM for each agent (or use a default)
- Tool mapping: plan references tool names → map to actual tool functions from registry
- "Execute" button

### Streaming Output

The runner wraps `SubAgent.run/2` in a Task and uses PubSub to broadcast updates:

```elixir
defmodule PtcViewer.Runner.AgentRunner do
  def run_agent(agent, opts, topic) do
    Task.Supervisor.start_child(PtcViewer.TaskSupervisor, fn ->
      # Enable tracing to get real-time events
      opts = Keyword.put(opts, :trace_context, build_trace_context(topic))

      case SubAgent.run(agent, opts) do
        {:ok, step} ->
          Phoenix.PubSub.broadcast(PtcViewer.PubSub, topic, {:agent_complete, step})
        {:error, step} ->
          Phoenix.PubSub.broadcast(PtcViewer.PubSub, topic, {:agent_error, step})
      end
    end)
  end
end
```

The LiveView subscribes to the topic and pushes updates as they arrive:

```elixir
def handle_info({:agent_complete, step}, socket) do
  {:noreply, assign(socket, :result, step)}
end
```

### Output Display

Results rendered as:
- Summary stats (duration, tokens, turns)
- Turn-by-turn view (reuse existing agent-view rendering)
- Tool call log
- Final return value (formatted)
- Trace saved to `traces/` for later viewing

---

## LLM Configuration

### Model Selector

Populated from `LLMClient.presets()`:

```elixir
# In the LiveView
def mount(_params, _session, socket) do
  presets = LLMClient.presets()
  {:ok, assign(socket, :models, presets)}
end
```

Display shows:
- Friendly name (e.g., "Haiku", "Sonnet", "Gemini Flash")
- Full model ID (e.g., `openrouter:anthropic/claude-haiku-4.5`)
- Availability indicator (green if API key present)

### Per-Agent LLM Override

In plan execution, each agent can use a different LLM:
- Default: use the globally selected model
- Override: pick a specific model per agent in the plan editor

---

## Implementation Phases

### Phase 1: Skeleton + Trace Viewer Port

Set up the Phoenix app and port the existing trace viewer.

- [ ] Initialize Phoenix project (no Ecto, no Mailer)
- [ ] Add dependencies: `phoenix`, `phoenix_live_view`, `esbuild`, `tailwind`, `jason`
- [ ] Create `DashboardLive` — list plans and traces from disk
- [ ] Create `TraceLive` — port existing viewer
- [ ] Port D3 visualizations as JS hooks (dag, fork-join, execution-tree, timeline)
- [ ] Port CSS theme (dark mode)
- [ ] Port JSONL parser to Elixir (move parsing server-side)

**Acceptance**: `mix phx.server` shows the dashboard, clicking a trace opens the viewer with D3 visualizations working identically to the current viewer.

### Phase 2: Plan Editor

- [ ] Create `PlanEditorLive` with two-panel layout (graph + detail)
- [ ] Implement `PlanStore` — load/save JSON files
- [ ] Create `PlanDagHook` — editable D3 DAG (add nodes, connect edges)
- [ ] Task detail form (all fields from Plan.task type)
- [ ] Agent definition panel
- [ ] Plan validation (call `Plan.validate/1`, highlight errors on graph)
- [ ] Save/load plan files
- [ ] "Generate from mission" — call `MetaPlanner.plan/2`, populate editor

**Acceptance**: Can create a plan from scratch using the graph editor, save it, reload it, and the JSON matches the `Plan.parse/1` format.

### Phase 3: Agent Runner

- [ ] Create `AgentLive` for single-agent execution
- [ ] Implement `AgentRunner` with PubSub broadcasting
- [ ] LLM selector component (from `LLMClient.presets()`)
- [ ] Basic tool palette (built-in tools only)
- [ ] Streaming output display (turns, tool calls, result)
- [ ] PTC-Lisp code input (CodeMirror hook)
- [ ] Context data input (JSON text area + sample data selector)

**Acceptance**: Can select a model, write a prompt, pick tools, run an agent, and see streaming results.

### Phase 4: Bundled Tools + Plan Execution

- [ ] Implement bundled tool modules (`FileSystem`, `Http`)
- [ ] Implement `ToolRegistry` (merge built-in + bundled)
- [ ] Tool palette shows all available tools grouped by tier
- [ ] Plan execution mode in AgentLive (run full plans via PlanRunner)
- [ ] Tool mapping: plan tool names → actual tool functions

**Acceptance**: Can run a plan that uses bundled file tools, see execution progress, view traces.

### Phase 5: MCP Integration

- [ ] Add `hermes_mcp` dependency
- [ ] Implement `MCP.Bridge` — convert MCP tools to PtcRunner format
- [ ] Implement `MCP.ServerConfig` — load/save MCP server definitions
- [ ] Implement `MCP.Supervisor` — manage MCP client connections
- [ ] UI: MCP server management panel (add/remove/toggle servers)
- [ ] Tool palette includes MCP-discovered tools
- [ ] Test with reference servers (filesystem, brave-search)

**Acceptance**: Can configure an MCP server (e.g., filesystem), see its tools appear in the palette, and use them in an agent run.

### Phase 6: Polish + Demo Replacement

- [ ] Sample data integration (products, orders, employees, expenses from demo)
- [ ] Preset plans/templates (common workflow patterns)
- [ ] Improve plan editor UX (undo/redo, keyboard shortcuts, snap-to-grid)
- [ ] Error display improvements (inline validation, toast notifications)
- [ ] Mix task: `mix ptc.workbench` to start the app

**Acceptance**: A new user can start the workbench, load sample data, create a plan visually, run it, and explore the trace — without touching the CLI.

---

## Dependencies

```elixir
# ptc_viewer/mix.exs
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.0"},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
    {:bandit, "~> 1.6"},
    {:jason, "~> 1.4"},
    {:hermes_mcp, "~> 0.14", optional: true},  # Phase 5
    {:ptc_runner, path: ".."}
  ]
end
```

### JS Dependencies (vendored or via esbuild)

- D3.js v7 (already vendored)
- CodeMirror 6 (for PTC-Lisp editor) — via npm/esbuild

---

## Key Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| D3 hook complexity | Medium | Port incrementally; keep existing D3 code nearly unchanged |
| hermes_mcp stability | Low | Optional dep; bundled tools work without MCP |
| Plan editor UX | High | Start with form-based editing, add graph interactions incrementally |
| Phoenix overhead for a "viewer" | Low | Minimal Phoenix setup; no Ecto, no auth, no dashboard |
| Trace file size | Medium | Stream-parse JSONL server-side instead of loading entire files |

---

## Open Questions

1. **Should the workbench live in `ptc_viewer/` (rename) or a new directory like `ptc_workbench/`?**
   Suggestion: rename to `ptc_workbench/` to reflect expanded scope.

2. **CodeMirror vs simpler editor for PTC-Lisp?**
   CodeMirror 6 is modular and tree-shakeable. A simpler option is Monaco (heavier) or a plain textarea with syntax highlighting overlay. CodeMirror 6 seems right for the scope.

3. **Should MCP be a hard or optional dependency?**
   Suggestion: optional. The workbench should work without MCP configured. Use `hermes_mcp` as an optional dep and conditionally compile the MCP modules.

4. **How to handle long-running plan executions?**
   Plans with many tasks can take minutes. The PubSub approach handles this — LiveView stays connected and receives incremental updates. Add a "cancel" button that kills the runner Task.

5. **Should the plan editor support collaborative editing (multiple browser tabs)?**
   Not initially. File-based storage with last-write-wins is fine for single-user.
