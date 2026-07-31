defmodule IncidentCompiler.Recorder do
  @moduledoc """
  Freezes scripted model responses into an `llm_replay` fixture file.

  A replay entry is keyed by the hash of the provider-neutral request the
  workflow actually built, and that request carries the accumulated transcript
  — so the key for turn N cannot be known until turns 1..N-1 have been
  answered. This recorder closes that loop without a credential: it runs the
  application against the fixture built so far, reads the `llm-request`
  arguments back out of the private inspection artifact, hashes them, pairs
  each with the authored response at the same position, and repeats until a
  run produces no request the fixture cannot already answer.

  A run that fails is expected and not an error here. Two of the shipped
  scenarios exist precisely to prove the compiler refuses to publish, so the
  loop terminates on request-set convergence rather than on run success.

  Usage:

      mix run incident_compiler/tools/record.exs [SCRIPT ...]
  """

  alias PtcRunner.Kernel.LLMReplay

  @app_dir "incident_compiler"
  @script_dir Path.join(@app_dir, "fixtures/replay/scripts")
  @program_dir Path.join(@app_dir, "fixtures/replay/programs")
  @fixture Path.join(@app_dir, "fixtures/replay/compiler.jsonl")
  @host_config Path.join(@app_dir, "ptc-host.json")
  @max_rounds 24

  def main(argv) do
    scripts = scripts(argv)
    fixture = load_fixture()

    {fixture, summaries} =
      Enum.reduce(scripts, {fixture, []}, fn script, {fixture, summaries} ->
        {fixture, summary} = record(script, fixture)
        {fixture, [summary | summaries]}
      end)

    write_fixture(fixture)

    IO.puts("\nwrote #{@fixture} (#{map_size(fixture)} entries)")

    summaries
    |> Enum.reverse()
    |> Enum.each(fn {name, turns, rounds} ->
      IO.puts("  #{name}: #{turns} turns recorded in #{rounds} rounds")
    end)
  end

  defp scripts([]) do
    @script_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  end

  defp scripts(names), do: Enum.map(names, &Path.join(@script_dir, &1 <> ".json"))

  defp record(path, fixture) do
    script = path |> File.read!() |> Jason.decode!()
    name = Path.basename(path, ".json")
    manifest = Path.join(@app_dir, script["manifest"])
    turns = script["turns"]

    IO.puts("recording #{name} (#{length(turns)} authored turns)")

    converge(name, manifest, turns, fixture, 1)
  end

  defp converge(name, _manifest, _turns, _fixture, round) when round > @max_rounds do
    raise "#{name}: did not converge within #{@max_rounds} rounds"
  end

  defp converge(name, manifest, turns, fixture, round) do
    requests = requests_from_run(manifest, fixture)

    {fixture, added} =
      requests
      |> Enum.with_index()
      |> Enum.reduce({fixture, 0}, fn {request, index}, {fixture, added} ->
        hash = hash!(request, name, index)

        cond do
          Map.has_key?(fixture, hash) ->
            {fixture, added}

          index >= length(turns) ->
            raise "#{name}: run asked for turn #{index + 1} but the script authors " <>
                    "only #{length(turns)} turns"

          true ->
            response = response(Enum.at(turns, index), index)
            {Map.put(fixture, hash, entry(hash, response)), added + 1}
        end
      end)

    IO.puts("  round #{round}: #{length(requests)} requests, #{added} newly answered")

    if added == 0 do
      {fixture, {name, length(requests), round}}
    else
      converge(name, manifest, turns, fixture, round + 1)
    end
  end

  # The fixture must be on disk before the run, because the replay provider
  # loads it from the path the host document names.
  defp requests_from_run(manifest, fixture) do
    write_fixture(fixture)

    artifact =
      Path.join(
        System.tmp_dir!(),
        "incident-record-#{System.unique_integer([:positive])}.inspection.jsonl"
      )

    try do
      run(manifest, artifact)
      llm_requests(artifact)
    after
      File.rm(artifact)
    end
  end

  defp run(manifest, artifact) do
    Mix.Task.rerun("ptc.run", [
      manifest,
      "--host-config",
      @host_config,
      "--inspect",
      artifact
    ])
  rescue
    error in [Mix.Error] ->
      IO.puts("  (run failed: #{Exception.message(error)})")
      :failed
  end

  defp llm_requests(artifact) do
    if File.exists?(artifact) do
      artifact
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["record_type"] == "capability-input"))
      |> Enum.filter(&(get_in(&1, ["payload", "name"]) == "llm-request"))
      |> Enum.sort_by(& &1["sequence"])
      |> Enum.map(&get_in(&1, ["payload", "arguments"]))
    else
      []
    end
  end

  defp hash!(request, name, index) do
    case LLMReplay.request_hash(request) do
      {:ok, hash} -> hash
      :error -> raise "#{name}: turn #{index + 1} request could not be hashed"
    end
  end

  defp entry(hash, response) do
    %{"schema_version" => 1, "request_hash" => hash, "response" => response}
  end

  # Authored turns keep their program in an ordinary `.clj` file rather than an
  # escaped JSON string, so a scripted model turn stays reviewable as code.
  defp response(turn, index) do
    program = @program_dir |> Path.join(turn["program"]) |> File.read!()

    %{
      "content" => turn["rationale"],
      "tool_calls" => [
        %{
          "id" => "call-#{index + 1}",
          "name" => "run_ptc_lisp",
          "args" => %{"program" => program}
        }
      ]
    }
  end

  defp load_fixture do
    if File.exists?(@fixture) do
      @fixture
      |> File.stream!()
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Map.new(fn line ->
        entry = Jason.decode!(line)
        {entry["request_hash"], entry}
      end)
    else
      %{}
    end
  end

  defp write_fixture(fixture) do
    File.mkdir_p!(Path.dirname(@fixture))

    contents =
      fixture
      |> bootstrap()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {_hash, entry} -> Jason.encode!(entry) end)

    File.write!(@fixture, contents <> "\n")
  end

  # An empty fixture file is not a loadable replay source, so the first round of
  # the first scenario has nothing to run against. This entry answers a hash no
  # request can produce and disappears as soon as one real turn is recorded.
  defp bootstrap(fixture) when map_size(fixture) == 0 do
    hash = "sha256:" <> String.duplicate("0", 64)
    %{hash => entry(hash, %{"content" => "unreachable bootstrap entry", "tool_calls" => []})}
  end

  defp bootstrap(fixture), do: fixture
end

IncidentCompiler.Recorder.main(System.argv())
