defmodule PtcRunner.Kernel.FrozenBundle do
  @moduledoc "An immutable, deterministically ordered bundle compilation result."
  @enforce_keys [:components, :component_ids, :hash]
  defstruct [:components, :component_ids, :hash]
  @type t :: %__MODULE__{components: [map()], component_ids: [binary()], hash: binary()}
end
