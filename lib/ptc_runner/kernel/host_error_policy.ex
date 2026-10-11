defmodule PtcRunner.Kernel.HostErrorPolicy do
  @moduledoc false
  @behaviour PtcRunner.Lisp.HostErrorPolicy

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.LLM.OutputLimit

  @impl true
  def sanitize_private_error({:runtime_limit_exceeded, _message, %{limit: limit} = details})
      when limit in [:subordinate_evaluations, :agent_turns, :max_transcript_chars] do
    with true <- valid_runtime_value?(limit, Map.get(details, :limit_value)),
         retained <- Map.take(details, runtime_fields(limit)) |> retain_evaluator_failure(details),
         {:ok, _name, message} <- RuntimeLimitDiagnostic.details_message(retained) do
      {:ok, {:runtime_limit_exceeded, message, retained}}
    else
      _invalid -> :error
    end
  end

  def sanitize_private_error({:model_output_truncated, _message, details}) do
    with {:ok, retained} <- output_details(details) do
      {:ok, {:model_output_truncated, "model output was truncated", retained}}
    end
  end

  def sanitize_private_error(
        {:llm_provider_failed, _message, %{failure_kind: "llm-provider-error"} = details}
      ) do
    case SafeMetadata.retain_llm_provider_failure_fields(details) do
      retained when map_size(retained) == 2 ->
        rebuilt =
          retained
          |> Map.put(:failure_kind, "llm-provider-error")
          |> Map.merge(LLMReplayDiagnostic.retain_candidate_metadata(details))

        {:ok, {:llm_provider_failed, "LLM provider request failed", rebuilt}}

      _invalid ->
        :error
    end
  end

  def sanitize_private_error({:invalid_agent_config, _message, details}) do
    with {:ok, retained} <- AgentConfigDiagnostic.retain_details(details),
         {:ok, message} <- AgentConfigDiagnostic.message(retained) do
      {:ok, {:invalid_agent_config, message, retained}}
    end
  end

  def sanitize_private_error({:result_contract_failed, _message, details}) do
    with {:ok, retained} <- ResultContractDiagnostic.retain_details(details),
         {:ok, message} <-
           ResultContractDiagnostic.message(retained.agent_turns, retained.constraint) do
      {:ok, {:result_contract_failed, message, retained}}
    end
  end

  def sanitize_private_error({:phase_return_contract_failed, _message, details}) do
    with {:ok, retained} <- ResultContractDiagnostic.retain_phase_details(details) do
      {:ok,
       {:phase_return_contract_failed, "standalone phase-return contract correction exhausted",
        retained}}
    end
  end

  def sanitize_private_error(_reason), do: :error

  @impl true
  def failure_metadata(value, :extract), do: SafeMetadata.failure_metadata(value)
  def failure_metadata(value, :retain), do: SafeMetadata.retain_failure_metadata(value)

  defp output_details(%{
         limit: :max_tokens,
         limit_value: value,
         limit_bindings: bindings,
         alias: alias_name
       }) do
    with {:ok, normalized} <-
           OutputLimit.normalize(%{name: :max_tokens, value: value, bindings: bindings}),
         true <- OutputLimit.valid_alias?(alias_name) do
      {:ok,
       %{
         limit: :max_tokens,
         limit_value: value,
         limit_bindings: normalized.bindings,
         alias: alias_name
       }}
    else
      _invalid -> :error
    end
  end

  defp output_details(%{alias: alias_name} = details) when map_size(details) >= 1 do
    if Map.has_key?(details, :limit) or Map.has_key?(details, :limit_value) or
         Map.has_key?(details, :limit_bindings) do
      :error
    else
      if OutputLimit.valid_alias?(alias_name), do: {:ok, %{alias: alias_name}}, else: :error
    end
  end

  defp output_details(_details), do: :error

  defp retain_evaluator_failure(
         %{limit: :agent_turns, limit_reason: :evaluation_error} = retained,
         %{last_evaluator_failure: %{kind: kind, details: details}}
       )
       when is_map(details) do
    case EvaluatorError.retain_reason({kind, details}) do
      {:ok, {kind, rebuilt}} ->
        Map.put(retained, :last_evaluator_failure, %{kind: kind, details: rebuilt})

      :error ->
        retained
    end
  end

  defp retain_evaluator_failure(retained, _details), do: retained

  defp valid_runtime_value?(:subordinate_evaluations, value) do
    with {:ok, row} <- LimitCatalog.fetch(:subordinate_evaluations) do
      LimitCatalog.valid_value?(row, value)
    end
  end

  defp valid_runtime_value?(:agent_turns, value), do: is_integer(value) and value in 1..128

  defp valid_runtime_value?(:max_transcript_chars, value),
    do: is_integer(value) and value in 1..1_000_000

  defp runtime_fields(:agent_turns), do: [:limit, :limit_value, :limit_reason]
  defp runtime_fields(_limit), do: [:limit, :limit_value]
end
