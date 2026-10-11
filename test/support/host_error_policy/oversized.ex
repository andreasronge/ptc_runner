defmodule PtcRunner.TestSupport.HostErrorPolicy.Oversized do
  @moduledoc false

  def sanitize_private_error(_),
    do: {:ok, {:host_error, "oversized policy", %{value: String.duplicate("x", 262_145)}}}

  def failure_metadata(_, _), do: %{failure_kind: String.duplicate("x", 4097)}
end
