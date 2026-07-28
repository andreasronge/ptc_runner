defmodule PtcRunner.Kernel.ProviderError do
  @moduledoc """
  A bounded host-constructed failure returned by a capability provider.

  Providers return `{:error, %ProviderError{}}` for expected failures. The
  dispatcher converts it into the uniform Lisp capability error envelope.
  `details` is truncated to 1,024 characters and must not contain credentials,
  BEAM exceptions, stack traces, or other host-private data.

  `mutation_state: :indeterminate` is orthogonal to the diagnostic `kind`: it
  means a non-successful call may already have changed external state and is
  therefore never retryable. `dispatch_provenance` is trusted, internal
  evidence for the mission dispatcher. Providers may set it to
  `:not_dispatched` only when no invocation could have reached the underlying
  transport; it is never copied into the public Lisp envelope. Missing
  provenance is treated conservatively after callback entry.
  """

  @kinds [
    :denied,
    :not_found,
    :unavailable,
    :invalid_request,
    :internal,
    :domain_error,
    :invalid_result,
    :authentication_failed,
    :timeout,
    :transport_error
  ]
  @options [:retryable?, :mutation_state, :dispatch_provenance]
  @enforce_keys [:kind]
  defstruct [:kind, :details, :mutation_state, :dispatch_provenance, retryable?: false]

  @type kind ::
          :denied
          | :not_found
          | :unavailable
          | :invalid_request
          | :internal
          | :domain_error
          | :invalid_result
          | :authentication_failed
          | :timeout
          | :transport_error
  @type mutation_state :: :indeterminate
  @type dispatch_provenance :: :not_dispatched | :possibly_dispatched
  @type t :: %__MODULE__{
          kind: kind(),
          details: binary() | nil,
          retryable?: boolean(),
          mutation_state: mutation_state() | nil,
          dispatch_provenance: dispatch_provenance() | nil
        }

  @spec new(kind(), binary() | nil, keyword()) :: t()
  @doc """
  Constructs a provider failure with optional bounded details and
  `:retryable?`, `:mutation_state`, and internal `:dispatch_provenance`
  metadata.

  Mutation state accepts only `:indeterminate`, and dispatch provenance accepts
  only `:not_dispatched` or `:possibly_dispatched`. An indeterminate failure is
  always constructed as non-retryable.
  """
  def new(kind, details \\ nil, opts \\ [])
      when kind in @kinds and (is_binary(details) or is_nil(details)) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @options,
         retryable? when is_boolean(retryable?) <- Keyword.get(opts, :retryable?, false),
         mutation_state when mutation_state in [nil, :indeterminate] <-
           Keyword.get(opts, :mutation_state),
         dispatch_provenance
         when dispatch_provenance in [nil, :not_dispatched, :possibly_dispatched] <-
           Keyword.get(opts, :dispatch_provenance),
         {:ok, details} <- bounded_details(details) do
      %__MODULE__{
        kind: kind,
        details: details,
        retryable?: retryable? and is_nil(mutation_state),
        mutation_state: mutation_state,
        dispatch_provenance: dispatch_provenance
      }
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
        dispatch_provenance: dispatch_provenance
      }) do
    kind in @kinds and valid_details?(details) and is_boolean(retryable?) and
      mutation_state in [nil, :indeterminate] and
      dispatch_provenance in [nil, :not_dispatched, :possibly_dispatched] and
      not (mutation_state == :indeterminate and retryable?)
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
end
