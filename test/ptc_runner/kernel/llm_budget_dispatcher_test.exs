defmodule PtcRunner.Kernel.LLMBudgetDispatcherTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.LLMBudgetSupport
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  @tariff %{currency: "USD", id: "fixture-v1"}
  @arguments %{"messages" => []}

  test "attests before admission and settles exact authenticated usage" do
    parent = self()

    router =
      router(
        fn _request, tariff ->
          send(parent, {:attested, tariff})

          {:ok,
           %{
             total_tokens: 40,
             cost: %{currency: "USD", microunits: 200, tariff_id: tariff.id}
           }}
        end,
        fn _request ->
          send(parent, :provider_called)

          {:ok,
           %{
             content: "answer",
             tokens: %{
               input: 11,
               output: 7,
               total_cost: %{currency: "USD", microunits: 75}
             }
           }}
        end
      )

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    assert %{status: :ok} = dispatch(state, environment)
    assert_receive {:attested, @tariff}
    assert_receive :provider_called

    assert RunState.usage(state).llm_budget == LLMBudgetSupport.settled_projection()
  end

  test "failed attestation is pre-dispatch and leaves both ledgers unchanged" do
    parent = self()

    router =
      router(
        fn _request, _tariff -> raise "attestation failed" end,
        fn _request ->
          send(parent, :provider_called)
          {:ok, %{content: "unreachable", tokens: %{input: 1, output: 1}}}
        end
      )

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :reservation_attestation_unavailable,
             retryable?: false
           } = dispatch(state, environment)

    refute_receive :provider_called

    assert %{
             "total_tokens" => %{"reserved" => 0, "charged" => 0, "refused" => 0},
             "cost" => %{
               "reserved_microusd" => 0,
               "charged_microusd" => 0,
               "refused" => 0
             }
           } = RunState.usage(state).llm_budget
  end

  test "token attestations below the authorized output ceiling are pre-dispatch failures" do
    parent = self()

    for total_tokens <- [0, 19] do
      router =
        router(
          fn _request, tariff ->
            {:ok,
             %{
               total_tokens: total_tokens,
               cost: %{currency: "USD", microunits: 100, tariff_id: tariff.id}
             }}
          end,
          fn _request ->
            send(parent, {:provider_called, total_tokens})
            {:ok, %{content: "unreachable", tokens: %{input: 1, output: 1}}}
          end
        )

      {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

      assert %{
               status: :error,
               kind: :capability_unavailable,
               reason: :reservation_attestation_unavailable,
               retryable?: false
             } = dispatch(state, environment)

      refute_receive {:provider_called, ^total_tokens}
      assert RunState.usage(state).llm_budget["total_tokens"]["charged"] == 0
    end
  end

  test "aggregate refusal prevents provider dispatch and preserves precedence" do
    parent = self()

    router =
      router(
        fn _request, tariff ->
          {:ok,
           %{
             total_tokens: 40,
             cost: %{currency: "USD", microunits: 200, tariff_id: tariff.id}
           }}
        end,
        fn _request ->
          send(parent, :provider_called)
          {:ok, %{content: "unreachable", tokens: %{input: 1, output: 1}}}
        end
      )

    {state, environment} = runtime(router, llm_total_tokens: 30, llm_cost_microusd: 100)

    assert %{
             status: :error,
             kind: :limit_exceeded,
             reason: :llm_total_tokens,
             details: %{
               limit: :llm_total_tokens,
               limit_value: 30,
               requested: 40,
               remaining: 30
             }
           } = dispatch(state, environment)

    refute_receive :provider_called
    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["refused"] == 1
    assert budget["cost"]["refused"] == 0

    assert RunState.budget_refusal?(state, %{
             limit: :llm_total_tokens,
             limit_value: 30,
             requested: 40,
             remaining: 30
           })
  end

  test "a cost reservation that does not fit is refused with owner-authored details" do
    parent = self()

    router =
      router(
        fn _request, tariff ->
          {:ok,
           %{
             total_tokens: 40,
             cost: %{currency: "USD", microunits: 2419, tariff_id: tariff.id}
           }}
        end,
        fn _request ->
          send(parent, :provider_called)
          {:ok, %{content: "unreachable", tokens: %{input: 1, output: 1}}}
        end
      )

    {state, environment} = runtime(router, llm_cost_microusd: 2400)

    assert %{
             status: :error,
             kind: :limit_exceeded,
             reason: :llm_cost_microusd,
             details: %{
               limit: :llm_cost_microusd,
               limit_value: 2400,
               requested: 2419,
               remaining: 2400
             }
           } = dispatch(state, environment)

    refute_receive :provider_called
    assert RunState.usage(state).llm_budget["cost"]["refused"] == 1

    assert RunState.budget_refusal?(state, %{
             limit: :llm_cost_microusd,
             limit_value: 2400,
             requested: 2419,
             remaining: 2400
           })

    refute RunState.budget_refusal?(state, %{
             limit: :llm_cost_microusd,
             limit_value: 2400,
             requested: 2419,
             remaining: 0
           })
  end

  test "provider failure after acknowledgement full-charges the reservation" do
    router =
      router(
        &bound/2,
        fn _request ->
          {:error, ProviderError.new(:unavailable, "fixture unavailable", retryable?: true)}
        end
      )

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    assert %{status: :error, kind: :provider_error, reason: :unavailable} =
             dispatch(state, environment)

    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["state"] == "incomplete"
    assert budget["total_tokens"]["charged"] == 40
    assert budget["cost"]["state"] == "incomplete"
    assert budget["cost"]["charged_microusd"] == 200
  end

  test "authenticated usage above the bound charges actual and fails closed" do
    router = overrun_router()

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :reservation_bound_exceeded,
             retryable?: false
           } = dispatch(state, environment)

    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["state"] == "overrun"
    assert budget["total_tokens"]["charged"] == 60
    assert budget["total_tokens"]["remaining"] == 0
    assert budget["cost"]["state"] == "overrun"
    assert budget["cost"]["charged_microusd"] == 300
    assert budget["cost"]["remaining_microusd"] == 0
  end

  test "inspection captures the fail-closed envelope after an authenticated overrun" do
    router = overrun_router()

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    {:ok, inspection} =
      StreamingInspection.start(run_id: "llm-budget-overrun", trace_id: "trace-overrun")

    assert result =
             %{
               status: :error,
               kind: :provider_error,
               reason: :reservation_bound_exceeded,
               retryable?: false,
               model: "primary"
             } = dispatch(state, environment, inspection)

    assert {:ok, records} = StreamingInspection.records(inspection)
    assert output = Enum.find(records, &(&1["record_type"] == "capability-output"))

    assert output["payload"]["result"] == %{
             "status" => "error",
             "kind" => "provider_error",
             "reason" => "reservation_bound_exceeded",
             "retryable?" => false,
             "model" => result.model
           }
  end

  test "inspection failure remains terminal when settlement also detects an overrun" do
    router = overrun_router()

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)

    {:ok, inspection} =
      StreamingInspection.start(
        run_id: "llm-budget-inspection-failure",
        trace_id: "trace-inspection-failure",
        max_records: 1
      )

    assert %{
             status: :error,
             kind: :inspection_sink_error,
             reason: :inspection_sink_error,
             retryable?: false
           } = dispatch(state, environment, inspection)

    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["state"] == "overrun"
    assert budget["cost"]["state"] == "overrun"
  end

  test "replay routes bypass attestation and operational ledgers" do
    parent = self()

    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          send(parent, :replay_called)
          {:ok, %{content: "fixture", tokens: %{input: 50, output: 50, total_cost: 1}}}
        end
      )

    {:ok, router} =
      LLMRouter.new([
        %{
          alias: "fixture",
          source: "llm_replay",
          installation_revision: "fixture-v1",
          default?: true,
          capability: capability,
          max_calls: nil
        }
      ])

    {state, environment} = runtime(router, llm_total_tokens: 100, llm_cost_microusd: 500)
    assert %{status: :ok} = dispatch(state, environment)
    assert_receive :replay_called

    budget = RunState.usage(state).llm_budget
    assert budget["total_tokens"]["charged"] == 0
    assert budget["cost"]["charged_microusd"] == 0
  end

  test "a direct live LLM capability carries reservation authority into dispatch" do
    parent = self()

    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          send(parent, :direct_provider_called)
          {:ok, %{content: "answer", tokens: %{input: 11, output: 7}}}
        end,
        usage_guarantees: %{tokens: true, cost_currency: nil},
        llm_reservation: %{
          source: "llm",
          output_tokens: 20,
          tariff: nil,
          bound: fn _request, nil ->
            send(parent, :direct_attested)
            {:ok, %{total_tokens: 40, cost: nil}}
          end
        }
      )

    {state, environment} = runtime(capability, llm_total_tokens: 100)

    assert %{status: :ok} = dispatch(state, environment)
    assert_receive :direct_attested
    assert_receive :direct_provider_called

    assert %{
             "state" => "available",
             "reserved" => 0,
             "charged" => 18,
             "remaining" => 82
           } = RunState.usage(state).llm_budget["total_tokens"]
  end

  test "an unaccountable direct LLM capability is refused under an aggregate budget" do
    parent = self()

    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          send(parent, :unaccountable_provider_called)
          {:ok, %{content: "unreachable", tokens: %{input: 1, output: 1}}}
        end
      )

    {state, environment} = runtime(capability, llm_total_tokens: 100)

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :reservation_attestation_unavailable
           } = dispatch(state, environment)

    refute_receive :unaccountable_provider_called
    assert RunState.usage(state).llm_budget["total_tokens"]["charged"] == 0
  end

  defp router(bound, requester) do
    {:ok, capability} =
      LLMCapability.new(
        requester: requester,
        usage_guarantees: %{tokens: true, cost_currency: "USD"}
      )

    {:ok, router} =
      LLMRouter.new([
        %{
          alias: "primary",
          source: "llm",
          installation_revision: "primary-v1",
          default?: true,
          capability: capability,
          max_calls: nil,
          output_tokens: 20,
          reservation_tariff: @tariff,
          reservation_bound: bound
        }
      ])

    router
  end

  defp runtime(router, limit_options) do
    {:ok, limits} = Limits.new(limit_options)
    {:ok, state} = RunState.start(limits)
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [router])
    {state, environment}
  end

  defp overrun_router do
    router(
      &bound/2,
      fn _request ->
        {:ok,
         %{
           content: "answer",
           tokens: %{
             input: 30,
             output: 30,
             total_cost: %{currency: "USD", microunits: 300}
           }
         }}
      end
    )
  end

  defp dispatch(state, environment, inspection_sink \\ nil) do
    Dispatcher.dispatch(
      state,
      :workflow,
      environment,
      "llm-request",
      @arguments,
      TestHelpers.dispatch_context(state, :workflow, 500),
      nil,
      inspection_sink
    )
  end

  defp bound(_request, tariff) do
    {:ok,
     %{
       total_tokens: 40,
       cost: %{currency: "USD", microunits: 200, tariff_id: tariff.id}
     }}
  end
end
