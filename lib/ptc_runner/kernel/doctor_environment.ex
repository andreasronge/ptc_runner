defmodule PtcRunner.Kernel.DoctorEnvironment do
  @moduledoc false

  # The two environment facts a default doctor plan is derived from.
  #
  # Both read this VM's own state only. Nothing here contacts a provider,
  # resolves a credential, starts an application, or consults a path outside the
  # code path, so collecting them cannot make a command that reports
  # `provider_activity: false` untrue.
  #
  # Neither fact can fail the command. An unsupported runtime or a missing
  # viewer is a warning row, because the closed result contract has no failing
  # environment code and both conditions are reportable rather than fatal.

  alias PtcRunner.Kernel.DoctorPlan

  # Kept in step with the `:elixir` requirement in `mix.exs` by
  # `PtcRunner.Kernel.DoctorEnvironmentTest`, so runtime code needs no Mix.
  @elixir_requirement "~> 1.15"
  @viewer PtcViewer

  @spec elixir_requirement() :: binary()
  @doc false
  def elixir_requirement, do: @elixir_requirement

  @spec facts() :: DoctorPlan.environment()
  @doc false
  def facts, do: %{runtime: runtime(), viewer: viewer()}

  defp runtime do
    if Version.match?(System.version(), @elixir_requirement),
      do: :supported,
      else: :unsupported
  rescue
    _exception -> :unsupported
  end

  # The viewer is an optional companion, so this asks the code path whether it
  # is installed rather than loading or starting it.
  defp viewer do
    if Code.ensure_loaded?(@viewer), do: :available, else: :unavailable
  end
end
