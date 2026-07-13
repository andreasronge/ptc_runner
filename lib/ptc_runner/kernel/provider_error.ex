defmodule PtcRunner.Kernel.ProviderError do
  @moduledoc """
  A bounded host-constructed failure returned by a capability provider.

  Providers return `{:error, %ProviderError{}}` for expected failures. The
  dispatcher converts it into the uniform Lisp capability error envelope.
  `details` is truncated to 1,024 characters and must not contain credentials,
  BEAM exceptions, stack traces, or other host-private data.
  """

  @enforce_keys [:kind]
  defstruct [:kind, :details, retryable?: false]

  @type kind :: :denied | :not_found | :unavailable | :invalid_request | :internal
  @type t :: %__MODULE__{kind: kind(), details: binary() | nil, retryable?: boolean()}

  @spec new(kind(), binary() | nil, keyword()) :: t()
  @doc """
  Constructs a provider failure with optional bounded details and
  `:retryable?` metadata.
  """
  def new(kind, details \\ nil, opts \\ [])
      when kind in [:denied, :not_found, :unavailable, :invalid_request, :internal] and
             (is_binary(details) or is_nil(details)) do
    %__MODULE__{
      kind: kind,
      details: details && String.slice(details, 0, 1_024),
      retryable?: Keyword.get(opts, :retryable?, false)
    }
  end
end
