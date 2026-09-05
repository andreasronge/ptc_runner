defmodule PtcRunner.Kernel.HostRuntimePayload do
  @moduledoc """
  Internal sealed transport for credential-bearing host runtime configuration.

  The authenticated ciphertext prevents credentials from appearing in normal
  struct inspection or accidental term logging while the payload crosses
  trusted Kernel boundaries. Its key is VM-local process state, so this is not
  a confidentiality boundary against trusted code running in the same VM,
  memory inspection, or crash dumps. Callers must apply the same operational
  protections to VM diagnostics and dumps as to the original host config.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationOwner

  @aad_version 1
  @nonce_bytes 12
  @tag_bytes 16

  @enforce_keys [:binding, :nonce, :ciphertext, :tag]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @opaque t :: %__MODULE__{
            binding: binary(),
            nonce: binary(),
            ciphertext: binary(),
            tag: binary(),
            attestation: binary() | nil
          }

  @spec seal(HostConfig.t()) :: {:ok, t()} | {:error, :invalid_host_runtime_payload}
  def seal(%HostConfig{} = host) do
    binding = Attestation.attest(HostInstallation, host)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    plaintext = :erlang.term_to_binary(host, [:compressed, :deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        encryption_key(),
        nonce,
        plaintext,
        aad(binding),
        @tag_bytes,
        true
      )

    payload = %__MODULE__{
      binding: binding,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag
    }

    {:ok, %{payload | attestation: Attestation.attest(__MODULE__, envelope(payload))}}
  rescue
    _exception -> {:error, :invalid_host_runtime_payload}
  end

  def seal(_host), do: {:error, :invalid_host_runtime_payload}

  @spec binding(t()) :: {:ok, binary()} | {:error, :invalid_host_runtime_payload}
  def binding(%__MODULE__{} = payload) do
    if valid_envelope?(payload),
      do: {:ok, payload.binding},
      else: {:error, :invalid_host_runtime_payload}
  end

  def binding(_payload), do: {:error, :invalid_host_runtime_payload}

  @spec bound_to?(term(), binary()) :: boolean()
  def bound_to?(%__MODULE__{} = payload, binding),
    do: valid_envelope?(payload) and payload.binding == binding

  def bound_to?(_payload, _binding), do: false

  @spec activate(t()) :: {:ok, struct()} | {:error, term()}
  def activate(%__MODULE__{} = payload),
    do: with_host(payload, &HostInstallationOwner.start/1)

  def activate(_payload), do: {:error, :invalid_host_runtime_payload}

  @spec resolve_credentials(t(), [binary()]) ::
          {:ok, %{binary() => binary()}} | {:error, term()}
  def resolve_credentials(%__MODULE__{} = payload, names) when is_list(names) do
    with_host(payload, fn host -> HostInstallation.resolve_runtime_credentials(host, names) end)
  end

  def resolve_credentials(_payload, _names), do: {:error, :invalid_host_runtime_payload}

  @doc false
  @spec any_environment_credential?(t(), [binary()]) :: boolean()
  def any_environment_credential?(%__MODULE__{} = payload, names) when is_list(names) do
    with_host(payload, fn host ->
      Enum.any?(names, fn name ->
        match?({:ok, %{source: :env}}, Map.fetch(host.credentials, name))
      end)
    end) == true
  end

  def any_environment_credential?(_payload, _names), do: false

  @doc false
  @spec oauth_authorities(t(), [binary()]) :: {:ok, map()} | {:error, term()}
  def oauth_authorities(%__MODULE__{} = payload, selected_names) when is_list(selected_names),
    do: with_host(payload, &HostInstallation.owner_call(&1, {:oauth_authorities, selected_names}))

  def oauth_authorities(_payload, _selected_names),
    do: {:error, :invalid_host_runtime_payload}

  @spec invoke(t(), term()) :: term()
  def invoke(
        %__MODULE__{} = payload,
        {operation, name, selection, context} = request
      )
      when operation in [:local_preflight, :connectivity_probe] and is_binary(name) and
             is_map(selection) and is_map(context) do
    with_host(payload, fn host -> HostInstallation.owner_call(host, request) end)
  end

  def invoke(_payload, _request), do: {:error, :invalid_host_runtime_payload}

  defp with_host(payload, operation) do
    with {:ok, host} <- decrypt(payload) do
      operation.(host)
    end
  rescue
    _exception -> {:error, :invalid_host_runtime_payload}
  catch
    _kind, _reason -> {:error, :invalid_host_runtime_payload}
  end

  defp decrypt(payload) do
    with true <- valid_envelope?(payload),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             encryption_key(),
             payload.nonce,
             payload.ciphertext,
             aad(payload.binding),
             payload.tag,
             false
           ),
         %HostConfig{} = host <- :erlang.binary_to_term(plaintext, [:safe]),
         true <- Attestation.valid?(HostInstallation, host, payload.binding) do
      {:ok, host}
    else
      _invalid -> {:error, :invalid_host_runtime_payload}
    end
  end

  defp valid_envelope?(%__MODULE__{attestation: attestation} = payload),
    do:
      Enum.sort(Map.keys(payload)) == @field_keys and
        is_binary(payload.binding) and byte_size(payload.binding) == 32 and
        is_binary(payload.nonce) and byte_size(payload.nonce) == @nonce_bytes and
        is_binary(payload.ciphertext) and is_binary(payload.tag) and
        byte_size(payload.tag) == @tag_bytes and
        Attestation.valid?(__MODULE__, envelope(payload), attestation)

  defp encryption_key, do: Attestation.attest(__MODULE__, :host_runtime_encryption_key)

  defp aad(binding), do: :erlang.term_to_binary({__MODULE__, @aad_version, binding})

  defp envelope(payload),
    do: {payload.binding, payload.nonce, payload.ciphertext, payload.tag}
end
