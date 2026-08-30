defmodule PtcRunner.Kernel.ProjectContext do
  @moduledoc false

  alias PtcRunner.Kernel.ProjectConfig

  @enforce_keys [:config, :derived_options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{config: ProjectConfig.t(), derived_options: MapSet.t(atom())}
end
