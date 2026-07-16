defmodule PtcRunner.Kernel.Capability do
  @moduledoc """
  A host-owned route from PTC-Lisp to trusted extension code.

  `name` is the environment-local Lisp tool name. `input_schema` is the frozen
  bounded JSON Schema checked before the optional semantic `validate` callback,
  budget reservation, and provider invocation. `output_schema`, when present,
  checks successful values before they return to Lisp. `callback` returns
  `{:ok, json_value}` or `{:error, %PtcRunner.Kernel.ProviderError{}}`.

  `description` and `model_visible` control bounded discovery metadata only.
  They do not grant authority. A capability can be invoked only when the host
  placed it in the active workflow or mission environment.

  Callbacks and validators remain host-owned and are never projected into Lisp
  values. The dispatcher contains ordinary raises, exits, timeouts, and
  oversized or invalid results, but capability implementations are trusted
  BEAM extensions rather than an adversarial-code boundary.
  """

  @name ~r|\A[a-z][a-z0-9._/-]{0,127}\z|
  alias PtcRunner.Kernel.JSONSchema

  @effects [:read, :write, :unknown]
  @options ~w(name callback validate description model_visible input_schema output_schema effect)a
  @enforce_keys [:name, :callback, :input_schema]
  defstruct [
    :name,
    :callback,
    :validate,
    :description,
    :input_schema,
    :output_schema,
    :input_validator,
    :output_validator,
    model_visible: true,
    effect: :unknown
  ]

  @type callback :: (map() -> {:ok, term()} | {:error, PtcRunner.Kernel.ProviderError.t()})
  @type t :: %__MODULE__{
          name: binary(),
          callback: callback(),
          validate: (map() -> :ok | {:error, binary()}) | nil,
          description: binary() | nil,
          model_visible: boolean(),
          input_schema: map(),
          output_schema: map() | nil,
          input_validator: JSONSchema.compiled(),
          output_validator: JSONSchema.compiled() | nil,
          effect: :read | :write | :unknown
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_capability}
  @doc """
  Constructs a capability from required `:name`, `:callback`, and
  `:input_schema` options plus optional `:output_schema`, `:effect`,
  `:validate`, `:description`, and `:model_visible` options.

  Names are bounded lower-case identifiers and may contain `.`, `_`, `/`, and
  `-`. Descriptions are limited to 4,096 bytes. Schemas use the bounded JSON
  Schema 2020-12 profile compiled by `PtcRunner.Kernel.JSONSchema`. Effects are
  `:read`, `:write`, or `:unknown` and default to `:unknown`.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- @options == [],
         {:ok, name} <- valid_name(Keyword.get(opts, :name)),
         callback when is_function(callback, 1) <- Keyword.get(opts, :callback),
         :ok <- valid_validator(Keyword.get(opts, :validate)),
         {:ok, description} <- valid_description(Keyword.get(opts, :description)),
         visible when is_boolean(visible) <- Keyword.get(opts, :model_visible, true),
         effect when effect in @effects <- Keyword.get(opts, :effect, :unknown),
         {:ok, input_schema, input_validator} <-
           JSONSchema.compile(Keyword.get(opts, :input_schema)),
         {:ok, output_schema, output_validator} <-
           optional_schema(Keyword.get(opts, :output_schema)) do
      {:ok,
       %__MODULE__{
         name: name,
         callback: callback,
         validate: Keyword.get(opts, :validate),
         description: description,
         model_visible: visible,
         input_schema: input_schema,
         output_schema: output_schema,
         input_validator: input_validator,
         output_validator: output_validator,
         effect: effect
       }}
    else
      _ -> {:error, :invalid_capability}
    end
  end

  @spec metadata(t()) :: map()
  @doc "Returns sanitized discovery metadata without the callback or validator."
  def metadata(%__MODULE__{} = capability) do
    %{
      name: capability.name,
      description: capability.description,
      model_visible: capability.model_visible,
      input_schema: capability.input_schema,
      output_schema: capability.output_schema,
      effect: capability.effect
    }
  end

  defp valid_name(name) when is_binary(name) do
    if name =~ @name, do: {:ok, name}, else: {:error, :invalid_capability}
  end

  defp valid_name(_name), do: {:error, :invalid_capability}
  defp valid_validator(nil), do: :ok
  defp valid_validator(validate) when is_function(validate, 1), do: :ok
  defp valid_validator(_validate), do: {:error, :invalid_capability}
  defp valid_description(nil), do: {:ok, nil}

  defp valid_description(description)
       when is_binary(description) and byte_size(description) <= 4_096, do: {:ok, description}

  defp valid_description(_description), do: {:error, :invalid_capability}

  defp optional_schema(nil), do: {:ok, nil, nil}
  defp optional_schema(schema), do: JSONSchema.compile(schema)
end
