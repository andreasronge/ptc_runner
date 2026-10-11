defmodule PtcRunner.TestSupport.HostErrorPolicy.Deep do
  @moduledoc false

  def sanitize_private_error(_), do: {:ok, {:host_error, "deep", nested(40)}}
  def failure_metadata(_, _), do: nested(5)

  defp nested(depth), do: Enum.reduce(1..depth, %{}, fn _, value -> %{nested: value} end)
end
