# Message History Optimization - Architecture

Implementation guidance for [message-history-optimization.md](./message-history-optimization.md).

## Breaking Changes

This feature introduces the following breaking changes:

| Change | From | To | Rationale |
|--------|------|-----|-----------|
| SubAgent field | `prompt` | `mission` | More semantic - describes the task |
| Step field | `trace` | `turns` | Structured turn data replaces raw trace |
| Debug option | `debug: true` required | Always captured | `raw_response` always in Turn |
| Debug API | `messages:`, `system:` | `view:`, `raw:` | Simpler, orthogonal options |

### Demo Migration

| File | Change | Action |
|------|--------|--------|
| `agent.ex` | `prompt:` → `mission:` | Update `SubAgent.new()` calls |
| `agent.ex` | `step.trace` → `step.turns` | Update `extract_program_from_trace/1` to use `Turn.program` |
| `prompts.ex` | `Lisp.Prompts` → `Lisp.LanguageSpec` | Update alias |
| `agent.ex` | System prompt is now static | Move role prefix to `system_prompt: %{prefix: ...}` |
| `cli_base.ex` | `preview_prompt` output changes | Data/tools now in USER message (expected) |
| `*_cli.ex` | `print_trace` API changes | Update to new options (`raw:`, `view:`) |

## Module Restructure

This feature requires restructuring prompt-related modules for clarity. The current naming overloads "prompt" for multiple concepts.

### Renames

| Current | New | Rationale |
|---------|-----|-----------|
| `PtcRunner.Prompt` | `PtcRunner.Template` | It's a template struct, not "the prompt" |
| `~PROMPT` sigil | `~T` | Matches Template naming |
| `SubAgent.Prompt` | `SubAgent.SystemPrompt` | Explicitly about system prompt |
| `SubAgent.Template` | `SubAgent.MissionExpander` | Clearer purpose |
| `Lisp.Prompts` | `Lisp.LanguageSpec` | It's the PTC-Lisp language reference |

### New Namespace-Centric Structure

Tools and data move from SYSTEM prompt to USER message. The SYSTEM prompt becomes fully static (cacheable).

```
PtcRunner.Template                    # Generic template engine
├── struct {template, placeholders}
├── parse/1, expand/2
└── ~T sigil

PtcRunner.SubAgent
├── agent.mission                     # The task (was agent.prompt)
│
├── SubAgent.SystemPrompt             # STATIC: language spec + output format
│   └── generate/2                    # Returns static system prompt only
│
├── SubAgent.Namespace                # Renders all namespaces for USER message
│   ├── Namespace.Tool                # tool/ rendering
│   ├── Namespace.Data                # data/ rendering
│   └── Namespace.User                # user/ prelude (from memory)
│
├── SubAgent.MissionExpander          # Expands {{placeholders}} in mission
│
└── SubAgent.Compression              # History compression strategies
    └── SingleUserCoalesced           # Default strategy

PtcRunner.Lisp.LanguageSpec           # Was Lisp.Prompts
└── get/1                             # :single_shot, :multi_turn
```

### Message Structure

The SYSTEM prompt is now fully static. All dynamic content goes in USER message:

```
SYSTEM: Language spec + output format (static, fully cacheable)
USER:   Mission + tool/ + data/ + [user/] + [history]
```

| Content | Location | Cacheable |
|---------|----------|-----------|
| Language spec | SYSTEM | Yes (static) |
| Output format | SYSTEM | Yes (static) |
| Mission | USER | No |
| tool/ namespace | USER | Yes (stable across turns) |
| data/ namespace | USER | Yes (stable across turns) |
| user/ namespace | USER | No (grows each turn) |
| Execution history | USER | No (changes each turn) |

## PTC-Lisp Enhancements Required

This feature depends on PTC-Lisp enhancements not covered in this document:

| Enhancement | Description | Affected Modules |
|-------------|-------------|------------------|
| Auto-fallback resolution | Allow `(search ...)` when unambiguous, resolving to `tool/search` | `Lisp.Analyze`, `Lisp.Env` |
| Return type capture | Capture return types for user-defined functions when called | `Lisp.Eval` (closure metadata) |

