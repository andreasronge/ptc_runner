defmodule PtcRunner.TestSupport.TestHelpers do
  @moduledoc """
  Shared test helper functions used across multiple test files.
  """

  @doc "Dummy tool that ignores name and args and returns :ok"
  def dummy_tool(_name, _args), do: :ok
end
