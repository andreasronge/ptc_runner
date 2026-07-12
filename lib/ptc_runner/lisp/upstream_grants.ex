defmodule PtcRunner.Lisp.UpstreamGrants do
  @moduledoc false

  @spec normalize(:all | MapSet.t(binary()) | [binary()]) ::
          {:ok, :all | MapSet.t(binary())} | {:error, binary()}
  def normalize(:all), do: {:ok, :all}

  def normalize(%MapSet{} = grants) do
    if Enum.all?(grants, &valid?/1),
      do: {:ok, grants},
      else: {:error, error_message()}
  end

  def normalize(grants) when is_list(grants), do: grants |> MapSet.new() |> normalize()
  def normalize(_grants), do: {:error, error_message()}

  defp valid?("upstream:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> true
      _invalid -> false
    end
  end

  defp valid?(_grant), do: false

  defp error_message,
    do: "upstream_tool_grants must be :all or upstream:<server>/<tool> strings"
end
