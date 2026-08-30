defmodule PtcRunner.Kernel.Capability do
  @moduledoc """
  A host-owned route from PTC-Lisp to trusted extension code.

  `name` is the environment-local Lisp tool name. `input_schema` is the frozen
  bounded JSON Schema checked before the optional semantic `validate` callback,
  budget reservation, and provider invocation. `output_schema`, when present,
  checks successful values before they return to Lisp. `callback` returns
  `{:ok, json_value}` or `{:error, %PtcRunner.Kernel.ProviderError{}}`.
  Expected transient failures must use `ProviderError` with an explicit
  `retryable?: true`. The dispatcher contains callback raises, exits, throws,
  and monitored process deaths, but these unclassified failures default to
  non-retryable.
  One-argument callbacks receive only normalized arguments. Trusted
  two-argument callbacks additionally receive a dispatcher-owned invocation
  context for private observation and safe trace propagation; that context
  never crosses into Lisp.

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
  alias PtcRunner.Lisp.KeyNormalizer
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.LLM.Requirements

  @effects [:read, :write, :unknown]
  @options ~w(name callback validate description model_visible input_schema output_schema effect inspection_capture llm_reservation)a
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
    :llm_reservation,
    model_visible: true,
    effect: :unknown,
    inspection_capture: :full
  ]

  @type callback_result :: {:ok, term()} | {:error, PtcRunner.Kernel.ProviderError.t()}
  @type invocation_context :: %{
          capability_id: binary(),
          inspection_sink: PtcRunner.Kernel.InspectionSink.t() | nil,
          traceparent: binary() | nil
        }
  @type callback ::
          (map() -> callback_result()) | (map(), invocation_context() -> callback_result())
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
          llm_reservation: map() | nil,
          effect: :read | :write | :unknown,
          inspection_capture: :full | :digest_results
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_capability}
  @doc """
  Constructs a capability from required `:name`, `:callback`, and
  `:input_schema` options plus optional `:output_schema`, `:effect`,
  `:validate`, `:description`, `:model_visible`, `:inspection_capture`, and
  `:llm_reservation` options.

  Names are bounded lower-case identifiers and may contain `.`, `_`, `/`, and
  `-`. Descriptions are limited to 4,096 bytes. Schemas use the bounded JSON
  Schema 2020-12 profile compiled by `PtcRunner.Kernel.JSONSchema`. Input
  property and constrained-literal keys must already use their underscore form
  so recursive Lisp argument normalization cannot change their meaning.
  Effects are `:read`, `:write`, or `:unknown` and default to `:unknown`.
  `:inspection_capture` is `:full` (the default) or `:digest_results`;
  `:digest_results` requires `effect: :read` and directs private inspection to
  retain a deterministic value identity in place of a successful result. It is
  private capture policy and never appears in `metadata/1`.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- @options == [],
         {:ok, name} <- valid_name(Keyword.get(opts, :name)),
         callback when is_function(callback, 1) or is_function(callback, 2) <-
           Keyword.get(opts, :callback),
         :ok <- valid_validator(Keyword.get(opts, :validate)),
         {:ok, description} <- valid_description(Keyword.get(opts, :description)),
         visible when is_boolean(visible) <- Keyword.get(opts, :model_visible, true),
         effect when effect in @effects <- Keyword.get(opts, :effect, :unknown),
         inspection_capture when inspection_capture in [:full, :digest_results] <-
           Keyword.get(opts, :inspection_capture, :full),
         true <- inspection_capture == :full or effect == :read,
         :ok <- valid_llm_reservation(Keyword.get(opts, :llm_reservation)),
         {:ok, input_schema, input_validator} <-
           JSONSchema.compile(Keyword.get(opts, :input_schema)),
         true <- callable_input_schema?(input_schema),
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
         llm_reservation: Keyword.get(opts, :llm_reservation),
         effect: effect,
         inspection_capture: inspection_capture
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
    if name =~ @name,
      do: {:ok, RetainedSize.detach_binaries(name)},
      else: {:error, :invalid_capability}
  end

  defp valid_name(_name), do: {:error, :invalid_capability}
  defp valid_validator(nil), do: :ok
  defp valid_validator(validate) when is_function(validate, 1), do: :ok
  defp valid_validator(_validate), do: {:error, :invalid_capability}
  defp valid_llm_reservation(nil), do: :ok

  defp valid_llm_reservation(%{source: "llm_replay"} = reservation)
       when map_size(reservation) == 1,
       do: :ok

  defp valid_llm_reservation(
         %{
           source: "llm",
           output_tokens: output_tokens,
           tariff: tariff,
           bound: bound
         } = reservation
       )
       when map_size(reservation) == 4 and is_integer(output_tokens) and output_tokens > 0 and
              is_function(bound, 2) do
    if Requirements.valid_cost_tariff?(tariff),
      do: :ok,
      else: {:error, :invalid_capability}
  end

  defp valid_llm_reservation(_reservation), do: {:error, :invalid_capability}
  defp valid_description(nil), do: {:ok, nil}

  defp valid_description(description)
       when is_binary(description) and byte_size(description) <= 4_096,
       do: {:ok, RetainedSize.detach_binaries(description)}

  defp valid_description(_description), do: {:error, :invalid_capability}

  defp optional_schema(nil), do: {:ok, nil, nil}
  defp optional_schema(schema), do: JSONSchema.compile(schema)

  # PTC-Lisp recursively normalizes hyphens to underscores in tool argument
  # keys before dispatch. Reject schemas whose property names would change at
  # that boundary; otherwise the advertised exact call can never validate.
  defp callable_input_schema?(schema) when is_map(schema) do
    callable_constraints?(schema) and callable_children?(schema)
  end

  defp callable_input_schema?(_schema), do: true

  defp callable_constraints?(schema) do
    Enum.all?(["const", "enum"], fn key ->
      case Map.fetch(schema, key) do
        {:ok, value} -> callable_argument_value?(value)
        :error -> true
      end
    end)
  end

  defp callable_children?(%{"type" => "object"} = schema) do
    schema
    |> Map.get("properties", %{})
    |> Enum.all?(fn {name, child} ->
      KeyNormalizer.normalize_key(name) == name and callable_input_schema?(child)
    end)
  end

  defp callable_children?(%{"type" => "array", "items" => items}),
    do: callable_input_schema?(items)

  defp callable_children?(_schema), do: true

  defp callable_argument_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, child} ->
      KeyNormalizer.normalize_key(key) == key and callable_argument_value?(child)
    end)
  end

  defp callable_argument_value?(value) when is_list(value),
    do: Enum.all?(value, &callable_argument_value?/1)

  defp callable_argument_value?(_value), do: true
end
