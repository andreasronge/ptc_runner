# Message History Optimization - Architecture

This document provides implementation guidance for the requirements in [message-history-optimization-requirements.md](./message-history-optimization-requirements.md).

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SubAgent.Loop                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────────┐ │
│  │ HistoryOpts │───▶│ HistoryState │───▶│ MessageBuilder                  │ │
│  │ (config)    │    │ (accumulated)│    │ (constructs USER message)       │ │
│  └─────────────┘    └──────────────┘    └─────────────────────────────────┘ │
│         │                  │                          │                      │
│         ▼                  ▼                          ▼                      │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    Summary.format/2                                      ││
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐           ││
│  │  │ ToolCalls  │ │ Functions  │ │ Definitions│ │ Output     │           ││
│  │  │ Section    │ │ Section    │ │ Section    │ │ Section    │           ││
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

## Module Breakdown

### 1. HistoryOpts (Config struct)

**File:** `lib/ptc_runner/sub_agent/history/opts.ex`

```elixir
defmodule PtcRunner.SubAgent.History.Opts do
  @moduledoc "Configuration for message history compression."

  defstruct [
    enabled: false,
    println_limit: 15,
    tool_call_limit: 20
  ]

  @type t :: %__MODULE__{
    enabled: boolean(),
    println_limit: pos_integer(),
    tool_call_limit: pos_integer()
  }

  @doc "Normalize compress_history option to %Opts{}"
  @spec from_option(boolean() | keyword() | nil) :: t()
  def from_option(nil), do: %__MODULE__{enabled: false}
  def from_option(false), do: %__MODULE__{enabled: false}
  def from_option(true), do: %__MODULE__{enabled: true}
  def from_option(opts) when is_list(opts) do
    %__MODULE__{
      enabled: true,
      println_limit: Keyword.get(opts, :println_limit, 15),
      tool_call_limit: Keyword.get(opts, :tool_call_limit, 20)
    }
  end
end
```

**Integration point:** `SubAgent.new/1` normalizes `compress_history` to `%Opts{}`.

---

### 2. HistoryState (Accumulated state across turns)

**File:** `lib/ptc_runner/sub_agent/history/state.ex`

Tracks accumulated data across successful turns:

```elixir
defmodule PtcRunner.SubAgent.History.State do
  @moduledoc "Accumulated history state for compression."

  defstruct [
    # Accumulated tool calls: [{name, args, result, turn}]
    tool_calls: [],
    # Accumulated definitions: %{name => {value, docstring, type, turn}}
    definitions: %{},
    # Accumulated functions: %{name => {docstring, turn}}
    functions: %{},
    # Accumulated println outputs: [{output, turn}]
    printlns: [],
    # Failed turns: [{turn, assistant_content, user_feedback}]
    failed_turns: [],
    # Mission text (never compressed)
    mission: ""
  ]

  @doc "Update state after a successful turn"
  @spec update_success(t(), map()) :: t()
  def update_success(state, %{
    turn: turn,
    tool_calls: tool_calls,
    definitions: definitions,
    functions: functions,
    printlns: printlns
  }) do
    %{state |
      tool_calls: state.tool_calls ++ tag_with_turn(tool_calls, turn),
      definitions: merge_definitions(state.definitions, definitions, turn),
      functions: merge_functions(state.functions, functions, turn),
      printlns: state.printlns ++ tag_with_turn(printlns, turn)
    }
  end

  @doc "Record a failed turn (kept full)"
  @spec record_failed_turn(t(), pos_integer(), String.t(), String.t()) :: t()
  def record_failed_turn(state, turn, assistant_content, user_feedback) do
    %{state |
      failed_turns: state.failed_turns ++ [{turn, assistant_content, user_feedback}]
    }
  end
end
```

**Key design decisions:**
- Tool calls and printlns are accumulated as lists (FIFO truncation from front)
- Definitions/functions use maps with turn tracking (latest wins)
- Failed turns stored separately for full preservation

