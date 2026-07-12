defprotocol PtcRunner.Lisp.UpstreamAccess do
  @moduledoc false
  @fallback_to_any true

  @spec tool_grants(t()) :: :all | MapSet.t(binary())
  def tool_grants(runtime)

  @spec constrain(t(), :all | MapSet.t(binary())) ::
          {:ok, :all | MapSet.t(binary())} | {:error, binary()}
  def constrain(runtime, grants)

  @spec upstream(t(), binary()) :: map() | nil
  def upstream(runtime, server)
end

defimpl PtcRunner.Lisp.UpstreamAccess, for: Any do
  def tool_grants(_runtime), do: MapSet.new()

  def constrain(_runtime, _grants),
    do: {:error, "unsupported upstream runtime handle"}

  def upstream(_runtime, _server), do: nil
end
