defmodule PtcRunner.Kernel.RunBuilderPublicationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @tag :tmp_dir
  test "one-shot publication reuses the captured result class", %{tmp_dir: directory} do
    File.write!(
      Path.join(directory, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"answer" 42}))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "events" => %{"policy" => "normal", "run_id" => "publication-class"}
    }

    manifest_path = Path.join(directory, "ptc.json")
    trace_path = Path.join(directory, "run.jsonl")
    output_path = Path.join(directory, "result.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    Code.ensure_loaded!(EventSink)
    assert :erlang.trace_pattern({EventSink, :policy, 1}, true, [:local]) == 1
    test = self()
    tracer = spawn_link(fn -> policy_trace_loop(test, 0) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, %{value: %{"answer" => 42}}, :normal} =
               RunBuilder.run_with_class(manifest_path, registry,
                 trace: trace_path,
                 output: output_path
               )

      tracee = self()
      reference = :erlang.trace_delivered(tracee)
      assert_receive {:trace_delivered, ^tracee, ^reference}
      send(tracer, :count)

      # A later sink loss cannot change publication authority when the live
      # policy is read exactly once, at the execution/publication checkpoint.
      assert_receive {:policy_call_count, 1}
      assert File.regular?(trace_path)
      assert Jason.decode!(File.read!(output_path)) == %{"answer" => 42}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({EventSink, :policy, 1}, false, [:local])
      send(tracer, :stop)
    end
  end

  defp policy_trace_loop(test, count) do
    receive do
      {:trace, _pid, :call, {EventSink, :policy, [_sink]}} ->
        policy_trace_loop(test, count + 1)

      :count ->
        send(test, {:policy_call_count, count})
        policy_trace_loop(test, count)

      :stop ->
        :ok
    end
  end
end