---

### 3. DefinitionTracker (Capture def/defn at eval time)

**File:** `lib/ptc_runner/lisp/eval/definition_tracker.ex`

The interpreter already captures definitions in `user_ns`. We need to additionally capture:
- **Docstrings** for both `def` and `defn`
- **Order of definition** (for display ordering)

**Changes to `EvalContext`:**

```elixir
# In lib/ptc_runner/lisp/eval/context.ex
defstruct [
  # ... existing fields ...
  # New: captures definition metadata
  # %{symbol => {docstring, order_index}}
  definition_meta: %{},
  definition_order: 0
]
```

**TRN-011: Truncate println at capture time** — Modify `EvalContext.append_print/2` to truncate output immediately (e.g., 2000 chars) rather than at summary time. This prevents memory bloat from `(println (slurp "huge-file"))`.

**Changes to `def` evaluation** (in `lib/ptc_runner/lisp/eval/special_forms.ex`):

```elixir
# (def name value) or (def name "docstring" value)
defp eval_def(ctx, [name, docstring, value]) when is_binary(docstring) do
  # ... eval value ...
  ctx = %{ctx |
    definition_meta: Map.put(ctx.definition_meta, name, {
      sanitize_docstring(docstring),
      ctx.definition_order
    }),
    definition_order: ctx.definition_order + 1
  }
  # ... rest unchanged ...
end

defp sanitize_docstring(doc), do: String.replace(doc, ";", "")
```

**Changes to `defn` evaluation:**
```elixir
# (defn name "docstring" [params] body) or (defn name [params] body)
# Similar pattern - capture docstring in definition_meta
```

**AST changes (Analyze module):** The analyzer currently discards docstrings. Update `CoreAST` to include optional docstring field in `{:def, name, docstring, value}` and `{:defn, name, docstring, params, body}` tuples.

**Step changes:**
```elixir
# Step gets new field
defstruct [
  # ... existing ...
  :definition_meta  # %{symbol => {docstring, order_index}}
]
```

---

### 4. TypeVocabulary (Type labeling)

**File:** `lib/ptc_runner/sub_agent/history/type_vocabulary.ex`

