defmodule PtcRunner.TestSupport.RaisingInspectStruct do
  @moduledoc false

  defstruct [:body]
end

defimpl Inspect, for: PtcRunner.TestSupport.RaisingInspectStruct do
  def inspect(_struct, _opts), do: raise("inspect should not run")
end
