if Code.ensure_loaded?(PtcLlmHttp) do
  defmodule PtcRunner.LLM.PtcLlmHttpPreparedModel do
    @moduledoc """
    Prepared request target owned by `PtcRunner.LLM.PtcLlmHttpAdapter`.

    Callers normally use configured selector strings. This value is exposed so
    the adapter's public types remain complete; its fields are an implementation
    detail and should be treated as opaque.
    """

    @enforce_keys [:selector, :target]
    defstruct @enforce_keys

    @opaque t :: %__MODULE__{selector: String.t(), target: term()}
  end
end
