fixture =
  Path.expand("../../../examples/kernel-inspection-lab/support/mcp_fixture.exs", __DIR__)

lab = Path.expand("../../../examples/kernel-inspection-lab/support/lab.exs", __DIR__)
Code.require_file(fixture)
Code.require_file(lab)

defmodule PtcRunner.Kernel.InspectionLabTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Examples.KernelInspectionLab
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerAdapter

  @tag :tmp_dir
  test "scripted file, native, and MCP journeys produce inspectable Viewer artifacts", %{
    tmp_dir: dir
  } do
    output = Path.join(dir, "lab")
    assert {:ok, [direct, wrapper]} = KernelInspectionLab.run(output)
    assert direct.name == "direct"
    assert wrapper.name == "wrapper"

    for journey <- [direct, wrapper] do
      assert {:ok, records} = InspectionArtifact.load(journey.inspection)
      assert File.read!(journey.trace) =~ "mcp-2025-11-25"

      inspection_body = File.read!(journey.inspection)
      refute inspection_body =~ "127.0.0.1"
      refute inspection_body =~ "inspection-lab-session"
      refute inspection_body =~ "mcp-session-id"

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-input" and
                 record["payload"]["name"] == "llm-request" and
                 record["payload"]["arguments"]["system"] =~ "Frozen mission inventory"
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "evaluation-source" and
                 record["payload"]["source"] =~ "remote"
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "llm-request" and
                 get_in(record, [
                   "payload",
                   "result",
                   "value",
                   "tool_calls",
                   Access.at(0),
                   "args",
                   "program"
                 ]) =~
                   "remote"
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "fs-read" and
                 get_in(record, ["payload", "result", "value", "content"]) == "fixture-file"
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "native-echo" and
                 get_in(record, ["payload", "result", "value", "echo"]) == "fixture"
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "remote.structured" and
                 get_in(record, ["payload", "result", "value", "value"]) == 42
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "remote.text" and
                 get_in(record, ["payload", "result", "value", "text"]) == ["fixture-text"]
             end)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 record["payload"]["name"] == "remote.fail" and
                 get_in(record, ["payload", "result", "status"]) == "error" and
                 get_in(record, ["payload", "result", "reason"]) == "domain_error"
             end)

      viewer_opts = [
        trace_dir: Path.dirname(journey.trace),
        kernel_trace_adapter: ViewerAdapter,
        inspection_file: journey.inspection,
        inspection_adapter: ViewerAdapter
      ]

      inspection =
        Plug.Test.conn(:get, "/api/inspection/runs/#{journey.run_id}")
        |> PtcViewer.Router.call(PtcViewer.Router.init(viewer_opts))

      assert inspection.status == 200
      assert %{"records" => ^records} = Jason.decode!(inspection.resp_body)

      {rendered, 0} =
        System.cmd(
          "node",
          [
            Path.expand("../../../ptc_viewer/test/render_inspection.mjs", __DIR__),
            journey.inspection
          ],
          stderr_to_stdout: true
        )

      assert rendered =~ "Sensitive inspection data"
      assert rendered =~ "evaluation-source"
      assert rendered =~ "remote.structured"
      assert rendered =~ "remote.text"
      assert rendered =~ "remote.fail"

      assert {:ok, canonical_trace} = TraceLog.new(source: {:file, journey.trace})

      assert {:ok, turns} =
               TraceLog.query(canonical_trace, :list_turns, %{"run_id" => journey.run_id})

      encoded_turns = Jason.encode!(turns)
      refute encoded_turns =~ "fixture-text"
      refute encoded_turns =~ "fixture-file"
    end

    direct_request = model_request(direct.inspection)
    wrapper_request = model_request(wrapper.inspection)
    refute direct_request["system"] =~ "lab.tools/read-file"
    assert wrapper_request["system"] =~ "lab.tools/read-file"
  end

  defp model_request(path) do
    {:ok, records} = InspectionArtifact.load(path)

    records
    |> Enum.find(
      &(&1["record_type"] == "capability-input" and &1["payload"]["name"] == "llm-request")
    )
    |> get_in(["payload", "arguments"])
  end
end
