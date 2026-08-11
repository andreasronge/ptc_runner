defmodule PtcRunner.Kernel.DispatcherEffectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  @effects [:read, :write, :unknown]
  @input_schema %{"type" => "object", "additionalProperties" => false}

  test "mission provider errors become indeterminate only after possible non-read dispatch" do
    for effect <- @effects do
      result =
        dispatch_mission(effect, fn ->
          {:error, ProviderError.new(:unavailable, "try later", retryable?: true)}
        end)

      assert_effect_failure(
        result,
        effect,
        %{kind: :provider_error, reason: :unavailable, details: "try later"},
        true
      )
    end
  end

  test "trusted not-dispatched provider errors preserve their retry policy and omit mutation state" do
    for effect <- @effects do
      result =
        dispatch_mission(effect, fn ->
          {:error,
           ProviderError.new(:invalid_request, "local validation",
             retryable?: true,
             dispatch_provenance: :not_dispatched
           )}
        end)

      assert %{
               status: :error,
               kind: :provider_error,
               reason: :invalid_request,
               details: "local validation",
               retryable?: true
             } = result

      refute Map.has_key?(result, :mutation_state)
      refute Map.has_key?(result, :dispatch_provenance)
    end
  end

  test "mission result normalization is effect-aware after callback invocation" do
    cases = [
      {
        fn -> {:ok, String.duplicate("x", 256)} end,
        [limits: [capability_result_bytes: 64]],
        %{kind: :result_exceeded, reason: :provider_result_limit}
      },
      {
        fn -> {:ok, %{"ok" => "not-boolean"}} end,
        [
          output_schema: %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}},
            "required" => ["ok"]
          }
        ],
        %{kind: :invalid_result, reason: :output_schema_mismatch}
      },
      {
        fn -> :unexpected end,
        [],
        %{kind: :invalid_result, reason: :invalid_provider_return}
      }
    ]

    for {callback, opts, expected} <- cases,
        effect <- @effects do
      result = dispatch_mission(effect, callback, opts)
      assert_effect_failure(result, effect, expected, false)
    end
  end

  test "mission quota, timeout, and result-size limits retain mission attribution" do
    cases = [
      {[capability_result_bytes: 64], 100, fn -> {:ok, String.duplicate("x", 256)} end,
       :provider_result_limit},
      {[], 100,
       fn ->
         receive do
           :never -> {:ok, nil}
         end
       end, :provider_timeout}
    ]

    for {limit_opts, timeout_ms, callback, reason} <- cases do
      {result, events} = dispatch_mission_with_events(limit_opts, timeout_ms, callback)
      assert result.kind in [:result_exceeded, :timeout]

      assert %{data: %{reason: ^reason, environment: :mission, mission_name: "reader"}} =
               Enum.find(events, &(&1.type == "limit-exceeded"))
    end

    {:ok, limits} =
      Limits.new(mission_capability_calls: 1, mission_capability_calls_per_name: 1)

    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-quota-attribution")
    {:ok, capability} = capability(:read, fn -> {:ok, 1} end)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "reader")

    context = %{
      timeout_ms: 100,
      validation_heap_words: limits.evaluation_heap_words,
      evaluation_lease: lease,
      validation_deadline_ms: nil,
      mission_name: "reader"
    }

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :mission,
               environment,
               capability.name,
               %{},
               context,
               sink,
               nil
             )

    assert %{kind: :limit_exceeded, reason: :capability_quota} =
             Dispatcher.dispatch(
               state,
               :mission,
               environment,
               capability.name,
               %{},
               context,
               sink,
               nil
             )

    assert %{data: %{reason: :capability_quota, mission_name: "reader"}} =
             EventSink.events(sink) |> Enum.find(&(&1.type == "limit-exceeded"))
  end

  test "mission callback raises, exits, and process deaths are effect-aware" do
    cases = [
      {fn -> raise "private failure" end, :exception},
      {fn -> exit(:private_failure) end, :exit},
      {fn -> Process.exit(self(), :kill) end, :provider_heap_exceeded}
    ]

    for {callback, reason} <- cases,
        effect <- @effects do
      result = dispatch_mission(effect, callback)
      assert_effect_failure(result, effect, %{kind: :provider_error, reason: reason}, true)
    end
  end

  test "mission timeouts are effect-aware after callback invocation" do
    parent = self()

    for effect <- @effects do
      task =
        Task.async(fn ->
          dispatch_mission(
            effect,
            fn ->
              send(parent, {:callback_started, effect})

              receive do
                :never -> {:ok, nil}
              end
            end,
            # `await_provider/6` in the dispatcher uses this single value both
            # as the deadline it reports as `:provider_timeout` AND as the
            # window the provider process has to be scheduled at all -- past
            # it, the dispatcher kills the provider outright, so 500ms gives
            # it a comfortable scheduling window under full-suite contention.
            timeout_ms: 500
          )
        end)

      # No timing race: `dispatch_mission` above only returns once its own
      # `timeout_ms` has elapsed (the callback blocks forever on :never, so
      # nothing else makes it return), so by the time `Task.await` unblocks,
      # `:callback_started` has already been sent if it was ever going to
      # be -- `assert_received` just checks the mailbox, no wait needed. A
      # racing `assert_receive` before this point (as a prior version of
      # this test had) could time out on a legitimately slow-but-successful
      # callback start that simply hadn't happened yet.
      result = Task.await(task, 5_000)
      assert_received {:callback_started, ^effect}

      assert_effect_failure(
        result,
        effect,
        %{kind: :timeout, reason: :provider_timeout},
        true
      )
    end
  end

  test "run closure after callback completion is effect-aware" do
    parent = self()

    for effect <- @effects do
      {:ok, state} = RunState.start(Limits.defaults())

      {:ok, capability} =
        capability(effect, fn ->
          send(parent, {:callback_started, effect, self()})

          receive do
            :finish -> {:ok, %{"ok" => true}}
          end
        end)

      {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
      {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state)

      task =
        Task.async(fn ->
          Dispatcher.dispatch_with_lease(
            state,
            :mission,
            environment,
            capability.name,
            %{},
            3_000,
            {nil, nil, lease}
          )
        end)

      # Unlike the timeout test above, this callback doesn't block forever
      # -- it waits for `:finish`, sent below -- so `Task.await` can't be
      # moved after this wait the same way (we need `provider`'s pid from
      # the message before we can send it anything). The wait here has to
      # cover not just the dispatch call's own deadline, but everything
      # before that deadline even starts ticking: Task scheduling plus
      # `Dispatcher.dispatch/6`'s own setup (capability validation, budget
      # reservation) ahead of `await_provider/6`. Both timeouts are
      # generous specifically to swallow that prefix too.
      assert_receive {:callback_started, ^effect, provider}, 5_000
      assert :ok = RunState.close(state)
      send(provider, :finish)

      assert_effect_failure(
        Task.await(task),
        effect,
        %{kind: :limit_exceeded, reason: :run_closed},
        false
      )
    end
  end

  test "inspection output replacement is effect-aware after callback completion" do
    for effect <- @effects do
      {:ok, inspection_sink} =
        InspectionSink.start(
          run_id: "dispatcher-effect-run",
          trace_id: "dispatcher-effect-trace",
          max_record_bytes: 4_000,
          max_total_bytes: 10_000
        )

      result =
        dispatch_mission(
          effect,
          fn -> {:ok, String.duplicate("x", 5_000)} end,
          inspection_sink: inspection_sink
        )

      assert_effect_failure(
        result,
        effect,
        %{kind: :inspection_sink_error, reason: :inspection_sink_error},
        false
      )
    end
  end

  test "failures proven to precede callback invocation omit mutation state" do
    parent = self()

    for effect <- @effects do
      {:ok, capability} =
        Capability.new(
          name: "effect-fixture",
          input_schema: %{
            "type" => "object",
            "properties" => %{"required" => %{"type" => "boolean"}},
            "required" => ["required"]
          },
          effect: effect,
          callback: fn _arguments ->
            send(parent, {:unexpected_callback, effect})
            {:ok, nil}
          end
        )

      {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
      {:ok, state} = RunState.start(Limits.defaults())
      {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state)

      assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} =
               result =
               Dispatcher.dispatch_with_lease(
                 state,
                 :mission,
                 environment,
                 capability.name,
                 %{},
                 100,
                 {nil, nil, lease}
               )

      refute Map.has_key?(result, :mutation_state)
      refute_received {:unexpected_callback, ^effect}
    end
  end

  test "inspection input failure precedes callback invocation and omits mutation state" do
    parent = self()

    for effect <- @effects do
      {:ok, inspection_sink} =
        InspectionSink.start(
          run_id: "dispatcher-input-run",
          trace_id: "dispatcher-input-trace"
        )

      assert {:error, :inspection_sink_error} =
               InspectionSink.emit(inspection_sink, "unsupported", %{}, %{})

      result =
        dispatch_mission(
          effect,
          fn ->
            send(parent, {:unexpected_callback, effect})
            {:ok, nil}
          end,
          inspection_sink: inspection_sink
        )

      assert %{
               status: :error,
               kind: :inspection_sink_error,
               reason: :inspection_sink_error,
               retryable?: false
             } = result

      refute Map.has_key?(result, :mutation_state)
      refute_received {:unexpected_callback, ^effect}
    end
  end

  test "successful mission calls omit mutation state for every effect" do
    for effect <- @effects do
      assert %{status: :ok, value: %{"ok" => true}} =
               result =
               dispatch_mission(effect, fn -> {:ok, %{"ok" => true}} end)

      refute Map.has_key?(result, :mutation_state)
    end
  end

  test "workflow llm-request keeps trusted retryable availability failures" do
    {:ok, capability} = LLMCapability.new(requester: fn _request -> {:error, :unavailable} end)
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :unavailable,
             retryable?: true
           } =
             result =
             Dispatcher.dispatch(state, :workflow, environment, "llm-request", %{}, 100)

    refute Map.has_key?(result, :mutation_state)
  end

  test "provider-declared mutation state reaches the public envelope without provenance" do
    result =
      dispatch_mission(:read, fn ->
        {:error,
         ProviderError.new(:transport_error, "connection lost",
           mutation_state: :indeterminate,
           dispatch_provenance: :possibly_dispatched
         )}
      end)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :transport_error,
             details: "connection lost",
             retryable?: false,
             mutation_state: :indeterminate
           } = result

    refute Map.has_key?(result, :dispatch_provenance)
  end

  test "directly constructed malformed provider errors stay inside the bounded envelope" do
    malformed_errors = [
      %ProviderError{kind: :unavailable, mutation_state: :invalid},
      %ProviderError{kind: :unavailable, dispatch_provenance: :invalid},
      %ProviderError{kind: :unavailable, retryable?: :invalid},
      %ProviderError{kind: :invalid},
      %ProviderError{kind: :unavailable, details: String.duplicate("x", 1_025)}
    ]

    for error <- malformed_errors,
        effect <- @effects do
      result = dispatch_mission(effect, fn -> {:error, error} end)

      assert_effect_failure(
        result,
        effect,
        %{kind: :invalid_result, reason: :invalid_provider_return},
        false
      )
    end
  end

  test "provider error construction truncates long valid details before validation" do
    details = String.duplicate("å", 1_025)

    assert %ProviderError{details: bounded} =
             ProviderError.new(:unavailable, details)

    assert String.length(bounded) == 1_024
    assert String.valid?(bounded)
  end

  defp dispatch_mission(effect, callback, opts \\ []) do
    limits =
      opts
      |> Keyword.get(:limits, [])
      |> Limits.new()
      |> then(fn {:ok, limits} -> limits end)

    {:ok, state} = RunState.start(limits)
    {:ok, capability} = capability(effect, callback, opts)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])

    # Mission dispatch only happens under an evaluation lease in production;
    # the reservation is authenticated against it.
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state)

    Dispatcher.dispatch_with_lease(
      state,
      :mission,
      environment,
      capability.name,
      %{},
      Keyword.get(opts, :timeout_ms, 100),
      {nil, Keyword.get(opts, :inspection_sink), lease}
    )
  end

  defp dispatch_mission_with_events(limit_opts, timeout_ms, callback) do
    {:ok, limits} = Limits.new(limit_opts)
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-limit-attribution")
    {:ok, capability} = capability(:read, callback)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "reader")

    result =
      Dispatcher.dispatch(
        state,
        :mission,
        environment,
        capability.name,
        %{},
        %{
          timeout_ms: timeout_ms,
          validation_heap_words: limits.evaluation_heap_words,
          evaluation_lease: lease,
          validation_deadline_ms: nil,
          mission_name: "reader"
        },
        sink,
        nil
      )

    {result, EventSink.events(sink)}
  end

  defp capability(effect, callback, opts \\ []) do
    Capability.new(
      name: "effect-fixture",
      input_schema: @input_schema,
      output_schema: Keyword.get(opts, :output_schema),
      effect: effect,
      callback: fn _arguments -> callback.() end
    )
  end

  defp assert_effect_failure(result, effect, expected, read_retryable?) do
    assert %{status: :error} = result
    assert Map.take(result, Map.keys(expected)) == expected
    refute Map.has_key?(result, :dispatch_provenance)

    if effect == :read do
      assert result.retryable? == read_retryable?
      refute Map.has_key?(result, :mutation_state)
    else
      assert result.retryable? == false
      assert result.mutation_state == :indeterminate
    end
  end
end
