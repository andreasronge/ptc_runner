defmodule PtcRunner.Kernel.RunState.LlmBudget do
  @moduledoc "Internal pure LLM ledger reservation, settlement and projection transitions."

  alias PtcRunner.Kernel.LLMUsage
  @budget_limits [:llm_total_tokens, :llm_cost_microusd]
  @maximum_integer 9_007_199_254_740_991

  def llm_output_exceeded?(_state, %{source: "llm", output_tokens: output_tokens})
      when not is_integer(output_tokens),
      do: true

  def llm_output_exceeded?(state, %{source: "llm", output_tokens: output_tokens}),
    do: output_tokens <= 0 or output_tokens > state.limits.llm_request_output_tokens

  def llm_output_exceeded?(_state, _route), do: false

  def llm_ledger_unavailable?(state, route, key) do
    case {Map.fetch!(state.llm_budget, key), llm_bound(route, key)} do
      {nil, _bound} -> false
      {%{state: :overrun}, _bound} -> true
      {_ledger, nil} -> live_llm_route?(route)
      {ledger, bound} -> bound > ledger_remaining(ledger)
    end
  end

  defp llm_bound(%{source: source, total_tokens: bound}, :total_tokens)
       when source in ["llm", "decision", "decision_replay"] and is_integer(bound) and
              bound in 0..@maximum_integer,
       do: bound

  defp llm_bound(%{source: source, cost_microusd: bound}, :cost)
       when source in ["llm", "decision", "decision_replay"] and is_integer(bound) and
              bound in 0..@maximum_integer,
       do: bound

  defp llm_bound(_route, _key), do: nil

  defp live_llm_route?(%{source: source}) when source in ["llm", "decision", "decision_replay"],
    do: true

  defp live_llm_route?(_route), do: false

  def llm_reservation(state, route) do
    if live_llm_route?(route) do
      %{
        total_tokens: enabled_bound(state.llm_budget.total_tokens, route, :total_tokens),
        cost: enabled_bound(state.llm_budget.cost, route, :cost)
      }
    end
  end

  defp enabled_bound(nil, _route, _key), do: nil
  defp enabled_bound(_ledger, route, key), do: llm_bound(route, key)

  def reserve_llm_ledgers(state, nil), do: state

  def reserve_llm_ledgers(state, reservation) do
    llm_budget =
      Enum.reduce([:total_tokens, :cost], state.llm_budget, fn key, budget ->
        case {Map.fetch!(budget, key), Map.fetch!(reservation, key)} do
          {nil, _amount} -> budget
          {_ledger, nil} -> budget
          {ledger, amount} -> Map.put(budget, key, %{ledger | reserved: ledger.reserved + amount})
        end
      end)

    %{state | llm_budget: llm_budget}
  end

  defp refuse_ledger(state, key) do
    update_in(state.llm_budget[key], fn
      nil -> nil
      ledger -> %{ledger | refused: min(ledger.refused + 1, @maximum_integer)}
    end)
  end

  def refuse_budget(state, route, key) do
    ledger = Map.fetch!(state.llm_budget, key)
    remaining = ledger_remaining(ledger)
    limit = budget_limit_field(key)
    requested = llm_bound(route, key)

    details =
      %{limit: limit, limit_value: ledger.limit, remaining: remaining}
      |> maybe_put_requested(requested)

    state =
      state
      |> refuse_ledger(key)
      |> record_budget_refusal(details)

    {details, state}
  end

  defp budget_limit_field(:total_tokens), do: :llm_total_tokens
  defp budget_limit_field(:cost), do: :llm_cost_microusd

  defp maybe_put_requested(details, requested) when is_integer(requested) and requested >= 0,
    do: Map.put(details, :requested, requested)

  defp maybe_put_requested(details, _requested), do: details

  defp ledger_remaining(%{state: :overrun}), do: 0

  defp ledger_remaining(ledger),
    do: max(ledger.limit - ledger.charged - ledger.reserved, 0)

  defp record_budget_refusal(
         state,
         %{limit: limit, limit_value: limit_value, requested: requested, remaining: remaining}
       )
       when limit in @budget_limits and is_integer(limit_value) and limit_value > 0 and
              is_integer(requested) and requested > remaining and is_integer(remaining) and
              remaining >= 0 and remaining <= limit_value do
    %{
      state
      | budget_refusals:
          MapSet.put(state.budget_refusals, {limit, limit_value, requested, remaining})
    }
  end

  defp record_budget_refusal(state, _details), do: state

  def settle_llm_budget(budget, %{llm: nil}, _evidence), do: {budget, []}

  def settle_llm_budget(budget, %{dispatched?: false, llm: reservation}, _evidence) do
    {release_llm_reservations(budget, reservation), []}
  end

  def settle_llm_budget(budget, %{dispatched?: true, llm: reservation}, :cleanup) do
    {full_charge_llm_reservations(budget, reservation), []}
  end

  def settle_llm_budget(
        budget,
        %{dispatched?: true, llm: reservation},
        {:adapter_error, :not_dispatched}
      ) do
    {release_llm_reservations(budget, reservation), []}
  end

  def settle_llm_budget(
        budget,
        %{dispatched?: true, llm: reservation},
        {:adapter_error, _reason}
      ) do
    {full_charge_llm_reservations(budget, reservation), []}
  end

  def settle_llm_budget(
        budget,
        %{dispatched?: true, llm: reservation},
        {:adapter_success, usage_evidence}
      ) do
    actuals = settlement_actuals(usage_evidence)

    Enum.reduce([:total_tokens, :cost], {budget, []}, fn key, {ledgers, overruns} ->
      case Map.fetch!(reservation, key) do
        nil ->
          {ledgers, overruns}

        reserved ->
          {ledger, overrun?} =
            settle_ledger(Map.fetch!(ledgers, key), reserved, Map.get(actuals, key))

          overruns = if overrun?, do: overruns ++ [key], else: overruns
          {Map.put(ledgers, key, ledger), overruns}
      end
    end)
  end

  defp settlement_actuals({:valid, usage}) do
    case canonical_usage(usage) do
      {:ok, canonical} ->
        %{
          total_tokens: actual_total_tokens(canonical),
          cost: actual_cost(canonical)
        }

      :error ->
        %{}
    end
  end

  defp settlement_actuals(_missing_or_invalid), do: %{}

  defp actual_total_tokens(%{"input" => input, "output" => output})
       when is_integer(input) and is_integer(output) do
    if input <= @maximum_integer - output, do: input + output, else: :overflow
  end

  defp actual_total_tokens(_usage), do: nil

  defp actual_cost(%{
         "total_cost" => %{"currency" => "USD", "microunits" => microunits}
       }),
       do: microunits

  defp actual_cost(_usage), do: nil

  defp canonical_usage(usage) when is_map(usage) and not is_struct(usage) do
    case LLMUsage.normalize(usage) do
      {:ok, canonical} -> if canonical == usage, do: {:ok, canonical}, else: :error
      {:error, :invalid_llm_usage} -> :error
    end
  end

  defp canonical_usage(_usage), do: :error

  defp settle_ledger(ledger, reserved, nil) do
    ledger = release_from_ledger(ledger, reserved)

    {%{
       ledger
       | charged: bounded_add(ledger.charged, reserved),
         state: if(ledger.state == :overrun, do: :overrun, else: :incomplete)
     }, false}
  end

  defp settle_ledger(ledger, reserved, :overflow) do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: @maximum_integer, state: :overrun}, true}
  end

  defp settle_ledger(ledger, reserved, actual) when is_integer(actual) and actual <= reserved do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: bounded_add(ledger.charged, actual)}, false}
  end

  defp settle_ledger(ledger, reserved, actual) when is_integer(actual) do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: bounded_add(ledger.charged, actual), state: :overrun}, true}
  end

  defp release_llm_reservations(budget, reservation) do
    Enum.reduce([:total_tokens, :cost], budget, fn key, ledgers ->
      case {Map.fetch!(ledgers, key), Map.fetch!(reservation, key)} do
        {nil, _amount} -> ledgers
        {_ledger, nil} -> ledgers
        {ledger, amount} -> Map.put(ledgers, key, release_from_ledger(ledger, amount))
      end
    end)
  end

  defp full_charge_llm_reservations(budget, reservation) do
    Enum.reduce([:total_tokens, :cost], budget, fn key, ledgers ->
      case {Map.fetch!(ledgers, key), Map.fetch!(reservation, key)} do
        {nil, _amount} ->
          ledgers

        {_ledger, nil} ->
          ledgers

        {ledger, amount} ->
          ledger = release_from_ledger(ledger, amount)

          Map.put(ledgers, key, %{
            ledger
            | charged: bounded_add(ledger.charged, amount),
              state: if(ledger.state == :overrun, do: :overrun, else: :incomplete)
          })
      end
    end)
  end

  defp release_from_ledger(ledger, amount),
    do: %{ledger | reserved: max(ledger.reserved - amount, 0)}

  defp bounded_add(left, right), do: min(left + right, @maximum_integer)

  def new_ledger(nil), do: nil

  def new_ledger(limit) when is_integer(limit) and limit in 1..@maximum_integer do
    %{limit: limit, reserved: 0, charged: 0, refused: 0, state: :available}
  end

  def llm_budget_projection(budget) do
    %{
      "total_tokens" => total_tokens_projection(budget.total_tokens),
      "cost" => cost_projection(budget.cost)
    }
  end

  defp total_tokens_projection(nil), do: nil

  defp total_tokens_projection(ledger) do
    %{
      "state" => Atom.to_string(ledger.state),
      "limit" => ledger.limit,
      "reserved" => ledger.reserved,
      "charged" => ledger.charged,
      "remaining" => ledger_remaining(ledger),
      "refused" => ledger.refused
    }
  end

  defp cost_projection(nil), do: nil

  defp cost_projection(ledger) do
    %{
      "state" => Atom.to_string(ledger.state),
      "currency" => "USD",
      "limit_microusd" => ledger.limit,
      "reserved_microusd" => ledger.reserved,
      "charged_microusd" => ledger.charged,
      "remaining_microusd" => ledger_remaining(ledger),
      "refused" => ledger.refused
    }
  end
end
