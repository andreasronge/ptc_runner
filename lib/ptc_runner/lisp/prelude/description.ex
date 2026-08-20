defmodule PtcRunner.Lisp.Prelude.Description do
  @moduledoc false

  alias PtcRunner.Lisp.Prelude.Spec

  @enforce_keys [:source, :specs, :namespace_metadata, :namespaces]
  defstruct [:source, :specs, :namespace_metadata, :namespaces]

  @type t :: %__MODULE__{
          source: String.t(),
          specs: [Spec.t()],
          namespace_metadata: %{String.t() => map()},
          namespaces: [String.t()]
        }
end
