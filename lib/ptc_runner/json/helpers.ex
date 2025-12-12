defmodule PtcRunner.Json.Helpers do
  @moduledoc false

  @doc false
  def is_implicit_object(node) when is_map(node) do
    not Map.has_key?(node, "op")
  end
end
