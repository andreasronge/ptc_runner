defmodule PtcRunner.Lisp.Prelude.AttachContext do
  @moduledoc """
  Host tool grants used to validate a prelude's `requires` at attach time.

  Tool names are strings, matching `PtcRunner.Lisp.run/2` execution lookup.
  """

  @type t :: %__MODULE__{tools: %{optional(String.t()) => term()}}

  defstruct tools: %{}

  @doc "Builds an attach context from a map or tuple-list `:tools` option."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{tools: Map.new(Keyword.get(opts, :tools, %{}))}
  end

  @doc "True when the granted tools map contains a typed tool named `name`."
  @spec grants_tool?(t(), String.t()) :: boolean()
  def grants_tool?(%__MODULE__{tools: tools}, name) when is_binary(name) do
    Map.has_key?(tools, name)
  end
end
