defmodule PtcRunner.LLM.Invocation do
  @moduledoc """
  Closed per-call adapter request sealed by `PtcRunner.LLM.callback/2`.

  Hosts receive an arity-two requester and do not construct this struct.
  Adapter `call/2` receives the sealed request map, credential, cache flag, and
  optional per-call deadline. A `nil` deadline means the call is not bound to a
  live Kernel cutoff.
  """

  @max_credential_bytes 65_536
  @keys [:request, :credential, :cache, :llm_request_deadline_ms]

  @enforce_keys @keys
  defstruct @keys

  @type t :: %__MODULE__{
          request: map(),
          credential: binary() | nil,
          cache: boolean(),
          llm_request_deadline_ms: integer() | nil
        }

  @doc false
  @spec new(map(), boolean(), binary() | nil, integer() | nil) ::
          {:ok, t()} | {:error, :invalid_llm_binding}
  def new(request, cache, credential, deadline_ms)
      when is_map(request) and not is_struct(request) and is_boolean(cache) do
    invocation = %__MODULE__{
      request: request,
      credential: credential,
      cache: cache,
      llm_request_deadline_ms: deadline_ms
    }

    if valid?(invocation), do: {:ok, invocation}, else: {:error, :invalid_llm_binding}
  end

  def new(_request, _cache, _credential, _deadline_ms), do: {:error, :invalid_llm_binding}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = invocation) do
    Enum.sort(Map.keys(invocation)) == Enum.sort([:__struct__ | @keys]) and
      is_map(invocation.request) and not is_struct(invocation.request) and
      valid_credential?(invocation.credential) and is_boolean(invocation.cache) and
      valid_deadline?(invocation.llm_request_deadline_ms)
  end

  def valid?(_invocation), do: false

  defp valid_credential?(nil), do: true

  defp valid_credential?(credential)
       when is_binary(credential) and byte_size(credential) in 1..@max_credential_bytes,
       do: true

  defp valid_credential?(_credential), do: false

  defp valid_deadline?(nil), do: true
  defp valid_deadline?(deadline_ms) when is_integer(deadline_ms), do: true
  defp valid_deadline?(_deadline_ms), do: false
end
