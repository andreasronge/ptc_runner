# Message History Optimization - Architecture

Implementation guidance for [message-history-optimization.md](./message-history-optimization.md).

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

## Module Breakdown

### 1. Turn (Immutable turn record)

**File:** `lib/ptc_runner/turn.ex`

```elixir
defmodule PtcRunner.Turn do
  @moduledoc """
  A single LLM interaction cycle in multi-turn execution.

  Turns are immutable once created. The turns list is append-only.
  """

  defstruct [
    :number,
    :program,
    :result,
    :prints,
    :tool_calls,
    :memory,
    :success?
  ]

  @type t :: %__MODULE__{
    number: pos_integer(),
    program: String.t(),
    result: term(),
    prints: [String.t()],
    tool_calls: [PtcRunner.Step.tool_call()],
    memory: map(),
    success?: boolean()
  }

  @doc "Create a successful turn"
  @spec success(pos_integer(), String.t(), term(), map(), keyword()) :: t()
  def success(number, program, result, memory, opts \\ []) do
    %__MODULE__{
      number: number,
      program: program,
      result: result,
      prints: Keyword.get(opts, :prints, []),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      memory: memory,
      success?: true
    }
  end

  @doc "Create a failed turn"
  @spec failure(pos_integer(), String.t(), term(), map(), keyword()) :: t()
  def failure(number, program, error, memory, opts \\ []) do
    %__MODULE__{
      number: number,
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
  Failed turns are preserved with full code.

  Message structure:
  ```
  [SYSTEM, USER(mission + context + turns_left), ASSISTANT(current)]
  ```
  """

  @behaviour PtcRunner.SubAgent.Compression

  alias PtcRunner.Turn
  alias PtcRunner.SubAgent.Compression.{Summary, TypeVocabulary}

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

    parts = [
      config.mission,
      Summary.format(successful, memory, config),
      format_failed_turns(failed),
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

  defp format_failed_turns([]), do: nil
  defp format_failed_turns(failed_turns) do
    Enum.map(failed_turns, fn turn ->
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

  defp format_error(%{message: message}), do: "Error: #{message}"
  defp format_error(error), do: "Error: #{inspect(error)}"

  defp format_turns_left(1) do
    "FINAL TURN - you must call (return result) or (fail reason) now."
  end
  defp format_turns_left(n), do: "Turns left: #{n}"
end
```

---

### 4. Summary (Format unified namespaces)

**File:** `lib/ptc_runner/sub_agent/compression/summary.ex`

The Summary module renders the unified namespace format (REPL with Prelude model):

