# Profiles the complete provider-free ServingTemplate call path without HTTP.
#
# Run:
#   mix run bench/serving_template.exs
#   PTC_SERVING_PROFILE=1 PROFILE_ITERS=200 mix run bench/serving_template.exs

alias PtcRunner.Kernel.Limits
alias PtcRunner.Kernel.RunAdmission
alias PtcRunner.Kernel.ServingTemplate

iterations = String.to_integer(System.get_env("PROFILE_ITERS", "1_000"))
directory = Path.join(System.tmp_dir!(), "ptc-serving-#{System.unique_integer([:positive])}")
File.mkdir_p!(directory)

schema = %{
  "type" => "object",
  "properties" => %{"answer" => %{"type" => "integer"}},
  "required" => ["answer"],
  "additionalProperties" => false
}

manifest = %{
  "version" => 1,
  "workflow" => %{
    "components" => [%{"id" => "app", "path" => "workflow.clj"}],
    "entry" => "app/run"
  },
  "input" => %{"path" => "unused.json"},
  "contracts" => %{
    "input_schema" => %{"path" => "schema.json"},
    "result_schema" => %{"path" => "schema.json"}
  }
}

File.write!(Path.join(directory, "workflow.clj"), """
(ns app)
(defn run {:effect :read} [input] (return input))
""")

File.write!(Path.join(directory, "schema.json"), Jason.encode!(schema))
manifest_path = Path.join(directory, "app.json")
File.write!(manifest_path, Jason.encode!(manifest))

try do
  {:ok, template} = ServingTemplate.from_directory(manifest_path, Limits.installed_defaults())
  {:ok, admission} = RunAdmission.start_link(max_concurrent_runs: 16)
  input = %{"answer" => 1}

  for _ <- 1..100, do: ServingTemplate.call(template, input, admission)

  samples =
    for _ <- 1..iterations do
      {elapsed_us, outcome} =
        :timer.tc(fn -> ServingTemplate.call(template, input, admission) end)

      :success = PtcRunner.Kernel.ServingOutcome.code(outcome)
      elapsed_us
    end

  sorted = Enum.sort(samples)
  median_us = Enum.at(sorted, div(length(sorted), 2))
  p95_us = Enum.at(sorted, floor(length(sorted) * 0.95))
  IO.puts("calls=#{iterations} median_us=#{median_us} p95_us=#{p95_us}")

  if System.get_env("PTC_SERVING_PROFILE") == "1" do
    tools_ebin =
      [to_string(:code.root_dir()), "lib", "tools-*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> List.first()

    if tools_ebin, do: Code.append_path(tools_ebin)

    unless Code.ensure_loaded?(:tprof) do
      raise "could not load :tprof from #{inspect(tools_ebin)}"
    end

    work = fn ->
      for _ <- 1..iterations, do: ServingTemplate.call(template, input, admission)
      :ok
    end

    :tprof.profile(work, %{type: :call_time, report: :total})
  end
after
  File.rm_rf!(directory)
end
