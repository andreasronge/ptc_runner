defmodule PtcRunner.Kernel.MCPTransportReasonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPTransportReason
  alias PtcRunner.Kernel.ProviderError

  @reasons [
    {:connection_refused, :mcp_endpoint_connection_refused, true},
    {:name_not_resolved, :mcp_endpoint_name_unresolved, false},
    {:tls_handshake_failed, :mcp_endpoint_tls_failed, false}
  ]

  test "normalizes closed HTTP reasons without losing proven provenance" do
    for {http_reason, mcp_reason, _retryable?} <- @reasons do
      assert {:error, ^mcp_reason, :not_dispatched} =
               MCPTransportReason.from_http(http_reason, :not_dispatched)
    end

    assert {:error, :mcp_timeout} =
             MCPTransportReason.from_http(:timeout, :possibly_dispatched)

    assert {:error, :mcp_response_exceeded} =
             MCPTransportReason.from_http(:response_exceeded, :possibly_dispatched)

    assert {:error, :mcp_transport_error} =
             MCPTransportReason.from_http(:transport_error, :possibly_dispatched)
  end

  test "projects closed invocation errors with bounded details and retry policy" do
    for {_http_reason, mcp_reason, retryable?} <- @reasons,
        effect <- [:read, :write] do
      assert {:ok,
              %ProviderError{
                kind: :transport_error,
                details: details,
                retryable?: ^retryable?,
                dispatch_provenance: :not_dispatched,
                mutation_state: nil
              }} = MCPTransportReason.provider_error(mcp_reason, effect, :not_dispatched)

      assert details == Atom.to_string(mcp_reason)
    end
  end

  test "keeps any unexpectedly ambiguous write conservative" do
    assert {:ok,
            %ProviderError{
              retryable?: false,
              dispatch_provenance: :possibly_dispatched,
              mutation_state: :indeterminate
            }} =
             MCPTransportReason.provider_error(
               :mcp_endpoint_connection_refused,
               :write,
               :possibly_dispatched
             )
  end

  test "refuses reasons outside its closed vocabulary" do
    assert :error =
             MCPTransportReason.provider_error(
               :mcp_transport_error,
               :read,
               :not_dispatched
             )
  end
end
