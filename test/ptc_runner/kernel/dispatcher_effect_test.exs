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
  alias PtcRunner.TestSupport.ObservedException
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

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

  test "trusted dispatched provider errors preserve their policy and omit mutation state" do
    for effect <- @effects do
      result =
        dispatch_mission(effect, fn ->
          {:error,
           ProviderError.new(:domain_error, "mcp_domain_error",
             retryable?: false,
             dispatch_provenance: :dispatched
           )}
        end)

      assert %{
               status: :error,
               kind: :provider_error,
               reason: :domain_error,
               details: "mcp_domain_error",
               retryable?: false
             } = result

      refute Map.has_key?(result, :mutation_state)
      refute Map.has_key?(result, :dispatch_provenance)
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
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "reader", :fail_fast)

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

    name = capability.name

    assert %{
             kind: :limit_exceeded,
             reason: :capability_quota,
             details: %{
               limit: :mission_capability_calls_per_name,
               name: ^name,
               limit_value: 1
             }
           } =
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

    assert %{
             data: %{
               reason: :capability_quota,
               mission_name: "reader",
               limit: :mission_capability_calls_per_name,
               name: _,
               limit_value: 1
             }
           } =
             EventSink.events(sink) |> Enum.find(&(&1.type == "limit-exceeded"))
  end

  test "raised mission callbacks are non-retryable" do
    assert_unclassified_mission_failure(fn -> raise "private failure" end, :exception)
  end

  test "raised callbacks retain a correlated private diagnostic without changing the public result" do
    {:ok, inspection_sink} =
      StreamingInspection.start(
        run_id: "dispatcher-exception-run",
        trace_id: "dispatcher-exception-trace"
      )

    result =
      dispatch_mission(:read, fn -> raise "private failure" end, inspection_sink: inspection_sink)

    assert result == %{
             status: :error,
             kind: :provider_error,
             reason: :exception,
             retryable?: false
           }

    assert {:ok, [input, diagnostic, output]} =
             StreamingInspection.records(inspection_sink)

    assert input["record_type"] == "capability-input"

    assert %{
             "record_type" => "capability-exception",
             "correlation" => %{"capability_id" => capability_id},
             "payload" => %{
               "environment" => "mission",
               "mission_name" => "default",
               "name" => "effect-fixture",
               "exception_class" => "Elixir.RuntimeError",
               "message" => "private failure",
               "message_truncated" => false,
               "stacktrace" => stacktrace,
               "stacktrace_truncated" => false
             }
           } = diagnostic

    assert input["correlation"] == %{"capability_id" => capability_id}
    assert stacktrace =~ "dispatcher_effect_test.exs"

    assert output["record_type"] == "capability-output"
    assert output["correlation"] == %{"capability_id" => capability_id}

    assert output["payload"]["result"] == %{
             "status" => "error",
             "kind" => "provider_error",
             "reason" => "exception",
             "retryable?" => false
           }
  end

  test "inspection-disabled raises do not format or retain exception details" do
    owner = self()

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :exception,
             retryable?: false
           } =
             dispatch_mission(:read, fn ->
               :erlang.raise(
                 :error,
                 %ObservedException{owner: owner, value: "inspection-disabled-secret"},
                 []
               )
             end)

    refute_receive {:exception_message_formatted, _message}
  end

  test "a blocking exception formatter cannot change the public or canonical outcome" do
    {:ok, inspection_sink} =
      StreamingInspection.start(
        run_id: "blocking-formatter-run",
        trace_id: "blocking-formatter-trace"
      )

    callback = fn ->
      :erlang.raise(:error, %ObservedException{mode: :block}, [])
    end

    # Generous enough that spawn-and-raise still wins under a loaded suite.
    # A formatter that blocked the provider-result path would still miss it.
    {result, events} = dispatch_mission_with_events([], 5_000, callback, inspection_sink)

    assert result == %{
             status: :error,
             kind: :provider_error,
             reason: :exception,
             retryable?: false
           }

    assert %{data: %{status: :error, kind: :provider_error, reason: :exception}} =
             Enum.find(events, &(&1.type == "capability-stopped"))

    refute Enum.any?(events, &(&1.type == "limit-exceeded"))

    assert {:ok, [_input, diagnostic, output]} =
             StreamingInspection.records(inspection_sink)

    assert diagnostic["payload"]["message"] == "exception message unavailable"
    assert diagnostic["payload"]["message_truncated"]
    assert diagnostic["payload"]["stacktrace_truncated"]
    assert output["payload"]["result"]["reason"] == "exception"
  end

  test "capability-stopped carries the closed rejection class without the payload" do
    secret = "SECRET_PROVIDER_DETAIL"

    {result, events} =
      dispatch_mission_with_events([], 100, fn ->
        {:error, ProviderError.new(:unavailable, secret, retryable?: true)}
      end)

    assert %{status: :error, kind: :provider_error, reason: :unavailable, details: ^secret} =
             result

    stopped = Enum.find(events, &(&1.type == "capability-stopped"))
    assert %{data: %{status: :error, kind: :provider_error, reason: :unavailable}} = stopped
    refute Map.has_key?(stopped.data, :details)
    refute inspect(stopped) =~ secret
  end

  test "workflow raises retain diagnostics without mission attribution" do
    {:ok, inspection_sink} =
      StreamingInspection.start(
        run_id: "workflow-exception-run",
        trace_id: "workflow-exception-trace"
      )

    assert %{kind: :provider_error, reason: :exception} =
             dispatch_workflow(fn -> raise "workflow failure" end,
               inspection_sink: inspection_sink
             )

    assert {:ok, [_input, diagnostic, _output]} =
             StreamingInspection.records(inspection_sink)

    assert diagnostic["record_type"] == "capability-exception"
    assert diagnostic["payload"]["environment"] == "workflow"
    refute Map.has_key?(diagnostic["payload"], "mission_name")
  end

  test "exit and throw retain no exception diagnostic" do
    for callback <- [fn -> exit(:private_failure) end, fn -> throw(:private_failure) end] do
      {:ok, inspection_sink} =
        StreamingInspection.start(
          run_id: "non-exception-run-#{System.unique_integer([:positive])}",
          trace_id: "non-exception-trace"
        )

      assert %{kind: :provider_error} =
               dispatch_mission(:read, callback, inspection_sink: inspection_sink)

      assert {:ok, [input, output]} =
               StreamingInspection.records(inspection_sink)

      assert input["record_type"] == "capability-input"
      assert output["record_type"] == "capability-output"
    end
  end

  test "exception diagnostic sink failure preserves the terminal inspection contract" do
    for effect <- [:read, :write] do
      {:ok, inspection_sink} =
        StreamingInspection.start(
          run_id: "exception-sink-failure-#{effect}",
          trace_id: "exception-sink-failure-trace",
          max_record_bytes: 2_000,
          max_total_bytes: 10_000
        )

      result =
        dispatch_mission(
          effect,
          fn ->
            :erlang.raise(
              :error,
              %ObservedException{value: String.duplicate("private", 1_000)},
              []
            )
          end,
          inspection_sink: inspection_sink
        )

      assert result.kind == :inspection_sink_error
      assert result.reason == :inspection_sink_error
      assert result.retryable? == false

      if effect == :write,
        do: assert(result.mutation_state == :indeterminate),
        else: refute(Map.has_key?(result, :mutation_state))
    end
  end

  test "private exception capture leaves the canonical failure projection unchanged" do
    {:ok, inspection_sink} =
      StreamingInspection.start(
        run_id: "canonical-separation-run",
        trace_id: "canonical-separation-trace"
      )

    callback = fn -> raise "canonical-separation-private-secret" end

    {captured_result, captured_events} =
      dispatch_mission_with_events([], 100, callback, inspection_sink)

    {plain_result, plain_events} = dispatch_mission_with_events([], 100, callback)

    assert captured_result == plain_result

    captured_stop = Enum.find(captured_events, &(&1.type == "capability-stopped"))
    plain_stop = Enum.find(plain_events, &(&1.type == "capability-stopped"))

    assert Map.drop(captured_stop.data, [:duration_ms, :capability_id]) ==
             Map.drop(plain_stop.data, [:duration_ms, :capability_id])

    canonical = inspect(captured_events)
    refute canonical =~ "canonical-separation-private-secret"
    refute canonical =~ "RuntimeError"
    refute canonical =~ "dispatcher_effect_test.exs"
  end

  test "exiting mission callbacks are non-retryable" do
    assert_unclassified_mission_failure(fn -> exit(:private_failure) end, :exit)
  end

  test "throwing mission callbacks are non-retryable" do
    assert_unclassified_mission_failure(fn -> throw(:private_failure) end, :throw)
  end

  test "killed mission provider processes are non-retryable" do
    assert_unclassified_mission_failure(
      fn -> Process.exit(self(), :kill) end,
      :provider_heap_exceeded
    )
  end

  test "abnormally exiting mission provider processes are non-retryable" do
    assert_unclassified_mission_failure(
      fn ->
        spawn_link(fn -> exit(:private_failure) end)

        receive do
          :never -> {:ok, nil}
        end
      end,
      :provider_exit
    )
  end

  test "unclassified workflow callback termination is non-retryable" do
    cases = [
      {fn -> raise "private failure" end, :exception},
      {fn -> exit(:private_failure) end, :exit},
      {fn -> throw(:private_failure) end, :throw},
      {fn -> Process.exit(self(), :kill) end, :provider_heap_exceeded},
      {fn ->
         spawn_link(fn -> exit(:private_failure) end)

         receive do
           :never -> {:ok, nil}
         end
       end, :provider_exit}
    ]

    for {callback, reason} <- cases do
      assert %{
               status: :error,
               kind: :provider_error,
               reason: ^reason,
               retryable?: false
             } = dispatch_workflow(callback)
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
      {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

      task =
        Task.async(fn ->
          Dispatcher.dispatch(
            state,
            :mission,
            environment,
            capability.name,
            %{},
            TestHelpers.dispatch_context(state, :mission, 3_000,
              lease: lease,
              mission_name: "default"
            ),
            nil,
            nil
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
        StreamingInspection.start(
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
      {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

      assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} =
               result =
               Dispatcher.dispatch(
                 state,
                 :mission,
                 environment,
                 capability.name,
                 %{},
                 TestHelpers.dispatch_context(state, :mission, 100,
                   lease: lease,
                   mission_name: "default"
                 ),
                 nil,
                 nil
               )

      refute Map.has_key?(result, :mutation_state)
      refute_received {:unexpected_callback, ^effect}
    end
  end

  test "inspection input failure precedes callback invocation and omits mutation state" do
    parent = self()

    for effect <- @effects do
      {:ok, inspection_sink} =
        StreamingInspection.start(
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
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "llm-request",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

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
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

    Dispatcher.dispatch(
      state,
      :mission,
      environment,
      capability.name,
      %{},
      TestHelpers.dispatch_context(
        state,
        :mission,
        Keyword.get(opts, :timeout_ms, 100),
        lease: lease,
        mission_name: "default"
      ),
      nil,
      Keyword.get(opts, :inspection_sink)
    )
  end

  defp dispatch_workflow(callback, opts \\ []) do
    {:ok, state} = RunState.start(Limits.defaults())
    {:ok, capability} = capability(:read, callback)
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])

    Dispatcher.dispatch(
      state,
      :workflow,
      environment,
      capability.name,
      %{},
      TestHelpers.dispatch_context(state, :workflow, 100),
      nil,
      Keyword.get(opts, :inspection_sink)
    )
  end

  defp dispatch_mission_with_events(limit_opts, timeout_ms, callback, inspection_sink \\ nil) do
    {:ok, limits} = Limits.new(limit_opts)
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-limit-attribution")
    {:ok, capability} = capability(:read, callback)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "reader", :fail_fast)

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
        inspection_sink
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

  defp assert_unclassified_mission_failure(callback, reason) do
    for effect <- @effects do
      result = dispatch_mission(effect, callback)

      assert_effect_failure(
        result,
        effect,
        %{kind: :provider_error, reason: reason},
        false
      )
    end
  end
end
