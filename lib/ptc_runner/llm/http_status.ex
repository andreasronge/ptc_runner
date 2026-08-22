defmodule PtcRunner.LLM.HTTPStatus do
  @moduledoc false

  # Shared HTTP status classification for LLM adapters. Kind and retryability
  # are PtcRunner policy, not provider-SDK vocabulary.

  @spec error_kind(integer()) :: atom()
  def error_kind(401), do: :authentication_failed
  def error_kind(402), do: :payment_required
  def error_kind(403), do: :denied
  def error_kind(404), do: :not_found
  def error_kind(408), do: :timeout
  def error_kind(429), do: :rate_limited
  def error_kind(status) when status in 400..499, do: :invalid_request
  def error_kind(status) when status in 500..599, do: :unavailable
  def error_kind(_status), do: :unavailable

  @spec retryable?(integer()) :: boolean()
  def retryable?(status) when status in [408, 409, 425, 429], do: true
  def retryable?(status) when status in 500..599, do: true
  def retryable?(_status), do: false
end
