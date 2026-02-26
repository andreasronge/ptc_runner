# Function Passing Between SubAgents — Implementation Guide

## Overview

Two mechanisms for passing PTC-Lisp closures between agents:

- **Phase 1 — Implicit inheritance for `:self` tools**: Parent's closures auto-inject into child's namespace. Child prompt shows signatures + docstrings.
- **Phase 2 — Explicit `:fn` params for any tool**: Signatures declare `:fn` parameters. Parent passes specific closures. Child sees them in `data/` with contract info.

Both use direct AST injection — closure tuples `{:closure, params, body, env, history, meta}` pass as-is. No serialization.

## Key Safety Properties

- **Prompt never leaks source**: Renderers read only `params`, `meta.docstring`, `meta.return_type`. Never `body` or `env`.
- **Immutable**: BEAM guarantees parent closures can't be mutated by child.
- **`inherited_ns` is set-once**: Assigned at child start, never updated across turns. It's a rendering hint.
- **Depth accumulates naturally**: At depth N, `state.memory` = inherited + own. `extract_closures(state.memory)` passes all to N+1.
- **Non-`:self` tools get nothing**: `self_tool?` returns false → no implicit inheritance.

## Verified: No eval changes needed

`(data/mapper_fn item)` already works. The chain:
1. `{:data, key}` resolves to closure tuple via `flex_get(ctx, key)` (eval.ex:186)
2. `{:call, ...}` dispatches to `Apply.apply_fun/4` (eval.ex:361)
3. `do_apply_fun({:closure, ...}, args, ...)` matches and calls `execute_closure` (apply.ex:79-89)

---

## Phase 1: Implicit Inheritance for `:self` Tools

13 files touched. Changes listed in dependency order.

---

### 1.1 ToolNormalizer — detect `:self`, extract closures, pass to child

**File**: `lib/ptc_runner/sub_agent/loop/tool_normalizer.ex`

**CHANGE A** — In `wrap_sub_agent_tool/3` (line 353), add inherited_ns extraction between the LLM resolution and run_opts building:

BEFORE (lines 362-372):
```elixir
      # Build run options (without trace_context - that's handled by TraceLog)
      run_opts =
        [
          llm: resolved_llm,
          llm_registry: state.llm_registry,
          context: args,
          _nesting_depth: state.nesting_depth + 1,
          _remaining_turns: state.remaining_turns,
          _mission_deadline: state.mission_deadline
        ]
        |> maybe_add_opt(:max_heap, state[:max_heap])
```

AFTER:
```elixir
      # For :self tools, pass parent's closures so child can call them directly
      inherited_ns =
        if self_tool?(tool, state), do: extract_closures(state.memory), else: nil

      # Build run options (without trace_context - that's handled by TraceLog)
      run_opts =
        [
          llm: resolved_llm,
          llm_registry: state.llm_registry,
          context: args,
          _nesting_depth: state.nesting_depth + 1,
          _remaining_turns: state.remaining_turns,
          _mission_deadline: state.mission_deadline
        ]
        |> maybe_add_opt(:max_heap, state[:max_heap])
        |> maybe_add_opt(:_inherited_ns, inherited_ns)
```

**CHANGE B** — Add two private functions after `wrap_sub_agent_tool/3` (after line 381):

```elixir
  # A :self tool points to the same agent struct as the parent
  defp self_tool?(%SubAgentTool{agent: child_agent}, state) do
    state[:parent_agent] != nil and state[:parent_agent] == child_agent
  end

  # Extract non-internal closures from memory for inheritance
  defp extract_closures(memory) when is_map(memory) do
    memory
    |> Enum.filter(fn
      {name, {:closure, _, _, _, _, _}} ->
        name_str = Atom.to_string(name)
        not String.starts_with?(name_str, "_") and not String.starts_with?(name_str, "__ptc_")

      _ ->
        false
    end)
    |> Map.new()
  end

  defp extract_closures(_), do: %{}
```

**WHY**: `state[:parent_agent]` is set in Change 1.3. `resolve_self_tools/2` in SubAgent stores the same agent struct in `SubAgentTool.agent`, so `==` comparison matches. `extract_closures` filters to closures only and excludes internal keys (`_` prefix, `__ptc_` prefix).

---

### 1.2 Loop.run — extract `_inherited_ns` from opts

**File**: `lib/ptc_runner/sub_agent/loop.ex`

**CHANGE A** — After line 144 (`tool_cache = ...`), add extraction:

