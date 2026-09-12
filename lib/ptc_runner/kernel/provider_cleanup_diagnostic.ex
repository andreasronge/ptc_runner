defmodule PtcRunner.Kernel.ProviderCleanupDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandSubject

  @message ~r/\Aprovider cleanup failed for [a-z][a-z0-9._-]{0,127} over (stdio|streamable_http): (cleanup deadline expired|launcher reported (server_exit|close|owner_eof|launcher_signal|protocol_error|termination_timeout)|transport (close timed out|closed without a finish frame))( \(exit status -?[0-9]+\))? after [0-9]+ ms \(grace_ms [0-9]+; cleanup budget [0-9]+ ms\)(; stderr: [^\r\n]{1,1024})?(; stderr truncated)?(; increase limits\.provider_cleanup_timeout_ms)?\z/u

  def fields(
        %{
          provider: provider,
          transport: transport,
          grace_ms: grace_ms,
          reason: reason,
          duration_ms: duration_ms,
          cleanup_budget_ms: budget_ms
        } = details
      )
      when transport in [:stdio, :streamable_http] and is_integer(grace_ms) and grace_ms > 0 and
             reason in [:cleanup_deadline_expired, :transport_failed] and
             is_integer(duration_ms) and duration_ms >= 0 and is_integer(budget_ms) and
             budget_ms > 0 do
    with {:ok, subject} <- CommandSubject.provider(provider, :cleanup),
         {:ok, cause} <- cause(reason, details) do
      message =
        "provider cleanup failed for #{provider} over #{transport}: #{cause} after #{duration_ms} ms " <>
          "(grace_ms #{grace_ms}; cleanup budget #{budget_ms} ms)" <>
          stderr_suffix(details) <> truncation_suffix(details) <> hint_suffix(reason)

      if valid_message?(message), do: {:ok, message, subject}, else: :error
    else
      _invalid -> :error
    end
  end

  def fields(_details), do: :error

  def valid_message?(message),
    do: is_binary(message) and byte_size(message) <= 2_048 and message =~ @message

  def trace_reason(details) do
    case fields(details) do
      {:ok, message, _subject} -> utf8_prefix(message, 1_020)
      :error -> :provider_cleanup_failed
    end
  end

  def message_schema(fallback),
    do: %{
      "anyOf" => [
        %{"const" => fallback},
        %{"type" => "string", "pattern" => schema_pattern(), "maxLength" => 2_048}
      ]
    }

  defp schema_pattern do
    @message
    |> Regex.source()
    |> String.replace("\\A", "^")
    |> String.replace("\\z", "$(?![\\s\\S])")
  end

  defp cause(:cleanup_deadline_expired, _details), do: {:ok, "cleanup deadline expired"}

  defp cause(:transport_failed, %{finish_reason: finish_reason} = details)
       when finish_reason in [
              :server_exit,
              :close,
              :owner_eof,
              :launcher_signal,
              :protocol_error,
              :termination_timeout
            ] do
    suffix =
      case Map.get(details, :exit_status) do
        status when is_integer(status) -> " (exit status #{status})"
        _unknown -> ""
      end

    {:ok, "launcher reported #{finish_reason}" <> suffix}
  end

  defp cause(:transport_failed, %{finish_reason: :close_timeout}),
    do: {:ok, "transport close timed out"}

  defp cause(:transport_failed, %{finish_reason: :finish_missing}),
    do: {:ok, "transport closed without a finish frame"}

  defp cause(_reason, _details), do: :error

  defp stderr_suffix(%{stderr: stderr}) when is_binary(stderr) and stderr != "" do
    stderr =
      stderr
      |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, " ")
      |> utf8_tail(1_024)

    if stderr == "", do: "", else: "; stderr: " <> stderr
  end

  defp stderr_suffix(_details), do: ""

  defp utf8_tail(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp utf8_tail(value, max_bytes) do
    offset = byte_size(value) - max_bytes
    valid_utf8_suffix(binary_part(value, offset, max_bytes))
  end

  defp valid_utf8_suffix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_suffix(binary_part(value, 1, byte_size(value) - 1))
  end

  defp utf8_prefix(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp utf8_prefix(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  defp truncation_suffix(%{stderr_truncated?: true}), do: "; stderr truncated"
  defp truncation_suffix(_details), do: ""
  defp hint_suffix(:cleanup_deadline_expired), do: "; increase limits.provider_cleanup_timeout_ms"
  defp hint_suffix(_reason), do: ""
end
