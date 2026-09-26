defmodule PtcRunner.Kernel.MCPTransportReasonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPTransportReason
  alias PtcRunner.Kernel.ProviderError

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
