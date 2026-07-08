defmodule PtcRunner.Kernel.FeedbackAB do
  @moduledoc false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Eval
  alias PtcRunner.Lisp.Prelude

  @seed "s19-feedback-ab-order-v1"
  @variant_a_path "priv/kernel_feedback_variants/feedback_a_default.lisp"
  @variant_b_path "priv/kernel_feedback_variants/feedback_b_memory_guidance.lisp"
  @prompt_path "priv/preludes/agent/prompt.lisp"
  @core_path "priv/preludes/agent/core.lisp"

  @variant_a_hash "b220eb0b285e2d4bae6454889f8b90d893dc3dc017b6c9e28fabee9b951ae474"
  @variant_b_hash "ef9bd2769fc404feed1db14e1de2923b4f6105f325b073cb0632c046f522eafe"
  @prompt_hash "827d9850b274a809f36782f3cd2c36191a5daf9b61fed3ebef381e4096cec29e"
  @core_hash "04470ec980f6e9f99988d31779b7b5b25c14da4a0e6a4342477176b4d28a370f"

  @type result :: %{
          suite: String.t(),
          mode: :mock | :live,
          model: String.t() | nil,
          runs: pos_integer(),
          seed: String.t(),
          cells: [map()],
          rows: [map()]
        }

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    suite = Keyword.get(opts, :suite, "mini")
    mode = Keyword.get(opts, :mode, :mock)
    runs = Keyword.get(opts, :runs, 5)
    seed = Keyword.get(opts, :seed, @seed)

    with :ok <- validate_suite(suite),
         :ok <- validate_runs(runs),
         {:ok, cells} <- validated_cells(),
         {:ok, cases} <- selected_cases(Keyword.get(opts, :case)),
         {:ok, model} <- resolve_model(mode, Keyword.get(opts, :model)),
         :ok <- preflight_live(mode, model),
         {:ok, rows} <- run_order(cases, cells, suite, mode, model, runs, seed, opts) do
      {:ok,
       %{
         suite: suite,
         mode: mode,
         model: if(mode == :live, do: model),
         runs: runs,
         seed: seed,
         cells: Enum.map(cells, &Map.delete(&1, :override)),
         rows: rows
       }}
    end
  end

  @spec passed?(result()) :: boolean()
  def passed?(%{rows: rows}), do: Enum.all?(rows, &(&1.status == :pass))

  @spec failure_count(result()) :: non_neg_integer()
  def failure_count(%{rows: rows}), do: Enum.count(rows, &(&1.status != :pass))

  @spec render_markdown(result()) :: String.t()
  def render_markdown(result) do
    rows =
      Enum.map(result.rows, fn row ->
        "| #{row.replicate} | #{row.case} | #{row.cell} | #{row.status} | #{row.action_count} | #{row.eval_count} | #{row.feedback_hash} | #{row.failure_reason || ""} |"
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
    # S19 Feedback A/B Shakedown

    evidence_level: non-M3 descriptive shakedown
    suite: #{result.suite}
    mode: #{result.mode}
    model: #{result.model || "mock"}
    runs_per_cell_case: #{result.runs}
    seed: #{result.seed}

    ## Frozen Cells

    | cell | label | source_hash |
    | --- | --- | --- |
    #{render_cells(result.cells)}

    ## Summary

    | cell | pass | fail | total |
    | --- | ---: | ---: | ---: |
    #{Enum.join(summary, "\n")}

    ## Outcomes

    | replicate | case | cell | status | actions | evals | feedback_hash | failure |
    | ---: | --- | --- | --- | ---: | ---: | --- | --- |
    #{Enum.join(rows, "\n")}

    ## Claim Boundary

    This run is descriptive only. D4 canonical TurnEvents are not present, so
    these outcomes do not support an M3 verdict or statistical superiority claim.
    """
    |> String.trim()
  end

  defp render_cells(cells) do
    Enum.map_join(cells, "\n", fn cell ->
      "| #{cell.id} | #{cell.label} | #{cell.source_hash} |"
    end)
  end

  defp validate_suite("mini"), do: :ok
  defp validate_suite(other), do: {:error, {:unknown_suite, other}}

  defp validate_runs(runs) when is_integer(runs) and runs > 0, do: :ok
  defp validate_runs(other), do: {:error, {:invalid_runs, other}}

  defp preflight_live(:mock, _model), do: :ok

  defp preflight_live(:live, model) do
    case Eval.run_cases([], mode: :live, model: model) do
      {:ok, _empty} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight_live(other, _model), do: {:error, {:unknown_mode, other}}

  defp resolve_model(:mock, _model), do: {:ok, nil}
  defp resolve_model(:live, model), do: Eval.resolve_model(model)
  defp resolve_model(other, _model), do: {:error, {:unknown_mode, other}}

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
         :ok <- validate_file_hash(@prompt_path, @prompt_hash),
         :ok <- validate_file_hash(@core_path, @core_hash),
         {:ok, cell_a} <-
           validated_cell(
             "A",
             "default-memory-summary-guidance",
             @variant_a_path,
             @variant_a_hash
           ),
         {:ok, cell_b} <-
           validated_cell(
             "B",
             "reuse-listed-memory-names-guidance",
             @variant_b_path,
             @variant_b_hash
           ) do
      {:ok, [cell_a, cell_b]}
    end
  end

  defp validated_cell(id, label, path, source_hash) do
    override = feedback_override(path)

    with {:ok, prelude} <- Kernel.compile_prelude(prelude_source_overrides: override),
         {:ok, components} <- components_by_id(Prelude.trace_summary(prelude)),
         :ok <- assert_component_hash(components, "agent.prompt", @prompt_hash),
         :ok <- assert_component_hash(components, "agent.core", @core_hash),
         :ok <- assert_component_hash(components, "agent.feedback", source_hash) do
      {:ok,
       %{
         id: id,
         label: label,
         source_path: path,
         source_hash: source_hash,
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
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp run_cell_case({block, cell}, suite, mode, model, opts) do
    case Eval.run_cases([block.case],
           suite: suite,
           mode: mode,
           model: model,
           runs: 1,
           prelude_source_overrides: cell.override,
           receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
           max_tokens: Keyword.get(opts, :max_tokens, 512),
           temperature: Keyword.get(opts, :temperature, 0.0)
         ) do
      {:ok, %{cases: [case_result]}} ->
        case assert_report_provenance(case_result, cell) do
          :ok ->
            {:ok, row(block, cell, case_result)}

          {:error, reason} ->
            {:error, {:provenance_mismatch, block.case.id, block.replicate, cell.id, reason}}
        end

      {:error, reason} ->
        {:error, {:cell_run_failed, block.case.id, block.replicate, cell.id, reason}}

      other ->
        {:error, {:unexpected_cell_result, block.case.id, block.replicate, cell.id, other}}
    end
  end

  defp row(block, cell, case_result) do
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
      feedback_hash: cell.source_hash
    }
  end

  defp assert_report_provenance(%{trace: trace}, cell) do
    with %{prelude: %{components: components}} <- Enum.find(trace, &(&1.event == "prelude")),
         component when is_map(component) <- Enum.find(components, &(&1.id == "agent.feedback")),
         true <- component.source_hash == cell.source_hash do
      :ok
    else
      nil -> {:error, :missing_prelude_event}
      false -> {:error, :feedback_hash_mismatch}
      _ -> {:error, :missing_feedback_component}
    end
  end

  defp feedback_override(path) do
    %{"agent.feedback" => %{source: File.read!(path), origin: {:file, path}}}
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
