defmodule PtcRunner.SubAgent.Signature do
  @moduledoc """
  Signature parsing and validation for SubAgents.

  Signatures define the contract between agents and tools:
  - Input parameters - What the caller must provide
  - Output type - What the callee will return

  ## Signature Format

  Full format: `(params) -> output`
  Shorthand: `output` (equivalent to `() -> output`)

  ## Types

  - Primitives: `:string`, `:int`, `:float`, `:bool`, `:keyword`, `:any`
  - Collections: `[:type]` (list), `{field :type}` (map), `:map` (untyped map)
  - Optional: `:type?` (nullable field or parameter)

  ## Examples

      iex> {:ok, sig} = Signature.parse("(name :string) -> {greeting :string}")
      iex> sig
      {:signature, [{"name", :string}], {:map, [{"greeting", :string}]}}

      iex> {:ok, sig} = Signature.parse("{count :int}")
      iex> sig
      {:signature, [], {:map, [{"count", :int}]}}

  """

  alias PtcRunner.SubAgent.Signature.Parser
  alias PtcRunner.SubAgent.Signature.Validator

  @type signature :: {:signature, [param()], return_type()}

  @type param :: {String.t(), type()}

  @type type ::
          :string
          | :int
          | :float
          | :bool
          | :keyword
          | :any
          | :map
          | {:optional, type()}
          | {:list, type()}
          | {:map, [field()]}

  @type field :: {String.t(), type()}

  @type return_type :: type()

  @type validation_error :: %{
          path: [String.t() | non_neg_integer()],
          message: String.t()
        }

  @doc """
  Parse a signature string into internal format.

  Returns `{:ok, signature()}` or `{:error, reason}`.

  ## Examples

      iex> Signature.parse("(id :int) -> {name :string}")
      {:ok, {:signature, [{"id", :int}], {:map, [{"name", :string}]}}}

      iex> Signature.parse("() -> :string")
      {:ok, {:signature, [], :string}}

      iex> Signature.parse("{count :int}")
      {:ok, {:signature, [], {:map, [{"count", :int}]}}}

      iex> Signature.parse("invalid")
      {:error, "..."}
  """
  @spec parse(String.t()) :: {:ok, signature()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    Parser.parse(input)
  end

  def parse(input) do
    {:error, "signature must be a string, got #{inspect(input)}"}
  end

  @doc """
  Validate data against a signature's return type.

  Returns `:ok` or `{:error, [validation_error()]}`.

  ## Examples

      iex> {:ok, sig} = Signature.parse("() -> {count :int, items [:string]}")
      iex> Signature.validate(sig, {:count => 5, :items => ["a", "b"]})
      :ok

      iex> {:ok, sig} = Signature.parse("() -> :int")
      iex> Signature.validate(sig, "not an int")
      {:error, [%{path: [], message: "expected int, got string"}]}
  """
  @spec validate(signature(), term()) :: :ok | {:error, [validation_error()]}
  def validate({:signature, _params, return_type}, data) do
    Validator.validate(data, return_type)
  end

  def validate(signature, _data) do
    {:error, "signature must be a parsed signature tuple, got #{inspect(signature)}"}
  end

  @doc """
  Validate input parameters against a signature.

  Returns `:ok` or `{:error, [validation_error()]}`.
  """
  @spec validate_input(signature(), map()) :: :ok | {:error, [validation_error()]}
  def validate_input({:signature, params, _return_type}, input) do
    Validator.validate(input, {:map, params})
  end

  def validate_input(signature, _input) do
    {:error, "signature must be a parsed signature tuple, got #{inspect(signature)}"}
  end

  @doc """
  Format a signature back to string representation.

  Used for rendering in prompts or debugging.
  """
  @spec render(signature()) :: String.t()
  def render({:signature, params, return_type}) do
    params_str =
      Enum.map_join(params, ", ", fn {name, type} -> "#{name} #{render_type(type)}" end)

    if params == [] do
      "-> #{render_type(return_type)}"
    else
      "(#{params_str}) -> #{render_type(return_type)}"
    end
  end

  # ============================================================
  # Type Rendering
  # ============================================================

  defp render_type(:string), do: ":string"
  defp render_type(:int), do: ":int"
  defp render_type(:float), do: ":float"
  defp render_type(:bool), do: ":bool"
  defp render_type(:keyword), do: ":keyword"
  defp render_type(:any), do: ":any"
  defp render_type(:map), do: ":map"

  defp render_type({:optional, type}) do
    render_type(type) <> "?"
  end

  defp render_type({:list, element_type}) do
    "[" <> render_type(element_type) <> "]"
  end

  defp render_type({:map, fields}) do
    fields_str =
      Enum.map_join(fields, ", ", fn {name, type} -> "#{name} #{render_type(type)}" end)

    "{#{fields_str}}"
  end
end
