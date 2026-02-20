defmodule Alma.Analyst do
  @moduledoc """
  Analyzes parent designs and produces natural language critique for the MetaAgent.

  The Analyst is a single-shot LLM call that examines parent designs' trajectories,
  scores, source code, and errors, then produces structured feedback about what
  worked, what failed, and what to try next. This replaces hardcoded strategy
  hints in the MetaAgent prompt — the Analyst discovers insights from evidence.
  """

  @doc """
  Analyzes parent designs and returns a critique string.

  The critique is passed to `MetaAgent.generate` as additional context, giving
  the MetaAgent evidence-based guidance without hardcoding domain knowledge.

  Returns `{:ok, critique}` or `{:error, reason}`.
  """
  def analyze(parents, opts \\ []) do
    llm = Keyword.get(opts, :llm)

    if is_nil(llm) or Enum.empty?(parents) do
      {:ok, ""}
    else
      prompt = build_prompt(parents)

      request = %{
        system: system_prompt(),
        messages: [%{role: :user, content: prompt}]
      }

      case llm.(request) do
        {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
        {:error, reason} -> {:error, reason}
        _ -> {:error, "unexpected LLM response"}
      end
    end
  end

  defp system_prompt do
    """
    You are a memory design analyst. You examine how memory designs performed \
    during agent evaluation and produce a concise critique with mandatory \
    constraints for the next design.

    Your critique should be evidence-based — derived from the trajectories, \
    scores, errors, and source code you observe.

    Structure your output in two sections:

    ## Analysis
    - Identify what the design did well or poorly based on episode outcomes
    - Note patterns in the trajectories (repeated actions, ignored recall advice, \
    useful vs useless observations stored)
    - Be specific about failures (e.g., "recall returned generic text that didn't \
    reference the current goal") rather than vague ("recall could be better")

    ## Mandatory Constraints
    Based on your analysis, list 2-4 concrete constraints that the NEXT design \
    MUST satisfy. These are hard requirements, not suggestions. Examples:
    - "MUST store observed facts using tool/store-obs with appropriate collections"
    - "MUST use tool/graph-update to record connections from observation_log"
    - "MUST use tool/find-similar in recall to retrieve relevant stored knowledge"
    - "MUST NOT return generic advice — recall must include specific details from \
    stored knowledge"
    - "MUST use tool/graph-path to compute navigation directions in recall"

    Constraints should address the specific weaknesses you identified. \
    Do not repeat constraints that the design already satisfies.

    Keep your analysis under 300 words. Focus on actionable insights.
    """
  end

  defp build_prompt(parents) do
    sections =
      parents
      |> Enum.map(fn parent ->
        name = Map.get(parent.design, :name, "unknown")
        score = parent.score
        errors = Map.get(parent, :errors, [])
        analysis = Map.get(parent, :analysis, %{})
        compressed = Map.get(parent, :compressed_trajectories, [])
        mem_update_src = Map.get(parent.design, :mem_update_source, "")
        recall_src = Map.get(parent.design, :recall_source, "")

        error_text =
          if errors != [] do
            "\nRuntime errors:\n" <> Enum.map_join(errors, "\n", &"- #{&1}")
          else
            ""
          end

        analysis_text = format_analysis(analysis)

        trajectory_text =
          if compressed != [] do
            "\nSample episodes:\n" <> Enum.join(compressed, "\n\n")
          else
            ""
          end

        """
        ## Design: #{name} (score: #{Float.round(score * 1.0, 2)})

        mem-update:
        ```
        #{mem_update_src}
        ```

        recall:
        ```
        #{recall_src}
        ```
        #{analysis_text}#{trajectory_text}#{error_text}
        """
      end)

    """
    Analyze the following memory designs and their performance. \
    Provide a critique that will help a designer create a better version.

    #{Enum.join(sections, "\n---\n")}
    """
  end

  defp format_analysis(analysis) when is_map(analysis) and map_size(analysis) > 0 do
    success_rate = Map.get(analysis, :success_rate, 0.0)
    avg_steps = Map.get(analysis, :avg_steps, 0.0)
    recall_pct = Map.get(analysis, :recall_provided, 0.0)
    avg_recall_len = Map.get(analysis, :avg_recall_length, 0.0)

    """

    Metrics:
    - Success rate: #{Float.round(success_rate * 100, 0)}%
    - Avg steps: #{Float.round(avg_steps * 1.0, 1)}
    - Recall provided: #{Float.round(recall_pct * 100, 0)}% of episodes (avg #{Float.round(avg_recall_len * 1.0, 0)} chars)
    """
  end

  defp format_analysis(_), do: ""
end
