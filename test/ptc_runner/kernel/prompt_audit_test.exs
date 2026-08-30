defmodule PtcRunner.Kernel.PromptAuditTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @ordinary_artifact "test/fixtures/prompts/agent-prompt-ordinary-turn.txt"
  @final_artifact "test/fixtures/prompts/agent-prompt-final-turn.txt"

  describe "segments" do
    test "rejoins to its input exactly for every recognised rendering" do
      for prompt <- [ordinary(), final(), empty_api(), no_docstring()] do
        assert rejoined(prompt) == prompt
      end
    end

    test "rejoins to its input exactly for an unrecognised one" do
      for prompt <- ["", "a manifest's own prompt", "PTC_AGENT_PROMPT_V1\n\nnothing else"] do
        assert rejoined(prompt) == prompt
      end
    end

    test "the current empty-API branch retains its explanatory sentence" do
      assert labels(empty_api()) ==
               ~w(marker protocol language examples api-heading api-empty)
    end

    test "current result-contract suffixes are recognised and rejoin exactly" do
      result =
        final() <>
          "\nApplication result contract\n" <>
          "The host validates the exact value passed to (return value).\nType: :string\n"

      phased =
        result <>
          "\nCurrent phase return contract (draft)\n" <>
          "A valid explicit (return value) is required to transition to the next phase.\n" <>
          "Type: :string\n"

      assert List.last(labels(result)) == "result-contract"
      assert Enum.take(labels(phased), -2) == ~w(result-contract phase-return-contract)
      assert rejoined(result) == result
      assert rejoined(phased) == phased
    end

    test "a mission with no namespace docstring omits only api-notes" do
      assert labels(no_docstring()) ==
               ~w(marker protocol language examples api-heading api-legend api-entries)
    end

    test "an unrecognised string collapses to one labelled segment" do
      unmarked = "You are a helpful assistant."
      reordered = String.replace(final(), "PTC-Lisp\n", "PTC-Lisp \n", global: false)
      truncated = "PTC_AGENT_PROMPT_V1\n\nInstructions\nno further anchors\n"

      for prompt <- [unmarked, reordered, truncated] do
        assert labels(prompt) == ["unrecognised"]
        assert measure(prompt)["recognised?"] == false
      end
    end

    test "a rendering truncated by even one character is unrecognised" do
      # A complete entry list ends in a blank line, so one missing character is
      # enough to make this a partial prompt. Trimming all trailing newlines
      # would pass a weaker check than the one that matters.
      for dropped <- [1, 2] do
        truncated = String.slice(final(), 0, String.length(final()) - dropped)

        assert labels(truncated) == ["unrecognised"],
               "dropping #{dropped} char(s) stayed recognised"

        assert measure(truncated)["recognised?"] == false
      end
    end

    test "a duplicated API-notes heading is unrecognised" do
      # The heading is the only boundary the notes segment has; a second one
      # makes its extent unknowable from the string alone.
      [head, rest] = String.split(final(), "API notes\n", parts: 2)
      duplicated = head <> "API notes\n" <> rest <> "API notes\n"

      assert labels(duplicated) == ["unrecognised"]
    end

    test "a non-string input is unrecognised rather than a failure" do
      assert eval!(~S|(return (mapv #(get % "label") (prompt.audit/segments 42)))|) ==
               ["unrecognised"]
    end
  end

  describe "measure" do
    test "authored and dynamic characters add up to total for a recognised prompt" do
      measured = measure(final())

      assert measured["recognised?"] == true

      assert row(measured, "authored")["characters"] + row(measured, "dynamic")["characters"] ==
               row(measured, "total")["characters"]

      assert row(measured, "total")["characters"] == String.length(final())
    end

    test "authored and dynamic characters add up to total for an unrecognised prompt" do
      measured = measure("not a rendering")

      assert measured["recognised?"] == false
      assert row(measured, "authored")["characters"] == 15
      assert row(measured, "dynamic")["characters"] == 0
      assert row(measured, "total")["characters"] == 15
    end

    test "rows are ordered by emission, then authored, dynamic and total" do
      assert Enum.map(measure(final())["rows"], & &1["label"]) ==
               ~w(marker protocol language examples api-heading api-notes api-legend
                  api-entries authored dynamic total)
    end

    test "a trailing newline closes its line rather than opening an empty one" do
      assert row(measure(""), "total")["lines"] == 0
      assert row(measure("one"), "total")["lines"] == 1
      assert row(measure("one\n"), "total")["lines"] == 1
      assert row(measure("one\ntwo"), "total")["lines"] == 2
      assert row(measure("one\ntwo\n"), "total")["lines"] == 2
      assert row(measure("\n"), "total")["lines"] == 1
    end

    test "summed segment lines equal the whole-string line count" do
      measured = measure(final())

      assert row(measured, "authored")["lines"] + row(measured, "dynamic")["lines"] ==
               row(measured, "total")["lines"]
    end

    test "tokens_estimated rounds up from characters" do
      assert row(measure(""), "total")["tokens_estimated"] == 0
      assert row(measure("a"), "total")["tokens_estimated"] == 1
      assert row(measure("abcd"), "total")["tokens_estimated"] == 1
      assert row(measure("abcde"), "total")["tokens_estimated"] == 2
    end

    test "derived rows estimate from their own characters, not from summed estimates" do
      measured = measure(final())
      total = row(measured, "total")

      assert total["tokens_estimated"] == ceil(total["characters"] / 4)

      summed =
        measured["rows"]
        |> Enum.reject(&(&1["label"] in ~w(authored dynamic total)))
        |> Enum.map(& &1["tokens_estimated"])
        |> Enum.sum()

      # The two genuinely differ; a summed estimate would over-count every
      # segment whose length is not a multiple of four.
      assert summed > total["tokens_estimated"]
    end

    test "a large rendering counts every line, past both runtime limits" do
      # Two limits sit under line counting and neither reports itself: loop/recur
      # is capped at a thousand iterations, and the regex runtime truncates its
      # input at 32,768 bytes and undercounts silently rather than failing.
      filler = String.duplicate("- Value: fixture/filler\n", 2_000)

      large =
        String.replace(
          final(),
          "- Value: fixture/sample-budget",
          filler <> "- Value: fixture/sample-budget",
          global: false
        )

      assert byte_size(large) > 32_768,
             "the fixture must exceed the regex input limit or this proves nothing"

      measured = measure(large)

      assert measured["recognised?"] == true

      # Counted outside the runtime, so an undercount fails instead of rounding
      # down quietly into a plausible number.
      assert row(measured, "total")["lines"] == expected_lines(large)

      assert row(measured, "authored")["lines"] + row(measured, "dynamic")["lines"] ==
               expected_lines(large)

      assert row(measured, "authored")["characters"] + row(measured, "dynamic")["characters"] ==
               row(measured, "total")["characters"]
    end

    test "characters counts graphemes, as count does" do
      assert row(measure("éé"), "total")["characters"] == 2
    end
  end

  describe "delta" do
    test "reports one row per label in either input, after's order first" do
      rows = delta(final(), empty_api())["rows"]

      assert Enum.map(rows, & &1["label"]) ==
               ~w(marker protocol language examples api-heading api-empty authored dynamic total
                  api-notes api-legend api-entries)
    end

    test "a label present on only one side counts zero on the other" do
      rows = delta(empty_api(), final())["rows"]
      notes = Enum.find(rows, &(&1["label"] == "api-notes"))

      assert notes["before"] == 0
      assert notes["after"] > 0
      assert notes["change"] == notes["after"]
    end

    test "percent is nil when before is zero and a rounded change otherwise" do
      rows = delta(empty_api(), final())["rows"]

      assert Enum.find(rows, &(&1["label"] == "api-notes"))["percent"] == nil

      marker = Enum.find(rows, &(&1["label"] == "marker"))
      assert marker["change"] == 0
      assert marker["percent"] == 0.0

      total = Enum.find(rows, &(&1["label"] == "total"))
      before = total["before"]
      assert total["percent"] == Float.round(total["change"] / before * 100, 1)
    end

    test "reports characters only, with no token estimates" do
      for row <- delta(ordinary(), final())["rows"] do
        assert Map.keys(row) |> Enum.sort() == ~w(after before change label percent)
      end
    end
  end

  test "the committed artifacts are both recognised renderings" do
    for prompt <- [ordinary(), final()] do
      assert measure(prompt)["recognised?"] == true
    end
  end

  defp ordinary, do: File.read!(@ordinary_artifact)
  defp final, do: File.read!(@final_artifact)

  # Both variants are cut from a committed artifact and use the exact current
  # renderer literals rather than hand-written approximations.
  defp empty_api do
    [head, _rest] = String.split(final(), "Available API\n", parts: 2)

    head <>
      "Available API\n- No mission-specific data, functions, or tools are available.\n"
  end

  defp no_docstring do
    [head, rest] = String.split(final(), "API notes\n", parts: 2)
    [_notes, tail] = String.split(rest, "\n\n", parts: 2)
    head <> tail
  end

  defp labels(prompt) do
    eval!(
      ~S|(return (mapv #(get % "label") (prompt.audit/segments data/prompt)))|,
      %{"prompt" => prompt}
    )
  end

  defp rejoined(prompt) do
    eval!(
      ~S|(return (join "" (mapv #(get % "text") (prompt.audit/segments data/prompt))))|,
      %{"prompt" => prompt}
    )
  end

  defp measure(prompt) do
    eval!(~S|(return (prompt.audit/measure data/prompt))|, %{"prompt" => prompt})
  end

  defp delta(before, aft) do
    eval!(
      ~S|(return (prompt.audit/delta data/before data/after))|,
      %{"before" => before, "after" => aft}
    )
  end

  defp row(measured, label), do: Enum.find(measured["rows"], &(&1["label"] == label))

  defp expected_lines(text) do
    breaks = length(String.split(text, "\n")) - 1
    if text == "" or String.ends_with?(text, "\n"), do: breaks, else: breaks + 1
  end

  defp eval!(program, input \\ %{}) do
    {:ok, components} = Library.components(["prompt.audit"])
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "prompt-audit-#{System.unique_integer([:positive])}"
      )

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: input,
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: value}} = Kernel.run(program, config)
    value
  end
end
