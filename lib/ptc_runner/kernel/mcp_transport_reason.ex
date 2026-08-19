defmodule PtcRunner.Kernel.MCPTransportReason do
  @moduledoc false

  alias PtcRunner.Kernel.ProviderError

  @reasons %{
    connection_refused: {:mcp_endpoint_connection_refused, true},
    name_not_resolved: {:mcp_endpoint_name_unresolved, false},
    tls_handshake_failed: {:mcp_endpoint_tls_failed, false}
  }
  @provider_reasons Map.new(@reasons, fn {_http_reason, {mcp_reason, retryable?}} ->
                      {mcp_reason, retryable?}
                    end)

  @type provenance :: :not_dispatched | :dispatched | :possibly_dispatched

  @spec from_http(term(), provenance()) ::
          {:error, atom(), provenance()} | {:error, atom()}
  def from_http(reason, provenance)
      when provenance in [:not_dispatched, :dispatched, :possibly_dispatched] do
    case Map.fetch(@reasons, reason) do
      {:ok, {mcp_reason, _retryable?}} -> {:error, mcp_reason, provenance}
      :error -> fallback(reason)
    end
  end

  @spec provider_error(term(), :read | :write | :unknown, provenance()) ::
          {:ok, ProviderError.t()} | :error
  def provider_error(reason, effect, provenance)
      when effect in [:read, :write, :unknown] and
             provenance in [:not_dispatched, :dispatched, :possibly_dispatched] do
    with {:ok, retryable?} <- Map.fetch(@provider_reasons, reason) do
      mutation_options =
        if effect in [:write, :unknown] and provenance == :possibly_dispatched,
          do: [mutation_state: :indeterminate],
          else: []

      {:ok,
       ProviderError.new(
         :transport_error,
         Atom.to_string(reason),
         [retryable?: retryable?, dispatch_provenance: provenance] ++ mutation_options
       )}
    end
  end

  def provider_error(_reason, _effect, _provenance), do: :error

  defp fallback(:timeout), do: {:error, :mcp_timeout}
  defp fallback(:response_exceeded), do: {:error, :mcp_response_exceeded}
  defp fallback(_reason), do: {:error, :mcp_transport_error}
end
