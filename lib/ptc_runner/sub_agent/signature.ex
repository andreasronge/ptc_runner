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
  alias PtcRunner.SubAgent.Signature.Renderer
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
      iex> Signature.validate(sig, %{count: 5, items: ["a", "b"]})
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
  def render(signature) do
    Renderer.render(signature)
  end

  @doc """
  Convert a signature to JSON Schema format.

  Extracts the return type and converts it to a JSON Schema
  that can be passed to LLM providers for structured output.

  Note: Array return types are wrapped in an object with an "items" property
  because most LLM providers require an object at the root level. Use
  `returns_list?/1` to check if unwrapping is needed.

  ## Examples

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("() -> {sentiment :string, score :float}")
      iex> PtcRunner.SubAgent.Signature.to_json_schema(sig)
      %{
        "type" => "object",
        "properties" => %{
          "sentiment" => %{"type" => "string"},
          "score" => %{"type" => "number"}
        },
        "required" => ["sentiment", "score"],
        "additionalProperties" => false
      }

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("() -> [:int]")
      iex> PtcRunner.SubAgent.Signature.to_json_schema(sig)
      %{
        "type" => "object",
        "properties" => %{
          "items" => %{"type" => "array", "items" => %{"type" => "integer"}}
        },
        "required" => ["items"],
        "additionalProperties" => false
      }

  """
  @spec to_json_schema(signature()) :: map()
  def to_json_schema({:signature, _params, {:list, _} = list_type}) do
    # Wrap arrays in object because most LLM providers require object at root
    %{
      "type" => "object",
      "properties" => %{
        "items" => type_to_json_schema(list_type)
      },
      "required" => ["items"],
      "additionalProperties" => false
    }
  end

  def to_json_schema({:signature, _params, return_type}) do
    type_to_json_schema(return_type)
  end

  @doc """
  Check if signature returns a list type.

  Used to determine if JSON mode response needs unwrapping.
  """
  @spec returns_list?(signature()) :: boolean()
  def returns_list?({:signature, _params, {:list, _}}), do: true
  def returns_list?(_), do: false

  @doc false
  @spec type_to_json_schema(type()) :: map()
  def type_to_json_schema(:string), do: %{"type" => "string"}
  def type_to_json_schema(:int), do: %{"type" => "integer"}
  def type_to_json_schema(:float), do: %{"type" => "number"}
  def type_to_json_schema(:bool), do: %{"type" => "boolean"}
  def type_to_json_schema(:keyword), do: %{"type" => "string"}
  # Bedrock requires input_schema to have a "type" field, so :any uses "object"
  def type_to_json_schema(:any), do: %{"type" => "object"}
  def type_to_json_schema(:map), do: %{"type" => "object"}

  def type_to_json_schema({:list, inner_type}) do
    %{"type" => "array", "items" => type_to_json_schema(inner_type)}
  end

  def type_to_json_schema({:optional, inner_type}) do
    # Optional just affects the required list, not the type schema
    type_to_json_schema(inner_type)
  end

  def type_to_json_schema({:map, fields}) do
    {properties, required} =
      Enum.reduce(fields, {%{}, []}, fn {name, type}, {props, req} ->
        {inner_type, is_optional} = unwrap_optional(type)
        schema = type_to_json_schema(inner_type)
        props = Map.put(props, name, schema)
        req = if is_optional, do: req, else: [name | req]
        {props, req}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required),
      "additionalProperties" => false
    }
  end

  @doc false
  @spec unwrap_optional(type()) :: {type(), boolean()}
  def unwrap_optional({:optional, inner}), do: {inner, true}
  def unwrap_optional(type), do: {type, false}
end