```elixir
defmodule PtcRunner.SubAgent.History.TypeVocabulary do
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

### 5. Summary (Format compressed history)

**File:** `lib/ptc_runner/sub_agent/history/summary.ex`

```elixir
defmodule PtcRunner.SubAgent.History.Summary do
  @moduledoc "Format accumulated history into compressed summary."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.History.{Opts, State, TypeVocabulary}

  @doc """
  Format accumulated history as a summary string.

  Returns summary text to append to USER message.
  """
  @spec format(State.t(), Opts.t()) :: String.t()
  def format(%State{} = state, %Opts{} = opts) do
    # Global check: if ANY turn used println, omit samples everywhere
    has_println = length(state.printlns) > 0

    sections = [
      format_tool_calls(state.tool_calls, opts.tool_call_limit),
      format_functions(state.functions),
      format_definitions(state.definitions, has_println),
      format_output(state.printlns, opts.println_limit, has_println)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")

    if sections == "", do: nil, else: sections
  end

  # Tool calls section
  defp format_tool_calls([], _limit), do: "; No tool calls made"
  defp format_tool_calls(tool_calls, limit) do
    # FIFO: keep most recent N
    recent = Enum.take(tool_calls, -limit)

    # Compress consecutive identical calls
    compressed = compress_consecutive(recent)

    lines = Enum.map(compressed, fn
      {name, args, _result, _turn, count} when count > 1 ->
        {args_str, _} = Format.to_clojure(args, limit: 3, printable_limit: 60)
        ";   #{name}(#{args_str}) x#{count}"
      {name, args, _result, _turn, _count} ->
        {args_str, _} = Format.to_clojure(args, limit: 3, printable_limit: 60)
        ";   #{name}(#{args_str})"
    end)

    ["; Tool calls:" | lines] |> Enum.join("\n")
  end

  # Functions section (defn)
  defp format_functions(functions) when map_size(functions) == 0, do: nil
  defp format_functions(functions) do
    functions
    |> Enum.sort_by(fn {_name, {_doc, order}} -> order end)
    |> Enum.map(fn
      {name, {nil, _order}} -> "; Function: #{name}"
      {name, {"", _order}} -> "; Function: #{name}"
      {name, {doc, _order}} -> "; Function: #{name} - \"#{doc}\""
    end)
    |> Enum.join("\n")
  end

  # Definitions section (def)
  defp format_definitions(definitions, has_println) when map_size(definitions) == 0, do: nil
  defp format_definitions(definitions, has_println) do
    definitions
    |> Enum.sort_by(fn {_name, {_val, _doc, _type, order}} -> order end)
    |> Enum.map(fn {name, {value, docstring, _type, _order}} ->
      type_label = TypeVocabulary.type_of(value)
      format_definition_line(name, docstring, type_label, value, has_println)
    end)
    |> Enum.join("\n")
  end

  defp format_definition_line(name, docstring, type, value, has_println) do
    base = if docstring && docstring != "" do
      "; Defined: #{name} - \"#{docstring}\" = #{type}"
    else
      "; Defined: #{name} = #{type}"
    end

    # Add sample only if no println output
    if has_println do
      base
    else
      sample = format_sample(value)
      if sample, do: "#{base}, sample: #{sample}", else: base
    end
  end

  defp format_sample(value) do
    {str, _truncated} = Format.to_clojure(value, limit: 3, printable_limit: 80)
    str
  end

  # Output section (println)
  defp format_output(_printlns, _limit, false), do: nil  # No println = no output section
  defp format_output(printlns, limit, true) do
    # FIFO: keep most recent N
    recent = Enum.take(printlns, -limit)

    lines = Enum.map(recent, fn {output, _turn} ->
      # Truncate per-call (TRN-011)
      truncate_output(output, 2000)
    end)

    ["; Output:" | lines] |> Enum.join("\n")
  end

  defp truncate_output(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end
  defp truncate_output(str, _max), do: str

  # Compress consecutive identical tool calls (TC-008)
  defp compress_consecutive(tool_calls) do
    # Group consecutive identical calls
    tool_calls
    |> Enum.chunk_by(fn {name, args, _, _} -> {name, args} end)
    |> Enum.flat_map(fn chunk ->
      {name, args, result, turn} = hd(chunk)
      [{name, args, result, turn, length(chunk)}]
    end)
  end
end
```

---

### 6. MessageBuilder (Construct compressed message array)

**File:** `lib/ptc_runner/sub_agent/history/message_builder.ex`

```elixir
defmodule PtcRunner.SubAgent.History.MessageBuilder do
  @moduledoc """
  Build message array with compressed history.

  Transforms accumulated history into the final message structure:
  [SYSTEM, USER(mission + summary + turns_left), ASSISTANT(current)]
  """

  alias PtcRunner.SubAgent.History.{Opts, State, Summary}

  @doc """
  Build messages for LLM call with compression.

  ## Parameters
  - `state` - Accumulated HistoryState
  - `opts` - HistoryOpts configuration
  - `current_turn` - Current turn number
  - `max_turns` - Maximum turns allowed

  ## Returns
  USER message content with mission, summary, failed turns, and turn info.
  """
  @spec build_user_message(State.t(), Opts.t(), pos_integer(), pos_integer()) :: String.t()
  def build_user_message(state, opts, current_turn, max_turns) do
    parts = [
      # Mission always first (MSG-007)
      state.mission,
      # Compressed summary (if any history)
      Summary.format(state, opts),
      # Failed turns kept full (ERR-001, ERR-002)
      format_failed_turns(state.failed_turns),
      # Turn info at end (MSG-005)
      format_turn_info(current_turn, max_turns)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")

    parts
  end

  defp format_failed_turns([]), do: nil
  defp format_failed_turns(failed_turns) do
    # Failed turns embedded with clear separators
    Enum.map(failed_turns, fn {_turn, assistant, feedback} ->
      """
      ---
      Your previous attempt:
      ```clojure
      #{extract_code(assistant)}
      ```

      #{feedback}
      ---
      """
    end)
    |> Enum.join("\n")
  end

  defp extract_code(assistant_content) do
    # Extract code block from assistant response
    ResponseHandler.extract_code_block(assistant_content) || assistant_content
  end

  defp format_turn_info(current_turn, max_turns) do
    turns_remaining = max_turns - current_turn + 1

    if turns_remaining == 1 do
      "\u26A0\uFE0F FINAL TURN - you must call (return result) or (fail response) next."
    else
      "Turns left: #{turns_remaining}"
    end
  end
end
```

---

### 7. Namespace Resolution (tool/, data/, bare names)

**File:** `lib/ptc_runner/lisp/eval/namespace.ex`

```elixir
defmodule PtcRunner.Lisp.Eval.Namespace do
  @moduledoc """
  Namespace resolution for PTC-Lisp symbols.

  - `tool/name` - Explicit tool namespace
  - `data/name` - Explicit data namespace
  - `name` - Auto-fallback with precedence:
    1. Local definitions (user_ns, let bindings)
    2. tool/name if exists and no data/name
    3. data/name if exists and no tool/name
    4. Error if both exist (ambiguous)
  """

  @tool_prefix "tool/"
  @data_prefix "data/"

  @doc "Resolve a symbol to its value"
  @spec resolve(atom(), map(), map(), map()) :: {:ok, term()} | {:error, term()}
  def resolve(symbol, local_env, tools, data) do
    name = Atom.to_string(symbol)

    cond do
      # Explicit tool namespace
      String.starts_with?(name, @tool_prefix) ->
        tool_name = String.trim_leading(name, @tool_prefix)
        resolve_tool(tool_name, tools)

      # Explicit data namespace
      String.starts_with?(name, @data_prefix) ->
        data_key = String.trim_leading(name, @data_prefix) |> String.to_atom()
        resolve_data(data_key, data)

      # Bare name - check local first
      Map.has_key?(local_env, symbol) ->
        {:ok, Map.get(local_env, symbol)}

      # Auto-fallback
      true ->
        auto_resolve(symbol, tools, data)
    end
  end

  defp resolve_tool(name, tools) do
    if Map.has_key?(tools, name) do
      {:ok, {:tool, name, Map.get(tools, name)}}
    else
      {:error, {:tool_not_found, name}}
    end
  end

  defp resolve_data(key, data) do
    if Map.has_key?(data, key) do
      {:ok, Map.get(data, key)}
    else
      {:error, {:data_not_found, key}}
    end
  end

  defp auto_resolve(symbol, tools, data) do
    name = Atom.to_string(symbol)
    has_tool = Map.has_key?(tools, name)
    has_data = Map.has_key?(data, symbol)

    cond do
      has_tool and has_data ->
        {:error, {:ambiguous_reference,
          "Symbol '#{name}' exists in both tool/ and data/ namespaces. Use explicit namespace."}}

      has_tool ->
        {:ok, {:tool, name, Map.get(tools, name)}}

      has_data ->
        {:ok, Map.get(data, symbol)}

      true ->
        {:error, {:undefined_symbol, symbol}}
    end
  end
end
```

**Integration with existing eval:**

The current symbol resolution in `lib/ptc_runner/lisp/eval.ex` needs to be updated to use the namespace module. The full resolution order:

1. Let bindings (lexical scope)
2. User namespace (def'd values)
3. Explicit namespaces (`tool/`, `data/`)
4. Auto-fallback (ambiguity check)
5. Builtins (`+`, `filter`, etc.) — **last**, so user code can shadow them

---

### 8. Loop Integration

**File:** `lib/ptc_runner/sub_agent/loop.ex` modifications

```elixir
defmodule PtcRunner.SubAgent.Loop do
  alias PtcRunner.SubAgent.History.{Opts, State, MessageBuilder}

  # In initial_state setup:
  defp do_run(agent, run_opts) do
    history_opts = agent.history_opts  # Already normalized by SubAgent.new

    initial_state = %{
      # ... existing fields ...

      # New: history compression state
      history_opts: history_opts,
      history_state: %State{mission: expanded_mission}
    }

    # ...
  end

  # After successful turn (in handle_successful_execution):
  defp continue_loop(lisp_step, state, agent, llm) do
    if state.history_opts.enabled do
      # Update history state with turn data
      turn_data = %{
        turn: state.turn,
        tool_calls: lisp_step.tool_calls,
        definitions: extract_definitions(lisp_step),
        functions: extract_functions(lisp_step),
        printlns: lisp_step.prints
      }

      new_history = State.update_success(state.history_state, turn_data)

      # Build compressed USER message
      user_content = MessageBuilder.build_user_message(
        new_history,
        state.history_opts,
        state.turn + 1,
        agent.max_turns
      )

      new_state = %{state |
        turn: state.turn + 1,
        # Replace messages with compressed form
        messages: [%{role: :user, content: user_content}],
        history_state: new_history,
        # ... other updates ...
      }

      loop(agent, llm, new_state)
    else
      # Existing behavior (no compression)
      # ...
    end
  end

  # After failed turn:
  defp handle_failed_turn(code, response, error_message, state, agent, llm) do
    if state.history_opts.enabled do
      # Record failed turn (kept full)
      new_history = State.record_failed_turn(
        state.history_state,
        state.turn,
        response,
        error_message
      )

      new_state = %{state |
        turn: state.turn + 1,
        history_state: new_history,
        # ... other updates ...
      }

      loop(agent, llm, new_state)
    else
      # Existing behavior
      # ...
    end
  end
end
```

---

## Data Flow Diagrams

### Successful Turn Flow

```
Turn N completes successfully
         │
         ▼
┌─────────────────────────────────────────┐
│ Extract from lisp_step:                 │
│ - tool_calls: [{name, args, result}]    │
│ - memory: %{symbol => value}            │
│ - prints: ["output1", "output2"]        │
│ - definition_meta: %{sym => {doc, ord}} │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ State.update_success(history_state, ...) │
│                                          │
│ Accumulate:                              │
│ - tool_calls (append with turn tag)     │
│ - definitions (merge, latest wins)      │
│ - functions (merge, latest wins)        │
│ - printlns (append with turn tag)       │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ MessageBuilder.build_user_message(...)   │
│                                          │
│ Output structure:                        │
│ ┌─────────────────────────────────────┐ │
│ │ {mission}                           │ │
│ │                                     │ │
│ │ ; Tool calls:                       │ │
│ │ ;   tool1(args)                     │ │
│ │ ;   tool2(args) x3                  │ │
│ │ ; Function: helper - "description"  │ │
│ │ ; Defined: x = list[5], sample: ... │ │
│ │ ; Output:                           │ │
│ │ printed output here                 │ │
│ │                                     │ │
│ │ Turns left: 3                       │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Loop continues with:                     │
│ messages: [%{role: :user, content: ...}]│
└─────────────────────────────────────────┘
```

### Failed Turn Flow

```
Turn N fails (parse error, eval error, etc.)
         │
         ▼
┌─────────────────────────────────────────┐
│ State.record_failed_turn(               │
│   history_state,                         │
│   turn: N,                              │
│   assistant_content: "```clojure...",    │
│   user_feedback: "Error: ..."           │
│ )                                        │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Failed turns preserved in message:       │
│                                          │
│ {mission}                                │
│                                          │
│ ; Tool calls: ...                        │
│ ; Defined: ...                           │
│                                          │
│ ```clojure                               │
│ (def x (broken-code))   <-- full code   │
│ ```                                      │
│                                          │
│ Error: undefined symbol 'broken-code'   │
│                                          │
│ Turns left: 2                           │
└─────────────────────────────────────────┘
```

### Message Array Structure

```
When compression DISABLED (current behavior):
┌────────────────────────────────────────────────────────────┐
│ messages = [                                               │
│   %{role: :user, content: "mission"},                     │
│   %{role: :assistant, content: "```clojure (def x 1)```"},│
│   %{role: :user, content: "output\nTurn 2 of 5"},         │
│   %{role: :assistant, content: "```clojure (def y 2)```"},│
│   %{role: :user, content: "output\nTurn 3 of 5"},         │
│   ...                                                      │
│ ]                                                          │
└────────────────────────────────────────────────────────────┘

When compression ENABLED:
┌────────────────────────────────────────────────────────────┐
│ messages = [                                               │
│   %{role: :user, content: """                             │
│     {mission}                                              │
│                                                            │
│     ; Tool calls:                                          │
│     ;   search-users("admin")                              │
│     ; Defined: x = integer, sample: 1                     │
│     ; Defined: y = integer, sample: 2                     │
│                                                            │
│     Turns left: 3                                          │
│   """}                                                     │
│ ]                                                          │
│                                                            │
│ LLM responds -> messages becomes:                          │
│ [                                                          │
│   %{role: :user, content: "...compressed..."},            │
│   %{role: :assistant, content: "```clojure...```"}        │
│ ]                                                          │
│                                                            │
│ After processing -> reset to:                              │
│ [                                                          │
│   %{role: :user, content: "...updated compressed..."}     │
│ ]                                                          │
└────────────────────────────────────────────────────────────┘
```

---

## Key Clarifications

### Tool Result Visibility (TC-004 vs TC-006)

- Tool call list shows `name(args)` only — results NOT shown inline (TC-004)
- If result was captured via `(def x (tool/foo))`, it appears in **Defined** section
- If tool was called without `def` and `has_println == false`, show result type: `;   foo(args) -> list[5]`

### Failed Turns in Single USER Message

Failed turns are embedded in the USER message (not separate assistant/user pairs) but clearly labeled:

```
{mission}

; Tool calls: ...
; Defined: ...

---
Your previous attempt:
```clojure
(def x (broken-code))
```

Error: undefined symbol 'broken-code'
---

Turns left: 2
```

The `---` separators and "Your previous attempt:" label preserve context without breaking the single-USER-message structure.

### has_println is Global

If **any** turn used println, samples are omitted from **all** definitions. This is simpler than per-turn tracking and encourages intentional output.

---

## Edge Cases and Scenarios

### 1. Redefinition Within Same Turn

```clojure
(def x 1)
(def x 2)  ; x redefined
```

**Handling:** Only final value in summary:
```
; Defined: x = integer, sample: 2
```

**Implementation:** `State.update_success` merges definitions by name, latest wins.

### 2. Redefinition Across Turns

Turn 1: `(def x 1)`
Turn 2: `(def x [1 2 3])`

**Handling:** Summary shows only latest:
```
; Defined: x = list[3], sample: [1 2 3]
```

### 3. Samples vs Output (SAM-001, SAM-002)

**No println in turn:**
```
; Defined: users = list[5], sample: {:name "Alice" :email "..."}
```

**With println in turn:**
```
; Defined: users = list[5]
; Output:
Found 5 users
```

### 4. Ambiguous Namespace Reference (NS-007)

```clojure
;; If both tool/status and data/status exist:
(status)  ; -> runtime error
```

**Error:**
```elixir
{:error, {:ambiguous_reference,
  "Symbol 'status' exists in both tool/ and data/ namespaces. Use explicit namespace."}}
```

### 5. Consecutive Identical Tool Calls (TC-008)

```clojure
(tool/notify "Alice")
(tool/notify "Alice")
(tool/notify "Alice")
(tool/notify "Bob")
```

**Summary:**
```
; Tool calls:
;   notify("Alice") x3
;   notify("Bob")
```

### 6. Single-Shot Mode (SS-001)

```elixir
SubAgent.run(prompt, max_turns: 1, compress_history: true)
```

**Handling:** No compression needed - only one turn, option is effectively ignored.

### 7. FIFO Truncation (TRN-010, TC-007)

When limits exceeded:
- **Tool calls:** Keep most recent N, drop oldest
- **println:** Keep most recent N calls, drop oldest

```elixir
# Example: println_limit: 3, but 5 println calls made
printlns = [
  {"output1", 1}, {"output2", 1},  # Turn 1
  {"output3", 2},                  # Turn 2
  {"output4", 3}, {"output5", 3}   # Turn 3
]

# After truncation (keep last 3):
[{"output3", 2}, {"output4", 3}, {"output5", 3}]
```

### 8. Failed Turn Recovery

Turn 1: Success
Turn 2: Failure (syntax error)
Turn 3: Current

**Message structure:**
```
{mission}

; Tool calls:
;   from turn 1
; Defined:
;   from turn 1

```clojure
(def broken (invalid syntax  ; <-- Turn 2 full code
```

Error: Unexpected end of input

Turns left: 3
```

### 9. Empty Collections

```clojure
(def items [])
(def data {})
```

**Summary:**
```
; Defined: items = list[0]
; Defined: data = map[0]
```

### 10. Docstring with Semicolons (DEF-007)

```clojure
(def config "Config; see README; important" {})
```

**Summary (semicolons removed):**
```
; Defined: config - "Config see README important" = map[0]
```

---

## Testing Strategy

### Unit Tests

1. **TypeVocabulary** - Test all type labels
2. **Summary.format** - Test each section format
3. **MessageBuilder** - Test message construction
4. **Namespace** - Test resolution with all combinations
5. **DefinitionTracker** - Test docstring capture

### Integration Tests

1. **Multi-turn compression** - Full loop with compression enabled
2. **Failed turn preservation** - Verify failed turns kept full
3. **Limit enforcement** - Verify FIFO truncation
4. **Namespace resolution** - Test tool/, data/, bare names

### E2E Tests

1. **Real LLM** - Verify LLM can work with compressed format
2. **Complex workflow** - Multi-turn with tools, definitions, println

---

## Implementation Order

1. **Phase 1: Core Infrastructure**
   - `HistoryOpts` struct and normalization
   - `TypeVocabulary` module
   - `Summary` module (format only)

2. **Phase 2: State Tracking**
   - `HistoryState` struct
   - `EvalContext` changes for definition_meta
   - Step changes to include definition_meta

3. **Phase 3: Namespace Design**
   - `Namespace` module
   - Integration with eval symbol resolution
   - Error handling for ambiguous references

4. **Phase 4: Loop Integration**
   - `MessageBuilder` module
   - Loop modifications for compression path
   - Failed turn handling

5. **Phase 5: Testing & Polish**
   - Comprehensive test suite
   - E2E validation with real LLM
   - Documentation updates

---

## Files to Create/Modify

### New Files
- `lib/ptc_runner/sub_agent/history/opts.ex`
- `lib/ptc_runner/sub_agent/history/state.ex`
- `lib/ptc_runner/sub_agent/history/summary.ex`
- `lib/ptc_runner/sub_agent/history/message_builder.ex`
- `lib/ptc_runner/sub_agent/history/type_vocabulary.ex`
- `lib/ptc_runner/lisp/eval/namespace.ex`
- `test/ptc_runner/sub_agent/history/*_test.exs`

### Modified Files
- `lib/ptc_runner/sub_agent.ex` - Add `compress_history` option
- `lib/ptc_runner/sub_agent/loop.ex` - Compression integration
- `lib/ptc_runner/lisp/eval/context.ex` - Add definition_meta
- `lib/ptc_runner/lisp/eval/special_forms.ex` - Capture docstrings
- `lib/ptc_runner/step.ex` - Add definition_meta field
