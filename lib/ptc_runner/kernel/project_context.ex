defmodule PtcRunner.Kernel.ProjectContext do
  @moduledoc false

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProjectConfig

  @enforce_keys [:config, :derived_options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{config: ProjectConfig.t(), derived_options: MapSet.t(atom())}

  @doc false
  @spec installed_limits(t() | nil) :: {:ok, Limits.t()} | {:error, term()}
  def installed_limits(nil), do: {:ok, Limits.installed_defaults()}

  def installed_limits(%__MODULE__{config: %ProjectConfig{host: nil}}),
    do: {:ok, Limits.installed_defaults()}

  def installed_limits(%__MODULE__{config: %ProjectConfig{host: path}}) when is_binary(path) do
    CommandAcquisition.with_catalog(path, fn _host, catalog ->
      {:ok, catalog.installed_limits}
    end)
  end
end
