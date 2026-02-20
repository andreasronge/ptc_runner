defmodule PtcRunner.SubAgent.PlannerWorkerE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  E2E test for the planner-worker-reviewer pattern.

  This test is primarily for trace analysis — run it, inspect the trace output,
  and iterate on prompts/architecture. Not about pass/fail.

  Run with: mix test test/ptc_runner/sub_agent/planner_worker_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini).

  The trace is written to tmp/planner_trace.txt for post-run analysis.
  """

  @moduletag :e2e
  @moduletag timeout: 300_000

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Debug
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 60_000
  @trace_file "tmp/planner_trace.txt"

  setup_all do
    LLMSupport.ensure_api_key!()
    File.mkdir_p!("tmp")
    IO.puts("\n=== Planner-Worker-Reviewer E2E Test ===")
    IO.puts("Model: #{LLMSupport.model()}\n")
    :ok
  end

  test "planner orchestrates worker and reviewer" do
    # --- fetch_page tool (real HTTP) ---
    fetch_page = fn %{"url" => url} ->
      case Req.get(url, redirect: true, max_redirects: 3, receive_timeout: 15_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          text =
            body
            |> String.replace(~r/<!--.*?-->/s, "")
            |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
            |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
            |> String.replace(~r/<nav[^>]*>.*?<\/nav>/s, "")
            |> String.replace(~r/<header[^>]*>.*?<\/header>/s, "")
            |> String.replace(~r/<footer[^>]*>.*?<\/footer>/s, "")
            |> String.replace(~r/<(br|\/p|\/div|\/li|\/h\d|\/tr|\/td|\/dt|\/dd)[^>]*>/i, "\n")
            |> String.replace(~r/<[^>]+>/, " ")
            |> String.replace(~r/&\w+;/, " ")
            |> String.replace(~r/[ \t]+/, " ")
            |> String.replace(~r/\n[ \t]*/, "\n")
            |> String.replace(~r/\n{3,}/, "\n\n")
            |> String.trim()
            |> String.slice(0, 6000)

          %{status: "ok", text: text}

        {:ok, %{status: status}} ->
          %{status: "error", text: "HTTP #{status}"}

        {:error, reason} ->
          %{status: "error", text: "Request failed: #{inspect(reason)}"}
      end
    end

    # --- Worker: multi-turn, has fetch_page tool ---
    worker =
      SubAgent.new(
        prompt: """
        {{task}}

        ## Rules
        - You MUST call `fetch_page` at least once. Never return the task description as your result.
        - Your return map must contain data extracted from web pages, not the task text.
        - Use `fetch_page` to retrieve web pages. It returns `{status :string, text :string}`.
          Check `(:status result)` — `"ok"` means success, `"error"` means failure.
          On error, try an alternative URL instead of retrying the same one.
        - For GitHub files, use raw URLs: `https://raw.githubusercontent.com/OWNER/REPO/REF/PATH`
        - Use `(tool/grep {:pattern "..." :text text})` or `(tool/grep-n {:pattern "..." :text text})` to search text.
        - Return a map with your findings as soon as you have useful data.
          Partial results are better than no results.
        """,
        description:
          "Research worker: fetches web pages and extracts information for a specific task",
        signature: "(task :string) -> :map",
        tools: %{
          "fetch_page" =>
            {fetch_page,
             signature: "(url :string) -> {status :string, text :string}",
             description: "Fetch a web page and return its text content.",
             cache: true}
        },
        builtin_tools: [:grep],
        max_turns: 3,
        retry_turns: 1,
        timeout: 30_000
      )

    # --- Reviewer: single-shot judge ---
    reviewer =
      SubAgent.new(
        prompt: """
        You are a quality reviewer. Evaluate whether the research result
        satisfies the acceptance criteria.

        ## Step
        {{step}}

        ## Acceptance Criteria
        {{criteria}}

        ## Result to Review
        {{result}}

        Be pragmatic:
        - Approve if the result contains a version number and at least some feature information.
        - Only reject if the result is completely empty or contains no relevant data at all.
        - A version number alone is sufficient — features are nice-to-have.
        - Partial results with real data should be approved with notes about gaps.
        """,
        description: "Reviews research results against acceptance criteria",
        signature:
          "(step :string, criteria :string, result :string) -> {approved :bool, summary :string, feedback :string}",
        max_turns: 1,
        retry_turns: 2,
        output: :json
      )

    # --- Plan steps (2 steps — no synthesis step) ---
    plan = [
      "Fetch the latest stable version and key features of Elixir from elixir-lang.org",
      "Fetch the latest stable version and key features of Erlang/OTP from erlang.org"
    ]

    # --- Planner-executor: orchestrates worker + reviewer ---
    planner_executor =
      SubAgent.new(
        prompt: """
        Answer this research question: {{question}}

        ## Your Role
        You are a planner-orchestrator. You delegate research to `research_worker`
        and verify results with `reviewer`. You never fetch pages yourself.

        ## The `do-step` Pattern
        Define a helper that dispatches to worker and reviewer. Format the result
        as readable key-value pairs before sending to the reviewer:

        (defn format-result [m]
          (reduce (fn [acc k] (str acc k ": " (get m k) "\\n")) "" (keys m)))

        (defn do-step [id task criteria]
          (let [result (tool/research_worker {:task task})
                result_str (format-result result)
                review (tool/reviewer {:step task :criteria criteria :result result_str})]
            (if (:approved review)
              (do (step-done id (:summary review)) result)
              (do (step-done id (str "REJECTED: " (:feedback review))) nil))))

        ## Rules
        - Always define `format-result` and `do-step` first, then use them for each plan step.
        - Use the step IDs from the Progress checklist.
        - Batch independent steps in the same turn (e.g. steps 1 and 2 together).
        - Maximum 1 retry per step. If a step fails twice, skip it and move on.
        - After all research steps are done, build the final answer map yourself
          from the collected data. Do NOT delegate synthesis to the worker.
          Extract fields with keywords: `(:version data)`, `(:features data)`.
        - Write specific but achievable acceptance criteria.
          Good: "Must include a version number"
          Bad: "Must include version, release date, 5+ features with descriptions"
        - If a step returns nil (rejected), you may retry once with a refined task.
          After that, skip and work with what you have.
        - Only `(return ...)` when all steps are done or skipped.
          Build the return map yourself:
          (return {:elixir elixir-data :erlang erlang-data})
        """,
        signature: "(question :string) -> :map",
        plan: plan,
        tools: %{
          "research_worker" => SubAgent.as_tool(worker, cache: true),
          "reviewer" => SubAgent.as_tool(reviewer, cache: true)
        },
        max_turns: 8,
        max_depth: 2,
        timeout: 180_000,
        journaling: true
      )

    # --- Run ---
    question =
      "What are the latest stable versions of Elixir and Erlang/OTP, and what are the key new features in each?"

    {result, step} =
      SubAgent.run(planner_executor,
        llm: llm_callback(),
        context: %{question: question},
        journal: %{},
        max_heap: 2_500_000,
        trace: true,
        collect_messages: true
      )

    # --- Capture trace to file ---
    trace_output =
      ExUnit.CaptureIO.capture_io(fn ->
        Debug.print_trace(step, raw: true, usage: true)
      end)

    # Append summary info
    summary = """

    ========== SUMMARY ==========
    Result: #{inspect(result)}
    Return: #{inspect(step.return, limit: 10, printable_limit: 500)}
    Fail: #{inspect(step.fail)}
    Summaries: #{inspect(step.summaries)}
    Usage: #{inspect(step.usage)}
    ==============================
    """

    full_trace = trace_output <> summary
    File.write!(@trace_file, full_trace)

    # Also print to console
    IO.puts(trace_output)
    IO.puts(summary)
    IO.puts("Trace written to #{@trace_file}")

    # Soft assertion — just ensure it ran to completion
    assert result in [:ok, :error],
           "Expected :ok or :error result, got: #{inspect(result)}"
  end

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(LLMSupport.model(), full_messages, receive_timeout: @timeout) do
        {:ok, text} -> {:ok, text}
        {:error, _} = error -> error
      end
    end
  end
end
