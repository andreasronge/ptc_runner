defmodule PtcRunner.Kernel.RoutedCapability do
  @moduledoc false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Utf8

  @name ~r|\A[a-z][a-z0-9._/-]{0,127}\z|
  @effects [:read, :write, :unknown]
  @error_attribute_keys ~w(model)
  @event_attribute_bytes 65_536
  @event_attribute_keys ~w(alias installation_revision)
  @max_resolution_details 4_096
  @options ~w(name resolve routes validation_arguments description model_visible input_schema output_schema effect discovery)a
  @enforce_keys [
    :name,
    :resolve,
    :routes,
    :validation_arguments,
    :description,
    :input_schema,
    :output_schema,
    :input_validator,
    :output_validator,
    :discovery
  ]
  defstruct @enforce_keys ++ [model_visible: true, effect: :unknown]

  @type resolution_error :: {:error, atom(), binary()}
  @type resolver :: (map() -> {:ok, CapabilityInvocation.t()} | resolution_error())
  @type t :: %__MODULE__{
          name: binary(),
          resolve: resolver(),
          routes: %{binary() => Capability.t()},
          validation_arguments: (map() -> map()),
          description: binary() | nil,
          model_visible: boolean(),
          input_schema: map(),
          output_schema: map() | nil,
          input_validator: JSONSchema.compiled(),
          output_validator: JSONSchema.compiled() | nil,
          effect: :read | :write | :unknown,
          discovery: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_routed_capability}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- @options == [],
         {:ok, name} <- valid_name(Keyword.get(opts, :name)),
         resolve when is_function(resolve, 1) <- Keyword.get(opts, :resolve),
         validation_arguments when is_function(validation_arguments, 1) <-
           Keyword.get(opts, :validation_arguments, &Function.identity/1),
         routes when is_map(routes) and map_size(routes) in 1..128 <- Keyword.get(opts, :routes),
         true <- valid_routes?(routes),
         {:ok, description} <- valid_description(Keyword.get(opts, :description)),
         visible when is_boolean(visible) <- Keyword.get(opts, :model_visible, true),
         effect when effect in @effects <- Keyword.get(opts, :effect, :unknown),
         discovery when is_map(discovery) and not is_struct(discovery) <-
           Keyword.get(opts, :discovery, %{}),
         true <- JSONValue.map?(discovery),
         {:ok, input_schema, input_validator} <-
           JSONSchema.compile(Keyword.get(opts, :input_schema)),
         {:ok, output_schema, output_validator} <-
           optional_schema(Keyword.get(opts, :output_schema)) do
      {:ok,
       %__MODULE__{
         name: name,
         resolve: resolve,
         routes: routes,
         validation_arguments: validation_arguments,
         description: description,
         model_visible: visible,
         input_schema: input_schema,
         output_schema: output_schema,
         input_validator: input_validator,
         output_validator: output_validator,
         effect: effect,
         discovery: RetainedSize.detach_binaries(discovery)
       }}
    else
      _invalid -> {:error, :invalid_routed_capability}
    end
  end

  def new(_opts), do: {:error, :invalid_routed_capability}

  @spec resolve(t(), map()) ::
          {:ok, CapabilityInvocation.t()} | resolution_error() | {:error, :resolver_unavailable}
  def resolve(%__MODULE__{} = routed, arguments) when is_map(arguments) do
    case routed.resolve.(arguments) do
      {:ok,
       %CapabilityInvocation{
         route_key: route_key,
         capability: %Capability{} = capability,
         arguments: resolved_arguments,
         event_attributes: event_attributes,
         error_attributes: error_attributes,
         usage_projection: usage_projection
       } = invocation}
      when is_binary(route_key) and is_map(resolved_arguments) and is_map(event_attributes) and
             is_map(error_attributes) and usage_projection in [nil, :llm_tokens] ->
        if Map.get(routed.routes, route_key) == capability and
             valid_attributes?(event_attributes, error_attributes),
           do: {:ok, invocation},
           else: {:error, :resolver_unavailable}

      {:error, reason, details} when is_atom(reason) and is_binary(details) ->
        details =
          details
          |> Utf8.truncate_valid(@max_resolution_details)
          |> RetainedSize.detach_binaries()

        {:error, reason, details}

      _invalid ->
        {:error, :resolver_unavailable}
    end
  rescue
    _exception -> {:error, :resolver_unavailable}
  catch
    _kind, _reason -> {:error, :resolver_unavailable}
  end

  @spec validation_arguments(t(), map()) :: {:ok, map()} | {:error, :resolver_unavailable}
  def validation_arguments(%__MODULE__{} = routed, arguments) when is_map(arguments) do
    case routed.validation_arguments.(arguments) do
      normalized when is_map(normalized) and not is_struct(normalized) -> {:ok, normalized}
      _invalid -> {:error, :resolver_unavailable}
    end
  rescue
    _exception -> {:error, :resolver_unavailable}
  catch
    _kind, _reason -> {:error, :resolver_unavailable}
  end

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = routed) do
    %{
      name: routed.name,
      description: routed.description,
      model_visible: routed.model_visible,
      input_schema: routed.input_schema,
      output_schema: routed.output_schema,
      effect: routed.effect
    }
    |> Map.merge(routed.discovery)
  end

  defp valid_routes?(routes) do
    Enum.all?(routes, fn
      {key, %Capability{}} -> is_binary(key) and key =~ @name
      _invalid -> false
    end)
  end

  defp valid_attributes?(event_attributes, error_attributes) do
    with {:ok, event_keys} <- normalized_attribute_keys(event_attributes),
         {:ok, error_keys} <- normalized_attribute_keys(error_attributes) do
      MapSet.disjoint?(event_keys, error_keys) and
        MapSet.subset?(event_keys, MapSet.new(@event_attribute_keys)) and
        MapSet.subset?(error_keys, MapSet.new(@error_attribute_keys)) and
        EventSinkState.payload_within_limit?(event_attributes, @event_attribute_bytes) and
        EventSinkState.payload_within_limit?(error_attributes, @event_attribute_bytes)
    else
      _invalid -> false
    end
  end

  defp normalized_attribute_keys(attributes)
       when is_map(attributes) and not is_struct(attributes) do
    keys =
      Enum.map(Map.keys(attributes), fn
        key when is_binary(key) -> key
        key when is_atom(key) -> Atom.to_string(key)
        _invalid -> nil
      end)

    if Enum.all?(keys, &is_binary/1) and length(keys) == length(Enum.uniq(keys)),
      do: {:ok, MapSet.new(keys)},
      else: {:error, :invalid_attributes}
  end

  defp normalized_attribute_keys(_attributes), do: {:error, :invalid_attributes}

  defp optional_schema(nil), do: {:ok, nil, nil}
  defp optional_schema(schema), do: JSONSchema.compile(schema)

  defp valid_name(name) when is_binary(name) do
    if name =~ @name,
      do: {:ok, RetainedSize.detach_binaries(name)},
      else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}

  defp valid_description(nil), do: {:ok, nil}

  defp valid_description(description)
       when is_binary(description) and byte_size(description) <= 4_096,
       do: {:ok, RetainedSize.detach_binaries(description)}

  defp valid_description(_description), do: {:error, :invalid_description}
end
