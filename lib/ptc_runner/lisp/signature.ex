defmodule PtcRunner.Lisp.Signature do
  @moduledoc """
  Signature parsing and validation for PTC-Lisp component exports.

  Signatures define the public contract of a prompt-visible function:
  - Input parameters - What the caller must provide
  - Output type - What the callee will return

  ## Signature Format

  Full format: `(params) -> output`
  Shorthand: `output` (equivalent to `() -> output`)

  ## Types

  - Primitives: `:string`, `:int`, `:float`, `:bool`, `:keyword`, `:any`, `:datetime`
  - Collections: `[:type]` (list), `{field :type}` (map), `:map` (untyped map)
  - Optional: `:type?` (nullable field or parameter)

  ## Examples

      iex> {:ok, sig} = PtcRunner.Lisp.Signature.parse("(name :string) -> {greeting :string}")
      iex> sig
      {:signature, [{"name", :string}], {:map, [{"greeting", :string}]}}

      iex> {:ok, sig} = PtcRunner.Lisp.Signature.parse("{count :int}")
      iex> sig
      {:signature, [], {:map, [{"count", :int}]}}

  """

  alias PtcRunner.Lisp.Signature.Parser
  alias PtcRunner.Lisp.Signature.Renderer
  alias PtcRunner.Lisp.Signature.Validator

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
          | :datetime
          | {:optional, type()}
          | {:list, type()}
          | {:map, [field()]}
          | {:closed_map, [field()]}

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

      iex> PtcRunner.Lisp.Signature.parse("(id :int) -> {name :string}")
      {:ok, {:signature, [{"id", :int}], {:map, [{"name", :string}]}}}

      iex> PtcRunner.Lisp.Signature.parse("() -> :string")
      {:ok, {:signature, [], :string}}

      iex> PtcRunner.Lisp.Signature.parse("{count :int}")
      {:ok, {:signature, [], {:map, [{"count", :int}]}}}

      iex> match?({:error, _}, PtcRunner.Lisp.Signature.parse("invalid"))
      true
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

      iex> {:ok, sig} = PtcRunner.Lisp.Signature.parse("() -> {count :int, items [:string]}")
      iex> PtcRunner.Lisp.Signature.validate(sig, %{count: 5, items: ["a", "b"]})
      :ok

      iex> {:ok, sig} = PtcRunner.Lisp.Signature.parse("() -> :int")
      iex> PtcRunner.Lisp.Signature.validate(sig, "not an int")
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

  @doc false
  @spec type_to_json_schema(type()) :: map()
  def type_to_json_schema(:string), do: %{"type" => "string"}
  def type_to_json_schema(:int), do: %{"type" => "integer"}
  def type_to_json_schema(:float), do: %{"type" => "number"}
  def type_to_json_schema(:bool), do: %{"type" => "boolean"}
  def type_to_json_schema(:keyword), do: %{"type" => "string"}
  # `:datetime` ships as a plain `{"type": "string"}` to providers. We initially
  # emitted `format: "date-time"` here, but OpenAI's strict-mode structured
  # output (and strict tool schemas) reject any keyword outside their supported
  # subset, including `format`. Strict-mode requests would 400 before our
  # local DateTime coercion got a chance to run. Local coercion does the
  # actual ISO 8601 + offset validation; the type's value to the caller (a
  # `%DateTime{}` struct, not a string) is what makes `:datetime` more than
  # `:string`. The prompt-side example value (`"2026-05-03T09:14:00Z"`)
  # covers the LLM-guidance role that `format` would have played.
  def type_to_json_schema(:datetime), do: %{"type" => "string"}
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

  # Closed maps already advertise `additionalProperties: false` via the
  # `{:map, ...}` branch above — the only difference is enforcement at
  # validation time, which the JSON Schema can't express any further.
  def type_to_json_schema({:closed_map, fields}), do: type_to_json_schema({:map, fields})

  @doc false
  @spec unwrap_optional(type()) :: {type(), boolean()}
  def unwrap_optional({:optional, inner}), do: {inner, true}
  def unwrap_optional(type), do: {type, false}
end
