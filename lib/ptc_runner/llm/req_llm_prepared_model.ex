if Code.ensure_loaded?(LLMDB.Model) do
  defmodule PtcRunner.LLM.ReqLLMPreparedModel do
    @moduledoc """
    Prepared request target owned by `PtcRunner.LLM.ReqLLMAdapter`.

    Callers normally use configured selector strings. This value is exposed so
    the adapter's public types remain complete; its fields are an implementation
    detail and should be treated as opaque.
    """

    @enforce_keys [:selector, :model]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            selector: String.t(),
            model: LLMDB.Model.t()
          }
  end
end
