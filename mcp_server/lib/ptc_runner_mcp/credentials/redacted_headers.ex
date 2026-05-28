defmodule PtcRunnerMcp.Credentials.RedactedHeaders do
  @moduledoc """
  Opaque wrapper around auth-bearing HTTP headers produced by
  `PtcRunnerMcp.Credentials.apply_emitter/2`.

  The struct's `Inspect` implementation renders only
  `#Credentials.RedactedHeaders<[REDACTED]>` so that `inspect/2` of any
  struct that transitively contains it (GenServer state, supervisor
  restart messages, telemetry payloads, etc.) cannot leak the
  underlying bytes. Per `Plans/http-transport-credentials.md` §7.3, the
  `Upstream.Http` request layer is the only legitimate consumer that
  unwraps it.

  A plain tagged tuple would not be sufficient —
  `inspect({:redacted_headers, headers})` prints the inner list. The
  struct + custom `Inspect` impl is the load-bearing safety property.

  Spec: `Plans/http-transport-credentials.md` §7.3.
  """

  @type t :: %__MODULE__{headers: [{String.t(), String.t()}]}
  defstruct [:headers]

  @doc """
  Wrap a list of `{name, value}` header tuples into a redacted
  container.
  """
  @spec new([{String.t(), String.t()}]) :: t()
  def new(headers) when is_list(headers), do: %__MODULE__{headers: headers}

  @doc """
  Unwrap the inner header list.

  This is the **only legitimate exit point** for the wrapped bytes.
  Per §7.3 the only legitimate caller is upstream HTTP transport auth
  request layer, which splices the headers into an outbound `Req`
  request and drops its reference once the request returns.
  """
  @spec headers(t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{headers: h}), do: h

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(_struct, _opts) do
      concat(["#Credentials.RedactedHeaders<[REDACTED]>"])
    end
  end
end
