defmodule PtcRunnerMcp.Sessions.Policy.Grant do
  @moduledoc false

  defstruct [
    :role,
    :fingerprint,
    ptc_tools: :all,
    upstream_tools: MapSet.new(),
    credentials: MapSet.new(),
    prelude_store: :read,
    preludes: :all,
    modes: MapSet.new([:read_only]),
    strict_transitive_calls: false
  ]
end