These should be implemented as part of Phase 1 or tracked in a separate PTC-Lisp enhancement issue.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SubAgent.Loop                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────────────────┐│
│  │ Execute     │────▶│ Append Turn │────▶│ Compression.to_messages/3      ││
│  │ turn        │     │ (immutable) │     │ (pure render)                   ││
│  └─────────────┘     └─────────────┘     └─────────────────────────────────┘│
│                                                     │                        │
│                                                     ▼                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    Strategy: SingleUserCoalesced                         ││
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐           ││
│  │  │  tool/     │ │   data/    │ │   user/    │ │  History   │           ││
│  │  │ (stable)   │ │  (stable)  │ │ (prelude)  │ │ (changes)  │           ││
│  │  └────────────┘ └────────────┘ └────────────┘ └────────────┘           ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    TypeVocabulary.type_of/1                             ││
│  │  (list[N], map[N], string, integer, float, boolean, keyword, nil, etc.)││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

## Core Design Principles

### REPL with Prelude

The LLM experience is modeled after a **Clojure REPL with a prelude**:

```
Turn 1: Fresh REPL with tool/ and data/ namespaces loaded
Turn N+1: Continue session with user/ prelude of previous definitions
```

Three namespaces rendered consistently:
- `tool/` - Available tools (external, stable)
- `data/` - Input data (external, stable)
- `user/` - LLM definitions (prelude, grows each turn)

### Prompt Caching

The `tool/` and `data/` sections are **stable** across turns:

```
Turn 1: [tool/ + data/] + [user/ empty]     ← tool/data cached
Turn 2: [tool/ + data/] + [user/ small]     ← tool/data cache hit
Turn 3: [tool/ + data/] + [user/ larger]    ← tool/data cache hit
```

Only `user/` and execution history change between turns.

### Append-Only Turns

Turns are **immutable** once created. The turns list is **append-only**:

```
Turn 1 executes → turns = [t1]
Turn 2 executes → turns = [t1, t2]
Turn 3 executes → turns = [t1, t2, t3]
```

No mutation. Each turn captures a snapshot of that cycle's execution.

### Compression as Pure Render

Compression is a **stateless transformation**:

```elixir
messages = Compression.to_messages(turns, memory, opts)
```

Same input always produces same output. The strategy:
- Receives the full turn history
- Renders it into messages for the LLM
- Has no side effects

### Turn Count from Data, Not Messages

```elixir
current_turn = length(turns)
turns_left = max_turns - current_turn
```

Never derived from message array length (which varies by compression strategy).

### Single Renderer Principle

All context rendering flows through `Summary.format/1`:

```
agent.tools   ──┐
agent.data    ──┼──▶ Summary.format(config) ──▶ USER message content
state.memory  ──┤
state.turns   ──┘
```

**No tool/data formatting elsewhere.** System prompt generation doesn't touch tools or data - it only contains static PTC-Lisp instructions.

This means:
- One module renders all namespaces (tool/, data/, user/)
- Turn 1 and Turn N use the same rendering path
- Testing is isolated to Summary module

## Module Breakdown

### 1. Turn (Immutable turn record)

**File:** `lib/ptc_runner/turn.ex`

```elixir
defmodule PtcRunner.Turn do
  @moduledoc """
  A single LLM interaction cycle in multi-turn execution.

  Turns are immutable once created. The turns list is append-only.
  `raw_response` is always captured (no debug flag needed).
  System prompt is NOT stored - it's static, use `SubAgent.Prompt.generate_system/2`.
  """

  defstruct [
    :number,
    :raw_response,
    :program,
    :result,
    :prints,
    :tool_calls,
    :memory,
    :success?
  ]

  @type t :: %__MODULE__{
    number: pos_integer(),
    raw_response: String.t(),
    program: String.t(),
    result: term(),
    prints: [String.t()],
    tool_calls: [PtcRunner.Step.tool_call()],
    memory: map(),
    success?: boolean()
  }

  @doc "Create a successful turn"
  @spec success(pos_integer(), String.t(), String.t(), term(), map(), keyword()) :: t()
  def success(number, raw_response, program, result, memory, opts \\ []) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: result,
      prints: Keyword.get(opts, :prints, []),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      memory: memory,
      success?: true
    }
  end

  @doc "Create a failed turn"
  @spec failure(pos_integer(), String.t(), String.t(), term(), map(), keyword()) :: t()
  def failure(number, raw_response, program, error, memory, opts \\ []) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: error,
      prints: Keyword.get(opts, :prints, []),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      memory: memory,
      success?: false
    }
  end
end
```

---

