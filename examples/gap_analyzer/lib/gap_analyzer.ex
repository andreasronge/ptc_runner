defmodule GapAnalyzer do
  @moduledoc """
  Elixir-driven compliance gap analysis.

  Demonstrates the pattern of:
  - Elixir controlling the investigation loop
  - Single-shot SubAgents doing focused analysis
  - Workspace storing state between iterations
  - Fresh LLM context each step (no history accumulation)
  """

  alias GapAnalyzer.{Workspace, SubAgents, Data}
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Debug

  @doc """
  Run a compliance gap analysis starting from a topic.

  ## Options

  - `:topic` - Starting topic to search for (default: "encryption")
  - `:max_iterations` - Maximum investigation iterations (default: 3)
  - `:batch_size` - Requirements to investigate per iteration (default: 3)
  - `:debug` - Enable debug output (default: false)
  - `:model` - LLM model to use

  ## Example

      {:ok, report} = GapAnalyzer.analyze(topic: "encryption")
  """
  def analyze(opts \\ []) do
    topic = Keyword.get(opts, :topic, "encryption")
    max_iterations = Keyword.get(opts, :max_iterations, 3)
    batch_size = Keyword.get(opts, :batch_size, 3)
    debug = Keyword.get(opts, :debug, false)

    # Start workspace
    ensure_workspace_started()
    Workspace.reset()

    # Build LLM function
    llm = build_llm(opts)

    # Phase 1: Discover requirements
    if debug, do: IO.puts("\n=== Phase 1: Discovery ===")

    case discover_requirements(topic, llm, debug) do
      {:ok, requirements} ->
        Workspace.add_pending(requirements)
        if debug, do: IO.puts("Found #{length(requirements)} requirements to investigate")

        # Phase 2: Investigate iteratively
        if debug, do: IO.puts("\n=== Phase 2: Investigation ===")
        investigate_loop(max_iterations, batch_size, llm, debug)

        # Phase 3: Summarize
        if debug, do: IO.puts("\n=== Phase 3: Summary ===")
        findings = Workspace.get_findings()

        case summarize_findings(findings, llm, debug) do
          {:ok, report} ->
            {:ok, Map.put(report, :findings, findings)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Analyze all requirements (not just one topic).
  """
  def analyze_all(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 5)
    batch_size = Keyword.get(opts, :batch_size, 3)
    debug = Keyword.get(opts, :debug, false)

    ensure_workspace_started()
    Workspace.reset()

    llm = build_llm(opts)

    # Get all regulations
    all_reqs =
      Data.regulation_sections()
      |> Enum.map(fn {_id, sec} ->
        %{id: sec.id, title: sec.title, summary: sec.summary}
      end)

    if debug, do: IO.puts("Investigating all #{length(all_reqs)} requirements")

    Workspace.add_pending(all_reqs)

    investigate_loop(max_iterations, batch_size, llm, debug)

    findings = Workspace.get_findings()

    case summarize_findings(findings, llm, debug) do
      {:ok, report} ->
        {:ok, Map.put(report, :findings, findings)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private functions ---

  defp ensure_workspace_started do
    case Workspace.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp build_llm(opts) do
    model = opts[:model] || LLMClient.default_model()

    fn input ->
      messages = [%{role: :system, content: input.system} | input.messages]

      case LLMClient.generate_text(model, messages) do
        {:ok, response} ->
          {:ok, %{content: response.content, tokens: response.tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp discover_requirements(topic, llm, debug) do
    agent = SubAgents.discovery()

    if debug, do: IO.puts("Searching for requirements related to: #{topic}")

    case SubAgent.run(agent, llm: llm, context: %{topic: topic}, debug: debug) do
      {:ok, step} ->
        if debug do
          Debug.print_trace(step, raw: true)
        end

        reqs = step.return["requirements"] || []
        {:ok, normalize_requirements(reqs)}

      {:error, step} ->
        if debug do
          IO.puts("Discovery failed: #{inspect(step.fail)}")
          Debug.print_trace(step, raw: true)
        end

        {:error, step.fail}
    end
  end

  defp investigate_loop(0, _batch_size, _llm, debug) do
    if debug, do: IO.puts("Max iterations reached")
    :ok
  end

  defp investigate_loop(remaining, batch_size, llm, debug) do
    pending = Workspace.get_pending(batch_size)

    if Enum.empty?(pending) do
      if debug, do: IO.puts("No more pending requirements")
      :ok
    else
      if debug do
        IO.puts("\nIteration #{remaining}: Investigating #{length(pending)} requirements")
        Enum.each(pending, fn r -> IO.puts("  - #{r.id}: #{r.title}") end)
      end

      case investigate_batch(pending, llm, debug) do
        {:ok, findings, follow_ups} ->
          # Save findings
          Workspace.save_findings(findings)

          # Mark as investigated
          ids = Enum.map(pending, & &1.id)
          Workspace.mark_investigated(ids)

          # Add follow-ups as new pending items
          if follow_ups && length(follow_ups) > 0 do
            if debug, do: IO.puts("Adding #{length(follow_ups)} follow-up topics")
            # Search for follow-up requirements
            new_pending = discover_follow_ups(follow_ups, llm)
            Workspace.add_pending(new_pending)
          end

          status = Workspace.status()

          if debug do
            IO.puts(
              "Progress: #{status.findings_count} findings, #{status.pending_count} pending"
            )
          end

          investigate_loop(remaining - 1, batch_size, llm, debug)

        {:error, reason} ->
          if debug, do: IO.puts("Investigation failed: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp investigate_batch(pending, llm, debug) do
    agent = SubAgents.investigator()
    previous = Workspace.get_findings() |> Enum.take(-5)

    # Pass structured data - the Data Inventory shows type and sample
    pending_data =
      Enum.map(pending, fn r ->
        %{id: r.id, title: r.title, summary: r.summary}
      end)

    previous_data =
      Enum.map(previous, fn f ->
        %{requirement_id: f.requirement_id, status: f.status, gap: f.gap}
      end)

    context = %{pending: pending_data, previous_findings: previous_data}

    case SubAgent.run(agent, llm: llm, context: context, debug: debug) do
      {:ok, step} ->
        findings = step.return["findings"] || []
        follow_ups = step.return["follow_up_queries"] || []
        {:ok, normalize_findings(findings), follow_ups}

      {:error, step} ->
        {:error, step.fail}
    end
  end

  defp discover_follow_ups(queries, llm) do
    queries
    |> Enum.flat_map(fn query ->
      case discover_requirements(query, llm, false) do
        {:ok, reqs} -> reqs
        {:error, _} -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp summarize_findings(findings, llm, debug) do
    if Enum.empty?(findings) do
      {:ok,
       %{
         summary: "No findings to report",
         compliant_count: 0,
         gap_count: 0,
         critical_gaps: [],
         recommendations: []
       }}
    else
      agent = SubAgents.summarizer()

      # Convert findings to string-keyed maps for mustache template
      findings_for_template =
        Enum.map(findings, fn f ->
          %{
            "requirement_id" => f.requirement_id,
            "status" => f.status,
            "gap" => f.gap,
            "policy_refs" => f.policy_refs,
            "reasoning" => f.reasoning || "No reasoning provided"
          }
        end)

      case SubAgent.run(agent,
             llm: llm,
             context: %{findings: findings_for_template},
             debug: debug
           ) do
        {:ok, step} ->
          {:ok, step.return}

        {:error, step} ->
          {:error, step.fail}
      end
    end
  end

  defp normalize_requirements(reqs) do
    Enum.map(reqs, fn r ->
      %{
        id: r["id"],
        title: r["title"],
        summary: r["summary"]
      }
    end)
  end

  defp normalize_findings(findings) do
    Enum.map(findings, fn f ->
      %{
        requirement_id: f["requirement_id"],
        status: f["status"],
        gap: f["gap"],
        policy_refs: f["policy_refs"],
        reasoning: f["reasoning"]
      }
    end)
  end
end
