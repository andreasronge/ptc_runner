defmodule PtcRunner.TestSupport.RunLifecycle do
  @moduledoc false

  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunRequest

  def build(request_result, registry, opts \\ [])

  def build({:ok, %RunRequest{} = request}, %ProviderRegistry{} = registry, opts),
    do: RunBuilder.build(request, registry, opts)

  def build({:error, _reason} = error, %ProviderRegistry{}, _opts), do: error

  def build({request_result, %ProviderRegistry{} = registry, opts}) when is_list(opts),
    do: build(request_result, registry, opts)

  def execute(build_result) do
    case execute_with_class(build_result) do
      {:ok, result, _class} -> {:ok, result}
      other -> other
    end
  end

  def execute_with_class({:ok, %{publication_authority: authority} = built}) do
    case RunBuilder.execute_built(built) do
      {:ok, %ExecutionOutcome{} = outcome} ->
        result = published_result(outcome, authority)
        prefer_cleanup_error(result, PublicationAuthority.close(authority))

      {:error, _reason} = error ->
        prefer_cleanup_error(error, PublicationAuthority.abort(authority))
    end
  end

  def execute_with_class({:error, _reason} = error), do: error

  defp published_result(outcome, authority) do
    case RunBuilder.publish_execution_report(outcome, authority) do
      {:ok, %{result: {:ok, result}, result_class: class}} -> {:ok, result, class}
      {:ok, %{result: {:error, reason}}} -> {:error, reason}
      {:error, %{error: error, result: result}} -> publication_error(error, result)
      {:error, %{error: error}} -> publication_error(error)
      {:error, _report} -> {:error, :invalid_execution_outcome}
    end
  end

  defp publication_error({:result_contract_failed, _details} = error), do: {:error, error}

  defp publication_error({:error, {:result_contract_failed, _details} = error}),
    do: {:error, error}

  defp publication_error(%PtcRunner.Kernel.Error{} = error), do: {:error, error}

  defp publication_error({stage, reason}) when stage in [:trace, :inspection, :result],
    do: {:error, {persistence_failure(stage), reason}}

  defp publication_error(error), do: {:error, error}

  defp publication_error({stage, reason}, result) when stage in [:trace, :inspection, :result],
    do: {:error, {persistence_failure(stage), reason, result}}

  defp publication_error(error, result), do: {:error, {error, result}}

  defp persistence_failure(:trace), do: :trace_persistence_failed
  defp persistence_failure(:inspection), do: :inspection_persistence_failed
  defp persistence_failure(:result), do: :result_persistence_failed

  defp prefer_cleanup_error(_result, {:error, _reason} = cleanup), do: cleanup
  defp prefer_cleanup_error(result, :ok), do: result
end