### 2. Compression (Behaviour)

**File:** `lib/ptc_runner/sub_agent/compression.ex`

```elixir
defmodule PtcRunner.SubAgent.Compression do
  @moduledoc """
  Behaviour for message history compression strategies.

  Compression strategies transform a list of turns into LLM messages.
  This is a pure render function - turns are immutable, strategies
  just provide different views.

  ## Built-in Strategies

  - `SingleUserCoalesced` - Accumulates all context into one USER message

  ## Implementing a Strategy

      defmodule MyCompression do
        @behaviour PtcRunner.SubAgent.Compression

        @impl true
        def name, do: "my-compression"

        @impl true
        def to_messages(turns, memory, opts) do
          # Build [%{role: :system | :user | :assistant, content: String.t()}]
        end
      end
  """

  alias PtcRunner.Turn

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type opts :: [
    mission: String.t(),
    system_prompt: String.t(),
    tools: map(),
    data: map(),
    println_limit: non_neg_integer(),
    tool_call_limit: non_neg_integer(),
    turns_left: non_neg_integer()
  ]

  @doc "Human-readable name for this strategy."
  @callback name() :: String.t()

  @doc """
  Render turns into LLM messages.

  ## Arguments

  - `turns` - Completed turns (append-only history)
  - `memory` - Final memory state (for type/sample info)
  - `opts` - Render options including mission, limits, turns_left

  ## Returns

  List of messages in OpenAI format, ready for LLM.
  """
  @callback to_messages(
    turns :: [Turn.t()],
    memory :: map(),
    opts :: opts()
  ) :: [message()]

  @doc "Normalize compression option to {strategy, opts} tuple"
  @spec normalize(boolean() | module() | {module(), keyword()} | nil) :: {module() | nil, keyword()}
  def normalize(nil), do: {nil, []}
  def normalize(false), do: {nil, []}
  def normalize(true), do: {SingleUserCoalesced, []}
  def normalize(module) when is_atom(module), do: {module, []}
  def normalize({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
end
```

---

### 3. SingleUserCoalesced (Default strategy)

**File:** `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex`

```elixir
defmodule PtcRunner.SubAgent.Compression.SingleUserCoalesced do
  @moduledoc """
  Default compression strategy.

  Accumulates all successful turn context into a single USER message.
  Failed turns use conditional collapsing: shown while still failing,
  collapsed after recovery.

  Message structure:
  ```
  [SYSTEM, USER(mission + context + turns_left), ASSISTANT(current)]
  ```
  """

  @behaviour PtcRunner.SubAgent.Compression

  alias PtcRunner.Turn
  alias PtcRunner.SubAgent.Namespace
  alias PtcRunner.SubAgent.Namespace.ExecutionHistory

  @default_println_limit 15
  @default_tool_call_limit 20

  @impl true
  def name, do: "single-user-coalesced"

  @impl true
  def to_messages(turns, memory, opts) do
    system_prompt = Keyword.fetch!(opts, :system_prompt)
    mission = Keyword.fetch!(opts, :mission)
    turns_left = Keyword.fetch!(opts, :turns_left)

    println_limit = Keyword.get(opts, :println_limit, @default_println_limit)
    tool_call_limit = Keyword.get(opts, :tool_call_limit, @default_tool_call_limit)

    user_content = build_user_content(turns, memory, %{
      mission: mission,
      turns_left: turns_left,
      println_limit: println_limit,
      tool_call_limit: tool_call_limit
    })

    [
      %{role: :system, content: system_prompt},
      %{role: :user, content: user_content}
    ]
  end

  defp build_user_content(turns, memory, config) do
    {successful, failed} = split_turns(turns)

    # Gather accumulated state from successful turns
    all_tool_calls = Enum.flat_map(successful, & &1.tool_calls)
    all_prints = Enum.flat_map(successful, & &1.prints)
    has_println = all_prints != []

    # Conditional collapsing: only show errors if last turn failed
    last_turn = List.last(turns)
    show_errors = last_turn && !last_turn.success?

    parts = [
      config.mission,
      Namespace.render(%{
        tools: config.tools,
        data: config.data,
        memory: memory,
        has_println: has_println
      }),
      ExecutionHistory.render_tool_calls(all_tool_calls, config.tool_call_limit),
      ExecutionHistory.render_output(all_prints, config.println_limit, has_println),
      if(show_errors, do: format_failed_turns(failed), else: nil),
      format_turns_left(config.turns_left)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp split_turns(turns) do
    Enum.split_with(turns, & &1.success?)
  end

  # Conditional collapsing: show most recent error only if still failing
  defp format_failed_turns([]), do: nil
  defp format_failed_turns(failed_turns) do
    # Only show most recent failed turn (limit: 1)
    [turn] = Enum.take(failed_turns, -1)
    [turn]
    |> Enum.map(fn turn ->
      """
      ---
      Your previous attempt:
      ```clojure
      #{turn.program}
      ```

      #{format_error(turn.result)}
      ---
      """
    end)
    |> Enum.join("\n")
  end

  # Turn.result stores step.fail which is %{reason: atom, message: string}
  # The message is already formatted by Lisp.format_error/1
  defp format_error(%{message: message}), do: "Error: #{message}"
  defp format_error(%{} = error), do: "Error: #{inspect(error)}"

  defp format_turns_left(1) do
    "FINAL TURN - you must call (return result) or (fail reason) now."
  end
  defp format_turns_left(n), do: "Turns left: #{n}"
end
```