BEFORE (lines 144-147):
```elixir
    tool_cache = Keyword.get(opts, :tool_cache, %{})

    # Extract Lisp.run resource limits (propagated to child agents)
    max_heap = Keyword.get(opts, :max_heap)
```

AFTER:
```elixir
    tool_cache = Keyword.get(opts, :tool_cache, %{})

    # Closures inherited from parent agent via :self tool
    inherited_ns = Keyword.get(opts, :_inherited_ns) || %{}

    # Extract Lisp.run resource limits (propagated to child agents)
    max_heap = Keyword.get(opts, :max_heap)
```

**CHANGE B** — Add `inherited_ns` to `run_opts` map (line 171-191):

BEFORE (lines 189-191):
```elixir
          journal: journal,
          tool_cache: tool_cache
        }
```

AFTER:
```elixir
          journal: journal,
          tool_cache: tool_cache,
          inherited_ns: inherited_ns
        }
```

---

### 1.3 Loop.do_run — seed memory, add parent_agent and inherited_ns to state

**File**: `lib/ptc_runner/sub_agent/loop.ex`

**CHANGE A** — In `do_run/2`, update `initial_state` (line 236). Three fields change:

BEFORE (lines 244-245):
```elixir
      memory: %{},
      last_fail: nil,
```

AFTER:
```elixir
      memory: run_opts.inherited_ns,
      last_fail: nil,
```

**CHANGE B** — Add two new fields. After line 298 (`agent_name: agent.name`):

BEFORE (lines 297-299):
```elixir
      # Agent name for TraceTree display
      agent_name: agent.name
    }
```

AFTER:
```elixir
      # Agent name for TraceTree display
      agent_name: agent.name,
      # Parent agent struct for :self tool detection in ToolNormalizer
      parent_agent: agent,
      # Inherited closures from parent (immutable, for prompt rendering only)
      inherited_ns: run_opts.inherited_ns
    }
```

**NOTE**: `inherited_ns` is never updated in `build_continuation_state/5`. It stays constant across all turns — it's only used by the prompt renderer to know which functions are inherited vs self-defined.

---

### 1.4 Loop — thread inherited_ns into first user message

**File**: `lib/ptc_runner/sub_agent/loop.ex`

**CHANGE A** — Update call site (line 234):

BEFORE:
```elixir
    first_user_message = build_first_user_message(agent, run_opts, expanded_prompt)
```

AFTER:
```elixir
    first_user_message =
      build_first_user_message(agent, run_opts, expanded_prompt, run_opts.inherited_ns)
```

**CHANGE B** — Update function signature and body (lines 1051-1056):

BEFORE:
```elixir
  defp build_first_user_message(agent, run_opts, expanded_mission) do
    context_prompt =
      SystemPrompt.generate_context(agent,
        context: run_opts.context,
        received_field_descriptions: run_opts.received_field_descriptions
      )
```

AFTER:
```elixir
  defp build_first_user_message(agent, run_opts, expanded_mission, inherited_ns) do
    context_prompt =
      SystemPrompt.generate_context(agent,
        context: run_opts.context,
        received_field_descriptions: run_opts.received_field_descriptions,
        inherited_ns: inherited_ns
      )
```

---

### 1.5 Loop — thread inherited_ns into compression

**File**: `lib/ptc_runner/sub_agent/loop.ex`

**CHANGE** — In `build_compressed_messages` (line 1117), add to compression_opts:

BEFORE:
```elixir
      |> Keyword.put(:field_descriptions, agent.field_descriptions)
```

AFTER:
```elixir
      |> Keyword.put(:field_descriptions, agent.field_descriptions)
      |> Keyword.put(:inherited_ns, state.inherited_ns)
```

---

### 1.6 SystemPrompt.generate_context — pass inherited_ns to Namespace

**File**: `lib/ptc_runner/sub_agent/system_prompt.ex`

**CHANGE** — At line 198, extract inherited_ns and pass it (lines 198-221):

BEFORE:
```elixir
  def generate_context(%SubAgent{} = agent, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    received_field_descriptions = Keyword.get(opts, :received_field_descriptions)
```

AFTER:
```elixir
  def generate_context(%SubAgent{} = agent, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    received_field_descriptions = Keyword.get(opts, :received_field_descriptions)
    inherited_ns = Keyword.get(opts, :inherited_ns, %{})
```

And the Namespace.render call (lines 213-221):

