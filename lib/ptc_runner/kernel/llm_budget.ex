defmodule PtcRunner.Kernel.LLMBudget do
  @moduledoc false

  alias PtcRunner.Kernel.Limits

  @maximum_integer 9_007_199_254_740_991
  @states ~w(available incomplete overrun)

  @spec validate_projection(term()) :: {:ok, map()} | {:error, :invalid_llm_budget}
  def validate_projection(projection), do: validate_projection(projection, :runtime)

  @spec validate_terminal_projection(term()) :: {:ok, map()} | {:error, :invalid_llm_budget}
  def validate_terminal_projection(projection), do: validate_projection(projection, :terminal)

  @doc false
  @spec initial_terminal_projection(Limits.t()) :: map()
  def initial_terminal_projection(%Limits{} = limits) do
    %{
      "total_tokens" => initial_ledger(limits.llm_total_tokens, :total_tokens),
      "cost" => initial_ledger(limits.llm_cost_microusd, :cost)
    }
  end

  @doc false
  @spec unavailable_terminal_projection(Limits.t()) :: map()
  def unavailable_terminal_projection(%Limits{} = limits) do
    %{
      "total_tokens" => unavailable_ledger(limits.llm_total_tokens, :total_tokens),
      "cost" => unavailable_ledger(limits.llm_cost_microusd, :cost)
    }
  end

  defp validate_projection(
         %{"total_tokens" => total_tokens, "cost" => cost} = projection,
         phase
       )
       when map_size(projection) == 2 do
    with :ok <- validate_total_tokens(total_tokens, phase),
         :ok <- validate_cost(cost, phase) do
      {:ok, projection}
    else
      _invalid -> {:error, :invalid_llm_budget}
    end
  end

  defp validate_projection(_projection, _phase), do: {:error, :invalid_llm_budget}

  defp validate_total_tokens(nil, _phase), do: :ok

  defp validate_total_tokens(
         %{
           "state" => state,
           "limit" => limit,
           "reserved" => reserved,
           "charged" => charged,
           "remaining" => remaining,
           "refused" => refused
         } = ledger,
         phase
       )
       when map_size(ledger) == 6 do
    validate_ledger(state, limit, reserved, charged, remaining, refused, phase)
  end

  defp validate_total_tokens(_ledger, _phase), do: :error

  defp validate_cost(nil, _phase), do: :ok

  defp validate_cost(
         %{
           "state" => state,
           "currency" => "USD",
           "limit_microusd" => limit,
           "reserved_microusd" => reserved,
           "charged_microusd" => charged,
           "remaining_microusd" => remaining,
           "refused" => refused
         } = ledger,
         phase
       )
       when map_size(ledger) == 7 do
    validate_ledger(state, limit, reserved, charged, remaining, refused, phase)
  end

  defp validate_cost(_ledger, _phase), do: :error

  defp validate_ledger(state, limit, reserved, charged, remaining, refused, phase) do
    cond do
      state not in @states ->
        :error

      not positive_bounded?(limit) ->
        :error

      not Enum.all?([reserved, charged, remaining, refused], &nonnegative_bounded?/1) ->
        :error

      reserved > limit ->
        :error

      phase == :terminal and reserved != 0 ->
        :error

      state != "overrun" and charged > limit ->
        :error

      remaining != expected_remaining(state, limit, charged, reserved) ->
        :error

      true ->
        :ok
    end
  end

  defp expected_remaining("overrun", _limit, _charged, _reserved), do: 0

  defp expected_remaining(_state, limit, charged, reserved),
    do: max(limit - charged - reserved, 0)

  defp positive_bounded?(value),
    do: is_integer(value) and value >= 1 and value <= @maximum_integer

  defp nonnegative_bounded?(value),
    do: is_integer(value) and value >= 0 and value <= @maximum_integer

  defp unavailable_ledger(nil, _kind), do: nil

  defp unavailable_ledger(limit, :total_tokens) do
    %{
      "state" => "incomplete",
      "limit" => limit,
      "reserved" => 0,
      "charged" => limit,
      "remaining" => 0,
      "refused" => 0
    }
  end

  defp unavailable_ledger(limit, :cost) do
    %{
      "state" => "incomplete",
      "currency" => "USD",
      "limit_microusd" => limit,
      "reserved_microusd" => 0,
      "charged_microusd" => limit,
      "remaining_microusd" => 0,
      "refused" => 0
    }
  end

  defp initial_ledger(nil, _kind), do: nil

  defp initial_ledger(limit, :total_tokens) do
    %{
      "state" => "available",
      "limit" => limit,
      "reserved" => 0,
      "charged" => 0,
      "remaining" => limit,
      "refused" => 0
    }
  end

  defp initial_ledger(limit, :cost) do
    %{
      "state" => "available",
      "currency" => "USD",
      "limit_microusd" => limit,
      "reserved_microusd" => 0,
      "charged_microusd" => 0,
      "remaining_microusd" => limit,
      "refused" => 0
    }
  end
end
