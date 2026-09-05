defmodule PtcRunner.Kernel.TerminalUsage do
  @moduledoc false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp.RetainedSize

  # Both counters saturate at the same 32-bit width the trace projection
  # admits. Neither can reach a bignum inside `run_duration_ms`, so this is a
  # retained-size upper bound as well as a value bound.
  @maximum_counter 4_294_967_295
  @maximum_llm_amount 9_007_199_254_740_991

  @doc """
  Builds the largest `run-stopped` usage projection one configuration can emit.

  It must carry every key `RunState.usage/1` produces, plus the `errors` count a
  REPL session adds on close; a key omitted here is a payload the sink admits at
  build time and cannot record at finalization.

  The shape has a fixed part every run carries and an application-scaled part
  keyed by declared capability and mission names. `RunConfig` measures the real
  inventory; the catalog floor measures the same shape with an empty inventory,
  so the two can never disagree about what a terminal payload must hold.
  """
  @spec maximum(map(), map(), [binary()], Limits.t()) :: map()
  def maximum(workflow_capabilities, mission_capabilities, mission_names, %Limits{} = limits)
      when is_map(workflow_capabilities) and is_map(mission_capabilities) and
             is_list(mission_names) do
    %{
      closed?: true,
      remaining_ms: limits.run_duration_ms,
      capability_calls: %{
        workflow:
          maximum_call_map(
            workflow_capabilities,
            limits.workflow_capability_calls,
            limits.workflow_capability_calls_per_name
          ),
        mission:
          maximum_call_map(
            mission_capabilities,
            limits.mission_capability_calls,
            limits.mission_capability_calls_per_name
          )
      },
      subordinate_evaluations: limits.subordinate_evaluations,
      evaluations_by_mission: Map.new(mission_names, &{&1, limits.subordinate_evaluations}),
      subordinate_source_checks: limits.subordinate_source_checks,
      protocol_errors: limits.protocol_errors + 1,
      agent_protocol_errors: @maximum_counter,
      evaluation_memory_bytes: limits.evaluation_memory_bytes,
      evaluation_history_bytes: limits.evaluation_history_bytes,
      evaluation_continuation_bytes:
        limits.evaluation_memory_bytes + limits.evaluation_history_bytes,
      evaluation_busy?: true,
      evaluation_missions: Enum.sort(mission_names),
      errors: @maximum_counter,
      capability_refusals: maximum_capability_refusals(),
      capability_denials: maximum_capability_denials(),
      llm_budget: maximum_llm_budget(limits),
      llm_spend: maximum_llm_spend()
    }
  end

  # `available` is the widest of the four spend states: the other three drop
  # `input`/`output`, and only this one carries the nested cost object.
  defp maximum_llm_spend do
    %{
      "state" => "available",
      "input" => LLMUsage.maximum_integer(),
      "output" => LLMUsage.maximum_integer(),
      "total_cost" => %{
        "currency" => "USD",
        "microunits" => LLMUsage.maximum_integer()
      }
    }
  end

  defp maximum_llm_budget(limits) do
    %{
      "total_tokens" =>
        if(is_nil(limits.llm_total_tokens),
          do: nil,
          else: %{
            "state" => "incomplete",
            "limit" => limits.llm_total_tokens,
            "reserved" => 0,
            "charged" => @maximum_llm_amount,
            "remaining" => 0,
            "refused" => @maximum_llm_amount
          }
        ),
      "cost" =>
        if(is_nil(limits.llm_cost_microusd),
          do: nil,
          else: %{
            "state" => "incomplete",
            "currency" => "USD",
            "limit_microusd" => limits.llm_cost_microusd,
            "reserved_microusd" => 0,
            "charged_microusd" => @maximum_llm_amount,
            "remaining_microusd" => 0,
            "refused" => @maximum_llm_amount
          }
        )
    }
  end

  # Closed class keys cannot be grown from caller input, but a trusted resolver
  # may still mint unrecognized atoms. Distinct keys are capped at the same
  # limit RunState enforces, plus `$overflow`, and reserved at fingerprint
  # length so a named class cannot enlarge run-stopped past event_payload_bytes.
  defp maximum_capability_refusals do
    fingerprint = "sha256:" <> String.duplicate("f", 64)
    count = 4_294_967_295
    limit = SafeMetadata.capability_refusal_map_limit()

    1..limit
    |> Map.new(fn index ->
      {"workflow/#{fingerprint}/#{fingerprint}-#{index}", count}
    end)
    |> Map.put("$overflow", count)
  end

  # Denial classes are runtime-owned atoms rather than resolver output, but
  # they are reserved at the widest key the schema admits for the same reason:
  # a class named later must not enlarge run-stopped past event_payload_bytes.
  defp maximum_capability_denials do
    count = @maximum_counter
    limit = SafeMetadata.capability_denial_map_limit()

    1..limit
    |> Map.new(fn index ->
      {String.duplicate("d", 63) <> Integer.to_string(index), count}
    end)
    |> Map.put("$overflow", count)
  end

  defp maximum_call_map(capabilities, total_limit, per_name_limit) do
    maximum_count = min(total_limit, per_name_limit)

    capabilities
    |> Map.keys()
    |> Enum.sort_by(&{-retained_name_bytes(&1), &1})
    |> Enum.take(total_limit)
    |> Map.new(&{&1, maximum_count})
  end

  defp retained_name_bytes(name) do
    case RetainedSize.bytes(name) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> 9_223_372_036_854_775_807
    end
  end
end
