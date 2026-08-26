defmodule PtcRunner.Kernel.DispatcherLlmDeadlineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"]
  }

  test "a live requester receives an integer whole-call deadline" do
    parent = self()

    {result, _state, _sink} =
      dispatch_llm(parent,
        requester: fn _request, context ->
          send(parent, {:called, context})
          {:ok, %{content: "ok", tokens: %{}}}
        end
      )

    assert %{status: :ok} = result
    assert_received {:called, %{llm_request_deadline_ms: deadline}}
    assert is_integer(deadline)
    assert deadline > System.monotonic_time(:millisecond)
  end

  test "the requester deadline is clamped by the existing workflow deadline" do
    parent = self()
    validation_deadline_ms = System.monotonic_time(:millisecond) + 500

    {result, _state, _sink} =
      dispatch_llm(parent,
        request_timeout_ms: 5_000,
        timeout_ms: 5_000,
        validation_deadline_ms: validation_deadline_ms,
        requester: fn _request, context ->
          send(parent, {:called, context})
          {:ok, %{content: "ok", tokens: %{}}}
        end
      )

    assert %{status: :ok} = result
    assert_received {:called, %{llm_request_deadline_ms: deadline}}
    assert deadline <= validation_deadline_ms
  end

  test "a replay requester receives a nil whole-call deadline" do
    parent = self()

    {result, _state, _sink} =
      dispatch_llm(parent,
        source: "llm_replay",
        requester: fn _request, context ->
          send(parent, {:called, context})
          {:ok, %{content: "ok", tokens: %{}}}
        end
      )

    assert %{status: :ok} = result
    assert_received {:called, %{llm_request_deadline_ms: nil}}
  end

  test "Dispatcher kills a hung live call when the LLM clock wins" do
    parent = self()

    {result, state, sink} =
      dispatch_llm(parent,
        request_timeout_ms: 500,
        timeout_ms: 5_000,
        requester: fn _request, context ->
          send(parent, {:called, context, self()})

          receive do
            :never -> {:ok, %{content: "ok", tokens: %{}}}
          end
        end
      )

    assert %{
             status: :error,
             kind: :timeout,
             reason: :llm_request_timeout,
             retryable?: true
           } = result

    assert_received {:called, %{llm_request_deadline_ms: deadline}, _worker}
    assert is_integer(deadline)
    assert RunState.usage(state).capability_calls.workflow["llm-request"] == 1

    assert Enum.any?(EventSink.events(sink), &(&1.type == "capability-started"))

    assert Enum.any?(EventSink.events(sink), fn event ->
             event.type == "capability-stopped" and event.data.reason == :llm_request_timeout
           end)
  end

  test "an equal enclosing dispatch timeout keeps provider_timeout" do
    parent = self()

    {result, _state, _sink} =
      dispatch_llm(parent,
        timeout_ms: 500,
        requester: fn _request, _context ->
          send(parent, {:called, :hung})

          receive do
            :never -> {:ok, %{content: "ok", tokens: %{}}}
          end
        end
      )

    assert %{
             status: :error,
             kind: :timeout,
             reason: :provider_timeout,
             retryable?: true
           } = result

    assert_received {:called, :hung}
  end

  test "an adapter timeout after the LLM clock wins is llm_request_timeout" do
    parent = self()

    {result, _state, _sink} =
      dispatch_llm(parent,
        request_timeout_ms: 200,
        timeout_ms: 5_000,
        requester: fn _request, %{llm_request_deadline_ms: deadline} ->
          wait_ms = max(deadline - System.monotonic_time(:millisecond) + 1, 0)

          if wait_ms > 0 do
            receive do
            after
              wait_ms -> :ok
            end
          end

          {:error, ProviderError.new(:timeout, "LLM request deadline elapsed", retryable?: true)}
        end
      )

    assert %{
             status: :error,
             kind: :timeout,
             reason: :llm_request_timeout,
             retryable?: true
           } = result
  end

  test "a provider timeout completed before the LLM deadline is not relabeled after delay" do
    parent = self()

    task =
      Task.async(fn ->
        dispatch_llm(parent,
          request_timeout_ms: 300,
          timeout_ms: 1_000,
          requester: fn _request, context ->
            send(parent, {:ready, context, self()})

            receive do
              :return_timeout ->
                {:error, ProviderError.new(:timeout, "provider timed out", retryable?: true)}
            end
          end
        )
      end)

    assert_receive {:ready, %{llm_request_deadline_ms: deadline}, worker}
    worker_ref = Process.monitor(worker)
    assert true == :erlang.suspend_process(task.pid)
    send(worker, :return_timeout)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

    try do
      wait_until(deadline + 10)
    after
      assert true == :erlang.resume_process(task.pid)
    end

    assert {
             %{status: :error, kind: :provider_error, reason: :timeout, retryable?: true},
             _state,
             _sink
           } = Task.await(task)
  end

  test "a delayed Dispatcher preserves the earlier LLM deadline winner" do
    parent = self()

    task =
      Task.async(fn ->
        dispatch_llm(parent,
          request_timeout_ms: 100,
          timeout_ms: 200,
          requester: fn _request, context ->
            send(parent, {:called, context})

            receive do
              :never -> {:ok, %{content: "ok", tokens: %{}}}
            end
          end
        )
      end)

    assert_receive {:called, %{llm_request_deadline_ms: deadline}}
    assert true == :erlang.suspend_process(task.pid)

    try do
      wait_until(deadline + 125)
    after
      assert true == :erlang.resume_process(task.pid)
    end

    assert {
             %{status: :error, kind: :timeout, reason: :llm_request_timeout, retryable?: true},
             _state,
             _sink
           } = Task.await(task)
  end

  test "an equal shared workflow clock keeps provider_timeout" do
    parent = self()
    deadline_ms = System.monotonic_time(:millisecond) + 500

    {result, _state, _sink} =
      dispatch_llm(parent,
        request_timeout_ms: 500,
        timeout_ms: 5_000,
        validation_deadline_ms: deadline_ms,
        requester: fn _request, _context ->
          send(parent, {:called, :hung})

          receive do
            :never -> {:ok, %{json: ~s({"ok":true}), tokens: %{}}}
          end
        end,
        structured_output_mode: :json_object,
        arguments: %{"schema" => @schema}
      )

    assert %{status: :error, kind: :timeout, reason: :provider_timeout, retryable?: true} =
             result

    assert_received {:called, :hung}
  end

  test "an earlier shared validation deadline stays authoritative after the LLM deadline" do
    parent = self()
    validation_deadline_ms = System.monotonic_time(:millisecond) + 300

    task =
      Task.async(fn ->
        dispatch_llm(parent,
          request_timeout_ms: 600,
          timeout_ms: 3_000,
          validation_deadline_ms: validation_deadline_ms,
          structured_output_mode: :json_object,
          arguments: %{"schema" => @schema},
          requester: fn _request, context ->
            send(parent, {:in_callback, context, self()})

            receive do
              :continue -> {:ok, %{json: ~s({"ok":true}), tokens: %{}}}
            end
          end
        )
      end)

    assert_receive {:in_callback, %{llm_request_deadline_ms: deadline}, worker}
    assert true == :erlang.suspend_process(task.pid)
    send(worker, :continue)

    try do
      wait_until(deadline + 10)
    after
      assert true == :erlang.resume_process(task.pid)
    end

    assert {result, _state, _sink} = Task.await(task)

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :output_validation_unavailable,
             retryable?: false
           } = result
  end

  test "a capability without an LLM deadline keeps the full enclosing timeout" do
    {:ok, capability} =
      Capability.new(
        name: "ordinary",
        callback: fn _arguments -> {:ok, %{}} end,
        input_schema: %{"type" => "object"}
      )

    invocation = CapabilityInvocation.leaf(capability, %{})

    assert 2_000_000_000 ==
             CapabilityInvocation.clamp_provider_timeout(invocation, 2_000_000_000)
  end

  defp dispatch_llm(_parent, opts) do
    requester = Keyword.fetch!(opts, :requester)
    {:ok, capability} = LLMCapability.new(requester: requester)

    route = %{
      alias: "model",
      source: Keyword.get(opts, :source, "llm"),
      installation_revision: "model-v1",
      default?: true,
      capability: capability,
      max_calls: nil
    }

    route =
      case Keyword.get(opts, :structured_output_mode) do
        nil -> route
        mode -> Map.put(route, :structured_output_mode, mode)
      end

    route =
      case Keyword.get(opts, :request_timeout_ms) do
        nil -> route
        timeout_ms -> Map.put(route, :request_timeout_ms, timeout_ms)
      end

    assert {:ok, router} = LLMRouter.new([route])
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [router])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "llm-deadline")
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_000)
    arguments = Keyword.get(opts, :arguments, %{})

    dispatch_opts =
      case Keyword.get(opts, :validation_deadline_ms) do
        nil -> []
        deadline_ms -> [validation_deadline_ms: deadline_ms]
      end

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        "llm-request",
        arguments,
        TestHelpers.dispatch_context(state, :workflow, timeout_ms, dispatch_opts),
        sink,
        nil
      )

    {result, state, sink}
  end

  defp wait_until(deadline_ms) do
    receive do
    after
      max(deadline_ms - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end
end
