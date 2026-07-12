defmodule PtcRunner.Kernel.FrozenBundle do
  @moduledoc "An immutable, deterministically ordered bundle compilation result."
  @enforce_keys [:components, :component_ids, :hash, :prelude]
  defstruct [:components, :component_ids, :hash, :prelude]

  @type t :: %__MODULE__{
          components: [map()],
          component_ids: [binary()],
          hash: binary(),
          prelude: PtcRunner.Lisp.Prelude.t()
        }
end
