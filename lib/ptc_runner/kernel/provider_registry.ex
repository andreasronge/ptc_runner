defmodule PtcRunner.Kernel.ProviderRegistry do
  @moduledoc """
  Host-owned mapping from manifest provider names to trusted builders.

  A manifest can select a bounded provider name and JSON configuration; it
  cannot register a module, function, callback, command, or code URL. Builders
  receive the canonical manifest directory, requested workflow or mission
  destination, building owner, and installed limits. They return either one
  legacy `PtcRunner.Kernel.Capability` or a normalized provider build with one
  or more capabilities, an optional safe snapshot, and an optional idempotent
  close function. A close function must return exactly `:ok`; any other return,
  exception, or exit is a provider-cleanup failure. The Kernel still attempts
  every registered close function and may replace the run outcome with
  `:provider_cleanup_error`.

  Trusted staged builders enforce a global preparation barrier. Every selected
  provider first performs pure selection checks, then every provider completes
  non-secret local preflight, then the registry resolves the union of declared
  credentials once before any provider is acquired. Preparation also freezes
  the provider's `data_class` and `accepts_data` policy so run assembly can
  reject an incompatible information flow before preflight or credentials.
  Legacy Elixir builders remain supported as normal-data-only providers and
  are deferred to the acquisition phase; a classified custom provider must use
  the staged form.

  There are no implicit built-ins. CLI applications receive exactly the
  aliases in their host installation, while trusted Elixir embedding can pass
  any explicit builder map. Builder exceptions are contained at their current
  lifecycle phase.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONValue

  @enforce_keys [:builders, :credential_resolver]
  defstruct [:builders, :credential_resolver]

  @type build_context :: %{
          directory: binary(),
          destination: :workflow | :mission,
          owner: pid(),
          limits: PtcRunner.Kernel.Limits.t(),
          installed_limits: PtcRunner.Kernel.Limits.t()
        }
  @type context :: %{
          directory: binary(),
          destination: :workflow | :mission,
          owner: pid(),
          limits: PtcRunner.Kernel.Limits.t(),
          installed_limits: PtcRunner.Kernel.Limits.t(),
          provider: binary()
        }
  @type built_provider :: %{
          capabilities: [Capability.t()],
          snapshot: map() | nil,
          close: PtcRunner.Kernel.ProviderResources.close() | nil,
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection]
        }
  @type builder ::
          (map(), context() ->
             {:ok, Capability.t() | built_provider()} | {:error, term()})
  @type credential_values :: %{binary() => binary()}
  @type acquire ::
          (credential_values() ->
             {:ok, Capability.t() | built_provider()} | {:error, term()})
  @type prepared :: %{
          credential_names: [binary()],
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          preflight: (-> {:ok, acquire()} | {:error, term()})
        }
  @type staged_builder ::
          {:staged,
           (map(), context() ->
              {:ok, prepared()} | {:error, term()})}
  @type registry_builder :: builder() | staged_builder()
  @type credential_resolver ::
          ([binary()] -> {:ok, credential_values()} | {:error, term()})
  @type t :: %__MODULE__{
          builders: %{binary() => registry_builder()},
          credential_resolver: credential_resolver()
        }

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, :invalid_provider_registry}
  @doc "Creates a registry from explicit builder functions keyed by provider name."
  def new(additional_builders \\ %{}, opts \\ [])

  def new(additional_builders, opts) when is_map(additional_builders) and is_list(opts) do
    resolver = Keyword.get(opts, :credential_resolver, &default_credential_resolver/1)

    if Enum.all?(additional_builders, fn {name, builder} ->
         valid_name?(name) and valid_builder?(builder)
       end) and is_function(resolver, 1) and
         Keyword.keys(opts) -- [:credential_resolver] == [] do
      {:ok,
       %__MODULE__{
         builders: additional_builders,
         credential_resolver: resolver
       }}
    else
      {:error, :invalid_provider_registry}
    end
  end

  def new(_builders, _opts), do: {:error, :invalid_provider_registry}

  @spec staged((map(), context() -> {:ok, prepared()} | {:error, term()})) ::
          staged_builder()
  @doc """
  Marks a trusted builder as staged.

  The preparation callback must be side-effect free. Its returned preflight
  callback may perform only non-secret local checks; the acquire callback is
  the first phase allowed to use resolved credentials or open a provider.
  Optional `:data_class` and `:accepts_data` fields default to normal-only and
  must exactly match the acquired build.
  """
  def staged(prepare) when is_function(prepare, 2), do: {:staged, prepare}

  @spec build(t(), binary(), map(), build_context()) ::
          {:ok, built_provider()} | {:error, term()}
  @doc """
  Builds one entry through all three lifecycle phases.

  Run assembly uses the individual phase functions so the barrier spans every
  selected provider. This convenience path remains useful for embedding and
  focused provider tests.
  """
  def build(%__MODULE__{} = registry, name, config, context) do
    with {:ok, prepared} <- prepare(registry, name, config, context),
         {:ok, preflighted} <- preflight(prepared),
         {:ok, credentials} <-
           resolve_credentials(registry, prepared.credential_names),
         do: acquire(preflighted, credentials)
  end

  @spec prepare(t(), binary(), map(), build_context()) ::
          {:ok, prepared()} | {:error, term()}
  @doc false
  def prepare(%__MODULE__{builders: builders}, name, config, context) do
    case Map.fetch(builders, name) do
      {:ok, {:staged, prepare}} ->
        invoke(
          fn -> prepare.(config, Map.put(context, :provider, name)) end,
          :provider_prepare_failed
        )
        |> normalize_prepared()

      {:ok, builder} when is_function(builder, 2) ->
        full_context = Map.put(context, :provider, name)

        {:ok,
         %{
           credential_names: [],
           data_class: :normal,
           accepts_data: [:normal],
           preflight: fn ->
             {:ok, fn %{} -> builder.(config, full_context) end}
           end
         }}

      :error ->
        {:error, :unknown_provider}
    end
  end

  @spec preflight(prepared()) ::
          {:ok,
           %{
             acquire: acquire(),
             data_class: :normal | :private_inspection,
             accepts_data: [:normal | :private_inspection]
           }}
          | {:error, term()}
  @doc false
  def preflight(%{
        preflight: preflight,
        data_class: data_class,
        accepts_data: accepts_data
      })
      when is_function(preflight, 0) do
    preflight
    |> invoke(:provider_preflight_failed)
    |> normalize_preflight(data_class, accepts_data)
  end

  def preflight(_prepared), do: {:error, :invalid_provider_preparation}

  @spec resolve_credentials(t(), [binary()]) ::
          {:ok, credential_values()} | {:error, term()}
  @doc false
  def resolve_credentials(%__MODULE__{credential_resolver: resolver}, names)
      when is_list(names) do
    names = Enum.sort(Enum.uniq(names))

    resolver
    |> invoke_with(names, :credential_resolution_failed)
    |> normalize_credentials(names)
  end

  def resolve_credentials(_registry, _names), do: {:error, :invalid_credential_names}

  @spec acquire(%{acquire: acquire()}, credential_values()) ::
          {:ok, built_provider()} | {:error, term()}
  @doc false
  def acquire(%{acquire: acquire}, credentials)
      when is_function(acquire, 1) and is_map(credentials) do
    acquire
    |> invoke_with(credentials, :provider_acquisition_failed)
    |> normalize_build()
  end

  def acquire(_preflighted, _credentials), do: {:error, :invalid_provider_preflight}

  defp normalize_prepared({:ok, %{credential_names: names, preflight: preflight} = prepared})
       when is_list(names) and is_function(preflight, 0) do
    prepared =
      prepared
      |> Map.put_new(:data_class, :normal)
      |> Map.put_new(:accepts_data, [:normal])

    if Map.keys(prepared) -- [:credential_names, :preflight, :data_class, :accepts_data] == [] and
         valid_data_policy?(prepared.data_class, prepared.accepts_data) and
         length(names) <= 128 and Enum.uniq(names) == names and Enum.all?(names, &valid_name?/1) do
      {:ok, prepared}
    else
      {:error, :invalid_provider_preparation}
    end
  end

  defp normalize_prepared({:error, _reason} = error), do: error
  defp normalize_prepared(_result), do: {:error, :invalid_provider_preparation}

  defp normalize_preflight({:ok, acquire}, data_class, accepts_data)
       when is_function(acquire, 1),
       do: {:ok, %{acquire: acquire, data_class: data_class, accepts_data: accepts_data}}

  defp normalize_preflight({:error, _reason} = error, _data_class, _accepts_data), do: error

  defp normalize_preflight(_result, _data_class, _accepts_data),
    do: {:error, :invalid_provider_preflight}

  defp normalize_credentials({:ok, credentials}, names) when is_map(credentials) do
    if Enum.sort(Map.keys(credentials)) == names and
         Enum.all?(credentials, fn {name, value} -> valid_name?(name) and is_binary(value) end) do
      {:ok, credentials}
    else
      {:error, :invalid_credential_values}
    end
  end

  defp normalize_credentials({:error, _reason} = error, _names), do: error
  defp normalize_credentials(_result, _names), do: {:error, :invalid_credential_values}

  defp normalize_build({:ok, %Capability{} = capability}) do
    {:ok,
     %{
       capabilities: [capability],
       snapshot: nil,
       close: nil,
       data_class: :normal,
       accepts_data: [:normal]
     }}
  end

  defp normalize_build({:ok, %{capabilities: capabilities} = built}) do
    snapshot = Map.get(built, :snapshot)
    close = Map.get(built, :close)
    data_class = Map.get(built, :data_class, :normal)
    accepts_data = Map.get(built, :accepts_data, [:normal])

    if Map.keys(built) --
         [:capabilities, :snapshot, :close, :data_class, :accepts_data] == [] and
         capabilities != [] and length(capabilities) <= 128 and
         Enum.all?(capabilities, &match?(%Capability{}, &1)) and
         (is_nil(snapshot) or JSONValue.map?(snapshot)) and
         (is_nil(close) or is_function(close, 0)) and
         data_class in [:normal, :private_inspection] and
         accepts_data != [] and accepts_data == Enum.uniq(accepts_data) and
         Enum.all?(accepts_data, &(&1 in [:normal, :private_inspection])) do
      {:ok,
       %{
         capabilities: capabilities,
         snapshot: snapshot,
         close: close,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      {:error, :invalid_provider_build}
    end
  end

  defp normalize_build({:error, _reason} = error), do: error
  defp normalize_build(_result), do: {:error, :invalid_provider_build}

  defp invoke(function, failure) do
    function.()
  rescue
    _exception -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end

  defp invoke_with(function, argument, failure),
    do: invoke(fn -> function.(argument) end, failure)

  defp default_credential_resolver([]), do: {:ok, %{}}
  defp default_credential_resolver(_names), do: {:error, :credential_resolver_missing}

  defp valid_builder?(builder) when is_function(builder, 2), do: true
  defp valid_builder?({:staged, prepare}) when is_function(prepare, 2), do: true
  defp valid_builder?(_builder), do: false

  defp valid_data_policy?(data_class, accepts_data) do
    data_class in [:normal, :private_inspection] and
      accepts_data != [] and accepts_data == Enum.uniq(accepts_data) and
      Enum.all?(accepts_data, &(&1 in [:normal, :private_inspection]))
  end

  @doc false
  def adapter_request(request) do
    request
    |> Map.take(~w(system messages tools cache))
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), adapter_value(key, value)} end)
  end

  defp adapter_value("messages", messages) when is_list(messages),
    do: Enum.map(messages, &adapter_message/1)

  defp adapter_value("tool_calls", calls) when is_list(calls),
    do: Enum.map(calls, &adapter_tool_call/1)

  defp adapter_value(_key, value), do: value

  defp adapter_message(message) when is_map(message) do
    message
    |> Enum.reduce(%{}, fn
      {key, value}, map when key in ["role", "content", "tool_calls", "tool_call_id"] ->
        value =
          cond do
            key == "role" and is_binary(value) -> role(value)
            key == "tool_calls" -> adapter_value("tool_calls", value)
            true -> value
          end

        Map.put(map, String.to_existing_atom(key), value)

      _field, map ->
        map
    end)
  end

  defp adapter_message(message), do: message

  defp adapter_tool_call(call) when is_map(call) do
    call
    |> Enum.reduce(%{}, fn
      {key, value}, map
      when key in ["id", "type", "function", "name", "args", "args_error"] ->
        value = if key == "function", do: adapter_function(value), else: value
        Map.put(map, String.to_existing_atom(key), value)

      _field, map ->
        map
    end)
  end

  defp adapter_tool_call(call), do: call

  defp adapter_function(function) when is_map(function) do
    function
    |> Map.take(~w(name arguments))
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp adapter_function(function), do: function
  defp role("system"), do: :system
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("tool"), do: :tool
  defp role(role), do: role

  defp valid_name?(name),
    do: is_binary(name) and name =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/
end
