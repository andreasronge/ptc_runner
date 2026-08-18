defmodule PtcRunner.Kernel.RuntimeLimitDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog

  @subordinate_prefix "subordinate_evaluations limit "
  @subordinate_suffix " was exceeded; raise the manifest or host ceiling, or reduce total subordinate evaluations or agent turns"
  @subordinate_limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @subordinate_maximum_digits 10
  @subordinate_maximum_message_bytes byte_size(@subordinate_prefix) +
                                       @subordinate_maximum_digits +
                                       byte_size(@subordinate_suffix)

  # A bounded agent loop can end four ways, and only two of them are answered by
  # buying more turns. Naming `max_turns` for a model that never emitted a
  # usable tool call sells the reader another round of the same failure, so each
  # reason states what stopped the loop and what to change. The remedy names the
  # configuration key rather than `agent.core/run`, because a manifest that
  # declares `agent.main/run` never mentions the inner entry.
  @agent_reasons [
    {:turn_limit_exceeded, "agent turn limit ",
     " was exceeded; raise max_turns in the agent configuration, or reduce the work per turn"},
    {:intermediate_result, "agent turn limit ",
     " was exceeded while the model was still working; raise max_turns in the agent configuration, or reduce the work per turn"},
    {:evaluation_error, "agent turn limit ",
     " was exceeded after the final program failed; raise max_turns in the agent configuration, or simplify the work per turn"},
    {:protocol_error, "the model produced no valid tool call in ",
     " turns; raising max_turns repeats it. Check that the model supports tool calling and that any configured max_tokens leaves room for a complete call"}
  ]
  @agent_reason_names [
    {"turn-limit-exceeded", :turn_limit_exceeded},
    {"intermediate-result", :intermediate_result},
    {"evaluation-error", :evaluation_error},
    {"protocol-error", :protocol_error}
  ]
  @agent_limit_pattern "(?:[1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])"
  @agent_maximum_digits 3

  @timeout_limits [:parallel_timeout_ms, :workflow_timeout_ms]
  @timeout_phases [:compilation, :execution]
  @timeout_value_pattern @subordinate_limit_pattern
  @timeout_maximum_message_bytes byte_size("workflow_timeout_ms limit ") +
                                   @subordinate_maximum_digits +
                                   byte_size(" ms was exceeded during compilation")

  @doc false
  @spec subordinate_evaluations_message(term()) :: {:ok, binary()} | :error
  def subordinate_evaluations_message(limit) do
    with {:ok, row} <- LimitCatalog.fetch(:subordinate_evaluations),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok, @subordinate_prefix <> Integer.to_string(limit) <> @subordinate_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec agent_turns_reasons() :: [atom()]
  def agent_turns_reasons,
    do: Enum.map(@agent_reasons, fn {reason, _prefix, _suffix} -> reason end)

  @doc false
  @spec agent_turns_reason?(term()) :: boolean()
  def agent_turns_reason?(reason), do: reason in agent_turns_reasons()

  @doc false
  @spec agent_turns_reason(term()) :: {:ok, atom()} | :error
  for {name, reason} <- @agent_reason_names do
    def agent_turns_reason(unquote(name)), do: {:ok, unquote(reason)}
  end

  def agent_turns_reason(_name), do: :error

  @doc false
  @spec agent_turns_message(term(), term()) :: {:ok, binary()} | :error
  for {reason, prefix, suffix} <- @agent_reasons do
    def agent_turns_message(limit, unquote(reason)) when is_integer(limit) and limit in 1..128,
      do: {:ok, unquote(prefix) <> Integer.to_string(limit) <> unquote(suffix)}
  end

  def agent_turns_message(_limit, _reason), do: :error

  @doc false
  @spec timeout_message(term(), term(), term()) :: {:ok, binary()} | :error
  def timeout_message(limit, limit_ms, phase)
      when limit in @timeout_limits and phase in @timeout_phases do
    build_timeout_message(limit, limit_ms, phase)
  end

  def timeout_message(_limit, _limit_ms, _phase), do: :error

  @doc false
  @spec live_timeout_message(term(), term(), term()) :: {:ok, binary()} | :error
  def live_timeout_message(limit, limit_ms, phase)
      when limit in [:run_duration_ms | @timeout_limits] and phase in @timeout_phases do
    build_timeout_message(limit, limit_ms, phase)
  end

  def live_timeout_message(_limit, _limit_ms, _phase), do: :error

  defp build_timeout_message(limit, limit_ms, phase) do
    with {:ok, row} <- LimitCatalog.fetch(limit),
         true <- LimitCatalog.valid_value?(row, limit_ms) do
      {:ok, "#{limit} limit #{limit_ms} ms was exceeded during #{phase}"}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    subordinate_evaluations_message?(message) or agent_turns_message?(message) or
      timeout_message?(message)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec agent_turns_message?(term()) :: boolean()
  def agent_turns_message?(message) when is_binary(message) do
    Enum.any?(@agent_reasons, fn {reason, prefix, suffix} ->
      valid_exact_message?(
        message,
        prefix,
        suffix,
        @agent_maximum_digits,
        &agent_turns_message(&1, reason)
      )
    end)
  end

  def agent_turns_message?(_message), do: false

  @doc false
  @spec subordinate_evaluations_message?(term()) :: boolean()
  def subordinate_evaluations_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @subordinate_prefix,
      @subordinate_suffix,
      @subordinate_maximum_digits,
      &subordinate_evaluations_message/1
    )
  end

  def subordinate_evaluations_message?(_message), do: false

  @doc false
  @spec timeout_message?(term()) :: boolean()
  def timeout_message?(message) when is_binary(message) do
    Enum.any?(@timeout_limits, fn limit ->
      Enum.any?(@timeout_phases, fn phase ->
        valid_exact_timeout_message?(message, limit, phase)
      end)
    end)
  end

  def timeout_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    message_schema(
      fallback,
      [subordinate_message_branch()] ++ agent_message_branches() ++ timeout_message_branches()
    )
  end

  @doc false
  @spec subordinate_evaluations_message_schema(binary()) :: map()
  def subordinate_evaluations_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [subordinate_message_branch()])

  @doc false
  @spec runtime_message_schema(binary()) :: map()
  def runtime_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [subordinate_message_branch() | timeout_message_branches()])

  @doc false
  @spec agent_turns_message_schema(binary()) :: map()
  def agent_turns_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, agent_message_branches())

  defp message_schema(fallback, branches) do
    %{
      "oneOf" => [%{"const" => fallback} | branches]
    }
  end

  defp subordinate_message_branch do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @subordinate_maximum_message_bytes,
      "pattern" =>
        "^subordinate_evaluations limit #{@subordinate_limit_pattern} was exceeded; raise the manifest or host ceiling, or reduce total subordinate evaluations or agent turns$(?![\\s\\S])"
    }
  end

  defp agent_message_branches do
    for {_reason, prefix, suffix} <- @agent_reasons do
      %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => byte_size(prefix) + @agent_maximum_digits + byte_size(suffix),
        "pattern" =>
          DiagnosticPattern.exact(
            DiagnosticPattern.escape(prefix) <>
              @agent_limit_pattern <> DiagnosticPattern.escape(suffix)
          )
      }
    end
  end

  defp timeout_message_branches do
    for limit <- @timeout_limits,
        phase <- @timeout_phases do
      %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => @timeout_maximum_message_bytes,
        "pattern" =>
          "^#{limit} limit #{@timeout_value_pattern} ms was exceeded during #{phase}$(?![\\s\\S])"
      }
    end
  end

  defp valid_exact_timeout_message?(message, limit, phase) do
    prefix = "#{limit} limit "
    suffix = " ms was exceeded during #{phase}"

    valid_exact_message?(
      message,
      prefix,
      suffix,
      @subordinate_maximum_digits,
      &timeout_message(limit, &1, phase)
    )
  end

  defp valid_exact_message?(message, prefix, suffix, maximum_digits, builder) do
    with true <- String.starts_with?(message, prefix),
         true <- String.ends_with?(message, suffix),
         digits_bytes <- byte_size(message) - byte_size(prefix) - byte_size(suffix),
         true <- digits_bytes in 1..maximum_digits,
         digits <- binary_part(message, byte_size(prefix), digits_bytes),
         {limit, ""} <- Integer.parse(digits),
         true <- Integer.to_string(limit) == digits,
         {:ok, expected} <- builder.(limit) do
      message == expected
    else
      _invalid -> false
    end
  end
end
