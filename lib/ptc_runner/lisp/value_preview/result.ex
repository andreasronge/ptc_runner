defmodule PtcRunner.Lisp.ValuePreview.Result do
  @moduledoc """
  Bounded, non-authoritative presentation of a PTC-Lisp value.

  The original value remains authoritative. A preview may be truncated or may
  be replaced by a small fallback without changing evaluation outcome or
  continuation state.
  """

  @enforce_keys [:text, :truncated?, :caps_hit, :sampled_keys]
  defstruct [:text, :truncated?, :caps_hit, :sampled_keys]

  @type cap :: :depth | :items | :nodes | :output | :string

  @type t :: %__MODULE__{
          text: String.t(),
          truncated?: boolean(),
          caps_hit: [cap()],
          sampled_keys: [String.t()]
        }
end