BEFORE:
```elixir
    namespace_content =
      Namespace.render(%{
        tools: tools,
        data: context,
        field_descriptions: all_field_descriptions,
        context_signature: context_signature,
        memory: %{},
        has_println: false
      })
```

AFTER:
```elixir
    namespace_content =
      Namespace.render(%{
        tools: tools,
        data: context,
        field_descriptions: all_field_descriptions,
        context_signature: context_signature,
        memory: inherited_ns,
        inherited_ns: inherited_ns,
        has_println: false
      })
```

**WHY `memory: inherited_ns`?** On turn 1, there are no self-defined entries yet. But inherited closures need to appear in the user/ section. Passing them as `memory` makes them visible. Passing the same map as `inherited_ns` tells the renderer to put them under the "inherited" header.

**NOTE**: The second `Namespace.render` call at line 396 (text mode) doesn't need changes — text mode agents don't use `:self` tools with PTC-Lisp closures.

---

### 1.7 Namespace.render — forward inherited_ns to User.render

**File**: `lib/ptc_runner/sub_agent/namespace.ex`

**CHANGE** — At line 54:

BEFORE:
```elixir
    user_opts = [has_println: config[:has_println] || false] ++ sample_opts
```

AFTER:
```elixir
    user_opts =
      [has_println: config[:has_println] || false, inherited_ns: config[:inherited_ns] || %{}] ++
        sample_opts
```

---

### 1.8 Namespace.User — split inherited vs own, separate headers

**File**: `lib/ptc_runner/sub_agent/namespace/user.ex`

This is the biggest change. Replace `render/2` and add helper functions.

**CHANGE A** — Replace `render/2` (lines 56-69):

BEFORE:
```elixir
  def render(memory, opts) do
    {functions, values} = partition_memory(memory)

    # Return nil if no informative entries after filtering
    if functions == [] and values == [] do
      nil
    else
      function_lines = format_functions(functions)
      value_lines = format_values(values, opts)

      [";; === user/ (your prelude) ===" | function_lines ++ value_lines]
      |> Enum.join("\n")
    end
  end
```

AFTER:
```elixir
  def render(memory, opts) do
    inherited_ns = Keyword.get(opts, :inherited_ns, %{})
    {inherited_entries, own_memory} = split_inherited(memory, inherited_ns)

    inherited_section = render_inherited_section(inherited_entries)
    own_section = render_own_section(own_memory, opts)

    case {inherited_section, own_section} do
      {nil, nil} -> nil
      {inh, nil} -> inh
      {nil, own} -> own
      {inh, own} -> inh <> "\n\n" <> own
    end
  end
```

**CHANGE B** — Add these private functions (before `partition_memory`):

```elixir
  # Separate inherited entries from self-defined ones
  defp split_inherited(memory, inherited_ns) when map_size(inherited_ns) == 0 do
    {[], memory}
  end

  defp split_inherited(memory, inherited_ns) do
    inherited_keys = MapSet.new(Map.keys(inherited_ns))

    {inherited, own} =
      memory
      |> Enum.split_with(fn {name, _} -> MapSet.member?(inherited_keys, name) end)

    {inherited, Map.new(own)}
  end

  # Inherited section: signature + docstring only, never source code
  defp render_inherited_section([]), do: nil

  defp render_inherited_section(entries) do
    closures =
      entries
      |> Enum.filter(fn {_, v} -> closure?(v) end)
      |> Enum.sort_by(&elem(&1, 0))

    if closures == [] do
      nil
    else
      lines = format_functions(closures)
      [";; === user/ (inherited) ===" | lines] |> Enum.join("\n")
    end
  end

  # Own section: existing behavior for self-defined entries
  defp render_own_section(memory, _opts) when map_size(memory) == 0, do: nil

  defp render_own_section(memory, opts) do
    {functions, values} = partition_memory(memory)

    if functions == [] and values == [] do
      nil
    else
      function_lines = format_functions(functions)
      value_lines = format_values(values, opts)

      [";; === user/ (your prelude) ===" | function_lines ++ value_lines]
      |> Enum.join("\n")
    end
  end
```

**CHANGE C** — Update doctests (lines 25-51). Existing doctests pass `inherited_ns: %{}` implicitly (default) so they remain correct. Add new doctests:

```elixir
      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, inherited_ns: %{double: closure})
      ";; === user/ (inherited) ===\\n(double [x])                  ; \\"Doubles x\\""

      iex> inherited = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{f: inherited, count: 5}, inherited_ns: %{f: inherited})
      ";; === user/ (inherited) ===\\n(f [x])\\n\\n;; === user/ (your prelude) ===\\ncount                         ; = integer, sample: 5"
```

