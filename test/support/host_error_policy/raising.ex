defmodule PtcRunner.TestSupport.HostErrorPolicy.Raising do
  @moduledoc false

  def sanitize_private_error(_), do: raise("POLICY_SECRET")
  def failure_metadata(_, _), do: raise("POLICY_SECRET")
end
