defmodule PageIndex.IterativeRetriever do
  @moduledoc """
  Two-agent iterative retrieval with structured findings and provenance tracking.

  Separates data extraction from reasoning by running a loop:
  1. **Extraction agent** (multi-turn): fetches sections and returns structured findings
  2. **Synthesis agent** (single-turn): decides if findings are sufficient to answer,
     or identifies the next "shopping item" to search for

  Each iteration produces findings with provenance (page, section, context) so the
  synthesis agent can cite sources and perform computations on collected data.
  """

  alias PageIndex.DocumentTools
  alias PtcRunner.SubAgent

  @doc """
  Retrieves an answer using iterative extraction and synthesis.

  ## Options

  - `:llm` - Required. LLM callback
  - `:pdf_path` - Required. Path to the PDF file
  - `:max_iterations` - Max extraction/synthesis cycles (default: 4)

  ## Returns

  - `{:ok, %{answer: string, sources: list, iterations: int, findings_count: int}}`
  - `{:error, reason}`
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_iterations = Keyword.get(opts, :max_iterations, 4)

    # Pre-warm the PDF cache before agent execution
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    nodes = DocumentTools.flatten_tree(tree)
    sections_summary = DocumentTools.format_sections(nodes)
    fetch_tool = DocumentTools.make_fetch_tool(nodes, pdf_path)
    grep_tool = DocumentTools.make_grep_tool(nodes, pdf_path)

    initial_state = %{findings: [], failed_searches: []}

    Enum.reduce_while(1..max_iterations, {query, initial_state}, fn i, {shopping_item, state} ->
      # 1. Run extraction agent
      state =
        case run_extraction(shopping_item, query, sections_summary, fetch_tool, grep_tool, llm) do
          {:ok, step} ->
            new_findings =
              (step.return["findings"] || [])
              |> Enum.map(fn f -> Map.put(f, "iteration", i) end)

            %{state | findings: state.findings ++ new_findings}

          {:error, step} ->
            failed = %{
              "item" => shopping_item,
              "reason" => (step.fail && step.fail.message) || "unknown",
              "iteration" => i
            }

            %{state | failed_searches: state.failed_searches ++ [failed]}
        end

      # 2. Run synthesis agent
      case run_synthesis(query, state.findings, state.failed_searches, llm) do
        {:ok, step} ->
          case step.return["status"] do
            "answer" ->
              {:halt,
               {:ok,
                %{
                  answer: step.return["answer"],
                  sources: step.return["sources"] || [],
                  iterations: i,
                  findings_count: length(state.findings)
                }}}

            "needs" ->
              {:cont, {step.return["needs"], state}}

            "fail" ->
              {:halt, {:error, step.return["reason"] || "synthesis concluded insufficient data"}}

            other ->
              {:halt, {:error, "unexpected synthesis status: #{inspect(other)}"}}
          end

        {:error, step} ->
          {:halt, {:error, (step.fail && step.fail.message) || "synthesis agent failed"}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {_shopping_item, state} -> run_final_synthesis(query, state, max_iterations, llm)
    end
  end

  defp run_final_synthesis(query, state, iterations, llm) do
    case run_synthesis(query, state.findings, state.failed_searches, llm, last_chance: true) do
      {:ok, step} ->
        if step.return["status"] == "answer" do
          {:ok,
           %{
             answer: step.return["answer"],
             sources: step.return["sources"] || [],
             iterations: iterations,
             findings_count: length(state.findings)
           }}
        else
          {:error, "max iterations reached without answer"}
        end

      _ ->
        {:error, "max iterations reached without answer"}
    end
  end

  defp run_extraction(shopping_item, question, sections_summary, fetch_tool, grep_tool, llm) do
    agent =
      SubAgent.new(
        prompt: """
        Extract structured data from a document to help answer a question.

        QUESTION: {{question}}
        SHOPPING ITEM: {{shopping_item}}

        AVAILABLE SECTIONS:
        #{sections_summary}

        INSTRUCTIONS:
        1. Read section summaries and identify 1-3 sections most likely to contain data for the shopping item
        2. Fetch each using: (tool/fetch_section {:node_id "section_id"})
        2b. PAGINATION: If a fetch result has `truncated: true`, call fetch_section again with
            the offset from the hint to get remaining content. Do not extract partial data from
            truncated tables — paginate until you find what you need or truncated is false.
            For large sections, use grep_section first to locate keywords, then fetch at the
            returned offset.
        3. Extract ALL relevant data points as structured findings with:
           - label: descriptive snake_case identifier
           - value: the number or text found (use raw numeric value, e.g., 34500 not "34,500")
           - unit: units if applicable (e.g., "millions_usd", "percent", "thousands_usd"). Always note the scale from the table header or footnotes.
           - page: page number where found (integer)
           - section: section title where found
           - context: brief description of what this data point represents
        4. Return findings list. Include BOTH the targeted shopping item data AND anything else relevant to the question.
        5. If no relevant data found in any fetched section, use (fail "reason") explaining what was searched and why it failed.
        """,
        signature:
          "(shopping_item :string, question :string) -> {findings [{label :string, value :any, unit :string, page :any, section :string, context :string}], sections_searched [:string]}",
        tools: %{"fetch_section" => fetch_tool, "grep_section" => grep_tool},
        max_turns: 10,
        timeout: 30_000
      )

    SubAgent.run(agent,
      llm: llm,
      context: %{shopping_item: shopping_item, question: question}
    )
  end

  defp run_synthesis(question, findings, failed_searches, llm, opts \\ []) do
    last_chance = Keyword.get(opts, :last_chance, false)

    last_chance_instruction =
      if last_chance do
        """

        IMPORTANT: This is the FINAL iteration — no more searches are possible.
        You MUST provide the best answer you can from the findings collected so far.
        If data is incomplete, answer with what you have and note any caveats.
        Always return status "answer" unless the findings are completely empty.
        """
      else
        ""
      end

    SubAgent.run(
      """
      You are evaluating whether collected data is sufficient to answer a question.

      QUESTION: #{question}

      FINDINGS COLLECTED SO FAR:
      #{format_findings(findings)}

      FAILED SEARCHES:
      #{format_failed_searches(failed_searches)}

      INSTRUCTIONS:
      - If you can answer the question from the findings: return status "answer" with the answer, citing page numbers from findings
      - If you need more data: return status "needs" with ONE specific thing to search for next, and why
        - Be as specific as possible (e.g., "operating income for 2022" not "more data")
        - Do NOT request something that already appears in failed_searches
        - If a direct data point failed, suggest an alternative path (e.g., compute from components)
      - If the data is genuinely insufficient and no alternative paths exist: return status "fail" with explanation
      - If computations are needed (ratios, percentages, comparisons), perform them using the findings values
      - IMPORTANT: When findings contain monetary values, verify the "unit" field matches before computing (e.g., thousands vs millions)
      #{last_chance_instruction}\
      """,
      output: :json,
      signature:
        "{status :string, answer :string, sources [:string], confidence :string, needs :string, reason :string}",
      llm: llm
    )
  end

  # --- Formatting helpers ---

  defp format_findings([]), do: "(none yet)"

  defp format_findings(findings) do
    findings
    |> Enum.with_index(1)
    |> Enum.map(fn {f, i} ->
      """
      #{i}. #{f["label"]}
         Value: #{inspect(f["value"])} #{f["unit"] || ""}
         Page: #{f["page"]}, Section: #{f["section"]}
         Context: #{f["context"]}
      """
    end)
    |> Enum.join("\n")
  end

  defp format_failed_searches([]), do: "(none)"

  defp format_failed_searches(failed) do
    failed
    |> Enum.map(fn f ->
      "- Searched for: #{f["item"]} → #{f["reason"]}"
    end)
    |> Enum.join("\n")
  end
end
