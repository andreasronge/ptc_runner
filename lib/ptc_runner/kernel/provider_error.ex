defmodule PtcRunner.Kernel.ProviderError do
  @moduledoc """
  A bounded host-constructed failure returned by a capability provider.

  Providers return `{:error, %ProviderError{}}` for expected failures. The
  dispatcher converts it into the uniform Lisp capability error envelope.
  `details` is truncated to 1,024 characters and must not contain credentials,
  BEAM exceptions, stack traces, or other host-private data.
  Adapters that translate dependency errors must select bounded diagnostic
  fields explicitly; inspecting an entire error value may retain request
  bodies, response bodies, headers, causes, or credentials and is forbidden.

  `mutation_state: :indeterminate` is orthogonal to the diagnostic `kind`: it
  means a non-successful call may already have changed external state and is
  therefore never retryable. `dispatch_provenance` is trusted, internal
  evidence for the mission dispatcher. Providers may set it to
  `:not_dispatched` only when no invocation could have reached the underlying
  transport, `:dispatched` when the callee returned a complete answer, or
  `:possibly_dispatched` when a call may have been sent and the outcome is
  unknown. It is never copied into the public Lisp envelope. A replay
  provider may attach its validated `:replay_request_hash`; the dispatcher
  records that host-owned evidence separately from the Lisp envelope. Missing
  provenance is treated conservatively after callback entry.
  """

  alias PtcRunner.Kernel.LLMFailureCatalog
  alias PtcRunner.Kernel.LLMReplayDiagnostic

  @kinds LLMFailureCatalog.provider_kinds()
  @options [:retryable?, :mutation_state, :dispatch_provenance, :replay_request_hash]
  @enforce_keys [:kind]
  defstruct [
    :kind,
    :details,
    :mutation_state,
    :dispatch_provenance,
    :replay_request_hash,
    retryable?: false
  ]

  @type kind :: LLMFailureCatalog.provider_kind()
  @type mutation_state :: :indeterminate
  @type dispatch_provenance :: :not_dispatched | :dispatched | :possibly_dispatched
  @type t :: %__MODULE__{
          kind: kind(),
          details: binary() | nil,
          retryable?: boolean(),
          mutation_state: mutation_state() | nil,
          dispatch_provenance: dispatch_provenance() | nil,
          replay_request_hash: binary() | nil
        }

  @spec new(kind(), binary() | nil, keyword()) :: t()
  @doc """
  Constructs a provider failure with optional bounded details and
  `:retryable?`, `:mutation_state`, internal `:dispatch_provenance`, and
  internal `:replay_request_hash` metadata.

  Mutation state accepts only `:indeterminate`, and dispatch provenance accepts
  `:not_dispatched`, `:dispatched`, or `:possibly_dispatched`. A replay request hash is
  valid only for a non-retryable `:not_found` error whose details are the exact
  replay-miss message for that hash. An indeterminate failure is always
  constructed as non-retryable.
  """
  def new(kind, details \\ nil, opts \\ [])
      when kind in @kinds and (is_binary(details) or is_nil(details)) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @options,
         retryable? when is_boolean(retryable?) <- Keyword.get(opts, :retryable?, false),
         mutation_state when mutation_state in [nil, :indeterminate] <-
           Keyword.get(opts, :mutation_state),
         dispatch_provenance
         when dispatch_provenance in [nil, :not_dispatched, :dispatched, :possibly_dispatched] <-
           Keyword.get(opts, :dispatch_provenance),
         replay_request_hash <- Keyword.get(opts, :replay_request_hash),
         {:ok, details} <- bounded_details(details) do
      error = %__MODULE__{
        kind: kind,
        details: details,
        retryable?: retryable? and is_nil(mutation_state),
        mutation_state: mutation_state,
        dispatch_provenance: dispatch_provenance,
        replay_request_hash: replay_request_hash
      }

      if valid?(error), do: error, else: raise(ArgumentError, "invalid provider error options")
    else
      _invalid_option -> raise ArgumentError, "invalid provider error options"
    end
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{
        kind: kind,
        details: details,
        retryable?: retryable?,
        mutation_state: mutation_state,
        dispatch_provenance: dispatch_provenance,
        replay_request_hash: replay_request_hash
      }) do
    kind in @kinds and valid_details?(details) and is_boolean(retryable?) and
      mutation_state in [nil, :indeterminate] and
      dispatch_provenance in [nil, :not_dispatched, :dispatched, :possibly_dispatched] and
      not (mutation_state == :indeterminate and retryable?) and
      valid_replay_miss?(kind, details, retryable?, mutation_state, replay_request_hash)
  end

  def valid?(_error), do: false

  defp bounded_details(nil), do: {:ok, nil}

  defp bounded_details(details) when is_binary(details) do
    if String.valid?(details),
      do: {:ok, String.slice(details, 0, 1_024)},
      else: :error
  end

  defp valid_details?(nil), do: true

  defp valid_details?(details) when is_binary(details),
    do: String.valid?(details) and String.length(details) <= 1_024

  defp valid_details?(_details), do: false

  defp valid_replay_miss?(_kind, _details, _retryable?, _mutation_state, nil), do: true

  defp valid_replay_miss?(:not_found, details, false, nil, request_hash)
       when is_binary(request_hash),
       do: LLMReplayDiagnostic.message(request_hash) == {:ok, details}

  defp valid_replay_miss?(_kind, _details, _retryable?, _mutation_state, _request_hash), do: false
end
