defmodule PtcRunner.Kernel.RuntimeLimitDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.LimitCatalog

  @subordinate_prefix "subordinate_evaluations limit "
  @subordinate_suffix " was exceeded; raise the manifest or host ceiling, or reduce total subordinate evaluations or agent turns"
  @subordinate_limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @subordinate_maximum_digits 10
  @subordinate_maximum_message_bytes byte_size(@subordinate_prefix) +
                                       @subordinate_maximum_digits +
                                       byte_size(@subordinate_suffix)

  @agent_prefix "agent turn limit "
  @agent_suffix " was exceeded; raise max_turns for this agent.core/run call, or reduce the work per turn"
  @agent_limit_pattern "(?:[1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])"
  @agent_maximum_digits 3
  @agent_maximum_message_bytes byte_size(@agent_prefix) + @agent_maximum_digits +
                                 byte_size(@agent_suffix)

  @transcript_prefix "transcript limit "
  @transcript_suffix " characters was exceeded; raise max_transcript_chars for this agent.core/run call, or reduce the work carried between turns"
  @transcript_limit_pattern "(?:[1-9][0-9]{0,5}|1000000)"
  @transcript_maximum_digits 7
  @transcript_maximum_message_bytes byte_size(@transcript_prefix) +
                                      @transcript_maximum_digits +
                                      byte_size(@transcript_suffix)

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
  @spec agent_turns_message(term()) :: {:ok, binary()} | :error
  def agent_turns_message(limit) when is_integer(limit) and limit in 1..128,
    do: {:ok, @agent_prefix <> Integer.to_string(limit) <> @agent_suffix}

  def agent_turns_message(_limit), do: :error

  @doc false
  @spec transcript_chars_message(term()) :: {:ok, binary()} | :error
  def transcript_chars_message(limit) when is_integer(limit) and limit in 1..1_000_000,
    do: {:ok, @transcript_prefix <> Integer.to_string(limit) <> @transcript_suffix}

  def transcript_chars_message(_limit), do: :error

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
      transcript_chars_message?(message) or timeout_message?(message)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec agent_turns_message?(term()) :: boolean()
  def agent_turns_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @agent_prefix,
      @agent_suffix,
      @agent_maximum_digits,
      &agent_turns_message/1
    )
  end

  def agent_turns_message?(_message), do: false

  @doc false
  @spec transcript_chars_message?(term()) :: boolean()
  def transcript_chars_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @transcript_prefix,
      @transcript_suffix,
      @transcript_maximum_digits,
      &transcript_chars_message/1
    )
  end

  def transcript_chars_message?(_message), do: false

  @doc false
  @spec run_duration_message?(term()) :: boolean()
  def run_duration_message?(message) when is_binary(message) do
    Enum.any?(@timeout_phases, fn phase ->
      valid_exact_message?(
        message,
        "run_duration_ms limit ",
        " ms was exceeded during #{phase}",
        @subordinate_maximum_digits,
        &live_timeout_message(:run_duration_ms, &1, phase)
      )
    end)
  end

  def run_duration_message?(_message), do: false

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
    message_schema(fallback, [
      subordinate_message_branch(),
      agent_message_branch(),
      transcript_message_branch()
      | timeout_message_branches()
    ])
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
  @spec agent_loop_message_schema(binary()) :: map()
  def agent_loop_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [agent_message_branch(), transcript_message_branch()])

  @doc false
  @spec run_duration_message_schema(binary()) :: map()
  def run_duration_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, run_duration_message_branches())

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

  defp agent_message_branch do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @agent_maximum_message_bytes,
      "pattern" =>
        "^agent turn limit #{@agent_limit_pattern} was exceeded; raise max_turns for this agent.core/run call, or reduce the work per turn$(?![\\s\\S])"
    }
  end

  defp transcript_message_branch do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @transcript_maximum_message_bytes,
      "pattern" =>
        "^transcript limit #{@transcript_limit_pattern} characters was exceeded; raise max_transcript_chars for this agent.core/run call, or reduce the work carried between turns$(?![\\s\\S])"
    }
  end

  defp run_duration_message_branches do
    for phase <- @timeout_phases do
      %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => @timeout_maximum_message_bytes,
        "pattern" =>
          "^run_duration_ms limit #{@timeout_value_pattern} ms was exceeded during #{phase}$(?![\\s\\S])"
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
