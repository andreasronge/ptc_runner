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
      raise "usage: mix run scripts/labs/inspection-lab/run.exs [OUTPUT_DIRECTORY]"
  end

{:ok, journeys} = PtcRunner.Examples.KernelInspectionLab.run(output)

IO.puts("Inspection lab completed in #{output}")

Enum.each(journeys, fn journey ->
  IO.puts("#{journey.name}: run=#{journey.run_id}")
  IO.puts("  trace: #{journey.trace}")
  IO.puts("  inspection: #{journey.inspection}")
end)

# The Viewer takes one project document rather than loose directories, so the
# lab writes the document that describes the layout it just produced. Each
# journey already keeps its canonical and private artifacts in the conventional
# `traces/` and `inspection/` pair beneath its own directory.
Enum.each(journeys, fn journey ->
  project = %{
    "$schema" => "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
    "kind" => "ptc-project",
    "version" => 1,
    "application" => %{"path" => "#{journey.name}/ptc.json"},
    "artifacts" => %{
      "root" => "#{journey.name}/artifacts",
      "trace" => true,
      "inspection" => true
    },
    # `private` grants this instance the journey's inspection artifacts, which
    # carry complete model requests, generated source, and capability payloads.
    "viewer" => %{"port" => 0, "open" => false, "repl" => false, "private" => true}
  }

  File.write!(
    Path.join(output, "#{journey.name}.ptc-project.json"),
    Jason.encode_to_iodata!(project, pretty: true)
  )
end)

IO.puts("Browse one journey, including its private payloads, with:")
IO.puts("  mix ptc viewer #{output}/direct.ptc-project.json")
