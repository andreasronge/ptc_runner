defmodule PtcRunner.Kernel.ParallelProviderLimitTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @input_schema %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "integer"}},
    "required" => ["id"],
    "additionalProperties" => false
  }

  test "effective live provider task ceiling bounds workflow pmap width" do
    parent = self()
    config = provider_config(parent, "pmap-provider-width", :manual_release)

    run = Task.async(fn -> Kernel.run(pmap_source(), config) end)
    started = receive_and_release_providers(4)

    assert {:ok, %{value: values}} = Task.await(run, 5_000)
    assert_provider_ids(started, values)
  end

  test "effective live provider task ceiling bounds REPL pmap width" do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        config = provider_config(parent, "repl-pmap-provider-width", :delayed_release)
        {:ok, session} = ReplSession.new(config: config)
        result = ReplSession.eval(session, pmap_source())
        send(parent, {:repl_result, result})
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert_receive {:repl_result, result}, 5_000
    assert {:ok, %{return: {:__ptc_return__, values}}, _session} = result
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
    started = receive_started_providers(4)
    assert_provider_ids(started, values)
  end

  defp provider_config(parent, run_id, release_mode) do
    {:ok, capability} =
      Capability.new(
        name: "gated",
        input_schema: @input_schema,
        callback: fn %{"id" => id} ->
          send(parent, {:provider_started, id, self()})
          await_release(release_mode)
          {:ok, %{"id" => id}}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        live_provider_tasks: 1,
        workflow_timeout_ms: 5_000,
        evaluation_timeout_ms: 5_000,
        run_duration_ms: 5_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    config
  end

  defp pmap_source do
    ~S|(return (pmap (fn [id] (tool/gated {"id" id})) [1 2 3 4]))|
  end

  defp receive_and_release_providers(count) do
    for _batch <- 1..count do
      provider = receive_provider()
      release_provider(provider)
      provider
    end
  end

  defp receive_started_providers(count) do
    for _provider <- 1..count, do: receive_provider()
  end

  defp receive_provider do
    assert_receive {:provider_started, id, pid}, 1_000
    {id, pid}
  end

  defp release_provider({_id, pid}), do: send(pid, :release)

  defp await_release(:manual_release) do
    receive do
      :release -> :ok
    end
  end

  defp await_release(:delayed_release) do
    Process.send_after(self(), :release, 100)
    await_release(:manual_release)
  end

  defp assert_provider_ids(started, values) do
    assert [1, 2, 3, 4] == started |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert [1, 2, 3, 4] ==
             values
             |> Enum.map(&provider_id/1)
             |> Enum.sort()
  end

  defp provider_id(result) do
    result
    |> Map.get(:value, Map.get(result, "value"))
    |> Map.fetch!("id")
  end
end
