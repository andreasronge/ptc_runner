defmodule PtcGateway.EventRecord do
  @moduledoc false

  def valid?(%{kind: :startup_stage, stage: stage, outcome: outcome} = record),
    do:
      keys?(record, [:kind, :stage, :outcome]) and
        stage in [:artifact_root, :templates, :audit, :run_admission, :warm_providers, :listener] and
        outcome in [:started, :ready]

  def valid?(%{kind: :startup_failed, code: code, reason_class: reason} = record),
    do:
      keys?(record, [:kind, :code, :reason_class]) and
        code in PtcGateway.StartupError.codes() and
        PtcGateway.StartupError.reason_class(reason) == reason

  def valid?(%{kind: :readiness, transition: transition, cause: cause} = record),
    do:
      keys?(record, [:kind, :transition, :tool, :provider, :cause]) and names?(record) and
        transition in [:ready, :not_ready] and
        cause in [:startup, :provider_runtime_lost, :provider_cleanup_failed]

  def valid?(%{kind: :transport, fault: fault, exit_status: status} = record),
    do:
      keys?(record, [:kind, :tool, :provider, :fault, :exit_status]) and names?(record) and
        fault in [
          :close,
          :server_exit,
          :owner_eof,
          :launcher_signal,
          :protocol_error,
          :close_timeout,
          :killed,
          :normal,
          :shutdown,
          :transport_error
        ] and
        (is_nil(status) or is_integer(status))

  def valid?(%{kind: kind, count: count, interval_ms: 1000} = record)
      when kind in [:busy, :detached, :settlement_timeout, :dropped_events],
      do:
        keys?(record, [:kind, :tool, :provider, :count, :interval_ms]) and names?(record) and
          is_integer(count) and count > 0

  def valid?(%{kind: :stderr_tail, text: text, truncated: truncated} = record),
    do:
      keys?(record, [:kind, :tool, :provider, :text, :truncated]) and names?(record) and
        is_binary(text) and String.valid?(text) and is_boolean(truncated)

  def valid?(_), do: false

  defp keys?(record, keys), do: Enum.sort(Map.keys(record)) == Enum.sort(keys)
  defp names?(record), do: name?(record.tool) and name?(record.provider)
  defp name?(nil), do: true

  defp name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,128}\z/, name)

  defp name?(_), do: false
end
