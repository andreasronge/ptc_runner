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
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    subordinate_evaluations_message?(message) or agent_turns_message?(message)
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
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    message_schema(fallback, [subordinate_message_branch(), agent_message_branch()])
  end

  @doc false
  @spec subordinate_evaluations_message_schema(binary()) :: map()
  def subordinate_evaluations_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [subordinate_message_branch()])

  @doc false
  @spec agent_turns_message_schema(binary()) :: map()
  def agent_turns_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [agent_message_branch()])

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
