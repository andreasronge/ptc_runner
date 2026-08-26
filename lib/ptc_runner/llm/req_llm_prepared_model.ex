if Code.ensure_loaded?(LLMDB.Model) do
  defmodule PtcRunner.LLM.ReqLLMPreparedModel do
    @moduledoc """
    Prepared request target owned by `PtcRunner.LLM.ReqLLMAdapter`.

    Callers normally use configured selector strings. This value is exposed so
    the adapter's public types remain complete; its fields are an implementation
    detail and should be treated as opaque.
    """

    @enforce_keys [:selector, :exact_options]
    defstruct [:selector, :exact_options, model: nil]

    @type t :: %__MODULE__{
            selector: String.t(),
            exact_options: map(),
            model: LLMDB.Model.t() | nil
          }
  end
end
