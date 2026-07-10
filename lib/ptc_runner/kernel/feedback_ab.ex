defmodule PtcRunner.Kernel.FeedbackAB do
  @moduledoc false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Eval
  alias PtcRunner.Kernel.Eval.RunContext
  alias PtcRunner.Lisp.Prelude

  @seed "m2-feedback-ab-order-v1"
  @variant_a_path "priv/kernel_feedback_variants/feedback_a_default.lisp"
  @variant_b_path "priv/kernel_feedback_variants/feedback_b_memory_guidance.lisp"
  @variant_c_feedback_path "priv/kernel_feedback_variants/feedback_c_no_memory_guidance.lisp"
  @prompt_path "priv/preludes/agent/prompt.lisp"
  @core_path "priv/preludes/agent/core.lisp"

  @variant_a_hash "c7babc612f8e87a2556898ac4cea31668baa0ff73153636a48b38c1faa74ab0b"
  @variant_b_hash "d39fae64506909201a5b3c542b504713984656c9f133423d9414138874282c8c"
  @variant_c_feedback_hash "ae83f8c52d178b906e2034c0937b7bc5b516825d4657ac67240e993db6d27e21"
  @prompt_hash "9bcaa98e2f05d8a1a08a1f44bbe3b1a5a23b27bbb6af33419d1582f5b1d556eb"
  @core_hash "7465d62ddc39b73969860acd45604bccbb3537aa2962ce662430d98cd5ed429a"
  @case_definition_hash "754473db7fa9d831a22a5d108765e732b574ac8bfdb283e25ce03472a2da14e5"
  @case_ids ~w(arithmetic context_filter_count context_aggregation domain_tool eval_retry memory_persistence)
  @cell_ids ~w(A B C)
  @registered_report_path "reports/kernel_eval/m2-feedback-ab-live.md"

  @type result :: %{
          suite: String.t(),
          mode: :mock | :live,
          model: String.t() | nil,
          requested_model: String.t() | nil,
          commit: String.t(),
          llm_source: String.t(),
          evidence_eligible: boolean(),
          preregistered_config: boolean(),
          case_definition_hash: String.t(),
          runs: pos_integer(),
          seed: String.t(),
          cells: [map()],
          rows: [map()],
          complete: boolean(),
          aborted: boolean(),
          abort_reason: term() | nil
        }

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    suite = Keyword.get(opts, :suite, "mini")
    mode = Keyword.get(opts, :mode, :mock)
    runs = Keyword.get(opts, :runs, 5)
    seed = Keyword.get(opts, :seed, @seed)

    with :ok <- validate_suite(suite),
         :ok <- validate_runs(runs),
         {:ok, cells} <- selected_cells(Keyword.get(opts, :cell)),
         {:ok, cases} <- selected_cases(Keyword.get(opts, :case)),
         {:ok, requested_model, model} <- resolve_model(mode, Keyword.get(opts, :model)),
         :ok <- preflight_live(mode, model, opts),
         case_definition_hash = Eval.case_definition_hash(cases),
         preregistered_config =
           preregistered_config?(%{
             suite: suite,
             mode: mode,
             runs: runs,
             seed: seed,
             requested_model: requested_model,
             temperature: Keyword.get(opts, :temperature, 0.0),
             max_tokens: Keyword.get(opts, :max_tokens, 512),
             receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
             report: Keyword.get(opts, :report),
             live_llm: Keyword.get(opts, :live_llm),
             unsafe_debug_agent: Keyword.get(opts, :unsafe_debug_agent),
             stop_on_failure: Keyword.get(opts, :stop_on_failure, false),
             case_ids: Enum.map(cases, & &1.id),
             cell_ids: Enum.map(cells, & &1.id),
             case_definition_hash: case_definition_hash
           }),
         run_context = maybe_start_run_context(preregistered_config, model, opts),
         {:ok, rows, abort_reason} <-
           run_order(
             cases,
             cells,
             suite,
             mode,
             model,
             runs,
             seed,
             opts
             |> Keyword.put(:require_provenance, preregistered_config)
             |> Keyword.put(:feedback_run_context, run_context)
           ) do
      llm_source = llm_source(mode, opts)
      expected_row_count = length(cases) * length(cells) * runs
      complete = length(rows) == expected_row_count
      commit = top_level_commit(rows)

      lifecycle_ok? = validate_lifecycle(run_context) == :ok
      abort_reason = if lifecycle_ok?, do: abort_reason, else: "repository_state_changed"

      {:ok,
       %{
         suite: suite,
         mode: mode,
         model: if(mode == :live, do: model),
         requested_model: requested_model,
         commit: commit,
         llm_source: llm_source,
         evidence_eligible:
           preregistered_config and
             lifecycle_ok? and evidence_eligible?(rows, abort_reason, expected_row_count),
         preregistered_config: preregistered_config,
         case_definition_hash: case_definition_hash,
         runs: runs,
         seed: seed,
         cells: Enum.map(cells, &Map.delete(&1, :override)),
         rows: rows,
         complete: complete,
         aborted: not is_nil(abort_reason),
         abort_reason: abort_reason,
         run_context: run_context
       }}
    end
  end

  @spec passed?(result()) :: boolean()
  def passed?(%{aborted: false, rows: rows}), do: Enum.all?(rows, &(&1.status == :pass))
  def passed?(_result), do: false

  @spec failure_count(result()) :: non_neg_integer()
  def failure_count(%{rows: rows}), do: Enum.count(rows, &(&1.status != :pass))

  @doc false
  @spec evidence_eligible?([map()], term() | nil, non_neg_integer()) :: boolean()
  def evidence_eligible?(rows, abort_reason, expected_row_count) do
    commits = rows |> Enum.map(&Map.get(&1, :commit)) |> Enum.uniq()

    is_nil(abort_reason) and rows != [] and length(rows) == expected_row_count and
      length(commits) == 1 and hd(commits) not in [nil, "unknown"] and
      Enum.all?(rows, &(&1.provenance_eligible == true))
  end

  defp top_level_commit(rows) do
    case rows |> Enum.map(&Map.get(&1, :commit)) |> Enum.uniq() do
      [commit] when is_binary(commit) -> commit
      [] -> "unknown"
      _commits -> "mixed"
    end
  end

  @doc false
  @spec preregistered_config?(map()) :: boolean()
  def preregistered_config?(config) do
    config.suite == "mini" and config.mode == :live and config.runs == 5 and
      config.seed == @seed and config.requested_model == "deepseek" and
      config.temperature == 0.0 and config.max_tokens == 512 and
      config.receive_timeout == 60_000 and registered_report_path?(config.report) and
      is_nil(config.live_llm) and
      is_nil(config.unsafe_debug_agent) and config.stop_on_failure == false and
      Enum.sort(config.case_ids) == Enum.sort(@case_ids) and
      Enum.sort(config.cell_ids) == Enum.sort(@cell_ids) and
      config.case_definition_hash == @case_definition_hash
  end

  defp registered_report_path?(path) when is_binary(path) and path != "" do
    Path.expand(path) == Path.expand(@registered_report_path)
  end

  defp registered_report_path?(_path), do: false

  @spec render_markdown(result()) :: String.t()
  def render_markdown(result) do
    rows =
      Enum.map(result.rows, fn row ->
        "| #{row.replicate} | #{row.case} | #{row.cell} | #{row.status} | #{row.action_count} | #{row.eval_count} | #{row.prompt_hash} | #{row.feedback_hash} | #{row.failure_reason || ""} |"
      end)

    summary =
      result.rows
      |> Enum.group_by(& &1.cell)
      |> Enum.sort_by(fn {cell, _rows} -> cell end)
      |> Enum.map(fn {cell, cell_rows} ->
        pass = Enum.count(cell_rows, &(&1.status == :pass))
        "| #{cell} | #{pass} | #{length(cell_rows) - pass} | #{length(cell_rows)} |"
      end)

    """
    # M2 Feedback Policy Shakedown

    evidence_level: non-M3 descriptive shakedown
    suite: #{result.suite}
    mode: #{result.mode}
    model: #{result.model || "mock"}
    requested_model: #{result.requested_model || "none"}
    commit: #{result.commit}
    llm_source: #{result.llm_source}
    evidence_eligible: #{result.evidence_eligible}
    preregistered_config: #{result.preregistered_config}
    case_definition_hash: #{result.case_definition_hash}
    complete: #{result.complete}
    runs_per_cell_case: #{result.runs}
    seed: #{result.seed}
    aborted: #{result.aborted}
    abort_reason: #{render_abort_reason(result.abort_reason)}

    ## Frozen Cells

    | cell | label | prompt_hash | feedback_hash |
    | --- | --- | --- | --- |
    #{render_cells(result.cells)}

    ## Summary

    | cell | pass | fail | total |
    | --- | ---: | ---: | ---: |
    #{Enum.join(summary, "\n")}

    ## Outcomes

    | replicate | case | cell | status | actions | evals | prompt_hash | feedback_hash | failure |
    | ---: | --- | --- | --- | ---: | ---: | --- | --- | --- |
    #{Enum.join(rows, "\n")}

    ## Claim Boundary

    This run is descriptive only. Canonical TurnEvents may be available for
    diagnostics, but this command does not supply the preregistered M3 sample
    size, stopping rules, or statistical plan required for a superiority claim.
    """
    |> String.trim()
  end

  defp render_cells(cells) do
    Enum.map_join(cells, "\n", fn cell ->
      "| #{cell.id} | #{cell.label} | #{cell.prompt_hash} | #{cell.feedback_hash} |"
    end)
  end

  defp render_abort_reason(nil), do: "none"
  defp render_abort_reason(reason), do: inspect(reason)

  defp validate_suite("mini"), do: :ok
  defp validate_suite(other), do: {:error, {:unknown_suite, other}}

  defp validate_runs(runs) when is_integer(runs) and runs > 0, do: :ok
  defp validate_runs(other), do: {:error, {:invalid_runs, other}}

  defp preflight_live(:mock, _model, _opts), do: :ok

  defp preflight_live(:live, model, opts) do
    case Eval.run_cases([],
           mode: :live,
           model: model,
           live_llm: Keyword.get(opts, :live_llm),
           report: eval_report_path([], "preflight")
         ) do
      {:ok, _empty} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight_live(other, _model, _opts), do: {:error, {:unknown_mode, other}}

  defp resolve_model(:mock, _model), do: {:ok, nil, nil}

  defp resolve_model(:live, model) do
    case Eval.resolve_model_identity(model) do
      {:ok, requested, resolved} -> {:ok, requested, resolved}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_model(other, _model), do: {:error, {:unknown_mode, other}}

  defp llm_source(:mock, _opts), do: "mock"

  defp llm_source(:live, opts) do
    if is_function(Keyword.get(opts, :live_llm), 1), do: "injected", else: "registry"
  end

  defp selected_cases(nil), do: {:ok, Eval.mini_cases()}

  defp selected_cases(case_id) do
    case Enum.filter(Eval.mini_cases(), &(&1.id == case_id)) do
      [] -> {:error, {:unknown_case, case_id}}
      cases -> {:ok, cases}
    end
  end

  defp validated_cells do
    with :ok <- validate_file_hash(@variant_a_path, @variant_a_hash),
         :ok <- validate_file_hash(@variant_b_path, @variant_b_hash),
         :ok <- validate_file_hash(@variant_c_feedback_path, @variant_c_feedback_hash),
         :ok <- validate_file_hash(@prompt_path, @prompt_hash),
         :ok <- validate_file_hash(@core_path, @core_hash),
         {:ok, cell_a} <-
           validated_cell(
             "A",
             "baseline-memory-summary-guidance",
             @prompt_path,
             @prompt_hash,
             @variant_a_path,
             @variant_a_hash
           ),
         {:ok, cell_b} <-
           validated_cell(
             "B",
             "reuse-listed-memory-names-guidance",
             @prompt_path,
             @prompt_hash,
             @variant_b_path,
             @variant_b_hash
           ),
         {:ok, cell_c} <-
           validated_cell(
             "C",
             "no-memory-guidance",
             @prompt_path,
             @prompt_hash,
             @variant_c_feedback_path,
             @variant_c_feedback_hash
           ) do
      {:ok, [cell_a, cell_b, cell_c]}
    end
  end

  defp selected_cells(nil), do: validated_cells()

  defp selected_cells(cell_id) when is_binary(cell_id) do
    with {:ok, cells} <- validated_cells() do
      case Enum.filter(cells, &(&1.id == cell_id)) do
        [] -> {:error, {:unknown_cell, cell_id}}
        selected -> {:ok, selected}
      end
    end
  end

  defp validated_cell(id, label, prompt_path, prompt_hash, feedback_path, feedback_hash) do
    override = prelude_override(prompt_path, feedback_path)

    with {:ok, prelude} <- Kernel.compile_prelude(prelude_source_overrides: override),
         {:ok, components} <- components_by_id(Prelude.trace_summary(prelude)),
         :ok <- assert_component_hash(components, "agent.prompt", prompt_hash),
         :ok <- assert_component_hash(components, "agent.core", @core_hash),
         :ok <- assert_component_hash(components, "agent.feedback", feedback_hash) do
      {:ok,
       %{
         id: id,
         label: label,
         prompt_path: prompt_path,
         prompt_hash: prompt_hash,
         feedback_path: feedback_path,
         feedback_hash: feedback_hash,
         override: override
       }}
    end
  end

  defp validate_file_hash(path, expected) do
    case File.read(path) do
      {:ok, source} ->
        actual = sha256(source)

        if actual == expected do
          :ok
        else
          {:error, {:hash_mismatch, path, expected, actual}}
        end

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  defp blocks(cases, runs, seed) do
    for replicate <- 1..runs, eval_case <- cases do
      %{replicate: replicate, case: eval_case}
    end
    |> stable_sort(seed, fn block -> "block:#{block.replicate}:#{block.case.id}" end)
  end

  defp cell_order(block, cells, seed) do
    cells
    |> stable_sort(seed, fn cell -> "cell:#{block.replicate}:#{block.case.id}:#{cell.id}" end)
    |> Enum.map(&{block, &1})
  end

  defp stable_sort(items, seed, key_fun) do
    Enum.sort_by(items, fn item -> sha256("#{seed}:#{key_fun.(item)}") end)
  end

  defp run_order(cases, cells, suite, mode, model, runs, seed, opts) do
    cases
    |> blocks(runs, seed)
    |> Enum.flat_map(&cell_order(&1, cells, seed))
    |> Enum.reduce_while({:ok, []}, fn block_cell, {:ok, rows} ->
      case run_cell_case(block_cell, suite, mode, model, opts) do
        {:ok, row} ->
          if Keyword.get(opts, :stop_on_failure) == true and row.status != :pass do
            {:halt, {:ok, [row | rows]}}
          else
            {:cont, {:ok, [row | rows]}}
          end

        {:error, reason} ->
          {:halt, {:aborted, rows, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows), nil}
      {:aborted, rows, reason} -> {:ok, Enum.reverse(rows), reason}
    end
  end

  defp run_cell_case({block, cell}, suite, mode, model, opts) do
    {unsafe_debug_agent, cleanup_debug} = unsafe_debug_agent(opts)

    try do
      with :ok <- validate_lifecycle(Keyword.get(opts, :feedback_run_context)),
           result <-
             Eval.run_cases([block.case],
               suite: suite,
               mode: mode,
               model: model,
               runs: 1,
               report: eval_report_path(opts, "#{block.case.id}-#{block.replicate}-#{cell.id}"),
               trace_dir: eval_trace_dir(opts, "#{block.case.id}-#{block.replicate}-#{cell.id}"),
               prelude_source_overrides: cell.override,
               receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
               max_tokens: Keyword.get(opts, :max_tokens, 512),
               temperature: Keyword.get(opts, :temperature, 0.0),
               live_llm: Keyword.get(opts, :live_llm),
               unsafe_debug: is_pid(unsafe_debug_agent),
               unsafe_debug_agent: unsafe_debug_agent
             ),
           :ok <- validate_lifecycle(Keyword.get(opts, :feedback_run_context)) do
        case result do
          {:ok, %{aborted: true, abort_reason: reason}} ->
            {:error, {:infrastructure_abort, block.case.id, block.replicate, cell.id, reason}}

          {:ok, %{cases: [case_result]} = eval_report} ->
            case require_preregistered_provenance(eval_report, opts) do
              :ok ->
                case validate_case_integrity(case_result) do
                  :ok ->
                    case assert_report_provenance(case_result, cell) do
                      :ok ->
                        {:ok, row(block, cell, case_result, eval_report)}

                      {:error, reason} ->
                        {:error,
                         {:provenance_mismatch, block.case.id, block.replicate, cell.id, reason}}
                    end

                  {:error, reason} ->
                    {:error,
                     {:infrastructure_abort, block.case.id, block.replicate, cell.id, reason}}
                end

              {:error, reason} ->
                {:error, {:provenance_mismatch, block.case.id, block.replicate, cell.id, reason}}
            end

          {:error, reason} ->
            {:error, {:cell_run_failed, block.case.id, block.replicate, cell.id, reason}}

          other ->
            {:error, {:unexpected_cell_result, block.case.id, block.replicate, cell.id, other}}
        end
      else
        {:error, "repository_state_changed"} ->
          {:error,
           {:infrastructure_abort, block.case.id, block.replicate, cell.id,
            "repository_state_changed"}}
      end
    rescue
      exception ->
        {:error,
         {:cell_run_raised, block.case.id, block.replicate, cell.id,
          exception |> Map.fetch!(:__struct__) |> inspect()}}
    after
      cleanup_debug.()
    end
  end

  @doc false
  def finalize_run_context(%{run_context: nil}), do: :ok
  def finalize_run_context(result) when not is_map_key(result, :run_context), do: :ok

  def finalize_run_context(%{run_context: context} = result) do
    state = if result.aborted, do: "aborted", else: "completed"
    RunContext.finish!(context, state, %{abort_reason: inspect(result.abort_reason)})
    :ok
  end

  @doc false
  def abort_run_context(%{run_context: nil}, _reason), do: :ok
  def abort_run_context(result, _reason) when not is_map_key(result, :run_context), do: :ok

  def abort_run_context(%{run_context: context}, reason) do
    RunContext.finish!(context, "aborted", %{abort_reason: inspect(reason.__struct__)})
    :ok
  end

  defp maybe_start_run_context(true, model, opts) do
    RunContext.start!(
      Keyword.fetch!(opts, :report),
      %{suite: "feedback_ab", model: model},
      opts
    )
  end

  defp maybe_start_run_context(false, _model, _opts), do: nil

  defp validate_lifecycle(nil), do: :ok
  defp validate_lifecycle(context), do: RunContext.validate(context)

  @doc false
  @spec require_preregistered_provenance(map(), keyword()) :: :ok | {:error, atom()}
  def require_preregistered_provenance(eval_report, opts) do
    if Keyword.get(opts, :require_provenance) == true and
         Map.get(eval_report, :provenance_eligible) != true do
      {:error, :ineligible_run_provenance}
    else
      :ok
    end
  end

  defp eval_report_path(opts, id) do
    directory =
      Keyword.get(
        opts,
        :eval_report_dir,
        Path.join(Mix.Project.build_path(), "kernel_eval_traces")
      )

    Path.join(directory, "feedback-ab-#{id}.md")
  end

  defp eval_trace_dir(opts, id) do
    opts
    |> Keyword.get(:eval_report_dir, Path.join(Mix.Project.build_path(), "kernel_eval_traces"))
    |> Path.join("feedback-ab-#{id}-traces")
  end

  defp unsafe_debug_agent(opts) do
    if is_pid(Keyword.get(opts, :unsafe_debug_agent)) do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {agent, fn -> if Process.alive?(agent), do: Agent.stop(agent) end}
    else
      {nil, fn -> :ok end}
    end
  end

  defp row(block, cell, case_result, eval_report) do
    %{
      replicate: block.replicate,
      case: case_result.case,
      cell: cell.id,
      label: cell.label,
      status: case_result.status,
      value: case_result.value,
      failure_reason: case_result.failure_reason,
      action_count: case_result.action_count,
      eval_count: case_result.eval_count,
      duration_ms: case_result.duration_ms,
      prompt_hash: cell.prompt_hash,
      feedback_hash: cell.feedback_hash,
      commit: eval_report.commit,
      llm_source: eval_report.llm_source,
      provenance_eligible: eval_report.provenance_eligible,
      unsafe_trace: Map.get(case_result, :unsafe_trace)
    }
  end

  @doc false
  @spec validate_case_integrity(map()) :: :ok | {:error, String.t()}
  def validate_case_integrity(%{write_errors: count}) when count > 0,
    do: {:error, "trace_integrity_failure"}

  def validate_case_integrity(%{expected_turns: expected, actual_turns: actual})
      when expected != actual,
      do: {:error, "trace_integrity_failure"}

  def validate_case_integrity(%{failure_reason: "trace_integrity_failure"}),
    do: {:error, "trace_integrity_failure"}

  def validate_case_integrity(_case_result), do: :ok

  @spec render_unsafe_debug(result()) :: String.t()
  def render_unsafe_debug(result) do
    rows =
      Enum.map_join(result.rows, "\n\n", fn row ->
        """
        ## #{row.cell} #{row.case} replicate #{row.replicate} - #{row.status}

        failure: #{row.failure_reason || ""}
        value: #{inspect(row.value, limit: 20, printable_limit: 500)}
        prompt_hash: #{row.prompt_hash}
        feedback_hash: #{row.feedback_hash}

        ```elixir
        #{inspect(row.unsafe_trace || [], pretty: true, limit: :infinity, printable_limit: :infinity)}
        ```
        """
        |> String.trim()
      end)

    """
    # UNSAFE M2 Feedback Debug Report

    This report intentionally includes raw model-visible prompts/messages and
    model-produced programs. Do not publish it as benchmark evidence.

    suite: #{result.suite}
    mode: #{result.mode}
    model: #{result.model || "mock"}
    requested_model: #{result.requested_model || "none"}
    commit: #{result.commit}
    llm_source: #{result.llm_source}
    evidence_eligible: #{result.evidence_eligible}
    preregistered_config: #{result.preregistered_config}
    case_definition_hash: #{result.case_definition_hash}
    complete: #{result.complete}
    runs_per_cell_case: #{result.runs}
    seed: #{result.seed}

    #{rows}
    """
    |> String.trim()
  end

  defp assert_report_provenance(%{trace: trace}, cell) do
    with %{prelude: %{components: components}} <- Enum.find(trace, &(&1.event == "prelude")),
         prompt when is_map(prompt) <- Enum.find(components, &(&1.id == "agent.prompt")),
         component when is_map(component) <- Enum.find(components, &(&1.id == "agent.feedback")),
         true <- prompt.source_hash == cell.prompt_hash,
         true <- component.source_hash == cell.feedback_hash do
      :ok
    else
      nil -> {:error, :missing_prelude_event}
      false -> {:error, :component_hash_mismatch}
      _ -> {:error, :missing_policy_component}
    end
  end

  defp prelude_override(prompt_path, feedback_path) do
    %{
      "agent.prompt" => %{source: File.read!(prompt_path), origin: {:file, prompt_path}},
      "agent.feedback" => %{source: File.read!(feedback_path), origin: {:file, feedback_path}}
    }
  end

  defp components_by_id(%{components: components}) do
    {:ok, Map.new(components, &{&1.id, &1})}
  end

  defp components_by_id(_summary), do: {:error, :missing_components}

  defp assert_component_hash(components, component, expected) do
    case Map.fetch(components, component) do
      {:ok, %{source_hash: ^expected}} ->
        :ok

      {:ok, %{source_hash: actual}} ->
        {:error, {:component_hash_mismatch, component, expected, actual}}

      :error ->
        {:error, {:missing_component, component}}
    end
  end

  defp sha256(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
