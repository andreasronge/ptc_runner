defmodule PtcRunner.Kernel.CommandMaterialize do
  @moduledoc false

  alias PtcRunner.Kernel.CommandApplicationDiagnostic
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.Materialize

  @spec dispatch(CommandArguments.t(), binary()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(%CommandArguments{command: :materialize} = arguments, run_ref)
      when is_binary(run_ref) do
    case Materialize.run(arguments.application, materialize_opts(arguments.options)) do
      {:ok, {:source_out, path}} ->
        {:ok,
         CommandOutcome.success(:materialize, run_ref, %{"mode" => "source-out", "path" => path})}

      {:ok, {:candidate, _report, published}} ->
        {:ok,
         CommandOutcome.success(:materialize, run_ref, %{
           "mode" => "candidate",
           "directory" => published.directory
         })}

      {:refused, _report} ->
        publication_error(run_ref, :candidate_refused)

      {:error, reason} ->
        materialize_error(run_ref, reason)
    end
  end

  defp materialize_opts(options) do
    [
      component: Map.get(options, :component),
      workflow: Map.get(options, :workflow),
      target_mission: Map.get(options, :target_mission),
      source_out: Map.get(options, :source_out),
      out: Map.get(options, :out),
      source: Map.get(options, :source),
      from_result: Map.get(options, :from_result),
      result_pointer: Map.get(options, :result_pointer),
      origin_run_id: Map.get(options, :origin_run_id),
      origin_prompt_hash: Map.get(options, :origin_prompt_hash),
      origin_authored_at: Map.get(options, :origin_authored_at),
      accept_widened_effect: Map.get(options, :accept_widened_effect)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp materialize_error(run_ref, reason) do
    case publication_code(reason) do
      {:ok, code} ->
        publication_error(run_ref, code)

      :error ->
        diagnostic = CommandApplicationDiagnostic.project(:materialize, reason)
        {:error, CommandOutcome.error(:materialize, run_ref, diagnostic)}
    end
  end

  defp publication_code(:source_out_destination_exists), do: {:ok, :source_out_destination_exists}
  defp publication_code(:source_out_parent_unusable), do: {:ok, :source_out_parent_unusable}
  defp publication_code(:source_out_failed), do: {:ok, :source_out_failed}
  defp publication_code(:candidate_source_too_large), do: {:ok, :candidate_source_too_large}
  defp publication_code(:unreadable_candidate_source), do: {:ok, :unreadable_candidate_source}
  defp publication_code(:candidate_cleanup_failed), do: {:ok, :candidate_cleanup_failed}
  defp publication_code(:candidate_destination_exists), do: {:ok, :candidate_destination_exists}
  defp publication_code(:candidate_publication_failed), do: {:ok, :candidate_publication_failed}
  defp publication_code(:invalid_candidate_destination), do: {:ok, :invalid_candidate_destination}
  defp publication_code(:descriptor_too_large), do: {:ok, :descriptor_too_large}
  defp publication_code(:result_artifact_too_large), do: {:ok, :result_artifact_too_large}
  defp publication_code(:unreadable_result_artifact), do: {:ok, :unreadable_result_artifact}
  defp publication_code(:result_artifact_invalid), do: {:ok, :result_artifact_invalid}
  defp publication_code(:override_component_not_selected), do: {:ok, :selected_component_missing}

  defp publication_code(reason)
       when reason in [
              :missing_result_pointer,
              :invalid_result_pointer,
              :result_pointer_missing,
              :result_pointer_not_a_string
            ],
       do: {:ok, :result_pointer_invalid}

  defp publication_code(_reason), do: :error

  defp publication_error(run_ref, code) do
    diagnostic = CommandDiagnostic.new!(:publication, code)
    {:error, CommandOutcome.error(:materialize, run_ref, diagnostic)}
  end
end
