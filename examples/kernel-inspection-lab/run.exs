directory = __DIR__
Code.require_file("support/mcp_fixture.exs", directory)
Code.require_file("support/lab.exs", directory)

output =
  case System.argv() do
    [path] ->
      Path.expand(path)

    [] ->
      Path.join(
        System.tmp_dir!(),
        "ptc-kernel-inspection-lab-#{System.unique_integer([:positive])}"
      )

    _arguments ->
      raise "usage: mix run examples/kernel-inspection-lab/run.exs [OUTPUT_DIRECTORY]"
  end

{:ok, journeys} = PtcRunner.Examples.KernelInspectionLab.run(output)

IO.puts("Inspection lab completed in #{output}")

Enum.each(journeys, fn journey ->
  IO.puts("#{journey.name}: run=#{journey.run_id}")
  IO.puts("  trace: #{journey.trace}")
  IO.puts("  inspection: #{journey.inspection}")
end)

IO.puts("Open one artifact with:")

IO.puts(
  "  mix ptc.viewer --trace-dir #{output}/direct/traces " <>
    "--inspection-file #{output}/direct/inspection/run.inspection.jsonl"
)
