defmodule PtcRunner.Kernel.DecisionProviderTest do
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.ChatDecisions
  alias PtcRunner.Kernel.DecisionCapability
  alias PtcRunner.Kernel.DecisionContract
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  @request %{
    "state" => %{},
    "questions" => %{"q" => %{"type" => "boolean", "instructions" => "Is it true?"}}
  }
  @response %{
    "model" => "served-model-v2",
    "answers" => %{"q" => %{"type" => "boolean", "probability" => 0.9, "confidence" => nil}},
    "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "cost" => 0.000075}
  }

  defp chat_decision_requester do
    ChatDecisions.requester(
      fn _, _ ->
        {:ok, %{object: %{"q" => false}, tokens: %{input: 10, output: 5, total_cost: 0.000075}}}
      end,
      "served-chat"
    )
  end

  test "zero cost settles reported usage and marks missing cost incomplete" do
    for cost <- [0, nil, 0.000075] do
      usage =
        if is_nil(cost),
          do: Map.delete(@response["usage"], "cost"),
          else: Map.put(@response["usage"], "cost", cost)

      response = Map.put(@response, "usage", usage)

      {state, environment} =
        runtime([decision(fn _, _ -> {:ok, response} end, 0, 40)],
          llm_total_tokens: 100,
          llm_cost_microusd: 500
        )

      result = dispatch(state, environment, "decision-request", @request)
      assert result.status == if(cost == 0.000075, do: :error, else: :ok)

      if cost == 0.000075 do
        assert result.reason == :invalid_result
        refute result.retryable?
      end

      budget = RunState.usage(state).llm_budget
      assert budget["cost"]["charged_microusd"] == if(cost == 0.000075, do: 75, else: 0)

      expected_state =
        cond do
          is_nil(cost) -> "incomplete"
          cost > 0 -> "overrun"
          true -> "available"
        end

      assert budget["cost"]["state"] == expected_state
    end
  end

  test "chat token errors still settle independently valid reported cost" do
    requester =
      ChatDecisions.requester(
        fn _, _ ->
          {:ok, %{object: %{"q" => false}, tokens: %{input: -1, output: 5, total_cost: 0.000075}}}
        end,
        "served-chat"
      )

    {state, environment} =
      runtime([decision(requester, 200, 40)], llm_total_tokens: 100, llm_cost_microusd: 500)

    assert %{status: :error, kind: :invalid_result, retryable?: false} =
             dispatch(state, environment, "decision-request", @request)

    assert RunState.usage(state).llm_budget["cost"]["charged_microusd"] == 75
  end

  test "exact declared reservations settle reported usage and overruns never retry" do
    for backend <- [:measured, :chat],
        {cost, tokens, outcome} <- [{200, 40, :ok}, {50, 40, :error}, {200, 12, :error}] do
      parent = self()

      requester =
        case backend do
          :measured -> fn _, _ -> {:ok, @response} end
          :chat -> chat_decision_requester()
        end

      capability =
        decision(
          fn _, context ->
            budget = RunState.usage(context.provider_run_state).llm_budget

            send(
              parent,
              {:reserved, budget["cost"]["reserved_microusd"], budget["total_tokens"]["reserved"]}
            )

            send(parent, :called)
            requester.(@request, context)
          end,
          cost,
          tokens
        )

      {state, environment} = runtime([capability], llm_total_tokens: 100, llm_cost_microusd: 500)
      result = dispatch(state, environment, "decision-request", @request)
      assert result.status == outcome

      if outcome == :error do
        assert result.reason == :invalid_result
        assert result.retryable? == false
      end

      assert_receive {:reserved, ^cost, ^tokens}
      assert_receive :called
      refute_received :called
      budget = RunState.usage(state).llm_budget
      assert budget["total_tokens"]["charged"] == 15
      assert budget["cost"]["charged_microusd"] == 75
      assert budget["total_tokens"]["reserved"] == 0
      assert budget["cost"]["reserved_microusd"] == 0
    end
  end

  test "both call kinds draw on one token and cost ceiling" do
    parent = self()

    decision =
      decision(
        fn _, _ ->
          send(parent, :decision_dispatched)
          chat_decision_requester().(@request, %{})
        end,
        200,
        40
      )

    {:ok, chat} =
      LLMCapability.new(
        requester: fn _ ->
          {:ok,
           %{
             content: "ok",
             tokens: %{input: 20, output: 10, total_cost: %{currency: "USD", microunits: 150}}
           }}
        end,
        llm_reservation: %{
          source: "llm",
          output_tokens: 10,
          tariff: %{currency: "USD", id: "test"},
          bound: fn _, _ ->
            {:ok,
             %{total_tokens: 40, cost: %{currency: "USD", microunits: 200, tariff_id: "test"}}}
          end
        }
      )

    {:ok, chat} =
      LLMRouter.new([
        %{
          alias: "chat",
          source: "llm",
          installation_revision: "chat-v1",
          default?: true,
          capability: chat,
          max_calls: nil,
          output_tokens: 10,
          reservation_tariff: %{currency: "USD", id: "test"},
          reservation_bound: chat.llm_reservation.bound
        }
      ])

    for limits <- [
          [llm_total_tokens: 60, llm_cost_microusd: 500],
          [llm_total_tokens: 100, llm_cost_microusd: 300]
        ] do
      {state, environment} = runtime([chat, decision], limits)
      assert %{status: :ok} = dispatch(state, environment, "llm-request", %{"messages" => []})

      assert %{status: :error, kind: :limit_exceeded} =
               dispatch(state, environment, "decision-request", @request)

      refute_received :decision_dispatched
    end
  end

  test "malformed distributions retain validated cost and tokens" do
    for response <- [
          put_in(@response, ["answers", "q", "probability"], -0.01),
          Map.put(@response, "answers", %{})
        ] do
      {state, environment} =
        runtime([decision(fn _, _ -> {:ok, response} end, 200, 40)],
          llm_total_tokens: 100,
          llm_cost_microusd: 500
        )

      assert %{status: :error, kind: :invalid_result, retryable?: false} =
               dispatch(state, environment, "decision-request", @request)

      assert RunState.usage(state).llm_budget["cost"]["charged_microusd"] == 75
      assert RunState.usage(state).llm_budget["total_tokens"]["charged"] == 15
    end
  end

  test "null measurement values remain valid evidence" do
    response = put_in(@response, ["answers", "q", "probability"], nil)
    {state, environment} = runtime([decision(fn _, _ -> {:ok, response} end, 200, 40)], [])

    assert %{status: :ok, value: ^response} =
             dispatch(state, environment, "decision-request", @request)
  end

  test "concurrent chat and decision calls share provider admission" do
    alias PtcRunner.Kernel.ProviderCallAdmission
    alias PtcRunner.Kernel.ProviderCallOwner
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 1})
    parent = self()

    request = fn name, result ->
      fn _, _ ->
        send(parent, {:entered, name, self()})

        receive do
          :complete -> result
        end
      end
    end

    for backend <- [:measured, :chat] do
      chat_requester = request.(:chat, {:ok, %{content: "ok"}})

      decision_requester =
        case backend do
          :measured ->
            request.(:decision, {:ok, @response})

          :chat ->
            ChatDecisions.requester(
              request.(
                :decision,
                {:ok,
                 %{object: %{"q" => false}, tokens: %{input: 10, output: 5, total_cost: 0.000075}}}
              ),
              "served-chat"
            )
        end

      {:ok, chat} =
        LLMCapability.new(
          requester: fn req, ctx -> ProviderCallOwner.run(admission, chat_requester, req, ctx) end
        )

      {:ok, decision} =
        DecisionCapability.new(
          requester: fn req, ctx ->
            ProviderCallOwner.run(admission, decision_requester, req, ctx)
          end
        )

      context = %{llm_request_deadline_ms: System.monotonic_time(:millisecond) + 5000}
      first = Task.async(fn -> chat.callback.(%{"messages" => []}, context) end)
      assert_receive {:entered, :chat, first_worker}
      second = Task.async(fn -> decision.callback.(@request, context) end)

      assert_eventually(fn ->
        match?({:ok, %{active: 1, waiting: 1}}, ProviderCallAdmission.snapshot(admission))
      end)

      refute_received {:entered, :decision, _}
      send(first_worker, :complete)
      assert {:ok, _} = Task.await(first)
      assert_receive {:entered, :decision, second_worker}
      send(second_worker, :complete)
      assert {:ok, response} = Task.await(second)
      assert DecisionContract.valid_response?(response, @request["questions"])
      if backend == :chat, do: assert(response["answers"]["q"]["value"] == false)
    end
  end

  test "request validation rejects malformed criteria before dispatch and admits large legal state" do
    parent = self()

    {:ok, capability} =
      DecisionCapability.new(
        requester: fn _, _ ->
          send(parent, :dispatched)
          {:error, ProviderError.new(:unavailable, "unavailable", retryable?: true)}
        end
      )

    {state, environment} = runtime([capability], [])

    base = %{
      "state" => %{},
      "questions" => %{
        "q" => %{"type" => "choice", "instructions" => "Pick", "criteria" => %{"a" => "A"}}
      }
    }

    malformed = [%{}, Map.new(1..256, &{Integer.to_string(&1), "x"})]

    for criteria <- malformed do
      request = put_in(base, ["questions", "q", "criteria"], criteria)

      assert %{status: :error, reason: :invalid_arguments} =
               dispatch(state, environment, "decision-request", request)

      refute_received :dispatched
    end

    large =
      base
      |> put_in(["state", "context"], String.duplicate("state ", 800))
      |> put_in(
        ["questions", "q", "criteria"],
        Map.new(1..255, &{"option_#{&1}", String.duplicate("description ", 4)})
      )

    assert byte_size(Jason.encode!(large)) > 4096

    assert %{status: :error, reason: :unavailable} =
             dispatch(state, environment, "decision-request", large)

    assert_receive :dispatched
  end

  defp decision(requester, cost, tokens) do
    {:ok, capability} =
      DecisionCapability.new(
        requester: requester,
        llm_reservation: %{
          source: "decision",
          total_tokens: tokens,
          cost_microusd: cost,
          alias: "decision",
          installation_revision: "decision-v1",
          max_calls: nil,
          request_timeout_ms: 5_000
        }
      )

    capability
  end

  defp runtime(capabilities, opts) do
    {:ok, limits} = Limits.new(opts)
    {:ok, state} = RunState.start(limits)
    {:ok, environment} = WorkflowEnvironment.new(capabilities: capabilities)
    {state, environment}
  end

  defp dispatch(state, environment, name, request) do
    Dispatcher.dispatch(
      state,
      :workflow,
      environment,
      name,
      request,
      TestHelpers.dispatch_context(state, :workflow),
      nil,
      nil
    )
  end
end