---

### 1.9 Compression — pass inherited_ns through

**File**: `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex`

**CHANGE** — At line 109:

BEFORE:
```elixir
    namespaces =
      Namespace.render(%{
        tools: tools,
        data: data,
        memory: memory,
        has_println: has_println,
        sample_limit: sample_limit,
        sample_printable_limit: sample_printable_limit
      })
```

AFTER:
```elixir
    namespaces =
      Namespace.render(%{
        tools: tools,
        data: data,
        memory: memory,
        inherited_ns: opts[:inherited_ns] || %{},
        has_println: has_println,
        sample_limit: sample_limit,
        sample_printable_limit: sample_printable_limit
      })
```

---

## Phase 2: Explicit `:fn` Params

---

### 2.1 Signature parser — add `:fn` type

**File**: `lib/ptc_runner/sub_agent/signature/parser.ex`

**CHANGE A** — Add `"fn"` to type_keyword choices (line 43). Insert before `string("any")`:

BEFORE:
```elixir
    |> choice([
      string("string"),
      string("int"),
      string("float"),
      string("bool"),
      string("keyword"),
      string("map"),
      string("any")
    ])
```

AFTER:
```elixir
    |> choice([
      string("string"),
      string("int"),
      string("float"),
      string("bool"),
      string("keyword"),
      string("map"),
      string("fn"),
      string("any")
    ])
```

**CHANGE B** — Add to `@valid_types` (line 182):

BEFORE:
```elixir
  @valid_types ~w(string int float bool keyword map any)
```

AFTER:
```elixir
  @valid_types ~w(string int float bool keyword map fn any)
```

---

### 2.2 Signature type spec and JSON schema

**File**: `lib/ptc_runner/sub_agent/signature.ex`

**CHANGE A** — Add `:fn` to `@type type` (line 40). Insert before `{:optional, type()}`:

BEFORE:
```elixir
        | :map
        | {:optional, type()}
```

AFTER:
```elixir
        | :map
        | :fn
        | {:optional, type()}
```

**CHANGE B** — Add JSON schema clause (after line 208):

BEFORE:
```elixir
  def type_to_json_schema(:map), do: %{"type" => "object"}
```

AFTER:
```elixir
  def type_to_json_schema(:map), do: %{"type" => "object"}
  def type_to_json_schema(:fn), do: %{"type" => "object"}
```

---

### 2.3 Signature validator — validate `:fn` as closure

**File**: `lib/ptc_runner/sub_agent/signature/validator.ex`

**CHANGE** — Add clauses after the `:any` clause (after line 84):

```elixir
  # Function type - must be a closure tuple or nil
  defp validate_type({:closure, _, _, _, _, _}, :fn, _path), do: []
  defp validate_type(nil, :fn, _path), do: []

  defp validate_type(data, :fn, path) do
    [error_at(path, "expected fn (closure), got #{type_name(data)}")]
  end
```

---

### 2.4 Signature renderer

**File**: `lib/ptc_runner/sub_agent/signature/renderer.ex`

**CHANGE** — Add after line 62:

BEFORE:
```elixir
  def render_type(:map), do: ":map"
```

AFTER:
```elixir
  def render_type(:map), do: ":map"
  def render_type(:fn), do: ":fn"
```

---

### 2.5 Data namespace — render closures with signature + docstring

**File**: `lib/ptc_runner/sub_agent/namespace/data.ex`

**CHANGE A** — Add a clause for closures BEFORE the existing `format_entry/5` (before line 67):

```elixir
  # Closure values in data/ — render as callable function with params + docstring
  defp format_entry(name, {:closure, params, _, _, _, meta}, _param_types, _field_descs, _opts) do
    name_str = to_string(name)
    params_str = format_closure_params(params)
    padded_name = String.pad_trailing("data/#{name_str}", @name_width)
    docstring = Map.get(meta, :docstring)
    doc_part = if docstring, do: " -- #{docstring}", else: ""
    "#{padded_name}; fn [#{params_str}]#{doc_part}"
  end
```

**CHANGE B** — Add helper functions (before `format_sample`):

```elixir
  defp format_closure_params({:variadic, leading, rest}) do
    leading_str = Enum.map_join(leading, " ", &extract_param_name/1)
    rest_str = "& #{extract_param_name(rest)}"
    if leading_str == "", do: rest_str, else: "#{leading_str} #{rest_str}"
  end

  defp format_closure_params(params) when is_list(params) do
    Enum.map_join(params, " ", &extract_param_name/1)
  end

  defp extract_param_name({:var, name}), do: Atom.to_string(name)
  defp extract_param_name(_), do: "_"
```

