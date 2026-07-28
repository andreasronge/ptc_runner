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
  A staged provider may additionally require or provide a bounded, code-owned
  acquisition service. Services pass opaque values only between selected
  trusted providers after the barrier; they never enter Lisp environments,
  connector snapshots, traces, or result artifacts.
  Legacy Elixir builders remain supported as normal-data-only providers and
  are deferred to the acquisition phase; a classified custom provider must use
  the staged form.

  There are no implicit built-ins. CLI applications receive exactly the
  aliases in their host installation, while trusted Elixir embedding can pass
  any explicit builder map. The registry also freezes the installed limit
  ceilings used when manifests are loaded, so every frontend applies the same
  host authority rather than reconstructing it in CLI-specific options.
  Builder exceptions are contained at their current lifecycle phase.

  ## Adding a field to the prepared contract

  A prepared map is built in two places: `normalize_prepared/1` defaults and
  validates the staged form, and `prepare/4`'s legacy-builder branch
  constructs one inline without passing through it. A new key must be added to
  both, and to the `t:prepared/0` typespec — that type is exact, so a runtime
  key it does not declare makes every later `preflight/1` clause unmatchable.
  Adding a key to only one construction site compiles cleanly and then fails
  at run time with `KeyError` in whatever reads it.

  `provides` is not a general marker. It names an acquisition service, and
  `normalize_build/2` requires the acquired build to export exactly the
  services declared here, so a provider that declares one without exporting it
  fails with `:invalid_provider_build`. Use a dedicated field for
  provider-kind facts, as `workflow_llm?` does.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits

  @enforce_keys [:builders, :credential_resolver, :installed_limits]
  defstruct [:builders, :credential_resolver, :installed_limits]

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
  @typedoc """
  A zero-arity cleanup function returned by a provider builder.

  Declared here rather than borrowed from the internal cleanup module, so the
  public contract does not depend on an implementation detail's documentation.
  """
  @type close :: (-> term())

  @type built_provider :: %{
          capabilities: [Capability.t()],
          snapshot: map() | nil,
          close: close() | nil,
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          exports: %{optional(atom()) => term()}
        }
  @type builder ::
          (map(), context() ->
             {:ok, Capability.t() | built_provider()} | {:error, term()})
  @type credential_values :: %{binary() => binary()}
  @type acquisition_services :: %{optional(atom()) => term()}
  @type acquire ::
          (credential_values() ->
             {:ok, Capability.t() | built_provider()} | {:error, term()})
          | (credential_values(), acquisition_services() ->
               {:ok, Capability.t() | built_provider()} | {:error, term()})
  @type prepared :: %{
          credential_names: [binary()],
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          requires: [atom()],
          provides: [atom()],
          workflow_llm?: boolean(),
          preflight: (-> {:ok, acquire()} | {:error, term()})
        }
  @type preflighted :: %{
          acquire: acquire(),
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          requires: [atom()],
          provides: [atom()]
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
          credential_resolver: credential_resolver(),
          installed_limits: Limits.t()
        }

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, :invalid_provider_registry}
  @doc "Creates a registry from explicit builder functions keyed by provider name."
  def new(additional_builders \\ %{}, opts \\ [])

  def new(additional_builders, opts) when is_map(additional_builders) and is_list(opts) do
    resolver = Keyword.get(opts, :credential_resolver, &default_credential_resolver/1)
    installed_limits = Keyword.get(opts, :installed_limits, Limits.installed_defaults())

    if Enum.all?(additional_builders, fn {name, builder} ->
         valid_name?(name) and valid_builder?(builder)
       end) and is_function(resolver, 1) and
         is_struct(installed_limits, Limits) and
         Keyword.keys(opts) -- [:credential_resolver, :installed_limits] == [] do
      {:ok,
       %__MODULE__{
         builders: additional_builders,
         credential_resolver: resolver,
         installed_limits: installed_limits
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
         do: acquire(preflighted, credentials, %{})
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
           requires: [],
           provides: [],
           workflow_llm?: false,
           preflight: fn ->
             {:ok, fn %{}, %{} -> builder.(config, full_context) end}
           end
         }}

      :error ->
        {:error, :unknown_provider}
    end
  end

  @spec preflight(prepared()) :: {:ok, preflighted()} | {:error, term()}
  @doc false
  def preflight(%{
        preflight: preflight,
        data_class: data_class,
        accepts_data: accepts_data,
        requires: requires,
        provides: provides
      })
      when is_function(preflight, 0) do
    preflight
    |> invoke(:provider_preflight_failed)
    |> normalize_preflight(data_class, accepts_data, requires, provides)
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

  @spec acquire(preflighted(), credential_values(), acquisition_services()) ::
          {:ok, built_provider()} | {:error, term()}
  @doc false
  def acquire(%{requires: []} = preflighted, credentials),
    do: acquire(preflighted, credentials, %{})

  def acquire(_preflighted, _credentials), do: {:error, :provider_dependency_unavailable}

  @doc false
  def acquire(%{acquire: acquire, requires: requires, provides: provides}, credentials, services)
      when is_function(acquire, 2) and is_map(credentials) and is_map(services) do
    if Enum.sort(Map.keys(services)) == Enum.sort(requires) do
      acquire
      |> invoke_with_two(credentials, services, :provider_acquisition_failed)
      |> normalize_build(provides)
    else
      {:error, :provider_dependency_unavailable}
    end
  end

  def acquire(%{acquire: acquire, requires: [], provides: provides}, credentials, %{})
      when is_function(acquire, 1) and is_map(credentials) do
    acquire
    |> invoke_with(credentials, :provider_acquisition_failed)
    |> normalize_build(provides)
  end

  def acquire(_preflighted, _credentials, _services),
    do: {:error, :invalid_provider_preflight}

  defp normalize_prepared({:ok, %{credential_names: names, preflight: preflight} = prepared})
       when is_list(names) and is_function(preflight, 0) do
    prepared =
      prepared
      |> Map.put_new(:data_class, :normal)
      |> Map.put_new(:accepts_data, [:normal])
      |> Map.put_new(:requires, [])
      |> Map.put_new(:provides, [])
      |> Map.put_new(:workflow_llm?, false)

    if Map.keys(prepared) --
         [
           :credential_names,
           :preflight,
           :data_class,
           :accepts_data,
           :requires,
           :provides,
           :workflow_llm?
         ] == [] and
         is_boolean(prepared.workflow_llm?) and
         valid_data_policy?(prepared.data_class, prepared.accepts_data) and
         length(names) <= 128 and Enum.uniq(names) == names and Enum.all?(names, &valid_name?/1) and
         valid_services?(prepared.requires) and valid_services?(prepared.provides) and
         MapSet.disjoint?(MapSet.new(prepared.requires), MapSet.new(prepared.provides)) do
      {:ok, prepared}
    else
      {:error, :invalid_provider_preparation}
    end
  end

  defp normalize_prepared({:error, _reason} = error), do: error
  defp normalize_prepared(_result), do: {:error, :invalid_provider_preparation}

  defp normalize_preflight({:ok, acquire}, data_class, accepts_data, requires, provides)
       when is_function(acquire, 1) and requires == [] do
    {:ok,
     %{
       acquire: acquire,
       data_class: data_class,
       accepts_data: accepts_data,
       requires: requires,
       provides: provides
     }}
  end

  defp normalize_preflight({:ok, acquire}, data_class, accepts_data, requires, provides)
       when is_function(acquire, 2) do
    {:ok,
     %{
       acquire: acquire,
       data_class: data_class,
       accepts_data: accepts_data,
       requires: requires,
       provides: provides
     }}
  end

  defp normalize_preflight(
         {:error, _reason} = error,
         _data_class,
         _accepts_data,
         _requires,
         _provides
       ),
       do: error

  defp normalize_preflight(_result, _data_class, _accepts_data, _requires, _provides),
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

  defp normalize_build({:ok, %Capability{} = capability}, []) do
    {:ok,
     %{
       capabilities: [capability],
       snapshot: nil,
       close: nil,
       data_class: :normal,
       accepts_data: [:normal],
       exports: %{}
     }}
  end

  defp normalize_build({:ok, %{capabilities: capabilities} = built}, provides) do
    snapshot = Map.get(built, :snapshot)
    close = Map.get(built, :close)
    data_class = Map.get(built, :data_class, :normal)
    accepts_data = Map.get(built, :accepts_data, [:normal])
    exports = Map.get(built, :exports, %{})

    if Map.keys(built) --
         [:capabilities, :snapshot, :close, :data_class, :accepts_data, :exports] == [] and
         capabilities != [] and length(capabilities) <= 128 and
         Enum.all?(capabilities, &match?(%Capability{}, &1)) and
         (is_nil(snapshot) or JSONValue.map?(snapshot)) and
         (is_nil(close) or is_function(close, 0)) and
         data_class in [:normal, :private_inspection] and
         accepts_data != [] and accepts_data == Enum.uniq(accepts_data) and
         Enum.all?(accepts_data, &(&1 in [:normal, :private_inspection])) and
         is_map(exports) and Enum.sort(Map.keys(exports)) == Enum.sort(provides) do
      {:ok,
       %{
         capabilities: capabilities,
         snapshot: snapshot,
         close: close,
         data_class: data_class,
         accepts_data: accepts_data,
         exports: exports
       }}
    else
      {:error, :invalid_provider_build}
    end
  end

  defp normalize_build({:error, _reason} = error, _provides), do: error
  defp normalize_build(_result, _provides), do: {:error, :invalid_provider_build}

  defp invoke(function, failure) do
    function.()
  rescue
    _exception -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end

  defp invoke_with(function, argument, failure),
    do: invoke(fn -> function.(argument) end, failure)

  defp invoke_with_two(function, first, second, failure),
    do: invoke(fn -> function.(first, second) end, failure)

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

  defp valid_services?(services) do
    is_list(services) and length(services) <= 32 and Enum.uniq(services) == services and
      Enum.all?(services, &is_atom/1)
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
