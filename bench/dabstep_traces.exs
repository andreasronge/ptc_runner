alias PtcRunner.Kernel.CommandEngine

root = Path.expand("tmp/profiling/followup/trace-fixture")

if File.dir?(Path.join(root, ".ptc/traces")),
  do:
    raise(
      "trace fixture already exists; reuse its cohorts or remove only this generated fixture and its generated cohorts before regenerating"
    )

File.mkdir_p!(root)

File.write!(
  Path.join(root, "main.clj"),
  ~S|(ns bench.trace) (defn run [input] (return {"ok" true}))|
)

File.write!(
  Path.join(root, "ptc.json"),
  Jason.encode!(%{
    "version" => 1,
    "workflow" => %{
      "components" => [%{"id" => "bench.trace", "path" => "main.clj"}],
      "entry" => "bench.trace/run"
    },
    "input" => %{"value" => %{}}
  })
)

File.write!(Path.join(root, "host.json"), Jason.encode!(%{"install" => %{}}))

File.write!(
  Path.join(root, "project.json"),
  Jason.encode!(%{
    "kind" => "ptc-project",
    "version" => 1,
    "application" => %{"path" => "ptc.json"},
    "host" => %{"path" => "host.json"},
    "artifacts" => %{
      "root" => ".ptc",
      "trace" => true,
      "inspection" => true,
      "result" => false,
      "envelope" => false
    }
  })
)

# Generate through the real command boundary. Never rewrite canonical records.
for i <- 1..1025 do
  {:ok, outcome} = CommandEngine.dispatch(["run", Path.join(root, "project.json")])
  0 = outcome.exit_status

  if i in [1, 10, 100, 1000, 1025] do
    cohort = Path.expand("tmp/profiling/followup/trace-cohorts/#{i}")
    File.mkdir_p!(cohort)

    for collection <- ["traces", "inspection"] do
      File.cp_r!(Path.join([root, ".ptc", collection]), Path.join(cohort, collection))
    end

    files = Path.wildcard(Path.join(cohort, "traces/*"))

    IO.puts(
      Jason.encode!(%{
        runs: i,
        trace_files: length(files),
        trace_bytes: Enum.reduce(files, 0, &(File.stat!(&1).size + &2)),
        cohort: cohort
      })
    )
  end
end
