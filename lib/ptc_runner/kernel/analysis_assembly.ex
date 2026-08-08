defmodule PtcRunner.Kernel.AnalysisAssembly do
  @moduledoc false

  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.Attestation
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

    %{assembly | attestation: Attestation.attest(__MODULE__, payload(assembly))}
  end

  @doc false
  def valid?(%__MODULE__{attestation: attestation} = assembly) when is_binary(attestation) do
    Attestation.valid?(__MODULE__, payload(assembly), attestation) and
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

  defp payload(assembly) do
    {
      assembly.config,
      assembly.profile,
      assembly.resources,
      assembly.session_trace,
      assembly.run_state
    }
  end
end