---

### 4. Namespace (Renders all namespaces)

**File:** `lib/ptc_runner/sub_agent/namespace.ex`

The Namespace module coordinates rendering of all three namespaces for the USER message:

```elixir
defmodule PtcRunner.SubAgent.Namespace do
  @moduledoc """
  Renders namespaces for the USER message (REPL with Prelude model).

  Coordinates rendering of:
  - tool/  : Available tools (from agent config, stable)
  - data/  : Input data (from agent config, stable)
  - user/  : LLM definitions (prelude, grows each turn)
  """

  alias PtcRunner.SubAgent.Namespace.{Tool, Data, User}

  @doc "Render all namespaces as a single string"
  @spec render(map()) :: String.t()
  def render(config) do
    [
      Tool.render(config.tools),
      Data.render(config.data),
      User.render(config.memory, config.has_println)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
```

---

### 4a. Namespace.Tool

**File:** `lib/ptc_runner/sub_agent/namespace/tool.ex`

```elixir
defmodule PtcRunner.SubAgent.Namespace.Tool do
  @moduledoc "Renders the tool/ namespace section."

  @doc "Render tool/ namespace"
  @spec render(map()) :: String.t() | nil
  def render(tools) when map_size(tools) == 0, do: nil
  def render(tools) do
    lines = Enum.map(tools, fn {name, schema} ->
      "(tool/#{name} #{format_params(schema)})      ; #{format_signature(schema)}"
    end)

    [";; === tool/ ===" | lines] |> Enum.join("\n")
  end

  defp format_params(schema) do
    schema[:parameters] |> Map.keys() |> Enum.join(" ")
  end

  defp format_signature(schema) do
    # TODO: Full implementation should format as "param:type -> return_type"
    # This requires parsing JSON schema to extract parameter types.
    schema[:description] || ""
  end
end
```

---

### 4b. Namespace.Data

**File:** `lib/ptc_runner/sub_agent/namespace/data.ex`

```elixir
defmodule PtcRunner.SubAgent.Namespace.Data do
  @moduledoc "Renders the data/ namespace section."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary

  @doc "Render data/ namespace"
  @spec render(map()) :: String.t() | nil
  def render(data) when map_size(data) == 0, do: nil
  def render(data) do
    lines = Enum.map(data, fn {name, value} ->
      type_label = TypeVocabulary.type_of(value)
      sample = format_sample(value)
      "data/#{name}                    ; #{type_label}, sample: #{sample}"
    end)

    [";; === data/ ===" | lines] |> Enum.join("\n")
  end

  defp format_sample(value) do
    {str, _truncated} = Format.to_clojure(value, limit: 3, printable_limit: 80)
    str
  end
end
```

---

### 4c. Namespace.User

**File:** `lib/ptc_runner/sub_agent/namespace/user.ex`

