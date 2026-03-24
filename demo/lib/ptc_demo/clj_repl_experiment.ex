defmodule PtcDemo.CljReplExperiment do
  @moduledoc """
  Experiment: Drive a real LLM through a Clojure REPL session.

  Tests whether framing the conversation as a REPL session reduces
  hallucination and encourages incremental exploration.

  Uses `(return value)` and `(fail reason)` for typed completion signaling.
  """

  alias PtcDemo.CljRepl

  @max_turns 6

  @system_prompt """
  You are working in a Clojure REPL. A prelude has been loaded with:

  - `(tool/search {:query "..."})` — search policy documents by keyword (AND logic). Returns `{"results" [...], "cursor" ..., "has_more" ..., "total" ...}`. Each result has keys: `"id"`, `"title"`, `"topics"`, `"department"`.
  - `(tool/fetch {:id "DOC-NNN"})` — fetch full document content by ID. Returns the document map with `"content"` key, or nil if not found.
  - `data/question` — the question to answer.
  - `(return value)` — call when you have the final answer. Value can be any Clojure type: string, number, map, vector, etc.
  - `(fail reason)` — call if the task cannot be completed.

  Work interactively. Each turn, write ONE short Clojure expression or a small `(do ...)` block.
  You'll see the REPL output, then decide your next step.

  Rules:
  - Do NOT guess or fabricate data. Only use values you've seen in REPL output.
  - Explore incrementally: search first, inspect results, then fetch details.
  - Keep expressions short — this is a REPL, not a script.
  - When done, call `(return value)` with the appropriately typed result.
  """

  @tests %{
    20 => %{
      query:
        "Find the policy document about reimbursement for professional certifications. " <>
          "Search for relevant documents, then fetch the content of candidates to find " <>
          "the one specifically about certification reimbursement (not training budget). " <>
          "Return the document ID.",
      expect: "string (the document ID)",
      constraint: {:one_of, ["DOC-020", "DOC-021"]}
    },
    21 => %{
      query:
        "Search for documents about 'security', then search for documents about 'compliance'. " <>
          "Find which department has documents in BOTH categories. " <>
          "Return the department name.",
      expect: "string (the department name)",
      constraint: {:eq, "IT"}
    },
    22 => %{
      query:
        "Search for policies about 'leave'. Multiple types will come back. " <>
          "Find the one specifically about sabbatical leave and return its title.",
      expect: "string (the document title)",
      constraint: {:eq, "Sabbatical Leave Program"}
    },
    23 => %{
      query:
        "Fetch documents DOC-001 and DOC-002. Compare their content. " <>
          "Which one mentions 'ergonomics'? Return its document ID.",
      expect: "string (the document ID)",
      constraint: {:eq, "DOC-002"}
    }
  }

  def run(opts \\ []) do
    run_test(20, opts)
  end

  def run_test(test_num, opts \\ []) do
    test = Map.fetch!(@tests, test_num)
    model = Keyword.get(opts, :model, "openrouter:google/gemini-3.1-flash-lite-preview")
    verbose = Keyword.get(opts, :verbose, true)

    {:ok, _pid} = CljRepl.start_link()
    Process.sleep(1_000)

    if verbose, do: IO.puts("\n=== CljRepl: test ##{test_num} with #{model} ===\n")

    initial_msg = """
    The REPL is ready. Here's your task:

    #{test.query}

    Expected result type: #{test.expect}

    Start by exploring. Use tool calls to gather data, inspect results, then return your answer.
    """

    messages = [%{role: :user, content: initial_msg}]
    result = loop(messages, model, 1, verbose)

    CljRepl.stop()

    # Validate
    case result do
      {:ok, value} ->
        pass? = validate(value, test.constraint)
        status = if pass?, do: "PASS", else: "FAIL"

        if verbose do
          IO.puts("\n#{status}: got #{inspect(value)}, expected #{inspect(test.constraint)}")
        end

        {pass?, value}

      {:error, reason} ->
        if verbose, do: IO.puts("\nERROR: #{inspect(reason)}")
        {false, reason}
    end
  end

  @doc "Run all exploration tests (20-23) and report results."
  def run_all(opts \\ []) do
    model = Keyword.get(opts, :model, "openrouter:google/gemini-3.1-flash-lite-preview")
    verbose = Keyword.get(opts, :verbose, false)

    results =
      for {num, _test} <- Enum.sort(@tests) do
        {pass?, value} = run_test(num, model: model, verbose: verbose)
        status = if pass?, do: "PASS", else: "FAIL"
        IO.puts("  ##{num}: #{status} (#{inspect(value)})")
        {num, pass?, value}
      end

    passes = Enum.count(results, fn {_, pass?, _} -> pass? end)
    total = length(results)
    IO.puts("\n#{passes}/#{total} passed")
    results
  end

  # --- Loop ---

  defp loop(_messages, _model, turn, verbose) when turn > @max_turns do
    if verbose, do: IO.puts("\n--- Max turns reached ---")
    {:error, :max_turns}
  end

  defp loop(messages, model, turn, verbose) do
    if verbose, do: IO.puts("--- Turn #{turn} ---")

    full_messages = [%{role: :system, content: @system_prompt} | messages]

    case LLMClient.generate_text(model, full_messages,
           receive_timeout: 60_000,
           req_http_options: [retry: :transient, max_retries: 3]
         ) do
      {:ok, %{content: response}} ->
        if verbose, do: IO.puts("[LLM] #{response}")

        code = extract_code(response)

        if code do
          if verbose, do: IO.puts("[EVAL] #{code}")

          case CljRepl.eval_raw(code) do
            {:ok, raw_output} ->
              if verbose, do: IO.puts("[REPL] #{raw_output}\n")

              case parse_signal(raw_output) do
                {:return, value} ->
                  if verbose, do: IO.puts("=== RETURN: #{value} ===")
                  {:ok, value}

                {:fail, reason} ->
                  if verbose, do: IO.puts("=== FAIL: #{reason} ===")
                  {:error, {:failed, reason}}

                :continue ->
                  clean = clean_repl_output(raw_output)
                  truncated = truncate_feedback(clean, 250)

                  new_messages =
                    messages ++
                      [
                        %{role: :assistant, content: response},
                        %{role: :user, content: truncated}
                      ]

                  loop(new_messages, model, turn + 1, verbose)
              end

            {:error, err} ->
              if verbose, do: IO.puts("[ERROR] #{inspect(err)}\n")

              new_messages =
                messages ++
                  [
                    %{role: :assistant, content: response},
                    %{role: :user, content: "Error: #{inspect(err)}"}
                  ]

              loop(new_messages, model, turn + 1, verbose)
          end
        else
          if verbose, do: IO.puts("[WARN] No code found in response\n")

          new_messages =
            messages ++
              [
                %{role: :assistant, content: response},
                %{
                  role: :user,
                  content: "Please write a Clojure expression to evaluate in the REPL."
                }
              ]

          loop(new_messages, model, turn + 1, verbose)
        end

      {:error, reason} ->
        if verbose, do: IO.puts("[LLM ERROR] #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Validation ---

  defp validate(value, {:eq, expected}), do: clean_value(value) == expected
  defp validate(value, {:one_of, options}), do: clean_value(value) in options

  defp clean_value(value) do
    value
    |> String.trim()
    |> String.replace(~r/^"(.*)"$/, "\\1")
  end

  # --- Signal parsing ---

  defp parse_signal(raw_output) do
    cond do
      match = Regex.run(~r/::RETURN:: (.+)/s, raw_output) ->
        {:return, Enum.at(match, 1) |> String.trim() |> strip_trailing_repl()}

      match = Regex.run(~r/::FAIL:: (.+)/s, raw_output) ->
        {:fail, Enum.at(match, 1) |> String.trim() |> strip_trailing_repl()}

      true ->
        :continue
    end
  end

  defp strip_trailing_repl(value) do
    value
    |> String.split("\n")
    |> List.first()
    |> String.trim()
  end

  defp truncate_feedback(text, max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <>
        "\n... (truncated, use println to see full value)"
    else
      text
    end
  end

  defp clean_repl_output(raw) do
    raw
    |> String.split("\n")
    |> Enum.reject(&(&1 == "nil"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp extract_code(response) do
    cond do
      match = Regex.run(~r/```clojure\n(.*?)```/s, response) ->
        Enum.at(match, 1) |> String.trim()

      match = Regex.run(~r/```\n(.*?)```/s, response) ->
        Enum.at(match, 1) |> String.trim()

      # Bare s-expression (handles nested parens up to 4 levels)
      match =
          Regex.run(
            ~r/(\((?:[^()]*|\((?:[^()]*|\((?:[^()]*|\((?:[^()]*|\([^()]*\))*\))*\))*\))*\))/s,
            response
          ) ->
        Enum.at(match, 1) |> String.trim()

      true ->
        nil
    end
  end
end
