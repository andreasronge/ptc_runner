defmodule PtcRunner.PreludeRolePolicy.Grant do
  @moduledoc false

  @type t :: %__MODULE__{
          role: String.t(),
          fingerprint: String.t() | nil,
          prelude_store_access: :none | :read | :write,
          preludes: %{optional({String.t(), pos_integer()}) => map()},
          default_preludes: [term()],
          inner_preludes: %{optional({String.t(), pos_integer()}) => map()},
          default_inner_preludes: [term()]
        }

  defstruct [
    :role,
    :fingerprint,
    prelude_store_access: :none,
    preludes: %{},
    default_preludes: [],
    inner_preludes: %{},
    default_inner_preludes: []
  ]
end
