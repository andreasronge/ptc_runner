defmodule PtcRunner.Kernel.LLMBudgetLedgerTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.TestSupport.LLMBudgetSupport

  @live_route %{
    route_key: "primary",
    max_calls: 16,
    source: "llm",
    output_tokens: 20,
    total_tokens: 40,
    cost_microusd: 200
  }
  @maximum_integer 9_007_199_254_740_991

  test "disabled ledgers are authoritative null projections" do
    {:ok, state} = RunState.start(Limits.defaults())

    assert RunState.usage(state).llm_budget == %{
             "total_tokens" => nil,
             "cost" => nil
           }
  end

  test "one admission reserves both ledgers and exact success refunds the difference" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100, llm_cost_microusd: 500)
    {:ok, state} = RunState.start(limits)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, @live_route)

    assert is_reference(reservation_id)

    assert RunState.usage(state).llm_budget == %{
             "total_tokens" => %{
               "state" => "available",
               "limit" => 100,
               "reserved" => 40,
               "charged" => 0,
               "remaining" => 60,
               "refused" => 0
             },
             "cost" => %{
               "state" => "available",
               "currency" => "USD",
               "limit_microusd" => 500,
               "reserved_microusd" => 200,
               "charged_microusd" => 0,
               "remaining_microusd" => 300,
               "refused" => 0
             }
           }

    provider = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)
    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    usage = %{
      "input" => 11,
      "output" => 7,
      "total_cost" => %{"currency" => "USD", "microunits" => 75}
    }

    assert {:ok, :settled} =
             RunState.finish_provider(state, reservation_id, {:adapter_success, {:valid, usage}})

    assert RunState.usage(state).llm_budget == LLMBudgetSupport.settled_projection()
  end

  test "dispatch gate opening is one-way, provider-bound, and required before full charge" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100)
    {:ok, state} = RunState.start(limits)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(
               state,
               :workflow,
               "llm-request",
               nil,
               Map.put(@live_route, :cost_microusd, nil)
             )

    provider = idle_provider()
    other = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)

    assert {:error, :provider_mismatch} =
             RunState.open_provider_gate(state, reservation_id, other, make_ref())

    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    assert {:error, :already_dispatched} =
             RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    assert {:ok, :settled} =
             RunState.finish_provider(
               state,
               reservation_id,
               {:adapter_error, :provider_error}
             )

    assert %{
             "state" => "incomplete",
             "reserved" => 0,
             "charged" => 40,
             "remaining" => 60
           } = RunState.usage(state).llm_budget["total_tokens"]

    assert {:error, :unknown_reservation} =
             RunState.finish_provider(
               state,
               reservation_id,
               {:adapter_success, {:valid, %{"input" => 1, "output" => 1}}}
             )
  end

  test "an unknown reservation cannot attach or dispatch a provider" do
    {:ok, state} = RunState.start(Limits.defaults())
    provider = idle_provider()

    assert {:error, :unknown_reservation} =
             RunState.attach_provider(state, make_ref(), provider)

    assert {:error, :unknown_reservation} =
             RunState.open_provider_gate(state, make_ref(), provider, make_ref())

    refute Process.alive?(provider)
    assert RunState.usage(state).capability_calls.workflow == %{}
  end

  test "an admitted call released before acknowledgement charges zero" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100)
    {:ok, state} = RunState.start(limits)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(
               state,
               :workflow,
               "llm-request",
               nil,
               Map.put(@live_route, :cost_microusd, nil)
             )

    assert {:ok, :settled} =
             RunState.finish_provider(state, reservation_id, {:adapter_error, :cancelled})

    assert %{
             "state" => "available",
             "reserved" => 0,
             "charged" => 0,
             "remaining" => 100
           } = RunState.usage(state).llm_budget["total_tokens"]
  end

  test "opening the provider gate is atomic with the dispatched transition" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100)
    {:ok, state} = RunState.start(limits)
    parent = self()
    gate = make_ref()

    provider =
      spawn(fn ->
        receive do
          ^gate ->
            send(parent, :provider_gate_opened)
            receive do: (:stop -> :ok)
        end
      end)

    provider_ref = Process.monitor(provider)

    caller =
      spawn(fn ->
        {:ok, reservation_id} =
          RunState.reserve_capability(
            state,
            :workflow,
            "llm-request",
            nil,
            Map.put(@live_route, :cost_microusd, nil)
          )

        :ok = RunState.attach_provider(state, reservation_id, provider)
        send(parent, {:gate_ready, self()})

        receive do
          :open_gate ->
            send(parent, :opening_gate)

            result =
              RunState.open_provider_gate(state, reservation_id, provider, gate)

            send(parent, {:gate_call_returned, result})
        end
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:gate_ready, ^caller}
    assert :ok = :sys.suspend(state.pid)

    try do
      send(caller, :open_gate)
      assert_receive :opening_gate

      assert_eventually(fn ->
        case Process.info(state.pid, :message_queue_len) do
          {:message_queue_len, count} -> count >= 1
          _missing -> false
        end
      end)

      assert true == :erlang.suspend_process(caller)
      assert :ok = :sys.resume(state.pid)

      assert_receive :provider_gate_opened
      refute_receive {:gate_call_returned, _result}

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
      assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}

      assert_eventually(fn ->
        RunState.usage(state).llm_budget["total_tokens"]["charged"] == 40
      end)
    after
      case Process.info(state.pid, :status) do
        {:status, :suspended} -> :sys.resume(state.pid)
        _running_or_stopped -> :ok
      end

      if Process.alive?(caller), do: Process.exit(caller, :kill)
      if Process.alive?(provider), do: Process.exit(provider, :kill)
    end
  end

  test "authenticated overruns charge actual with saturation and refuse in fixed order" do
    {:ok, limits} = Limits.new(llm_total_tokens: 50, llm_cost_microusd: 250)
    {:ok, state} = RunState.start(limits)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, @live_route)

    provider = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)
    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    usage = %{
      "input" => 30,
      "output" => 30,
      "total_cost" => %{"currency" => "USD", "microunits" => 300}
    }

    assert {:ok, {:overrun, [:total_tokens, :cost]}} =
             RunState.finish_provider(state, reservation_id, {:adapter_success, {:valid, usage}})

    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["state"] == "overrun"
    assert budget["total_tokens"]["charged"] == 60
    assert budget["total_tokens"]["remaining"] == 0
    assert budget["cost"]["state"] == "overrun"
    assert budget["cost"]["charged_microusd"] == 300
    assert budget["cost"]["remaining_microusd"] == 0

    assert {:error, :llm_total_tokens_limit,
            %{
              limit: :llm_total_tokens,
              limit_value: 50,
              requested: 40,
              remaining: 0
            }} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, @live_route)

    assert RunState.budget_refusal?(state, %{
             limit: :llm_total_tokens,
             limit_value: 50,
             requested: 40,
             remaining: 0
           })

    refused = RunState.usage(state).llm_budget
    assert refused["total_tokens"]["refused"] == 1
    assert refused["cost"]["refused"] == 0
  end

  test "an overrun cost ledger does not authenticate a zero reservation as a refused reservation" do
    {:ok, limits} = Limits.new(llm_cost_microusd: 250)
    {:ok, state} = RunState.start(limits)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, @live_route)

    provider = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)
    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    usage = %{
      "input" => 1,
      "output" => 1,
      "total_cost" => %{"currency" => "USD", "microunits" => 300}
    }

    assert {:ok, {:overrun, [:cost]}} =
             RunState.finish_provider(state, reservation_id, {:adapter_success, {:valid, usage}})

    zero_cost = Map.put(@live_route, :cost_microusd, 0)

    assert {:error, :llm_cost_limit,
            %{
              limit: :llm_cost_microusd,
              limit_value: 250,
              requested: 0,
              remaining: 0
            } = details} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, zero_cost)

    # A zero reservation against remaining 0 is overspend-lock, not a refused
    # reservation. The owner still authors the exact bound and does not
    # authenticate a diagnostic it cannot print.
    refute RunState.budget_refusal?(state, details)

    assert RuntimeLimitDiagnostic.budget_message(details.limit, details.limit_value, 0, 0) ==
             :error
  end

  test "an unrepresentable authenticated token total saturates and locks the ledger" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100)
    {:ok, state} = RunState.start(limits)
    route = Map.put(@live_route, :cost_microusd, nil)

    assert {:ok, reservation_id} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, route)

    provider = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)
    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    usage = %{"input" => @maximum_integer, "output" => 1}

    assert {:ok, {:overrun, [:total_tokens]}} =
             RunState.finish_provider(state, reservation_id, {:adapter_success, {:valid, usage}})

    assert %{
             "state" => "overrun",
             "reserved" => 0,
             "charged" => @maximum_integer,
             "remaining" => 0
           } = RunState.usage(state).llm_budget["total_tokens"]

    assert {:error, :llm_total_tokens_limit,
            %{
              limit: :llm_total_tokens,
              remaining: 0,
              requested: 40
            }} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
  end

  test "replay aliases never reserve or charge operational ledgers" do
    {:ok, limits} = Limits.new(llm_total_tokens: 50, llm_cost_microusd: 250)
    {:ok, state} = RunState.start(limits)

    replay_route = %{route_key: "fixture", max_calls: 16, source: "llm_replay"}

    assert {:ok, reservation_id} =
             RunState.reserve_capability(state, :workflow, "llm-request", nil, replay_route)

    provider = idle_provider()
    assert :ok = RunState.attach_provider(state, reservation_id, provider)
    assert :ok = RunState.open_provider_gate(state, reservation_id, provider, make_ref())

    usage = %{
      "input" => 50,
      "output" => 50,
      "total_cost" => %{"currency" => "USD", "microunits" => 250}
    }

    assert {:ok, :settled} =
             RunState.finish_provider(state, reservation_id, {:adapter_success, {:valid, usage}})

    assert RunState.usage(state).llm_budget["total_tokens"]["charged"] == 0
    assert RunState.usage(state).llm_budget["cost"]["charged_microusd"] == 0
  end

  test "terminal cleanup releases unacknowledged work and full-charges acknowledged work" do
    {:ok, limits} =
      Limits.new(
        llm_total_tokens: 100,
        workflow_capability_calls_per_name: 4,
        live_provider_tasks: 2
      )

    {:ok, state} = RunState.start(limits)
    parent = self()
    route = Map.put(@live_route, :cost_microusd, nil)

    first =
      spawn(fn ->
        {:ok, id} = RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
        provider = spawn(fn -> receive do: (:stop -> :ok) end)
        :ok = RunState.attach_provider(state, id, provider)
        :ok = RunState.open_provider_gate(state, id, provider, make_ref())
        send(parent, {:admitted, self(), id})
        receive do: (:done -> :ok)
      end)

    second =
      spawn(fn ->
        {:ok, id} = RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
        send(parent, {:admitted, self(), id})
        receive do: (:done -> :ok)
      end)

    assert_receive {:admitted, ^first, _first_id}
    assert_receive {:admitted, ^second, _second_id}
    assert :ok = RunState.close_and_drain(state)

    assert %{
             "state" => "incomplete",
             "reserved" => 0,
             "charged" => 40,
             "remaining" => 60
           } = RunState.usage(state).llm_budget["total_tokens"]

    send(first, :done)
    send(second, :done)
  end

  test "concurrent admissions cannot oversubscribe one ledger" do
    {:ok, limits} =
      Limits.new(
        llm_total_tokens: 60,
        workflow_capability_calls_per_name: 4,
        live_provider_tasks: 2
      )

    {:ok, state} = RunState.start(limits)
    parent = self()
    barrier = make_ref()
    route = Map.put(@live_route, :cost_microusd, nil)

    callers =
      for _index <- 1..2 do
        spawn(fn ->
          receive do
            ^barrier ->
              result = RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
              send(parent, {:admission, self(), result})

              receive do
                {:settle, reservation_id} ->
                  settled =
                    RunState.finish_provider(
                      state,
                      reservation_id,
                      {:adapter_error, :cancelled}
                    )

                  send(parent, {:settled, self(), settled})

                :done ->
                  :ok
              end
          end
        end)
      end

    Enum.each(callers, &send(&1, barrier))

    admissions =
      for _index <- 1..2 do
        assert_receive {:admission, caller, result}
        {caller, result}
      end

    assert 1 == Enum.count(admissions, fn {_caller, result} -> match?({:ok, _id}, result) end)

    assert 1 ==
             Enum.count(admissions, fn {_caller, result} ->
               match?(
                 {:error, :llm_total_tokens_limit,
                  %{
                    limit: :llm_total_tokens,
                    limit_value: 60,
                    requested: 40,
                    remaining: 20
                  }},
                 result
               )
             end)

    assert %{
             "reserved" => 40,
             "charged" => 0,
             "remaining" => 20,
             "refused" => 1
           } = RunState.usage(state).llm_budget["total_tokens"]

    [{admitted, {:ok, reservation_id}}] =
      Enum.filter(admissions, fn {_caller, result} -> match?({:ok, _id}, result) end)

    send(admitted, {:settle, reservation_id})
    assert_receive {:settled, ^admitted, {:ok, :settled}}

    Enum.each(callers -- [admitted], &send(&1, :done))
    assert RunState.usage(state).llm_budget["total_tokens"]["reserved"] == 0
  end

  defp idle_provider do
    provider = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(provider), do: send(provider, :stop) end)
    provider
  end
end
