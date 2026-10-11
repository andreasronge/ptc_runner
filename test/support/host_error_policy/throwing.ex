defmodule PtcRunner.TestSupport.HostErrorPolicy.Throwing do
  @moduledoc false

  def sanitize_private_error(_), do: throw("POLICY_SECRET")
  def failure_metadata(_, _), do: throw("POLICY_SECRET")
end
