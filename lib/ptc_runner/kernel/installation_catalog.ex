defmodule PtcRunner.Kernel.InstallationCatalog do
  @moduledoc """
  Inert provider declarations paired with trusted implementations.

  Phase 5 reads only `descriptors`; process-free implementations remain sealed
  for later active phases. Credential access is supplied separately through
  `PtcRunner.Kernel.ProviderRuntimeServices` when execution opens.
  Host-backed catalogs carry an opaque keyed binding so runtime services from
  a different host document are rejected before activation.
  Catalog construction checks that active validators, connectivity probes, and
  local checks agree with their descriptors without invoking any callback.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices

  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @implementation_keys [
    :builder,
    :oauth_builder,
    :local_preflight,
    :provider_application,
    :selection_validator,
    :connectivity_probe
  ]

  @enforce_keys [
    :descriptors,
    :implementations,
    :authorities,
    :installed_limits,
    :runtime_binding
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type implementation :: %{
          required(:builder) => function(),
          optional(:oauth_builder) => function(),
          optional(:local_preflight) => (map(), map(), ProviderRuntimeServices.t() ->
                                           :ok | {:error, term()}),
          optional(:provider_application) => :req_llm,
          optional(:selection_validator) => function(),
          optional(:connectivity_probe) => (map(), map(), ProviderRuntimeServices.t() ->
                                              :ok | {:error, term()})
        }
  @type registration :: %{
          required(:descriptor) => ProviderDescriptor.t(),
          required(:implementation) => implementation(),
          required(:authority) => Authority.t() | :host_runtime | nil
        }
  @type t :: %__MODULE__{
          descriptors: %{binary() => ProviderDescriptor.t()},
          implementations: %{binary() => implementation()},
          authorities: %{binary() => Authority.t() | :host_runtime | nil},
          installed_limits: Limits.t(),
          runtime_binding: binary() | nil,
          attestation: binary() | nil
        }

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, :invalid_installation_catalog}
  @doc "Validates and seals explicit registrations without invoking implementations."
  def new(registrations \\ %{}, opts \\ [])

  def new(registrations, opts)
      when is_map(registrations) and not is_struct(registrations) and is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:installed_limits, :runtime_binding] == [] and
         length(opts) == MapSet.size(MapSet.new(Keyword.keys(opts))) do
      with {:ok, descriptors, implementations, authorities} <-
             split_registrations(registrations) do
        catalog = %__MODULE__{
          descriptors: descriptors,
          implementations: implementations,
          authorities: authorities,
          installed_limits: Keyword.get(opts, :installed_limits, Limits.installed_defaults()),
          runtime_binding: Keyword.get(opts, :runtime_binding)
        }

        if valid_shape?(catalog) do
          {:ok, %{catalog | attestation: Attestation.attest(__MODULE__, payload(catalog))}}
        else
          {:error, :invalid_installation_catalog}
        end
      end
    else
      {:error, :invalid_installation_catalog}
    end
  end

  def new(_registrations, _opts), do: {:error, :invalid_installation_catalog}

  @spec valid?(term()) :: boolean()
  @doc "Checks declaration/implementation parity and the catalog seal."
  def valid?(%__MODULE__{attestation: attestation} = catalog),
    do:
      Enum.sort(Map.keys(catalog)) == @field_keys and valid_shape?(catalog) and
        Attestation.valid?(__MODULE__, payload(catalog), attestation)

  def valid?(_catalog), do: false

  @spec fetch(t(), binary()) :: {:ok, ProviderDescriptor.t()} | :error
  @doc "Fetches one inert descriptor by installed safe alias."
  def fetch(%__MODULE__{descriptors: descriptors}, name) when is_binary(name),
    do: Map.fetch(descriptors, name)

  def fetch(_catalog, _name), do: :error

  @spec names(t()) :: [binary()]
  @doc "Returns installed aliases in UTF-8 byte order."
  def names(%__MODULE__{descriptors: descriptors}), do: descriptors |> Map.keys() |> Enum.sort()

  @doc "Closes an inert catalog."
  @spec close(t()) :: :ok
  def close(_catalog), do: :ok

  @spec public_installations(t()) :: [map()]
  @doc "Returns the closed selector-safe installed-provider projection."
  def public_installations(%__MODULE__{} = catalog) do
    Enum.map(names(catalog), fn name ->
      ProviderDescriptor.display_projection(Map.fetch!(catalog.descriptors, name), name)
    end)
  end

  @doc false
  @spec runtime_registry(t(), ProviderRuntimeServices.t()) ::
          {:ok, ProviderRegistry.t()} | {:error, atom()}
  def runtime_registry(%__MODULE__{} = catalog, %ProviderRuntimeServices{} = services) do
    with true <- valid?(catalog),
         true <- ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding),
         {:ok, owner} <- activate_registry_owner(services, catalog.runtime_binding) do
      open_runtime_registry(catalog, services, owner)
    else
      _invalid -> {:error, :invalid_provider_registry}
    end
  end

  def runtime_registry(_catalog, _services), do: {:error, :invalid_provider_registry}

  defp split_registrations(registrations) when map_size(registrations) <= 128 do
    Enum.reduce_while(registrations, {:ok, %{}, %{}, %{}}, fn
      {name,
       %{
         descriptor: %ProviderDescriptor{} = descriptor,
         implementation: implementation,
         authority: authority
       } = registration},
      {:ok, descriptors, implementations, authorities} ->
        if valid_name?(name) and not Map.has_key?(descriptors, name) and
             map_size(registration) == 3 and valid_authority_binding?(descriptor, authority) and
             valid_implementation?(descriptor, implementation) do
          {:cont,
           {:ok, Map.put(descriptors, name, descriptor),
            Map.put(implementations, name, implementation), Map.put(authorities, name, authority)}}
        else
          {:halt, {:error, :invalid_installation_catalog}}
        end

      _registration, _catalog ->
        {:halt, {:error, :invalid_installation_catalog}}
    end)
  end

  defp split_registrations(_registrations), do: {:error, :invalid_installation_catalog}

  defp valid_shape?(catalog) do
    catalog_maps_valid?(catalog) and catalog_keys_match?(catalog) and
      catalog_registrations_valid?(catalog) and catalog_support_valid?(catalog)
  end

  defp catalog_maps_valid?(catalog) do
    is_map(catalog.descriptors) and not is_struct(catalog.descriptors) and
      is_map(catalog.implementations) and not is_struct(catalog.implementations) and
      is_map(catalog.authorities) and not is_struct(catalog.authorities)
  end

  defp catalog_keys_match?(catalog) do
    descriptor_keys = Enum.sort(Map.keys(catalog.descriptors))

    descriptor_keys == Enum.sort(Map.keys(catalog.implementations)) and
      descriptor_keys == Enum.sort(Map.keys(catalog.authorities))
  end

  defp catalog_registrations_valid?(catalog) do
    Enum.all?(catalog.descriptors, fn {name, descriptor} ->
      valid_name?(name) and ProviderDescriptor.valid?(descriptor) and
        valid_authority_binding?(descriptor, Map.fetch!(catalog.authorities, name)) and
        valid_implementation?(descriptor, Map.fetch!(catalog.implementations, name))
    end)
  end

  defp catalog_support_valid?(catalog) do
    Limits.valid?(catalog.installed_limits) and valid_runtime_binding?(catalog.runtime_binding) and
      runtime_authority_bindings_valid?(catalog)
  end

  defp valid_runtime_binding?(nil), do: true
  defp valid_runtime_binding?(binding), do: is_binary(binding) and byte_size(binding) == 32

  defp runtime_authority_bindings_valid?(%{runtime_binding: nil, authorities: authorities}),
    do: Enum.all?(authorities, fn {_name, authority} -> authority != :host_runtime end)

  defp runtime_authority_bindings_valid?(%{runtime_binding: binding, authorities: authorities})
       when is_binary(binding),
       do:
         Enum.all?(authorities, fn
           {_name, %Authority{}} -> false
           {_name, authority} -> authority in [nil, :host_runtime]
         end)

  defp valid_implementation?(descriptor, implementation)
       when is_map(implementation) and not is_struct(implementation) do
    Map.keys(implementation) -- @implementation_keys == [] and
      is_function(Map.get(implementation, :builder), 2) and
      oauth_builder_matches?(descriptor, Map.get(implementation, :oauth_builder)) and
      local_preflight_matches?(
        descriptor.local_preflight != :none,
        Map.get(implementation, :local_preflight)
      ) and
      valid_provider_application?(Map.get(implementation, :provider_application)) and
      operation_matches?(
        descriptor.selection_validation == :active,
        Map.get(implementation, :selection_validator)
      ) and
      connectivity_probe_matches?(
        descriptor.connectivity_mode == :probe,
        Map.get(implementation, :connectivity_probe)
      )
  end

  defp valid_implementation?(_descriptor, _implementation), do: false

  defp valid_provider_application?(nil), do: true
  defp valid_provider_application?(:req_llm), do: true
  defp valid_provider_application?(_application), do: false

  defp operation_matches?(true, callback), do: is_function(callback, 2)
  defp operation_matches?(false, nil), do: true
  defp operation_matches?(_required, _callback), do: false

  defp local_preflight_matches?(true, callback), do: is_function(callback, 3)
  defp local_preflight_matches?(false, nil), do: true
  defp local_preflight_matches?(_required, _callback), do: false

  defp connectivity_probe_matches?(true, callback), do: is_function(callback, 3)
  defp connectivity_probe_matches?(false, nil), do: true
  defp connectivity_probe_matches?(_required, _callback), do: false

  defp oauth_builder_matches?(%{authorization_mode: :oauth}, callback),
    do: is_function(callback, 3)

  defp oauth_builder_matches?(%{authorization_mode: :none}, nil), do: true
  defp oauth_builder_matches?(_descriptor, _callback), do: false

  defp valid_authority_binding?(
         %{authorization_mode: :oauth, authority_fingerprint: fingerprint},
         %Authority{} = authority
       ),
       do: Authority.valid?(authority) and authority.fingerprint == fingerprint

  defp valid_authority_binding?(
         %{authorization_mode: :oauth, authority_fingerprint: fingerprint},
         :host_runtime
       ),
       do: is_binary(fingerprint)

  defp valid_authority_binding?(
         %{authorization_mode: :none, authority_fingerprint: nil},
         nil
       ),
       do: true

  defp valid_authority_binding?(_descriptor, _authority), do: false

  defp valid_name?(name), do: is_binary(name) and name =~ @name

  defp activate_registry_owner(services, runtime_binding) do
    case ProviderRuntimeServices.activate(services) do
      {:ok, nil} when is_binary(runtime_binding) ->
        {:error, :invalid_provider_registry}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, catalog_owner} when is_nil(runtime_binding) ->
        HostInstallationAuthority.release(catalog_owner)
        {:error, :invalid_provider_registry}

      {:ok, catalog_owner} ->
        transfer_registry_owner(catalog_owner)

      {:error, _reason} ->
        {:error, :invalid_provider_registry}
    end
  end

  defp transfer_registry_owner(catalog_owner) do
    case HostInstallationAuthority.transfer_to_registry(catalog_owner) do
      {:ok, registry_owner} ->
        {:ok, registry_owner}

      {:error, _reason} ->
        HostInstallationAuthority.release(catalog_owner)
        {:error, :invalid_provider_registry}
    end
  rescue
    exception ->
      HostInstallationAuthority.release(catalog_owner)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      HostInstallationAuthority.release(catalog_owner)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp open_runtime_registry(catalog, services, owner) do
    case runtime_oauth_authorities(catalog, owner) do
      {:ok, []} ->
        build_runtime_registry(catalog, services, %{}, owner)

      {:ok, authorities} ->
        open_oauth_registry(catalog, services, authorities, owner)

      {:error, _reason} ->
        HostInstallationAuthority.release(owner)
        {:error, :invalid_provider_registry}
    end
  end

  defp runtime_oauth_authorities(catalog, %HostInstallationAuthority{} = owner) do
    case HostInstallationAuthority.invoke(owner, :oauth_authorities) do
      {:ok, authorities} -> validate_runtime_oauth_authorities(catalog, authorities)
      {:error, _reason} -> {:error, :invalid_provider_registry}
    end
  end

  defp runtime_oauth_authorities(catalog, nil) do
    authorities =
      catalog.authorities
      |> Enum.reject(fn {_name, authority} -> is_nil(authority) end)
      |> Enum.sort_by(&elem(&1, 0))

    {:ok, authorities}
  end

  defp validate_runtime_oauth_authorities(catalog, authorities)
       when is_map(authorities) and not is_struct(authorities) do
    expected_names =
      catalog.descriptors
      |> Enum.filter(fn {_name, descriptor} -> descriptor.authorization_mode == :oauth end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if Enum.sort(Map.keys(authorities)) == expected_names and
         runtime_authorities_match?(authorities, catalog.descriptors) do
      {:ok, Enum.sort_by(authorities, &elem(&1, 0))}
    else
      {:error, :invalid_provider_registry}
    end
  end

  defp validate_runtime_oauth_authorities(_catalog, _authorities),
    do: {:error, :invalid_provider_registry}

  defp runtime_authorities_match?(authorities, descriptors) do
    Enum.all?(authorities, fn {name, authority} ->
      descriptor = Map.fetch!(descriptors, name)
      runtime_authority_matches?(authority, descriptor.authority_fingerprint)
    end)
  end

  defp runtime_authority_matches?(%Authority{} = authority, fingerprint),
    do: Authority.valid?(authority) and authority.fingerprint == fingerprint

  defp runtime_authority_matches?(_authority, _fingerprint), do: false

  defp open_oauth_registry(catalog, services, authorities, owner) do
    case ProviderRuntimeServices.oauth_context(services) do
      {:ok, context} ->
        claims =
          Enum.map(authorities, fn {_name, authority} ->
            {authority.installation_id, authority.fingerprint}
          end)

        activate_oauth_registry(catalog, services, authorities, claims, context, owner)

      {:error, _reason} = error ->
        HostInstallationAuthority.release(owner)
        error
    end
  end

  defp activate_oauth_registry(catalog, services, authorities, claims, context, owner) do
    case Store.claim_authorities(context.store, context.tenant_id, claims, 5_000) do
      {:ok, epochs} ->
        runtimes =
          Map.new(authorities, fn {name, authority} ->
            {name,
             %{
               authority: authority,
               authority_epoch: Map.fetch!(epochs, authority.installation_id),
               context: context
             }}
          end)

        build_runtime_registry(catalog, services, runtimes, owner)

      {:error, _reason} = error ->
        HostInstallationAuthority.release(owner)
        error
    end
  rescue
    exception ->
      HostInstallationAuthority.release(owner)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      HostInstallationAuthority.release(owner)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp build_runtime_registry(catalog, services, oauth_runtimes, owner) do
    result =
      with :ok <- install_oauth_runtimes(owner, oauth_runtimes) do
        ProviderRegistry.new(runtime_builders(catalog, oauth_runtimes, owner),
          credential_resolver: runtime_credential_resolver(services, owner),
          installed_limits: catalog.installed_limits,
          authority_owner: owner
        )
      end

    if match?({:error, _reason}, result), do: HostInstallationAuthority.release(owner)
    result
  rescue
    exception ->
      HostInstallationAuthority.release(owner)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      HostInstallationAuthority.release(owner)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp runtime_builders(catalog, _oauth_runtimes, %HostInstallationAuthority{} = owner) do
    Map.new(catalog.implementations, fn {name, _implementation} ->
      {name, ProviderRegistry.staged(HostInstallation.runtime_builder(owner, name))}
    end)
  end

  defp runtime_builders(catalog, oauth_runtimes, nil) do
    Map.new(catalog.implementations, fn {name, implementation} ->
      builder =
        case Map.fetch(oauth_runtimes, name) do
          {:ok, runtime} ->
            fn selection, context ->
              implementation.oauth_builder.(selection, context, runtime)
            end

          :error ->
            implementation.builder
        end

      {name, ProviderRegistry.staged(builder)}
    end)
  end

  defp runtime_credential_resolver(services, %HostInstallationAuthority{} = owner) do
    resolver = services.credential_resolver

    fn names ->
      HostInstallationAuthority.with_credential_lease(owner, fn -> resolver.(names) end)
    end
  end

  defp runtime_credential_resolver(services, nil), do: services.credential_resolver

  defp install_oauth_runtimes(%HostInstallationAuthority{} = owner, runtimes),
    do: HostInstallationAuthority.invoke(owner, {:install_oauth_runtimes, runtimes})

  defp install_oauth_runtimes(nil, _runtimes), do: :ok

  defp payload(catalog) do
    {
      catalog.descriptors,
      catalog.implementations,
      catalog.authorities,
      catalog.installed_limits,
      catalog.runtime_binding
    }
  end
end
