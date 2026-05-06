defmodule PtcRunner.SubAgent.TextModeCombinedComputeE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Live-provider e2e for combined mode (`output: :text, ptc_transport: :tool_call`)
  with **zero app tools** — exercises the Addendum #19 guarantee that the compact
  PTC-Lisp reference card is included in the system prompt even when no
  `:both`/`:ptc_lisp` tools exist.

  Backs the "Text Mode with Deterministic Compute (Combined Mode)" section in
  `docs/guides/subagent-getting-started.md`.

  ## Question under test

  *Does the LLM actually call `ptc_lisp_execute` for a task it could plausibly
  answer in its head?* Counting the letter `r` in `raspberry` is the classic
  miscount — the answer is 3, models often say 2.

  Two models are run side-by-side (`haiku` vs `gemini-flash-lite`) and the
  results printed as a comparison table at the end of the suite. Escalation
  behaviour is **observed, not asserted**: the only firm assertion is that
  the final text contains the correct count.

  Run with:

      OPENROUTER_API_KEY=... mix test --include e2e \\
        test/ptc_runner/sub_agent/text_mode_combined_compute_e2e_test.exs

  Skipped cleanly without `OPENROUTER_API_KEY` (the `test_helper.exs` excludes
  `:e2e` by default).
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent

  # Combined into a single mission string (the SubAgent `prompt:` field is the
  # user message; the framework generates the system prompt itself, including
  # the compact PTC-Lisp reference card per Addendum #19). The nudge to
  # escalate is intentionally kept in-prompt: that's the test of whether the
  # model takes the hint when it could plausibly answer in its head.
  @mission """
  You are a helpful assistant. For deterministic computation
  (counting characters, exact arithmetic, string manipulation),
  call ptc_lisp_execute instead of computing in your head.
  Programs run in a sandbox and return deterministic results.

  How many letter 'r' in the word 'raspberry'?
  """

  # ---------------------------------------------------------------------------
  # Cross-test result accumulator. Two `test` blocks each push one row; an
  # `on_exit` registered in `setup_all` prints the comparison table once both
  # tests have completed (or the suite is torn down). An Agent is the
  # simplest fit: survives across tests, GC'd when the test process exits.

  setup_all do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      rows =
        try do
          Agent.get(agent, & &1)
        catch
          :exit, _ -> []
        end

      print_comparison_table(rows)
    end)

    {:ok, results: agent}
  end

  # ---------------------------------------------------------------------------
  # Per-test telemetry capture: `[:tool, :call]` events with
  # `exposure_layer: :native` for `ptc_lisp_execute` invocations.

  setup do
    table = :ets.new(:combined_compute_e2e_events, [:bag, :public])

    handler_id = "combined-compute-e2e-#{:erlang.unique_integer([:positive])}"

    handler = fn event, measurements, metadata, %{table: t} ->
      :ets.insert(t, {event, measurements, metadata})
    end

    :telemetry.attach(
      handler_id,
      [:ptc_runner, :sub_agent, :tool, :call],
      handler,
      %{table: table}
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
    end)

    {:ok, table: table}
  end

  # ---------------------------------------------------------------------------
  # Shared run shape (parametrized only by model alias)

  defp run_for(model, table) do
    agent =
      SubAgent.new(
        prompt: @mission,
        output: :text,
        ptc_transport: :tool_call,
        max_turns: 4
      )

    {:ok, step} =
      SubAgent.run(agent,
        llm: PtcRunner.LLM.callback(model),
        collect_messages: true
      )

    # Native ptc_lisp_execute calls (telemetry: exposure_layer: :native).
    native_ptc_events =
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {_event, _meas, meta} ->
        meta.tool_name == "ptc_lisp_execute" and meta.exposure_layer == :native
      end)

    # Programs the model wrote, pulled from assistant tool_calls in transcript.
    programs =
      step.messages
      |> List.wrap()
      |> Enum.flat_map(fn
        %{role: :assistant, tool_calls: calls} when is_list(calls) ->
          calls
          |> Enum.filter(&ptc_lisp_execute_call?/1)
          |> Enum.map(&extract_program/1)

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    %{
      model: model,
      escalated?: native_ptc_events != [],
      escalation_count: length(native_ptc_events),
      programs: programs,
      final_text: step.return,
      turns: get_in(step.usage, [:turns]),
      input_tokens: get_in(step.usage, [:input_tokens]),
      output_tokens: get_in(step.usage, [:output_tokens])
    }
  end

  defp ptc_lisp_execute_call?(%{name: "ptc_lisp_execute"}), do: true
  defp ptc_lisp_execute_call?(%{function: %{name: "ptc_lisp_execute"}}), do: true
  defp ptc_lisp_execute_call?(_), do: false

  defp extract_program(%{args: %{"program" => p}}), do: p
  defp extract_program(%{args: %{program: p}}), do: p

  defp extract_program(%{function: %{arguments: args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{"program" => p}} -> p
      _ -> nil
    end
  end

  defp extract_program(_), do: nil

  # ---------------------------------------------------------------------------
  # Firm assertions — same shape for each model.

  defp assert_correct_answer(%{final_text: text, model: model}) do
    assert is_binary(text),
           "[#{model}] expected text return; got #{inspect(text)}"

    # Soft regex: digit "3" or word "three" anywhere in the answer.
    # Phrasing varies wildly: "3", "three", "3 r's", "three letter r's", etc.
    assert text =~ ~r/\b(3|three)\b/i,
           "[#{model}] expected final text to contain count 3; got: #{inspect(text)}"
  end

  # ---------------------------------------------------------------------------
  # Two test blocks — one per model. Each pushes a result row to the
  # `setup_all` accumulator; the table is printed once on suite teardown.

  describe "combined mode, zero app tools, classic miscount question" do
    test "haiku: counts r in raspberry", %{table: table, results: results} do
      row = run_for("haiku", table)
      Agent.update(results, fn rows -> rows ++ [row] end)
      assert_correct_answer(row)
    end

    test "gemini-flash-lite: counts r in raspberry", %{table: table, results: results} do
      row = run_for("gemini-flash-lite", table)
      Agent.update(results, fn rows -> rows ++ [row] end)
      assert_correct_answer(row)
    end
  end

  # ---------------------------------------------------------------------------
  # Comparison table (printed in `on_exit` from `setup_all`).

  defp print_comparison_table([]), do: :ok

  defp print_comparison_table(rows) do
    IO.puts("\n=== Combined-mode escalation comparison ===")

    header =
      "Model              | Escalated | Calls | Program (first)                         | Turns | In tokens | Out tokens | Final answer"

    sep = String.duplicate("-", String.length(header))

    IO.puts(header)
    IO.puts(sep)

    Enum.each(rows, fn row ->
      model = String.pad_trailing(row.model, 18)
      escalated = if row.escalated?, do: "yes", else: "no "
      calls = row.escalation_count |> to_string() |> String.pad_leading(5)

      program =
        case row.programs do
          [first | _] -> first |> truncate(40)
          _ -> "-"
        end
        |> String.pad_trailing(40)

      turns = row.turns |> to_string() |> String.pad_leading(5)
      in_t = (row.input_tokens || "-") |> to_string() |> String.pad_leading(9)
      out_t = (row.output_tokens || "-") |> to_string() |> String.pad_leading(10)
      final = row.final_text |> to_string() |> truncate(60)

      IO.puts(
        "#{model} | #{escalated}       | #{calls} | #{program} | #{turns} | #{in_t} | #{out_t} | #{final}"
      )
    end)

    IO.puts("")
    :ok
  end

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n do
    binary_part(s, 0, n - 1) <> "…"
  end

  defp truncate(s, _n) when is_binary(s), do: s
  defp truncate(s, _n), do: inspect(s)
end
