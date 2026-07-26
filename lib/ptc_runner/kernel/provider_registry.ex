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
  credentials once before any provider is acquired. Legacy Elixir builders
  remain supported and are deferred to the acquisition phase.

  The built-ins are `llm`, permitted only in the workflow environment, and
  `file-read`, permitted only in the mission environment. Additional builders
  cannot replace built-in names. Builder exceptions are contained at their
  current lifecycle phase.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.FileCapability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMCapability

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
  @doc """
  Creates a registry with the built-ins and optional additional builder
  functions keyed by provider name.
  """
  def new(additional_builders \\ %{}, opts \\ [])

  def new(additional_builders, opts) when is_map(additional_builders) and is_list(opts) do
    builtins =
      if Keyword.get(opts, :builtins, true),
        do: %{"file-read" => &build_file/2, "llm" => &build_llm/2},
        else: %{}

    resolver = Keyword.get(opts, :credential_resolver, &default_credential_resolver/1)

    if Enum.all?(additional_builders, fn {name, builder} ->
         valid_name?(name) and valid_builder?(builder) and not Map.has_key?(builtins, name)
       end) and is_function(resolver, 1) and
         is_boolean(Keyword.get(opts, :builtins, true)) and
         Keyword.keys(opts) -- [:credential_resolver, :builtins] == [] do
      {:ok,
       %__MODULE__{
         builders: Map.merge(builtins, additional_builders),
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
           preflight: fn ->
             {:ok, fn %{} -> builder.(config, full_context) end}
           end
         }}

      :error ->
        {:error, :unknown_provider}
    end
  end

  @spec preflight(prepared()) :: {:ok, %{acquire: acquire()}} | {:error, term()}
  @doc false
  def preflight(%{preflight: preflight}) when is_function(preflight, 0) do
    preflight
    |> invoke(:provider_preflight_failed)
    |> normalize_preflight()
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
    if Map.keys(prepared) -- [:credential_names, :preflight] == [] and
         length(names) <= 128 and Enum.uniq(names) == names and Enum.all?(names, &valid_name?/1) do
      {:ok, prepared}
    else
      {:error, :invalid_provider_preparation}
    end
  end

  defp normalize_prepared({:error, _reason} = error), do: error
  defp normalize_prepared(_result), do: {:error, :invalid_provider_preparation}

  defp normalize_preflight({:ok, acquire}) when is_function(acquire, 1),
    do: {:ok, %{acquire: acquire}}

  defp normalize_preflight({:error, _reason} = error), do: error
  defp normalize_preflight(_result), do: {:error, :invalid_provider_preflight}

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

  defp build_file(config, %{directory: directory, destination: :mission}) do
    with :ok <- exact_keys(config, ~w(root max_bytes model_visible), ~w(root)),
         root when is_binary(root) <- config["root"],
         {:ok, root} <- safe_directory(directory, root),
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Map.get(config, "max_bytes", 1_000_000),
         model_visible when is_boolean(model_visible) <-
           Map.get(config, "model_visible", true) do
      FileCapability.new(root: root, max_bytes: max_bytes, model_visible: model_visible)
    else
      _ -> {:error, :invalid_file_provider}
    end
  end

  defp build_file(_config, _context), do: {:error, :provider_destination_denied}

  defp build_llm(config, %{destination: :workflow}) do
    with :ok <- exact_keys(config, ~w(model cache), ~w(model)),
         model when is_binary(model) and byte_size(model) in 1..256 <- config["model"],
         cache when is_boolean(cache) <- Map.get(config, "cache", false) do
      requester = PtcRunner.LLM.callback(model, cache: cache)
      LLMCapability.new(requester: fn request -> requester.(adapter_request(request)) end)
    else
      _ -> {:error, :invalid_llm_provider}
    end
  end

  defp build_llm(_config, _context), do: {:error, :provider_destination_denied}

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

  defp safe_directory(directory, relative) do
    cond do
      not String.valid?(relative) or byte_size(relative) not in 1..1_024 ->
        {:error, :unsafe_provider_path}

      Path.type(relative) != :relative or
          Enum.any?(Path.split(relative), &(&1 in ["", ".", ".."])) ->
        {:error, :unsafe_provider_path}

      true ->
        relative
        |> Path.split()
        |> Enum.reduce_while({:ok, directory}, fn segment, {:ok, parent} ->
          path = Path.join(parent, segment)

          case File.lstat(path) do
            {:ok, %{type: :directory}} -> {:cont, {:ok, path}}
            _ -> {:halt, {:error, :unsafe_provider_path}}
          end
        end)
    end
  end

  defp exact_keys(map, allowed, required) do
    keys = Map.keys(map)
    if keys -- allowed == [] and required -- keys == [], do: :ok, else: {:error, :invalid_config}
  end

  defp valid_name?(name),
    do: is_binary(name) and name =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/
end
