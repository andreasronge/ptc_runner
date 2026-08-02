defmodule PtcRunner.Kernel.ProviderRuntimeServices do
  @moduledoc """
  Sealed services supplied only when active provider runtime is opened.

  Construction is process-free and invokes no resolver or context factory.
  Activation may start one private host authority, and OAuth context creation
  remains lazy until a selected catalog requires it.
  An opaque keyed binding prevents host services from opening a catalog built
  from a different host document without exposing credential declarations.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.HostRuntimePayload
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext

  @enforce_keys [
    :activation,
    :credential_resolver,
    :oauth_mode,
    :runtime_binding,
    :host_payload
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type credential_resolver ::
          ([binary()] -> {:ok, %{binary() => binary()}} | {:error, term()})
  @type activation :: (-> {:ok, struct() | nil} | {:error, term()})
  @type oauth_mode ::
          :disabled | {:context_factory, (-> {:ok, OAuthContext.t()} | {:error, term()})}
  @type t :: %__MODULE__{
          activation: activation(),
          credential_resolver: credential_resolver(),
          oauth_mode: oauth_mode(),
          runtime_binding: binary() | nil,
          host_payload: struct() | nil,
          attestation: binary() | nil
        }

  @doc "Validates and seals runtime services without invoking them."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_provider_runtime_services}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and unique_allowed_options?(opts) do
      build(
        Keyword.get(opts, :activation, fn -> {:ok, nil} end),
        Keyword.get(opts, :credential_resolver, &default_credential_resolver/1),
        Keyword.get(opts, :oauth_mode, :disabled),
        nil,
        nil
      )
    else
      {:error, :invalid_provider_runtime_services}
    end
  end

  def new(_opts), do: {:error, :invalid_provider_runtime_services}

  @doc false
  @spec from_host_payload(HostRuntimePayload.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_provider_runtime_services}
  def from_host_payload(payload, opts \\ [])

  def from_host_payload(payload, opts) when is_list(opts) do
    if Keyword.keyword?(opts) and unique_oauth_options?(opts) do
      case HostRuntimePayload.binding(payload) do
        {:ok, binding} ->
          build(
            fn -> HostRuntimePayload.activate(payload) end,
            fn names -> HostRuntimePayload.resolve_credentials(payload, names) end,
            Keyword.get(opts, :oauth_mode, :disabled),
            binding,
            payload
          )

        {:error, _reason} ->
          {:error, :invalid_provider_runtime_services}
      end
    else
      {:error, :invalid_provider_runtime_services}
    end
  end

  def from_host_payload(_payload, _opts), do: {:error, :invalid_provider_runtime_services}

  @doc "Checks the complete sealed runtime-services value."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = services),
    do:
      Enum.sort(Map.keys(services)) == @field_keys and fields_valid?(services) and
        Attestation.valid?(__MODULE__, payload(services), attestation)

  def valid?(_services), do: false

  @doc false
  @spec bound_to?(term(), binary() | nil) :: boolean()
  def bound_to?(%__MODULE__{} = services, nil),
    do: valid?(services) and is_nil(services.runtime_binding) and is_nil(services.host_payload)

  def bound_to?(%__MODULE__{} = services, runtime_binding) when is_binary(runtime_binding),
    do:
      valid?(services) and services.runtime_binding == runtime_binding and
        HostRuntimePayload.bound_to?(services.host_payload, runtime_binding)

  def bound_to?(_services, _runtime_binding), do: false

  @doc false
  @spec host_call(t(), binary(), term()) :: term()
  def host_call(
        %__MODULE__{} = services,
        runtime_binding,
        {operation, name, selection, context} = request
      )
      when is_binary(runtime_binding) and
             operation in [:local_preflight, :connectivity_probe] and is_binary(name) and
             is_map(selection) and is_map(context) do
    if bound_to?(services, runtime_binding) do
      HostRuntimePayload.invoke(services.host_payload, request)
    else
      {:error, :invalid_provider_runtime_services}
    end
  end

  def host_call(_services, _runtime_binding, _request),
    do: {:error, :invalid_provider_runtime_services}

  @doc false
  @spec activate(t()) ::
          {:ok, HostInstallationAuthority.t() | nil}
          | {:error, :invalid_provider_runtime_services}
  def activate(%__MODULE__{} = services) do
    with true <- valid?(services),
         {:ok, owner} <- services.activation.() do
      validate_activation_owner(owner)
    else
      _invalid -> {:error, :invalid_provider_runtime_services}
    end
  rescue
    _exception -> {:error, :invalid_provider_runtime_services}
  catch
    _kind, _reason -> {:error, :invalid_provider_runtime_services}
  end

  defp validate_activation_owner(nil), do: {:ok, nil}

  defp validate_activation_owner(%HostInstallationAuthority{} = owner) do
    if HostInstallationAuthority.valid?(owner) do
      {:ok, owner}
    else
      HostInstallationAuthority.release(owner)
      {:error, :invalid_provider_runtime_services}
    end
  rescue
    _exception ->
      HostInstallationAuthority.release(owner)
      {:error, :invalid_provider_runtime_services}
  catch
    _kind, _reason ->
      HostInstallationAuthority.release(owner)
      {:error, :invalid_provider_runtime_services}
  end

  defp validate_activation_owner(_owner), do: {:error, :invalid_provider_runtime_services}

  @doc false
  @spec oauth_context(t()) ::
          {:ok, OAuthContext.t()} | {:error, :authorization_context_required}
  def oauth_context(%__MODULE__{} = services) do
    if valid?(services) do
      case services.oauth_mode do
        {:context_factory, factory} ->
          case factory.() do
            {:ok, %OAuthContext{} = context} -> {:ok, context}
            _invalid -> {:error, :authorization_context_required}
          end

        :disabled ->
          {:error, :authorization_context_required}
      end
    else
      {:error, :authorization_context_required}
    end
  rescue
    _exception -> {:error, :authorization_context_required}
  catch
    _kind, _reason -> {:error, :authorization_context_required}
  end

  defp unique_allowed_options?(opts) do
    keys = Keyword.keys(opts)

    keys -- [:activation, :credential_resolver, :oauth_mode] == [] and
      length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp unique_oauth_options?(opts) do
    keys = Keyword.keys(opts)
    keys -- [:oauth_mode] == [] and length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp build(activation, credential_resolver, oauth_mode, runtime_binding, host_payload) do
    services = %__MODULE__{
      activation: activation,
      credential_resolver: credential_resolver,
      oauth_mode: oauth_mode,
      runtime_binding: runtime_binding,
      host_payload: host_payload
    }

    if fields_valid?(services) do
      {:ok, %{services | attestation: Attestation.attest(__MODULE__, payload(services))}}
    else
      {:error, :invalid_provider_runtime_services}
    end
  end

  defp fields_valid?(services),
    do:
      is_function(services.activation, 0) and
        is_function(services.credential_resolver, 1) and
        valid_oauth_mode?(services.oauth_mode) and
        valid_runtime_binding?(services.runtime_binding, services.host_payload)

  defp valid_oauth_mode?(:disabled), do: true
  defp valid_oauth_mode?({:context_factory, factory}), do: is_function(factory, 0)
  defp valid_oauth_mode?(_mode), do: false

  defp valid_runtime_binding?(nil, nil), do: true

  defp valid_runtime_binding?(binding, payload),
    do:
      is_binary(binding) and byte_size(binding) == 32 and
        HostRuntimePayload.bound_to?(payload, binding)

  defp default_credential_resolver([]), do: {:ok, %{}}
  defp default_credential_resolver(_names), do: {:error, :credential_resolver_missing}

  defp payload(services),
    do:
      {services.activation, services.credential_resolver, services.oauth_mode,
       services.runtime_binding, services.host_payload}
end
