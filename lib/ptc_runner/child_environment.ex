defmodule PtcRunner.ChildEnvironment do
  @moduledoc false

  @doc """
  Builds Port environment overrides that remove inherited variables except the
  explicitly retained names. An empty Port environment list inherits everything.
  """
  @spec clear_environment([String.t()]) :: [{charlist(), false}]
  def clear_environment(retained_names \\ []) do
    System.get_env()
    |> Map.keys()
    |> Enum.reject(&(&1 in retained_names))
    |> Enum.map(&{String.to_charlist(&1), false})
  end
end
