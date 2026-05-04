defmodule UsageRulesTest do
  @moduledoc """
  Keeps `usage-rules.md` and `usage-rules/*.md` in sync with the actual API.

  Two layers:

  1. **Lint** — scans the markdown files for known-bad patterns the previous
     review caught. New anti-patterns are added as we find them.
  2. **Smoke** — runs the canonical contracts the docs claim. If `SubAgent.run/2`,
     `Lisp.run/2`, the LLM callback shape, or the tool-arity contract changes
     in ways that break these, the tests fail and the docs need an update.

  Lint failures point at a specific file:line; smoke failures point at the
  contract that drifted.

  ## Lint scope: fenced code blocks only

  We scan only ```` ``` ```` fenced blocks, not inline `backticks`. Reason:
  prose calls out anti-patterns by name (e.g. `` `&MyApp.list/0` will crash ``)
  and scanning inline code would false-positive on those deliberate warnings.
  If a real anti-pattern slips into prose, a doc reviewer will catch it; the
  lint's job is the executable-looking examples in fences, where copy-paste
  rot is most damaging.
  """

  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Compiler

  @rules_root Path.expand("..", __DIR__)
  @rules_files [
    "usage-rules.md",
    "usage-rules/subagent.md",
    "usage-rules/ptc-lisp.md",
    "usage-rules/llm-setup.md",
    "usage-rules/testing.md"
  ]

  describe "lint: usage-rules anti-patterns" do
    test "no bare-reference tool examples with arity != 1" do
      # &MyApp.foo/0, /2, /3+ are wrong — tools must be arity-1.
      # &MyApp.foo/1 is allowed (it already takes a map).
      pattern = ~r/&[A-Z][\w.]*\/(?:[023456789]|\d{2,})/

      for file <- @rules_files do
        assert_no_match(file, pattern, """
        Found bare function reference with non-1 arity. Tool functions must be
        arity-1 taking a string-keyed map. Wrap as `fn _args -> Mod.fun() end`
        or `fn %{"k" => v} -> Mod.fun(v) end`.
        """)
      end
    end

    test "no references to non-existent step.trace field" do
      # Step has :turns, :journal, :child_traces, :trace_id, :parent_trace_id —
      # but no top-level :trace. Match common alternative forms too.
      pattern = ~r/(?:\bstep\.trace\b|step\[:trace\]|%Step\{[^}]*\btrace:|\bStep\.trace\b)/

      for file <- @rules_files do
        assert_no_match(file, pattern, """
        `step.trace` does not exist on `%PtcRunner.Step{}`. Use `step.turns`
        for execution history, or `step.trace_id` / `step.parent_trace_id`
        for telemetry correlation.
        """)
      end
    end

    test "no obsolete (call \"name\" ...) PTC-Lisp form in examples" do
      # Modern form is (tool/name ...). The (call "...") form predates the
      # tool/ namespace and is no longer the documented contract.
      pattern = ~r/\(call\s+"[\w-]+"/

      for file <- @rules_files do
        assert_no_match(file, pattern, """
        `(call "name" ...)` is the legacy tool form. Use `(tool/name ...)`.
        """)
      end
    end

    test "no implicit data/<tool-name> binding claim" do
      # Tool results are NOT auto-bound to data/<name>. Programs must capture
      # via (def x (tool/...)) or compose inline.
      #
      # This is a narrow guard for the historical bug (`data/results` after a
      # `(call "search" ...)`); a generic `data/<word>` regex would false-fire
      # on legitimate context bindings like `data/items`. Add new specific
      # tool-name false-binding patterns here as you spot them.
      pattern = ~r/data\/(?:results|search_results|tool_results)\b/

      for file <- @rules_files do
        assert_no_match(file, pattern, """
        Tool results are not automatically bound to `data/<name>`. Use
        `(def results (tool/...))` or compose inline.
        """)
      end
    end
  end

  describe "smoke: contracts the docs depend on" do
    test "SubAgent.run/2 with arity-1 tool + map arg returns the program result" do
      # Mirrors usage-rules/subagent.md "Tools — accepted shapes" + "Result shape".
      llm = fn _ -> {:ok, ~S|(return {:doubled (tool/double {:n data/n})})|} end

      tools = %{
        "double" => fn %{"n" => n} -> n * 2 end
      }

      {:ok, step} =
        SubAgent.run("Double {{n}}",
          signature: "(n :int) -> {doubled :int}",
          context: %{n: 21},
          tools: tools,
          llm: llm
        )

      # Public Step fields the docs reference must exist.
      assert step.return["doubled"] == 42
      assert is_list(step.turns)
      assert is_list(step.tool_calls)
      assert is_nil(step.fail)
      refute Map.has_key?(step, :trace)
    end

    test "Lisp.run/2 executes without an LLM" do
      # Mirrors usage-rules/ptc-lisp.md "Basic shape".
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(->> data/items (filter :active) (count))|,
          context: %{items: [%{active: true}, %{active: false}, %{active: true}]}
        )

      assert step.return == 2
    end

    test "Lisp.run/2 memory contract: top-level map passes through unchanged" do
      # Mirrors usage-rules/ptc-lisp.md "Memory contract".
      # No implicit merge of returned maps into memory; persistence is via def.
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|{:foo 1 :bar 2}|,
          context: %{}
        )

      assert step.return == %{foo: 1, bar: 2}
      # The map is NOT silently merged into memory.
      assert step.memory == %{} or not Map.has_key?(step.memory, :foo)
    end

    test "Lisp.run/2 (def x v) persists v in memory" do
      # Counter-example to above: explicit def is the only persistence path.
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(def x 42) x|,
          context: %{}
        )

      assert step.return == 42
      assert step.memory[:x] == 42
    end

    test "LLM callback may return a raw string OR a normalized map" do
      # Mirrors usage-rules/llm-setup.md "Custom callback" output shapes.
      raw = fn _ -> {:ok, "(+ 1 2)"} end
      normalized = fn _ -> {:ok, %{content: "(+ 1 2)", tokens: %{input: 1, output: 1}}} end

      for llm <- [raw, normalized] do
        {:ok, step} = SubAgent.run("Q", max_turns: 1, llm: llm)
        assert step.return == 3
      end
    end

    test "LLM callback tokens reach step.usage" do
      # Mirrors usage-rules/llm-setup.md token shape — the canonical map form
      # carries token accounting through the loop into the final Step.
      llm = fn _ ->
        {:ok, %{content: "(+ 1 2)", tokens: %{input: 7, output: 13}}}
      end

      {:ok, step} = SubAgent.run("Q", max_turns: 1, llm: llm)
      assert is_map(step.usage)
      # Either the keys round-trip directly or are mapped to canonical names.
      # Don't pin exact keys (that's adapter-specific), just assert they exist.
      assert map_size(step.usage) > 0
    end

    test "scripted multi-turn LLM: tool result captured via (def ...) lands in memory" do
      # Mirrors usage-rules/testing.md scripted-callback example.
      counter = start_supervised!({Agent, fn -> 0 end})

      programs = [
        ~S|(def results (tool/search {:query "test"}))|,
        ~S|(return {:count (count results)})|
      ]

      llm = fn _ ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        {:ok, Enum.at(programs, i, List.last(programs))}
      end

      {:ok, step} =
        SubAgent.run("Search and count",
          signature: "{count :int}",
          tools: %{"search" => fn _args -> [%{id: 1}, %{id: 2}] end},
          llm: llm
        )

      assert step.return["count"] == 2
      # Memory persistence claim from the docs: (def x ...) survives across turns.
      assert step.memory[:results] == [%{id: 1}, %{id: 2}]
    end

    test "single-shot mode: max_turns: 1, no tools, no retry_turns" do
      # Mirrors usage-rules/subagent.md "Execution modes" — single-shot
      # returns the last expression directly without (return ...).
      llm = fn _ -> {:ok, "(* 6 7)"} end

      {:ok, step} = SubAgent.run("Compute", max_turns: 1, llm: llm)
      assert step.return == 42
    end

    test "SubAgent.compile/2 happy path: produces a callable that returns a Step" do
      # Mirrors usage-rules/subagent.md "Composition" — the documented
      # success contract for compile/2.
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      llm = fn _ -> {:ok, ~S|(return {:result (tool/double {:n data/n})})|} end

      assert {:ok, compiled} = Compiler.compile(agent, llm: llm, sample: %{n: 5})
      assert is_function(compiled.execute, 2)

      step = compiled.execute.(%{n: 21}, [])
      assert %PtcRunner.Step{} = step
      assert step.return.result == 42
    end

    test "SubAgent.compile/2 rejects multi-turn or text-mode agents" do
      # Mirrors usage-rules/subagent.md "Composition" — compile/2 is
      # constrained to max_turns: 1 + output: :ptc_lisp.
      multi_turn = SubAgent.new(prompt: "x", max_turns: 5)
      text_mode = SubAgent.new(prompt: "x", max_turns: 1, output: :text)
      llm = fn _ -> {:ok, ""} end

      assert_raise ArgumentError, ~r/single-shot|max_turns/, fn ->
        Compiler.compile(multi_turn, llm: llm)
      end

      assert_raise ArgumentError, ~r/text|ptc_lisp|output/, fn ->
        Compiler.compile(text_mode, llm: llm)
      end
    end

    test "SubAgent.as_tool/2 raises when description is missing" do
      # Mirrors usage-rules/subagent.md "Composition" — as_tool requires
      # either opts[:description] or agent.description.
      no_desc = SubAgent.new(prompt: "x")

      assert_raise ArgumentError, ~r/description/, fn ->
        SubAgent.as_tool(no_desc)
      end

      tool = SubAgent.as_tool(no_desc, description: "ok")
      assert tool.description == "ok"
    end
  end

  # Match anti-patterns only inside fenced code blocks. See moduledoc for why
  # inline backticks aren't scanned.
  defp assert_no_match(file, pattern, hint) do
    path = Path.join(@rules_root, file)
    code_blocks = path |> File.read!() |> extract_fenced_blocks()

    hits =
      Enum.flat_map(code_blocks, fn {line, block} ->
        case Regex.scan(pattern, block) do
          [] -> []
          matches -> Enum.map(matches, fn m -> {line, hd(m)} end)
        end
      end)

    case hits do
      [] ->
        :ok

      _ ->
        details =
          Enum.map_join(hits, "\n", fn {line, m} -> "  - #{file}:~#{line}: #{inspect(m)}" end)

        flunk("""
        Anti-pattern matched in code blocks of #{file}.

        Pattern: #{inspect(pattern)}
        Hits:
        #{details}

        Why this matters:
        #{hint}
        """)
    end
  end

  # Returns [{starting_line_number, block_content}, ...] for every
  # ```...``` fenced block in the markdown.
  defp extract_fenced_blocks(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil, []}, fn {line, lineno}, {blocks, current, current_lines} ->
      cond do
        current == nil and String.starts_with?(line, "```") ->
          {blocks, lineno, []}

        current != nil and String.starts_with?(line, "```") ->
          {[{current, Enum.join(Enum.reverse(current_lines), "\n")} | blocks], nil, []}

        current != nil ->
          {blocks, current, [line | current_lines]}

        true ->
          {blocks, current, current_lines}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
