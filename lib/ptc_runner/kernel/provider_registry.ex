defmodule PtcRunner.Kernel.ProviderRegistry do
  @moduledoc """
  Host-owned mapping from manifest provider names to trusted builders.

  A manifest can select a bounded provider name and JSON configuration; it
  cannot register a module, function, callback, command, or code URL. Builders
  receive a path-free application identity, requested workflow or mission
  destination, building owner, and installed limits. Acquisition returns a
  normalized provider build with one or more capabilities, an optional safe
  snapshot, and an optional idempotent
  close function. A close function must return exactly `:ok`; any other return,
  exception, or exit is a provider-cleanup failure. The Kernel still attempts
  every registered close function and may replace the run outcome with
  `:provider_cleanup_error`.

  Trusted staged builders enforce a global preparation barrier. Every selected
  provider first performs pure selection checks, then every provider completes
  non-secret local preflight, and no provider is acquired before the union of
  declared credentials has been resolved exactly once.

  *When* that resolution happens differs by caller, and the difference is the
  authority each one has. An active command resolves at phase-8 step 5 from its
  sealed declarations, before any provider callback runs, and supplies the map;
  `resolve_credentials/2` is not called again below that point. Direct embedding
  has no sealed declarations to derive a union from before preparation, so it
  keeps resolving here, from what preparation reported, with the synchronous
  semantics its caller selected. Active command assembly bounds preparation,
  preflight, and acquisition by its shared run deadline; preflight releases
  share the provider-cleanup budget.
  Preparation also freezes
  the provider's `data_class` and `accepts_data` policy so run assembly can
  reject an incompatible information flow before preflight or credentials.
  A builder bound to the data policy declared by its sealed
  `PtcRunner.Kernel.ProviderDescriptor` cannot contradict it: preparation
  returning a different `data_class` or set of accepted classes than phase 5
  admitted, and than sink authorization used, fails with
  `:provider_declaration_mismatch` before preflight, credentials, or
  acquisition. Explicit embedding builders registered without a declared policy
  have no such declaration, so their preparation remains authoritative for
  them.
  A staged provider may additionally require or provide a bounded, code-owned
  acquisition service. Services pass opaque values only between selected
  trusted providers after the barrier; they never enter Lisp environments,
  connector snapshots, traces, or result artifacts.
  There are no implicit built-ins. CLI applications receive exactly the
  aliases in their host installation, while trusted Elixir embedding can pass
  any explicit builder map. The registry also freezes the installed limit
  ceilings used when manifests are loaded, so every frontend applies the same
  host authority rather than reconstructing it in CLI-specific options.
  Builder exceptions are contained at their current lifecycle phase.

  A staged acquisition context's `owner` is the private signal owner for that
  provider's resource scope. Any process or port root started by an acquisition
  must monitor that owner and synchronously call
  `PtcRunner.Kernel.ResourceRegistrar.register_root/1` from the root's init
  callback before its start operation returns. The registrar's private
  controller forwards registration into the scope's authoritative cleanup
  owner. Ports must be owned by a registered process. Registration after start
  returns is unsupported. A root
  retaining an unsettled OAuth release or persistence fence may call
  `PtcRunner.Kernel.ResourceRegistrar.handoff_root/2` only after it has stopped
  accepting work and the terminal operation has a bounded self-owner or
  adopter.

  `provides` is not a general marker. It names an acquisition service, and
  `normalize_build/2` requires the acquired build to export exactly the
  services declared here, so a provider that declares one without exporting it
  fails with `:invalid_provider_build`. Use a dedicated field for
  provider-kind facts, as `workflow_llm?` does.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ResourceRegistrar

  @application_content_digest ~r/\A[0-9a-f]{64}\z/
  @build_context_keys [
    :application_content_digest,
    :destination,
    :owner,
    :limits,
    :installed_limits
  ]
  @deadline_context_keys [:deadline, :deadline_ms]

  @enforce_keys [:builders, :credential_resolver, :installed_limits]
  defstruct @enforce_keys ++ [authority_owner: nil]

  @type build_context :: %{
          optional(:deadline) => Deadline.t(),
          optional(:deadline_ms) => integer(),
          optional(:resource_registrar) => ResourceRegistrar.t(),
          application_content_digest: binary(),
          destination: :workflow | :mission,
          owner: pid(),
          limits: PtcRunner.Kernel.Limits.t(),
          installed_limits: PtcRunner.Kernel.Limits.t()
        }
  @type context :: %{
          optional(:deadline) => Deadline.t(),
          optional(:deadline_ms) => integer(),
          optional(:resource_registrar) => ResourceRegistrar.t(),
          application_content_digest: binary(),
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
  @type credential_values :: %{binary() => binary()}
  @type acquisition_services :: %{optional(atom()) => term()}
  @type acquire ::
          (credential_values() -> {:ok, built_provider()} | {:error, term()})
          | (credential_values(), acquisition_services() ->
               {:ok, built_provider()} | {:error, term()})
  @type prepared :: %{
          credential_names: [binary()],
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          requires: [atom()],
          provides: [atom()],
          workflow_llm?: boolean(),
          workflow_llm_route:
            nil
            | %{
                required(:source) => binary(),
                required(:installation_revision) => binary(),
                required(:default) => boolean(),
                optional(:max_calls) => pos_integer() | nil,
                optional(:structured_output_mode) =>
                  :json_schema | :json_object | :unsupported | nil,
                optional(:request_timeout_ms) => pos_integer() | nil
              },
          preflight: (-> {:ok, acquire()}
                         | {:ok, acquire(), (-> :ok | {:error, term()})}
                         | {:error, term()})
        }
  @type preflighted :: %{
          acquire: acquire(),
          release: (-> :ok | {:error, term()}) | nil,
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          requires: [atom()],
          provides: [atom()]
        }
  @type staged_builder ::
          {:staged,
           (map(), context() ->
              {:ok, prepared()} | {:error, term()}), ProviderDescriptor.data_policy() | nil}
  @type registry_builder :: staged_builder()
  @type credential_resolver ::
          ([binary()] -> {:ok, credential_values()} | {:error, term()})
  @opaque authority_owner :: struct()
  @type t :: %__MODULE__{
          builders: %{binary() => registry_builder()},
          credential_resolver: credential_resolver(),
          installed_limits: Limits.t(),
          authority_owner: authority_owner() | nil
        }

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, :invalid_provider_registry}
  @doc "Creates a registry from explicit staged builders keyed by provider name."
  def new(additional_builders \\ %{}, opts \\ [])

  def new(additional_builders, opts)
      when is_map(additional_builders) and not is_struct(additional_builders) and is_list(opts) do
    if Keyword.keyword?(opts) do
      registry = %__MODULE__{
        builders: additional_builders,
        credential_resolver:
          Keyword.get(opts, :credential_resolver, &default_credential_resolver/1),
        installed_limits: Keyword.get(opts, :installed_limits, Limits.installed_defaults()),
        authority_owner: Keyword.get(opts, :authority_owner)
      }

      keys = Keyword.keys(opts)

      if valid?(registry) and
           keys -- [:credential_resolver, :installed_limits, :authority_owner] == [] and
           length(keys) == MapSet.size(MapSet.new(keys)) do
        {:ok, registry}
      else
        {:error, :invalid_provider_registry}
      end
    else
      {:error, :invalid_provider_registry}
    end
  end

  def new(_builders, _opts), do: {:error, :invalid_provider_registry}

  @spec valid?(term()) :: boolean()
  @doc "Checks the complete inert registry shape accepted by the constructor."
  def valid?(
        %__MODULE__{
          builders: builders,
          credential_resolver: resolver,
          installed_limits: installed_limits,
          authority_owner: authority_owner
        } = registry
      ) do
    map_size(registry) == map_size(struct(__MODULE__)) and
      is_map(builders) and not is_struct(builders) and
      Enum.all?(builders, fn {name, builder} ->
        valid_name?(name) and valid_builder?(builder)
      end) and
      is_function(resolver, 1) and Limits.valid?(installed_limits) and
      (is_nil(authority_owner) or HostInstallationAuthority.valid?(authority_owner))
  end

  def valid?(_registry), do: false

  @doc "Idempotently releases private host authority retained by this registry."
  @spec close(t()) :: :ok
  def close(%__MODULE__{authority_owner: owner}), do: HostInstallationAuthority.close(owner)
  def close(_registry), do: :ok

  @doc false
  @spec oauth_authority_epoch(t(), binary(), Deadline.t()) ::
          {:ok, term()} | {:error, :authorization_context_required}
  def oauth_authority_epoch(
        %__MODULE__{builders: builders, authority_owner: %HostInstallationAuthority{} = owner},
        name,
        deadline
      )
      when is_binary(name) do
    if Map.has_key?(builders, name) and Deadline.live?(deadline) do
      case BoundedWorker.run(
             fn -> HostInstallationAuthority.invoke(owner, {:oauth_authority_epoch, name}) end,
             timeout_ms: max(Deadline.remaining(deadline), 1),
             max_heap_words: 100_000,
             cancel_with_caller: true
           ) do
        {:ok, {:ok, authority_epoch}} -> {:ok, authority_epoch}
        _unavailable -> {:error, :authorization_context_required}
      end
    else
      {:error, :authorization_context_required}
    end
  end

  def oauth_authority_epoch(_registry, _name, _deadline),
    do: {:error, :authorization_context_required}

  @spec staged(
          (map(), context() -> {:ok, prepared()} | {:error, term()}),
          ProviderDescriptor.data_policy() | nil
        ) :: staged_builder()
  @doc """
  Marks a trusted builder as staged, optionally bound to its declared policy.

  The preparation callback must be side-effect free. Its returned preflight
  callback may perform only non-secret local checks; the acquire callback is
  the first phase allowed to use resolved credentials or open a provider.
  Optional `:data_class` and `:accepts_data` fields default to normal-only and
  must exactly match the acquired build. A builder bound to a declared policy
  must also prepare exactly that policy; an installed catalog projects one from
  the sealed descriptor of every builder it selects.
  """
  def staged(prepare, declared_policy \\ nil)

  def staged(prepare, nil) when is_function(prepare, 2), do: {:staged, prepare, nil}

  def staged(prepare, %{data_class: _class, accepts_data: _accepts} = declared_policy)
      when is_function(prepare, 2),
      do: {:staged, prepare, declared_policy}

  @spec build(t(), binary(), map(), build_context()) ::
          {:ok, built_provider()} | {:error, term()}
  @doc """
  Builds one entry through all three lifecycle phases.

  Run assembly uses the individual phase functions so the barrier spans every
  selected provider. This convenience path remains useful for embedding and
  focused provider tests. It rejects registrar-backed contexts because scoped
  acquisition requires `PtcRunner.Kernel.ProviderAcquisition`'s complete
  multi-provider lifecycle.
  """
  def build(%__MODULE__{}, _name, _config, %{resource_registrar: _registrar}),
    do: {:error, :invalid_provider_context}

  def build(%__MODULE__{} = registry, name, config, context) do
    with {:ok, prepared} <- prepare(registry, name, config, context),
         {:ok, preflighted} <- preflight(prepared) do
      try do
        with {:ok, credentials} <-
               resolve_credentials(registry, prepared.credential_names),
             do: acquire(preflighted, credentials, %{})
      after
        release_preflight(preflighted)
      end
    end
  end

  @spec prepare(t(), binary(), map(), build_context()) ::
          {:ok, prepared()} | {:error, term()}
  @doc false
  def prepare(%__MODULE__{builders: builders}, name, config, context) do
    with :ok <- validate_build_context(context) do
      prepare_builder(builders, name, config, context)
    end
  end

  def prepare(_registry, _name, _config, _context), do: {:error, :invalid_provider_context}

  defp prepare_builder(builders, name, config, context) do
    case Map.fetch(builders, name) do
      {:ok, {:staged, prepare, declared_policy}} ->
        invoke(
          fn -> prepare.(config, Map.put(context, :provider, name)) end,
          :provider_prepare_failed
        )
        |> normalize_prepared()
        |> declared_policy_honored(declared_policy)

      :error ->
        {:error, :unknown_provider}

      {:ok, _invalid} ->
        {:error, :invalid_provider_registry}
    end
  end

  defp validate_build_context(context)
       when is_map(context) and not is_struct(context) do
    if valid_build_context_keys?(context) and
         is_binary(context.application_content_digest) and
         context.application_content_digest =~ @application_content_digest and
         context.destination in [:workflow, :mission] and
         is_pid(context.owner) and
         valid_context_deadline?(context) and
         valid_resource_registrar?(context) and
         match?(%Limits{}, context.limits) and
         match?(%Limits{}, context.installed_limits) do
      :ok
    else
      {:error, :invalid_provider_context}
    end
  end

  defp validate_build_context(_context), do: {:error, :invalid_provider_context}

  defp valid_build_context_keys?(context) do
    keys = Enum.sort(Map.keys(context))

    Enum.any?(
      [
        @build_context_keys,
        [:resource_registrar | @build_context_keys],
        @deadline_context_keys ++ @build_context_keys,
        [:resource_registrar | @deadline_context_keys ++ @build_context_keys]
      ],
      &(keys == Enum.sort(&1))
    )
  end

  defp valid_context_deadline?(%{deadline: deadline, deadline_ms: deadline_ms}),
    do: Deadline.valid?(deadline) and Deadline.expires_at(deadline) == deadline_ms

  defp valid_context_deadline?(context),
    do: not Map.has_key?(context, :deadline) and not Map.has_key?(context, :deadline_ms)

  defp valid_resource_registrar?(%{resource_registrar: registrar, owner: owner}),
    do: ResourceRegistrar.valid?(registrar) and ResourceRegistrar.owner(registrar) == owner

  defp valid_resource_registrar?(_context), do: true

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
  def acquire(preflighted, credentials, services) do
    acquire_unreleased(preflighted, credentials, services)
  after
    release_preflight(preflighted)
  end

  @doc false
  @spec acquire_unreleased(preflighted(), credential_values(), acquisition_services()) ::
          {:ok, built_provider()} | {:error, term()}
  def acquire_unreleased(
        %{acquire: acquire, requires: requires, provides: provides},
        credentials,
        services
      )
      when is_function(acquire, 2) and is_map(credentials) and is_map(services) do
    if Enum.sort(Map.keys(services)) == Enum.sort(requires) do
      acquire
      |> invoke_with_two(credentials, services, :provider_acquisition_failed)
      |> normalize_build(provides)
    else
      {:error, :provider_dependency_unavailable}
    end
  end

  def acquire_unreleased(
        %{acquire: acquire, requires: [], provides: provides},
        credentials,
        %{}
      )
      when is_function(acquire, 1) and is_map(credentials) do
    acquire
    |> invoke_with(credentials, :provider_acquisition_failed)
    |> normalize_build(provides)
  end

  def acquire_unreleased(_preflighted, _credentials, _services),
    do: {:error, :invalid_provider_preflight}

  @doc false
  @spec release_preflight(preflighted() | term()) :: :ok
  def release_preflight(%{release: release}) when is_function(release, 0) do
    _ignored = invoke(release, :provider_preflight_release_failed)
    :ok
  end

  def release_preflight(%{release: nil}), do: :ok
  def release_preflight(_preflighted), do: :ok

  defp normalize_prepared({:ok, %{credential_names: names, preflight: preflight} = prepared})
       when is_list(names) and is_function(preflight, 0) do
    prepared =
      prepared
      |> Map.put_new(:data_class, :normal)
      |> Map.put_new(:accepts_data, [:normal])
      |> Map.put_new(:requires, [])
      |> Map.put_new(:provides, [])
      |> Map.put_new(:workflow_llm?, false)
      |> Map.put_new(:workflow_llm_route, nil)

    if Map.keys(prepared) --
         [
           :credential_names,
           :preflight,
           :data_class,
           :accepts_data,
           :requires,
           :provides,
           :workflow_llm?,
           :workflow_llm_route
         ] == [] and
         is_boolean(prepared.workflow_llm?) and
         valid_workflow_llm_route?(prepared.workflow_llm?, prepared.workflow_llm_route) and
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

  defp valid_workflow_llm_route?(false, nil), do: true

  defp valid_workflow_llm_route?(true, route)
       when is_map(route) and not is_struct(route) do
    extra =
      Map.keys(route) --
        [
          :default,
          :installation_revision,
          :max_calls,
          :source,
          :structured_output_mode,
          :request_timeout_ms
        ]

    extra == [] and
      Map.has_key?(route, :source) and
      Map.has_key?(route, :installation_revision) and
      Map.has_key?(route, :default) and
      route.source in ["llm", "llm_replay", "custom"] and
      is_binary(route.installation_revision) and valid_name?(route.installation_revision) and
      is_boolean(route.default) and valid_optional_max_calls?(Map.get(route, :max_calls)) and
      valid_structured_output_mode?(Map.get(route, :structured_output_mode), route.source) and
      LLMRouter.valid_route_timeout_ms?(Map.get(route, :request_timeout_ms), route.source)
  end

  defp valid_workflow_llm_route?(_workflow_llm?, _route), do: false

  defp valid_structured_output_mode?(nil, source) when source in ["llm_replay", "custom"],
    do: true

  defp valid_structured_output_mode?(mode, "llm")
       when mode in [:json_schema, :json_object, :unsupported],
       do: true

  defp valid_structured_output_mode?(_mode, _source), do: false

  defp valid_optional_max_calls?(nil), do: true
  defp valid_optional_max_calls?(max_calls) when is_integer(max_calls) and max_calls > 0, do: true
  defp valid_optional_max_calls?(_max_calls), do: false

  # Checked after normalization so an omitted field is compared as the
  # normal-only default it becomes, not as an absent value. `accepts_data` is a
  # set of admitted classes; the declaration keeps it in canonical order and a
  # preparation need not.
  defp declared_policy_honored(result, nil), do: result

  defp declared_policy_honored({:ok, prepared}, %{data_class: class, accepts_data: accepts})
       when is_list(accepts) do
    if prepared.data_class == class and
         MapSet.new(prepared.accepts_data) == MapSet.new(accepts),
       do: {:ok, prepared},
       else: {:error, :provider_declaration_mismatch}
  end

  defp declared_policy_honored({:error, _reason} = error, _declared_policy), do: error

  # A bound builder whose declared policy is not that projection cannot be
  # honored at all, so its preparation is refused rather than admitted
  # unchecked.
  defp declared_policy_honored(_result, _declared_policy),
    do: {:error, :provider_declaration_mismatch}

  defp normalize_preflight({:ok, acquire}, data_class, accepts_data, requires, provides)
       when is_function(acquire, 1) and requires == [] do
    {:ok,
     %{
       acquire: acquire,
       release: nil,
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
       release: nil,
       data_class: data_class,
       accepts_data: accepts_data,
       requires: requires,
       provides: provides
     }}
  end

  defp normalize_preflight(
         {:ok, acquire, release},
         data_class,
         accepts_data,
         requires,
         provides
       )
       when is_function(acquire, 1) and requires == [] and is_function(release, 0) do
    {:ok,
     %{
       acquire: acquire,
       release: once_release(release),
       data_class: data_class,
       accepts_data: accepts_data,
       requires: requires,
       provides: provides
     }}
  end

  defp normalize_preflight(
         {:ok, acquire, release},
         data_class,
         accepts_data,
         requires,
         provides
       )
       when is_function(acquire, 2) and is_function(release, 0) do
    {:ok,
     %{
       acquire: acquire,
       release: once_release(release),
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

  defp once_release(release) do
    gate = :atomics.new(1, signed: false)
    :ok = :atomics.put(gate, 1, 0)

    fn ->
      case :atomics.compare_exchange(gate, 1, 0, 1) do
        :ok -> release.()
        _already_released -> :ok
      end
    end
  end

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

  defp normalize_build({:ok, %{capabilities: capabilities} = built}, provides) do
    snapshot = Map.get(built, :snapshot)
    close = Map.get(built, :close)
    data_class = Map.get(built, :data_class, :normal)
    accepts_data = Map.get(built, :accepts_data, [:normal])
    exports = Map.get(built, :exports, %{})

    if Map.keys(built) --
         [:capabilities, :snapshot, :close, :data_class, :accepts_data, :exports] == [] and
         valid_capabilities?(capabilities, provides) and
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

  defp valid_capabilities?(capabilities, provides) when is_list(capabilities) do
    (capabilities != [] or provides != []) and length(capabilities) <= 128 and
      Enum.all?(capabilities, &match?(%Capability{}, &1))
  end

  defp valid_capabilities?(_capabilities, _provides), do: false

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

  defp valid_builder?({:staged, prepare, nil}) when is_function(prepare, 2), do: true

  defp valid_builder?({:staged, prepare, %{data_class: class, accepts_data: accepts} = policy})
       when is_function(prepare, 2) and map_size(policy) == 2,
       do: valid_data_policy?(class, accepts)

  defp valid_builder?(_builder), do: false

  defp valid_data_policy?(data_class, accepts_data) do
    data_class in [:normal, :private_inspection] and is_list(accepts_data) and
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
    |> Map.take(~w(system messages tools cache schema))
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
