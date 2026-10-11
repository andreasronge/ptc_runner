defmodule PtcRunner.TestSupport.HostErrorPolicy.Alternate do
  @moduledoc false

  def sanitize_private_error(_),
    do:
      {:ok, {:runtime_limit_exceeded, "alternate policy", %{limit: :agent_turns, limit_value: 2}}}

  def failure_metadata(_, _), do: %{failure_kind: "alternate"}
end
