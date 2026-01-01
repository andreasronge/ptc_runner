defmodule PtcRunner.SubAgent.Loop.LLMRetry do
  @moduledoc """
  LLM retry logic with configurable backoff strategies.

  This module handles retrying failed LLM calls based on error classification
  and backoff configuration. It supports exponential, linear, and constant
  backoff strategies.

  ## Configuration

  Retry behavior is configured via a map with the following keys:

  - `max_attempts` - Maximum number of attempts (default: 1, no retries)
  - `backoff` - Backoff strategy: `:exponential`, `:linear`, or `:constant` (default: `:exponential`)
  - `base_delay` - Base delay in milliseconds (default: 1000)
  - `retryable_errors` - List of error types to retry (default: `[:rate_limit, :timeout, :server_error]`)

  ## Error Classification

  Errors are classified into the following types:

  - `:rate_limit` - HTTP 429 errors
  - `:server_error` - HTTP 5xx errors
  - `:client_error` - HTTP 4xx errors (not retryable by default)
  - `:timeout` - Timeout errors
  - `:config_error` - LLM configuration errors
  - `:unknown` - Unclassified errors
  """

  alias PtcRunner.SubAgent.LLMResolver

  @default_retryable_errors [:rate_limit, :timeout, :server_error]
  @default_base_delay 1000

  @doc """
  Call LLM with retry logic based on retry configuration.

  ## Parameters

  - `llm` - LLM callback function or atom reference
  - `input` - LLM input map
  - `llm_registry` - Registry for resolving atom LLM references
  - `retry_config` - Optional retry configuration map

  ## Returns

  - `{:ok, response}` on success
  - `{:error, reason}` on failure after all retries exhausted
  """
  @spec call_with_retry(term(), map(), map(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def call_with_retry(llm, input, llm_registry, retry_config, attempt \\ 1) do
    config = retry_config || %{}
    max_attempts = Map.get(config, :max_attempts, 1)

    case LLMResolver.resolve(llm, input, llm_registry) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when attempt < max_attempts ->
        if retryable?(reason, config) do
          delay = calculate_delay(config, attempt)
          Process.sleep(delay)
          call_with_retry(llm, input, llm_registry, retry_config, attempt + 1)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Determine if an error should be retried based on configuration.

  ## Examples

      iex> PtcRunner.SubAgent.Loop.LLMRetry.retryable?({:http_error, 429, "rate limited"}, %{})
      true

      iex> PtcRunner.SubAgent.Loop.LLMRetry.retryable?({:http_error, 400, "bad request"}, %{})
      false
  """
  @spec retryable?(term(), map()) :: boolean()
  def retryable?(reason, config) do
    error_type = classify_error(reason)
    retryable_errors = Map.get(config, :retryable_errors, @default_retryable_errors)
    error_type in retryable_errors
  end

  @doc """
  Classify error type for retry decision.

  ## Examples

      iex> PtcRunner.SubAgent.Loop.LLMRetry.classify_error({:http_error, 429, "rate limited"})
      :rate_limit

      iex> PtcRunner.SubAgent.Loop.LLMRetry.classify_error({:http_error, 500, "server error"})
      :server_error

      iex> PtcRunner.SubAgent.Loop.LLMRetry.classify_error(:timeout)
      :timeout
  """
  @spec classify_error(term()) :: atom()
  def classify_error({:http_error, 429, _}), do: :rate_limit
  def classify_error({:http_error, status, _}) when status >= 500, do: :server_error
  def classify_error({:http_error, status, _}) when status >= 400, do: :client_error
  def classify_error(:timeout), do: :timeout
  def classify_error({:llm_not_found, _}), do: :config_error
  def classify_error({:llm_registry_required, _}), do: :config_error
  def classify_error({:invalid_llm, _}), do: :config_error
  def classify_error(_), do: :unknown

  @doc """
  Calculate delay based on backoff strategy.

  ## Examples

      iex> PtcRunner.SubAgent.Loop.LLMRetry.calculate_delay(%{backoff: :constant, base_delay: 100}, 3)
      100

      iex> PtcRunner.SubAgent.Loop.LLMRetry.calculate_delay(%{backoff: :linear, base_delay: 100}, 3)
      300
  """
  @spec calculate_delay(map(), pos_integer()) :: pos_integer()
  def calculate_delay(%{backoff: :exponential, base_delay: base}, attempt) do
    trunc(base * :math.pow(2, attempt - 1))
  end

  def calculate_delay(%{backoff: :linear, base_delay: base}, attempt) do
    base * attempt
  end

  def calculate_delay(%{backoff: :constant, base_delay: base}, _attempt) do
    base
  end

  def calculate_delay(%{base_delay: base}, attempt) do
    # Default to exponential if backoff not specified
    trunc(base * :math.pow(2, attempt - 1))
  end

  def calculate_delay(_config, _attempt) do
    # Default delay when base_delay not specified
    @default_base_delay
  end
end