Produces output like:
```
data/mapper_fn                ; fn [line] -- Extracts timestamp and error code.
data/compare_fn               ; fn [a b]
```

---

## Tests

### Phase 1 Integration Test

**File**: `test/ptc_runner/sub_agent/inherited_ns_test.exs` (new)

```elixir
defmodule PtcRunner.SubAgent.InheritedNsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "implicit closure inheritance via :self" do
    test "child can call parent's defn" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: _} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        code =
          if n == 1 do
            "(defn double [x] (* x 2))\n(return (tool/sub {:value 21}))"
          else
            "(return (double data/value))"
          end

        {:ok, "```clojure\n#{code}\n```"}
      end

      agent =
        SubAgent.new(
          prompt: "Process {{value}}",
          signature: "(value :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 3,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{value: 0})
      assert step.return == 42
    end

    test "only closures are inherited, not plain values" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        if n == 1 do
          code = "(def counter 99)\n(defn id [x] x)\n(return (tool/sub {:v 1}))"
          {:ok, "```clojure\n#{code}\n```"}
        else
          # child: id should work, counter should NOT be accessible
          user_msg = Enum.find(messages, &(&1.role == :user))
          # Verify: inherited section has id but not counter
          assert user_msg.content =~ "(id [x])"
          refute user_msg.content =~ "counter"

          {:ok, "```clojure\n(return (id data/v))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(v :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 3,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{v: 0})
      assert step.return == 1
    end

    test "non-self SubAgentTool does not inherit" do
      parent_call_count = :counters.new(1, [:atomics])

      child_agent =
        SubAgent.new(
          prompt: "Return {{n}} doubled",
          signature: "(n :int) -> :int",
          max_turns: 1
        )

      parent_llm = fn %{messages: _} ->
        n = :counters.get(parent_call_count, 1) + 1
        :counters.put(parent_call_count, 1, n)

        {:ok, "```clojure\n(defn helper [x] x)\n(return (tool/child {:n 5}))\n```"}
      end

      child_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        # Verify: no inherited section
        refute user_msg.content =~ "inherited"
        refute user_msg.content =~ "helper"
        {:ok, "```clojure\n(* data/n 2)\n```"}
      end

      parent =
        SubAgent.new(
          prompt: "Use child",
          signature: "(n :int) -> :int",
          tools: %{"child" => SubAgent.as_tool(child_agent)},
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(parent, llm: parent_llm, context: %{n: 0})
      # child_llm needs to be in registry or bound — adjust based on your as_tool API
    end

    test "docstrings appear in inherited section" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        if n == 1 do
          code = """
          (defn parse-line "Extracts fields from a log line" [s] s)
          (return (tool/sub {:data "test"}))
          """
          {:ok, "```clojure\n#{code}\n```"}
        else
          user_msg = Enum.find(messages, &(&1.role == :user))
          assert user_msg.content =~ "inherited"
          assert user_msg.content =~ "parse-line"
          assert user_msg.content =~ "Extracts fields from a log line"
          {:ok, "```clojure\n(return (parse-line data/data))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(data :string) -> :string",
          tools: %{"sub" => :self},
          max_turns: 3,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{data: "x"})
      assert step.return == "test"
    end

    test "internal keys are not inherited" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        if n == 1 do
          code = "(defn _private [x] x)\n(defn public [x] x)\n(return (tool/sub {:v 1}))"
          {:ok, "```clojure\n#{code}\n```"}
        else
          user_msg = Enum.find(messages, &(&1.role == :user))
          assert user_msg.content =~ "public"
          refute user_msg.content =~ "_private"
          {:ok, "```clojure\n(return (public data/v))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(v :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 3,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{v: 0})
      assert step.return == 1
    end
  end
end
```

### Phase 1 Unit Tests

**File**: `test/ptc_runner/sub_agent/namespace/user_test.exs` (add to existing or create)

```elixir
describe "inherited namespace rendering" do
  test "inherited functions render under separate header" do
    closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x"}}
    result = User.render(%{double: closure, count: 5}, inherited_ns: %{double: closure})

    assert result =~ ";; === user/ (inherited) ==="
    assert result =~ ~s|(double [x])|
    assert result =~ ~s|"Doubles x"|
    assert result =~ ";; === user/ (your prelude) ==="
    assert result =~ "count"
  end

  test "only inherited section when no own entries" do
    closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
    result = User.render(%{f: closure}, inherited_ns: %{f: closure})

    assert result =~ ";; === user/ (inherited) ==="
    refute result =~ ";; === user/ (your prelude) ==="
  end

  test "no inherited section when inherited_ns is empty" do
    closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
    result = User.render(%{f: closure}, [])

    refute result =~ "inherited"
    assert result =~ ";; === user/ (your prelude) ==="
  end

  test "child override moves function from inherited to own" do
    parent_closure = {:closure, [{:var, :x}], {:lit, 1}, %{}, [], %{}}
    child_closure = {:closure, [{:var, :x}], {:lit, 2}, %{}, [], %{}}
    # After child redefines, memory has child's version but inherited_ns has parent's
    result = User.render(%{f: child_closure}, inherited_ns: %{f: parent_closure})

    # f is in inherited_ns keys, so it renders under inherited header
    # (using the current value from memory, which is child's version)
    assert result =~ ";; === user/ (inherited) ==="
    assert result =~ "(f [x])"
  end
end
```

### Phase 2 Unit Tests

**File**: `test/ptc_runner/sub_agent/signature/parser_test.exs` (add to existing)

```elixir
test "parses :fn type" do
  assert {:ok, {:signature, [{"data", {:list, :any}}, {"mapper", :fn}], {:list, :string}}} =
           Signature.parse("(data [:any], mapper :fn) -> [:string]")
end

test "parses optional :fn type" do
  assert {:ok, {:signature, [{"filter", {:optional, :fn}}], :any}} =
           Signature.parse("(filter :fn?) -> :any")
end
```

**File**: `test/ptc_runner/sub_agent/signature/validator_test.exs` (add to existing)

```elixir
test "validates closure for :fn type" do
  closure = {:closure, [{:var, :x}], {:var, :x}, %{}, [], %{}}
  assert :ok = Validator.validate(closure, :fn)
end

test "rejects non-closure for :fn type" do
  assert {:error, _} = Validator.validate("not a fn", :fn)
end

test "accepts nil for :fn type" do
  assert :ok = Validator.validate(nil, :fn)
end
```

**File**: `test/ptc_runner/sub_agent/namespace/data_test.exs` (add to existing)

```elixir
test "renders closure in data/ with signature and docstring" do
  closure = {:closure, [{:var, :line}], nil, %{}, [], %{docstring: "Parse a log line"}}
  result = Data.render(%{mapper_fn: closure})
  assert result =~ "data/mapper_fn"
  assert result =~ "fn [line]"
  assert result =~ "Parse a log line"
end

test "renders closure in data/ without docstring" do
  closure = {:closure, [{:var, :a}, {:var, :b}], nil, %{}, [], %{}}
  result = Data.render(%{compare: closure})
  assert result =~ "fn [a b]"
  refute result =~ "--"
end
```

---

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix precommit   # all of the above plus more
```

---

## File Summary

| Change | File | What |
|--------|------|------|
| 1.1 | `loop/tool_normalizer.ex` | `self_tool?`, `extract_closures`, pass `_inherited_ns` |
| 1.2 | `loop.ex` (run) | Extract `_inherited_ns` from opts, add to `run_opts` |
| 1.3 | `loop.ex` (do_run) | Seed `memory`, add `parent_agent` + `inherited_ns` to state |
| 1.4 | `loop.ex` (build_first_user_message) | Thread `inherited_ns` to SystemPrompt |
| 1.5 | `loop.ex` (build_compressed_messages) | Add `inherited_ns` to compression_opts |
| 1.6 | `system_prompt.ex` | Extract `inherited_ns`, pass to Namespace.render |
| 1.7 | `namespace.ex` | Forward `inherited_ns` to User.render |
| 1.8 | `namespace/user.ex` | Split inherited/own rendering, two headers |
| 1.9 | `compression/single_user_coalesced.ex` | Pass `inherited_ns` to Namespace.render |
| 2.1 | `signature/parser.ex` | Add `:fn` to type choices + `@valid_types` |
| 2.2 | `signature.ex` | Add `:fn` to type spec + JSON schema |
| 2.3 | `signature/validator.ex` | Validate `:fn` as closure or nil |
| 2.4 | `signature/renderer.ex` | `render_type(:fn)` |
| 2.5 | `namespace/data.ex` | Render closure entries with `fn [params] -- docstring` |
