defmodule PtcRunner.TestSupport.HostErrorPolicy.Invalid do
  @moduledoc false

  def sanitize_private_error(_), do: {:ok, self()}
  def failure_metadata(_, _), do: "POLICY_SECRET"
end