```elixir
defmodule PtcRunner.SubAgent.Namespace.User do
  @moduledoc "Renders the user/ namespace section (prelude from previous turns)."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary

  @doc "Render user/ namespace (prelude)"
  @spec render(map(), boolean()) :: String.t() | nil
  def render(memory, _has_println) when map_size(memory) == 0, do: nil
  def render(memory, has_println) do
    {functions, definitions} = partition_memory(memory)

    fn_lines = Enum.map(functions, &format_function/1)
    def_lines = Enum.map(definitions, &format_definition(&1, has_println))

    lines = fn_lines ++ def_lines
    [";; === user/ (your prelude) ===" | lines] |> Enum.join("\n")
  end

  defp partition_memory(memory) do
    Enum.split_with(memory, fn {_name, value} ->
      match?({:closure, _, _, _, _}, value)
    end)
  end

  defp format_function({name, {:closure, params, _body, _env, meta}}) do
    params_str = Enum.join(params, " ")
    docstring = meta[:doc]
    return_type = meta[:return_type]

    cond do
      docstring && return_type ->
        "(#{name} [#{params_str}])           ; \"#{docstring}\" -> #{return_type}"
      docstring ->
        "(#{name} [#{params_str}])           ; \"#{docstring}\""
      true ->
        "(#{name} [#{params_str}])"
    end
  end

  defp format_definition({name, value}, has_println) do
    type_label = TypeVocabulary.type_of(value)

    if has_println do
      "#{name}                         ; = #{type_label}"
    else
      {sample, _} = Format.to_clojure(value, limit: 3, printable_limit: 80)
      "#{name}                         ; = #{type_label}, sample: #{sample}"
    end
  end
end
```

---

### 4d. Namespace.TypeVocabulary

**File:** `lib/ptc_runner/sub_agent/namespace/type_vocabulary.ex`

```elixir
defmodule PtcRunner.SubAgent.Namespace.TypeVocabulary do
  @moduledoc "Type labels for namespace rendering."

  @doc "Get type label for a value"
  @spec type_of(term()) :: String.t()
  def type_of([]), do: "list[0]"
  def type_of(list) when is_list(list), do: "list[#{length(list)}]"
  def type_of(map) when is_map(map) and map_size(map) == 0, do: "map[0]"
  def type_of(%MapSet{} = set), do: "set[#{MapSet.size(set)}]"
  def type_of(map) when is_map(map) and not is_struct(map), do: "map[#{map_size(map)}]"
  def type_of(s) when is_binary(s), do: "string"
  def type_of(n) when is_integer(n), do: "integer"
  def type_of(f) when is_float(f), do: "float"
  def type_of(b) when is_boolean(b), do: "boolean"
  def type_of(nil), do: "nil"
  def type_of(a) when is_atom(a), do: "keyword"
  def type_of({:closure, _, _, _, _}), do: "#fn[...]"
  def type_of(_), do: "unknown"
end
```

---

### 5. ExecutionHistory (Tool calls and output)

**File:** `lib/ptc_runner/sub_agent/namespace/execution_history.ex`

```elixir
defmodule PtcRunner.SubAgent.Namespace.ExecutionHistory do
  @moduledoc "Renders tool call history and println output."

  alias PtcRunner.Lisp.Format

  @doc "Render tool calls made"
  @spec render_tool_calls([map()], non_neg_integer()) :: String.t()
  def render_tool_calls([], _limit), do: ";; No tool calls made"
  def render_tool_calls(tool_calls, limit) do
    recent = Enum.take(tool_calls, -limit)

    lines = Enum.map(recent, fn tc ->
      {args_str, _} = Format.to_clojure(tc.args, limit: 3, printable_limit: 60)
      ";   #{tc.name}(#{args_str})"
    end)

    [";; Tool calls made:" | lines] |> Enum.join("\n")
  end

  @doc "Render println output"
  @spec render_output([String.t()], non_neg_integer(), boolean()) :: String.t() | nil
  def render_output(_prints, _limit, false), do: nil
  def render_output(prints, limit, true) do
    recent = Enum.take(prints, -limit)
    [";; Output:" | recent] |> Enum.join("\n")
  end
end
```

---

### 6. Step Changes

**File:** `lib/ptc_runner/step.ex` modifications

```elixir
# Replace trace with turns
defstruct [
  # ... existing fields ...
  :turns,  # [Turn.t()] - replaces :trace
  # ... rest ...
]

@type t :: %__MODULE__{
  # ... existing ...
  turns: [Turn.t()] | nil,  # replaces trace
  # ... rest ...
}
```

The `trace` field becomes `turns`. Each Turn contains all the data previously in `trace_entry` plus `prints`.

---

### 7. Loop Integration

**File:** `lib/ptc_runner/sub_agent/loop.ex` modifications

