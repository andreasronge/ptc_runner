fixture_server =
  Path.expand("../../examples/kernel-inspection-lab/support/mcp_fixture.exs", __DIR__)

lab = Path.expand("../../examples/kernel-inspection-lab/support/lab.exs", __DIR__)
Code.require_file(fixture_server)
Code.require_file(lab)

alias PtcRunner.Examples.KernelInspectionLab
alias PtcRunner.Kernel.ViewerAdapter

output =
  Path.join(
    System.tmp_dir!(),
    "ptc-viewer-dialogue-#{System.unique_integer([:positive])}"
  )

try do
  {:ok, [_direct, wrapper]} = KernelInspectionLab.run(output)
  source = {:file, wrapper.trace}

  {:ok, metadata} =
    ViewerAdapter.query(source, :get_run, %{"run_id" => wrapper.run_id})

  {:ok, turns} =
    ViewerAdapter.query(source, :list_turns, %{"run_id" => wrapper.run_id, "limit" => 100})

  {:ok, grant} = ViewerAdapter.pin_inspection(wrapper.inspection, source)
  {:ok, inspection} = ViewerAdapter.inspection(grant, wrapper.run_id)

  fixtures = Path.expand("../test/fixtures", __DIR__)
  File.write!(Path.join(fixtures, "dialogue_metadata.json"), Jason.encode!(metadata))
  File.write!(Path.join(fixtures, "dialogue_turns.json"), Jason.encode!(turns))
  File.write!(Path.join(fixtures, "dialogue_inspection.json"), Jason.encode!(inspection))
after
  File.rm_rf(output)
end
