defmodule PtcRunner.Kernel.DabstepReviewerRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 600_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @example Path.expand("../../../examples/dabstep-fraud", __DIR__)
  @application Path.join(@example, "reviewer.ptc.json")
  @host Path.join(@example, "ptc-host.reviewer-replay.json")

  test "the reviewer's own measurement contradicts the captured wrong-metric answer" do
    assert {:ok, result} = run("reviewer-wrong-metric.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "wrong-metric"
    assert result.value["reviewer_answer"] == "B. BE"
    assert result.value["measurements_agree"]
    assert result.value["problems"] != []
  end

  test "the reviewer's own measurement contradicts the seeded off-by-one totals" do
    assert {:ok, result} = run("reviewer-off-by-one.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "off-by-one"
    assert result.value["reviewer_answer"] == "B. BE"
    refute result.value["measurements_agree"]
    assert result.value["problems"] != []
  end

  test "the reviewer's own measurement contradicts a wrong fraud column both analyzers shared" do
    assert {:ok, result} = run("reviewer-shared-refused.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "shared-refused"
    assert result.value["reviewer_answer"] == "B. BE"
    refute result.value["measurements_agree"]
    assert result.value["problems"] != []
  end

  @tag :tmp_dir
  test "recorded multi-turn command replay survives file replacement and rejects changed bytes",
       %{
         tmp_dir: directory
       } do
    copy_example(directory)
    project = Path.join(directory, "ptc-project.replay.json")
    csv = Path.join(directory, "data/payments.csv")
    original = File.read!(csv)

    # A final-program-only fixture cannot exercise cursor-bearing feedback.
    assert Enum.count(File.stream!(Path.join(directory, "replay.jsonl"))) > 3

    for rebuild? <- [false, true] do
      if rebuild? do
        # Keep the old inode allocated until the replacement exists.
        previous = csv <> ".previous"
        File.rename!(csv, previous)
        File.write!(csv, original)
        refute File.stat!(csv).inode == File.stat!(previous).inode
        File.rm!(previous)
      end

      assert {:ok, outcome} =
               CommandEngine.dispatch(["run", project, "--input", "inputs/luna.json"])

      assert outcome.exit_status == 0, inspect(outcome.envelope)

      assert Map.drop(outcome.envelope["result"]["value"], ["problems"]) == %{
               "ok" => true,
               "value" => "B. BE",
               "agreed" => true,
               "top_country" => %{"analysis" => "BE", "recheck" => "BE", "review" => "BE"}
             }

      assert [_reviewer_observation] = outcome.envelope["result"]["value"]["problems"]

      assert [%{"calls" => calls}] = outcome.envelope["execution"]["usage"]["llm_usage"]
      assert calls > 3
    end

    # Change a data byte at EOF so the first page remains valid, but its
    # semantic cursor identity changes before the second model request.
    last = byte_size(original) - 1
    <<prefix::binary-size(^last), byte>> = original
    File.write!(csv, prefix <> <<Bitwise.bxor(byte, 1)>>)

    assert {:error, failed} =
             CommandEngine.dispatch(["run", project, "--input", "inputs/luna.json"])

    assert failed.exit_status == 5
    assert failed.envelope["error"]["code"] == "explicit_failure"
  end

  @tag :tmp_dir
  test "command replay corrects a seeded reviewer error and withholds it without turns", %{
    tmp_dir: directory
  } do
    copy_example(directory)
    project = Path.join(directory, "ptc-project.replay.json")
    host = Path.join(directory, "ptc-host.verification-replay.json")

    for {input, expected} <- [
          {"luna.json", "B. BE"},
          {"verification-exhausted.json", "Not Applicable"}
        ] do
      assert {:ok, outcome} =
               CommandEngine.dispatch([
                 "run",
                 project,
                 "--host-config",
                 host,
                 "--input",
                 Path.join([@example, "inputs", input])
               ])

      assert outcome.exit_status == 0, inspect(outcome.envelope)
      assert outcome.envelope["result"]["value"]["value"] == expected
      assert outcome.envelope["result"]["value"]["agreed"] == (expected == "B. BE")

      assert [%{"alias" => "luna", "calls" => calls, "usage_calls" => 0, "usage" => usage}] =
               outcome.envelope["execution"]["usage"]["llm_usage"]

      assert calls == if(expected == "B. BE", do: 4, else: 3)
      assert usage == %{}
    end
  end

  defp copy_example(directory) do
    # Never copy accumulated private traces into another test's source tree.
    for path <- Path.wildcard(Path.join(@example, "*")), File.regular?(path) do
      File.cp!(path, Path.join(directory, Path.basename(path)))
    end

    File.cp_r!(Path.join(@example, "inputs"), Path.join(directory, "inputs"))
    File.mkdir_p!(Path.join(directory, "data"))
    File.cp!(Path.join(@example, "data/payments.csv"), Path.join(directory, "data/payments.csv"))
  end

  defp run(input_name, application \\ @application, host_path \\ @host) do
    {:ok, host} = HostConfig.load(host_path)

    {:ok, registry} =
      host
      |> HostInstallation.catalog()
      |> then(fn {:ok, catalog} -> HostInstallation.runtime_registry(host, catalog) end)

    application
    |> ApplicationPackage.request_directory(
      installed_limits: registry.installed_limits,
      input: Path.join([@example, "inputs", input_name])
    )
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end
end