```elixir
defmodule PtcRunner.SubAgent.Compression.Summary do
  @moduledoc """
  Format turn data as unified namespaces (REPL with Prelude model).

  Renders three namespace sections plus execution history:
  - tool/  : Available tools (from agent config, stable)
  - data/  : Input data (from agent config, stable)
  - user/  : LLM definitions (prelude, grows each turn)
  - Tool calls made / Output (execution history)
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Compression.TypeVocabulary

  @doc "Format all context as unified namespace sections"
  @spec format(map()) :: String.t()
  def format(config) do
    sections = [
      format_tool_namespace(config.tools),
      format_data_namespace(config.data),
      format_user_namespace(config.memory, config.has_println),
      format_tool_calls_made(config.tool_calls, config.tool_call_limit),
      format_output(config.prints, config.println_limit, config.has_println)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")

    sections
  end

  # tool/ namespace (stable, cacheable)
  defp format_tool_namespace(tools) when map_size(tools) == 0, do: nil
  defp format_tool_namespace(tools) do
    lines = tools
    |> Enum.map(fn {name, schema} ->
      "(tool/#{name} #{format_params(schema)})      ; #{format_signature(schema)}"
    end)

    [";; === tool/ ===" | lines] |> Enum.join("\n")
  end

  # data/ namespace (stable, cacheable)
  defp format_data_namespace(data) when map_size(data) == 0, do: nil
  defp format_data_namespace(data) do
    lines = data
    |> Enum.map(fn {name, value} ->
      type_label = TypeVocabulary.type_of(value)
      sample = format_sample(value)
      "data/#{name}                    ; #{type_label}, sample: #{sample}"
    end)

    [";; === data/ ===" | lines] |> Enum.join("\n")
  end

  # user/ namespace (prelude, grows each turn)
  defp format_user_namespace(memory, _has_println) when map_size(memory) == 0, do: nil
  defp format_user_namespace(memory, has_println) do
    {functions, definitions} = partition_memory(memory)

    fn_lines = Enum.map(functions, fn {name, closure} ->
      format_user_function(name, closure)
    end)

    def_lines = Enum.map(definitions, fn {name, value} ->
      format_user_definition(name, value, has_println)
    end)

    lines = fn_lines ++ def_lines
    [";; === user/ (your prelude) ===" | lines] |> Enum.join("\n")
  end

  defp format_user_function(name, {:closure, params, _body, _env, meta}) do
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

  defp format_user_definition(name, value, has_println) do
    type_label = TypeVocabulary.type_of(value)

    if has_println do
      "#{name}                         ; = #{type_label}"
    else
      sample = format_sample(value)
      "#{name}                         ; = #{type_label}, sample: #{sample}"
    end
  end

  # Tool calls made (execution history)
  defp format_tool_calls_made([], _limit), do: ";; No tool calls made"
  defp format_tool_calls_made(tool_calls, limit) do
    recent = Enum.take(tool_calls, -limit)

    lines = Enum.map(recent, fn tc ->
      {args_str, _} = Format.to_clojure(tc.args, limit: 3, printable_limit: 60)
      ";   #{tc.name}(#{args_str})"
    end)

    [";; Tool calls made:" | lines] |> Enum.join("\n")
  end

  # Output section (println history)
  defp format_output(_prints, _limit, false), do: nil
  defp format_output(prints, limit, true) do
    recent = Enum.take(prints, -limit)
    [";; Output:" | recent] |> Enum.join("\n")
  end

  # Helpers
  defp partition_memory(memory) do
    Enum.split_with(memory, fn {_name, value} ->
      match?({:closure, _, _, _, _}, value)
    end)
  end

  defp format_sample(value) do
    {str, _truncated} = Format.to_clojure(value, limit: 3, printable_limit: 80)
    str
  end

  defp format_params(schema) do
    # Extract param names from tool schema
    schema[:parameters] |> Map.keys() |> Enum.join(" ")
  end

  defp format_signature(schema) do
    # Format as "param:type -> return_type, description"
    "#{schema[:description]}"
  end
end
```

---

### 5. TypeVocabulary (Type labeling)

**File:** `lib/ptc_runner/sub_agent/compression/type_vocabulary.ex`

```elixir
defmodule PtcRunner.SubAgent.Compression.TypeVocabulary do
  @moduledoc "Type labels for summary format."

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
        # Create immutable turn record
        turn = Turn.success(
          state.turn_number + 1,
          extract_program(response),
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

      {:error, error, lisp_step} ->
        # Create failed turn record
        turn = Turn.failure(
          state.turn_number + 1,
          extract_program(response),
          error,
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
┌─────────────┐    ┌─────────────┐
│ Successful  │    │ Failed      │
│ → Summary   │    │ → Full code │
└─────────────┘    └─────────────┘
      │                  │
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
│ │ --- (failed turns if any) ---       │ │
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
| `lib/ptc_runner/turn.ex` | Turn struct |
| `lib/ptc_runner/sub_agent/compression.ex` | Behaviour definition |
| `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex` | Default strategy |
| `lib/ptc_runner/sub_agent/compression/summary.ex` | Summary formatting |
| `lib/ptc_runner/sub_agent/compression/type_vocabulary.ex` | Type labels |

## Files to Modify

| File | Changes |
|------|---------|
| `lib/ptc_runner/step.ex` | Replace `trace` with `turns` |
| `lib/ptc_runner/sub_agent/loop.ex` | Create Turn, use Compression |
| `lib/ptc_runner/sub_agent.ex` | Add `compression` option |

## Implementation Order

1. **Phase 1: Core Types**
   - `Turn` struct
   - `Compression` behaviour
   - `TypeVocabulary` module

2. **Phase 2: Default Strategy**
   - `SingleUserCoalesced` implementation
   - `Summary` formatting

3. **Phase 3: Integration**
   - Step changes (`trace` → `turns`)
   - Loop integration
   - Option handling

4. **Phase 4: Testing**
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