```elixir
defmodule PtcRunner.SubAgent.Loop do
  alias PtcRunner.{Turn, Step}
  alias PtcRunner.SubAgent.Compression

  defp do_run(agent, run_opts) do
    {compression_strategy, compression_opts} = Compression.normalize(agent.compression)

    initial_state = %{
      turns: [],
      turn_number: 0,
      memory: initial_memory,
      compression_strategy: compression_strategy,
      compression_opts: compression_opts,
      # ... other fields ...
    }

    loop(agent, llm, initial_state)
  end

  defp loop(agent, llm, state) do
    # Build messages for LLM
    messages = build_messages(state, agent)

    # Call LLM
    {:ok, response} = llm.(messages)

    # Execute code
    case execute(response, state) do
      {:continue, lisp_step} ->
        # Create immutable turn record (raw_response always captured)
        turn = Turn.success(
          state.turn_number + 1,
          response,                    # raw_response
          extract_program(response),   # program
          lisp_step.return,
          lisp_step.memory,
          prints: lisp_step.prints,
          tool_calls: lisp_step.tool_calls
        )

        # Append turn (immutable)
        new_state = %{state |
          turns: state.turns ++ [turn],
          turn_number: state.turn_number + 1,
          memory: lisp_step.memory
        }

        loop(agent, llm, new_state)

      {:error, lisp_step} ->
        # Create failed turn record (raw_response always captured)
        # lisp_step.fail contains %{reason: atom, message: string}
        turn = Turn.failure(
          state.turn_number + 1,
          response,                    # raw_response
          extract_program(response),   # program
          lisp_step.fail,              # Store the full fail map
          lisp_step.memory,
          prints: lisp_step.prints,
          tool_calls: lisp_step.tool_calls
        )

        new_state = %{state |
          turns: state.turns ++ [turn],
          turn_number: state.turn_number + 1
        }

        loop(agent, llm, new_state)

      {:done, result} ->
        build_final_step(result, state)
    end
  end

  defp build_messages(state, agent) do
    turns_left = agent.max_turns - state.turn_number

    if state.compression_strategy do
      # Use compression strategy
      opts = [
        mission: agent.mission,
        system_prompt: agent.system_prompt,
        turns_left: turns_left
      ] ++ state.compression_opts

      state.compression_strategy.to_messages(state.turns, state.memory, opts)
    else
      # No compression - use existing message building
      build_messages_uncompressed(state, agent, turns_left)
    end
  end
end
```

---

## Data Flow

### Turn Execution Flow

```
Execute turn N
      │
      ▼
┌─────────────────────────────────────────┐
│ Create Turn struct:                      │
│ - number: N                              │
│ - raw_response: "..." (always captured)  │
│ - program: "..."                         │
│ - result: term()                         │
│ - prints: [...]                          │
│ - tool_calls: [...]                      │
│ - memory: %{...}                         │
│ - success?: true/false                   │
└─────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────┐
│ Append to turns list:                    │
│ turns = turns ++ [turn]                  │
│ (immutable - no modification of old)     │
└─────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────┐
│ Build messages for next LLM call:        │
│ Compression.to_messages(turns, memory)   │
│ (pure render - reads turns, no mutation) │
└─────────────────────────────────────────┘
```

### Message Building Flow (SingleUserCoalesced)

```
to_messages(turns, memory, opts)
      │
      ▼
┌─────────────────────────────────────────┐
│ Split turns: successful vs failed        │
└─────────────────────────────────────────┘
      │
      ├──────────────────┐
      ▼                  ▼
┌─────────────┐    ┌─────────────────────┐
│ Successful  │    │ Failed              │
│ → Summary   │    │ → Conditional:      │
└─────────────┘    │   Last failed? Show │
      │            │   Recovered? Hide   │
      │            └─────────────────────┘
      └────────┬─────────┘
               ▼
┌─────────────────────────────────────────┐
│ Assemble USER message:                   │
│ ┌─────────────────────────────────────┐ │
│ │ {mission}                           │ │
│ │                                     │ │
│ │ ; Tool calls: ...                   │ │
│ │ ; Function: ...                     │ │
│ │ ; Defined: ...                      │ │
│ │ ; Output: ...                       │ │
│ │                                     │ │
│ │ --- (last error, if still failing)  │ │
│ │                                     │ │
│ │ Turns left: N                       │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────┐
│ Return: [SYSTEM, USER]                   │
│ (LLM adds ASSISTANT response)            │
└─────────────────────────────────────────┘
```

