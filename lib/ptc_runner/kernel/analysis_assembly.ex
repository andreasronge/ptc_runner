defmodule PtcRunner.Kernel.AnalysisAssembly do
  @moduledoc false

  import Bitwise, only: [bor: 2, bxor: 2]

  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.SessionTrace

  @enforce_keys [:config, :profile, :resources, :session_trace, :run_state, :attestation]
  defstruct [:config, :profile, :resources, :session_trace, :run_state, :attestation]

  @doc false
  def seal(config, profile, resources, session_trace, run_state) do
    assembly = %__MODULE__{
      config: config,
      profile: profile,
      resources: resources,
      session_trace: session_trace,
      run_state: run_state,
      attestation: nil
    }

    %{assembly | attestation: attest(assembly)}
  end

  @doc false
  def valid?(%__MODULE__{attestation: attestation} = assembly) when is_binary(attestation) do
    secure_compare(attestation, attest(assembly)) and
      SessionTrace.valid_binding?(
        assembly.session_trace,
        assembly.run_state,
        assembly.config.event_sink,
        assembly.config.limits
      ) and
      valid_profile_assembly?(assembly)
  end

  def valid?(_assembly), do: false

  defp valid_profile_assembly?(%__MODULE__{profile: %{id: id}} = assembly) do
    case AnalysisProfileRegistry.fetch(id) do
      {:ok, recipe} ->
        recipe.valid_assembly?(
          assembly.config,
          assembly.profile,
          assembly.resources,
          assembly.session_trace
        )

      {:error, _reason} ->
        false
    end
  end

  defp valid_profile_assembly?(_assembly), do: false

  defp attest(assembly) do
    :crypto.mac(
      :hmac,
      :sha256,
      key(),
      :erlang.term_to_binary(
        {
          assembly.config,
          assembly.profile,
          assembly.resources,
          assembly.session_trace,
          assembly.run_state
        },
        [:deterministic]
      )
    )
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      bor(difference, bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp key do
    storage_key = {__MODULE__, :attestation_key}

    case :persistent_term.get(storage_key, :missing) do
      :missing ->
        :global.trans({storage_key, self()}, fn ->
          case :persistent_term.get(storage_key, :missing) do
            :missing ->
              secret = :crypto.strong_rand_bytes(32)
              :persistent_term.put(storage_key, secret)
              secret

            secret ->
              secret
          end
        end)

      secret ->
        secret
    end
  end
end
