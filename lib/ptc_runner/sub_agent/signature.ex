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

  - Primitives: `:string`, `:int`, `:float`, `:bool`, `:keyword`, `:any`, `:datetime`
  - Collections: `[:type]` (list), `{field :type}` (map), `:map` (untyped map)
  - Optional: `:type?` (nullable field or parameter)

  ## Examples

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("(name :string) -> {greeting :string}")
      iex> sig
      {:signature, [{"name", :string}], {:map, [{"greeting", :string}]}}

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("{count :int}")
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

      iex> PtcRunner.SubAgent.Signature.parse("(id :int) -> {name :string}")
      {:ok, {:signature, [{"id", :int}], {:map, [{"name", :string}]}}}

      iex> PtcRunner.SubAgent.Signature.parse("() -> :string")
      {:ok, {:signature, [], :string}}

      iex> PtcRunner.SubAgent.Signature.parse("{count :int}")
      {:ok, {:signature, [], {:map, [{"count", :int}]}}}

      iex> match?({:error, _}, PtcRunner.SubAgent.Signature.parse("invalid"))
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

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("() -> {count :int, items [:string]}")
      iex> PtcRunner.SubAgent.Signature.validate(sig, %{count: 5, items: ["a", "b"]})
      :ok

      iex> {:ok, sig} = PtcRunner.SubAgent.Signature.parse("() -> :int")
      iex> PtcRunner.SubAgent.Signature.validate(sig, "not an int")
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

  Used to determine if text mode response needs unwrapping.
  """
  @spec returns_list?(signature()) :: boolean()
  def returns_list?({:signature, _params, {:list, _}}), do: true
  def returns_list?(_), do: false

  @supported_scalar_keys ~w(type description)
  @supported_array_keys ~w(type description items)
  @supported_object_keys ~w(type description properties required additionalProperties)

  @doc """
  Convert a JSON Schema subset map to a PTC signature return type.

  Inverse of `type_to_json_schema/1`. Supports scalar types (`string`,
  `integer`, `number`, `boolean`), `array` with `items`, and `object`
  with `properties`/`required`/`additionalProperties`. Unsupported JSON
  Schema features (combinators, `$ref`, `enum`, `pattern`, etc.) return
  `{:error, reason}`.

  `additionalProperties: false` produces a closed map (`{:closed_map, ...}`)
  whose validation rejects undeclared fields. `additionalProperties: true`
  (or its absence) produces an open `{:map, ...}` that tolerates extras.
  Every `required` entry must be a string naming a declared property,
  otherwise an `{:error, reason}` is returned.

  ## Examples

      iex> PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "integer"})
      {:ok, :int}

      iex> PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "array", "items" => %{"type" => "string"}})
      {:ok, {:list, :string}}

      iex> PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "object", "properties" => %{"count" => %{"type" => "integer"}}, "required" => ["count"]})
      {:ok, {:map, [{"count", :int}]}}

      iex> PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
      {:ok, {:map, [{"name", {:optional, :string}}]}}

      iex> PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}, "required" => ["x"], "additionalProperties" => false})
      {:ok, {:closed_map, [{"x", :int}]}}

      iex> match?({:error, _}, PtcRunner.SubAgent.Signature.from_json_schema(%{"type" => "object", "properties" => %{}, "required" => ["missing"]}))
      true

  """
  @spec from_json_schema(map()) :: {:ok, type()} | {:error, String.t()}
  def from_json_schema(%{"type" => "string"} = s), do: check_scalar_keys(s, :string)
  def from_json_schema(%{"type" => "integer"} = s), do: check_scalar_keys(s, :int)
  def from_json_schema(%{"type" => "number"} = s), do: check_scalar_keys(s, :float)
  def from_json_schema(%{"type" => "boolean"} = s), do: check_scalar_keys(s, :bool)
  def from_json_schema(%{"type" => "array"} = s), do: convert_array_schema(s)
  def from_json_schema(%{"type" => "object"} = s), do: convert_object_schema(s)

  def from_json_schema(%{"type" => type}) when is_binary(type),
    do: {:error, "unsupported type: #{inspect(type)}"}

  def from_json_schema(schema) when is_map(schema),
    do: {:error, "schema must have a \"type\" key"}

  def from_json_schema(other),
    do: {:error, "schema must be a JSON object, got #{inspect(other)}"}

  defp check_scalar_keys(schema, type) do
    case check_unsupported_keys(schema, @supported_scalar_keys) do
      :ok -> {:ok, type}
      error -> error
    end
  end

  defp convert_array_schema(schema) do
    with :ok <- check_unsupported_keys(schema, @supported_array_keys) do
      case Map.fetch(schema, "items") do
        {:ok, items} when is_map(items) ->
          case from_json_schema(items) do
            {:ok, inner} -> {:ok, {:list, inner}}
            error -> error
          end

        {:ok, _} ->
          {:error, "array \"items\" must be a JSON object"}

        :error ->
          {:error, "array type requires an \"items\" key"}
      end
    end
  end

  defp convert_object_schema(schema) do
    with :ok <- check_unsupported_keys(schema, @supported_object_keys),
         {:ok, mode} <- additional_properties_mode(schema) do
      required = Map.get(schema, "required", [])

      case Map.fetch(schema, "properties") do
        {:ok, properties} when is_map(properties) ->
          with :ok <- validate_required_entries(required, properties) do
            convert_object_fields(properties, required, mode)
          end

        {:ok, _} ->
          {:error, "object \"properties\" must be a JSON object"}

        :error ->
          with :ok <- validate_required_entries(required, %{}) do
            {:ok, empty_object_type(mode)}
          end
      end
    end
  end

  # `additionalProperties` controls whether undeclared fields survive
  # validation. We only honour the boolean form of the keyword; the
  # schema-valued form (`additionalProperties: {...}`) is rejected as
  # unsupported so it can never be silently dropped.
  defp additional_properties_mode(schema) do
    case Map.fetch(schema, "additionalProperties") do
      :error ->
        {:ok, :open}

      {:ok, true} ->
        {:ok, :open}

      {:ok, false} ->
        {:ok, :closed}

      {:ok, other} ->
        {:error, ~s|"additionalProperties" must be true or false, got #{inspect(other)}|}
    end
  end

  defp empty_object_type(:closed), do: {:closed_map, []}
  defp empty_object_type(:open), do: :map

  defp validate_required_entries(required, _properties) when not is_list(required),
    do: {:error, ~s|"required" must be an array of strings|}

  defp validate_required_entries(required, properties) do
    declared = Map.keys(properties)

    Enum.reduce_while(required, :ok, fn
      entry, :ok when is_binary(entry) ->
        if entry in declared do
          {:cont, :ok}
        else
          {:halt, {:error, ~s|"required" entry #{inspect(entry)} is not a declared property|}}
        end

      entry, :ok ->
        {:halt, {:error, ~s|"required" entries must be strings, got #{inspect(entry)}|}}
    end)
  end

  defp convert_object_fields(properties, required, mode) do
    properties
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, sub_schema}, {:ok, acc} ->
      case from_json_schema(sub_schema) do
        {:ok, type} ->
          field_type = if name in required, do: type, else: {:optional, type}
          {:cont, {:ok, [{name, field_type} | acc]}}

        {:error, reason} ->
          {:halt, {:error, "property #{inspect(name)}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, build_object_type(mode, Enum.reverse(fields))}
      {:error, _} = err -> err
    end
  end

  defp build_object_type(:closed, fields), do: {:closed_map, fields}
  defp build_object_type(:open, fields), do: {:map, fields}

  defp check_unsupported_keys(schema, allowed) do
    extra = schema |> Map.keys() |> Enum.reject(&Enum.member?(allowed, &1))

    if extra == [] do
      :ok
    else
      {:error, "unsupported JSON Schema key(s): #{Enum.join(Enum.sort(extra), ", ")}"}
    end
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