---

## Files to Create

| File | Purpose |
|------|---------|
| `lib/ptc_runner/template.ex` | Generic template struct (renamed from Prompt) |
| `lib/ptc_runner/turn.ex` | Turn struct |
| `lib/ptc_runner/sub_agent/compression.ex` | Behaviour definition |
| `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex` | Default strategy |
| `lib/ptc_runner/sub_agent/namespace.ex` | Namespace coordinator |
| `lib/ptc_runner/sub_agent/namespace/tool.ex` | tool/ namespace rendering |
| `lib/ptc_runner/sub_agent/namespace/data.ex` | data/ namespace rendering |
| `lib/ptc_runner/sub_agent/namespace/user.ex` | user/ namespace rendering |
| `lib/ptc_runner/sub_agent/namespace/type_vocabulary.ex` | Type labels |
| `lib/ptc_runner/sub_agent/namespace/execution_history.ex` | Tool calls and output |

## Files to Rename

| From | To | Rationale |
|------|-----|-----------|
| `lib/ptc_runner/prompt.ex` | `lib/ptc_runner/template.ex` | Template struct, not "prompt" |
| `lib/ptc_runner/sub_agent/prompt.ex` | `lib/ptc_runner/sub_agent/system_prompt.ex` | Explicitly system prompt |
| `lib/ptc_runner/sub_agent/template.ex` | `lib/ptc_runner/sub_agent/mission_expander.ex` | Clearer purpose |
| `lib/ptc_runner/lisp/prompts.ex` | `lib/ptc_runner/lisp/language_spec.ex` | It's the language reference |

## Files to Modify

| File | Changes |
|------|---------|
| `lib/ptc_runner/step.ex` | Replace `trace` with `turns` |
| `lib/ptc_runner/sub_agent/loop.ex` | Create Turn, use Compression |
| `lib/ptc_runner/sub_agent.ex` | Rename `prompt` to `mission`, add `compression` option |
| `lib/ptc_runner/lisp/analyze.ex` | Auto-fallback namespace resolution (PTC-Lisp enhancement) |
| `lib/ptc_runner/lisp/env.ex` | Namespace registry for resolution (PTC-Lisp enhancement) |
| `lib/ptc_runner/lisp/eval.ex` | Capture return types on closure calls (PTC-Lisp enhancement) |

## Implementation Order

1. **Phase 1: Module Refactoring** (can be done independently)
   - Rename `PtcRunner.Prompt` → `PtcRunner.Template`
   - Rename `SubAgent.Prompt` → `SubAgent.SystemPrompt`
   - Rename `SubAgent.Template` → `SubAgent.MissionExpander`
   - Rename `Lisp.Prompts` → `Lisp.LanguageSpec`
   - Update `~PROMPT` sigil to `~T`
   - Move tools/data rendering out of SystemPrompt

2. **Phase 2: Core Types**
   - `Turn` struct
   - `Compression` behaviour

3. **Phase 3: Namespace Modules**
   - `Namespace` coordinator
   - `Namespace.Tool`, `Namespace.Data`, `Namespace.User`
   - `Namespace.TypeVocabulary`
   - `Namespace.ExecutionHistory`

4. **Phase 4: Default Strategy**
   - `SingleUserCoalesced` implementation
   - Integration with Namespace modules

5. **Phase 5: PTC-Lisp Enhancements**
   - Auto-fallback namespace resolution (`Analyze`, `Env`)
   - Return type capture for closures (`Eval`)

6. **Phase 6: Integration**
   - Step changes (`trace` → `turns`)
   - SubAgent field rename (`prompt` → `mission`)
   - Loop integration
   - Option handling

7. **Phase 7: Testing**
   - Unit tests for each module
   - Integration tests with compression enabled
   - E2E tests with real LLM

---

## Future Strategies

The behaviour allows alternative strategies:

| Strategy | Description |
|----------|-------------|
| `SingleUserCoalesced` | Default - all context in one USER |
| `RollingWindow` | Keep last N turns full, compress older |
| `PerTurnSummary` | Compress each turn, keep USER/ASSISTANT pairs |
| `Aggressive` | Minimal summaries for token-constrained scenarios |

Each implements `to_messages/3` with the same signature, different rendering logic.
