defmodule PtcRunner.Kernel.ProviderCleanupDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DiagnosticPattern

  @deadline_message "cleanup deadline expired"
  @finish_reasons [
    :server_exit,
    :close,
    :owner_eof,
    :launcher_signal,
    :protocol_error,
    :termination_timeout
  ]
  @launcher_template [
    {:literal, "launcher reported "},
    {:slot, :reason, :text, "(" <> Enum.map_join(@finish_reasons, "|", &Atom.to_string/1) <> ")"}
  ]
  @transport_prefix "transport "
  @transport_phrases [
    {:close_timeout, "close timed out"},
    {:finish_missing, "closed without a finish frame"}
  ]
  @exit_template [
    {:literal, " (exit status "},
    {:slot, :status, :integer, "-?[0-9]+"},
    {:literal, ")"}
  ]
  @stderr_template [{:literal, "; stderr: "}, {:slot, :stderr, :text, ~S'[^\r\n]{1,1024}'}]
  @truncated_message "; stderr truncated"
  @hint_message "; increase limits.provider_cleanup_timeout_ms"
  @cause_pattern "(" <>
                   DiagnosticPattern.escape(@deadline_message) <>
                   "|" <>
                   DiagnosticPattern.body(@launcher_template) <>
                   "|" <>
                   DiagnosticPattern.escape(@transport_prefix) <>
                   "(" <>
                   Enum.map_join(@transport_phrases, "|", fn {_reason, phrase} ->
                     DiagnosticPattern.escape(phrase)
                   end) <>
                   "))(" <> DiagnosticPattern.body(@exit_template) <> ")?"
  @template [
    {:literal, "provider cleanup failed for "},
    {:slot, :provider, :text, "[a-z][a-z0-9._-]{0,127}"},
    {:literal, " over "},
    {:slot, :transport, :text, "(stdio|streamable_http)"},
    {:literal, ": "},
    {:slot, :cause, :text, @cause_pattern},
    {:literal, " after "},
    {:slot, :duration, :integer, "[0-9]+"},
    {:literal, " ms (grace_ms "},
    {:slot, :grace, :integer, "[0-9]+"},
    {:literal, "; cleanup budget "},
    {:slot, :budget, :integer, "[0-9]+"},
    {:literal, " ms)"},
    {:slot, :stderr, :text, "(" <> DiagnosticPattern.body(@stderr_template) <> ")?"},
    {:slot, :truncated, :text, "(" <> DiagnosticPattern.escape(@truncated_message) <> ")?"},
    {:slot, :hint, :text, "(" <> DiagnosticPattern.escape(@hint_message) <> ")?"}
  ]
  @message Regex.compile!("\\A" <> DiagnosticPattern.body(@template) <> "\\z", "u")

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
        DiagnosticPattern.render(@template, %{
          provider: provider,
          transport: Atom.to_string(transport),
          cause: cause,
          duration: duration_ms,
          grace: grace_ms,
          budget: budget_ms,
          stderr: stderr_suffix(details),
          truncated: truncation_suffix(details),
          hint: hint_suffix(reason)
        })

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

  defp cause(:cleanup_deadline_expired, _details), do: {:ok, @deadline_message}

  defp cause(:transport_failed, %{finish_reason: finish_reason} = details)
       when finish_reason in @finish_reasons do
    suffix =
      case Map.get(details, :exit_status) do
        status when is_integer(status) ->
          DiagnosticPattern.render(@exit_template, %{status: status})

        _unknown ->
          ""
      end

    {:ok,
     DiagnosticPattern.render(@launcher_template, %{reason: Atom.to_string(finish_reason)}) <>
       suffix}
  end

  for {reason, phrase} <- @transport_phrases do
    defp cause(:transport_failed, %{finish_reason: unquote(reason)}),
      do: {:ok, @transport_prefix <> unquote(phrase)}
  end

  defp cause(_reason, _details), do: :error

  defp stderr_suffix(%{stderr: stderr}) when is_binary(stderr) and stderr != "" do
    stderr =
      stderr
      |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, " ")
      |> utf8_tail(1_024)

    if stderr == "", do: "", else: DiagnosticPattern.render(@stderr_template, %{stderr: stderr})
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

  defp truncation_suffix(%{stderr_truncated?: true}), do: @truncated_message
  defp truncation_suffix(_details), do: ""
  defp hint_suffix(:cleanup_deadline_expired), do: @hint_message
  defp hint_suffix(_reason), do: ""
end
