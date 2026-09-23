defmodule PtcRunner.Kernel.HelperCorpusLabTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag :nightly

  alias PtcRunner.Labs.PreludeSearch

  lab = Path.expand("../../../scripts/labs/prelude-search", __DIR__)
  Code.require_file("support/mutations.exs", lab)
  Code.require_file("support/inputs.exs", lab)
  Code.require_file("support/lab.exs", lab)

  @tag :tmp_dir
  test "retained helper corpus replays byte-equal in a fresh VM and rejects a changed bundle", %{
    tmp_dir: tmp
  } do
    source = Path.expand("../../../scripts/labs/helper-corpus/corpus", __DIR__)
    copied = Path.join(tmp, "corpus")
    File.cp_r!(source, copied)

    {console, status} =
      System.cmd(
        System.find_executable("mix"),
        ["run", "scripts/labs/helper-corpus/run.exs", "--replay-artifacts", copied],
        stderr_to_stdout: true
      )

    assert status == 0, console
    assert console =~ "Replay equal:"

    failures =
      source
      |> Path.join("fold-pages/executions.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.filter(& &1["failure_envelope"])

    assert failures |> Enum.map(& &1["result_hash"]) |> Enum.uniq() |> length() ==
             length(failures)

    bundle = Path.join(copied, "segments/oracle-bundle/subject.clj")
    File.write!(bundle, File.read!(bundle) <> "\n; deliberate mutation\n")

    {console, status} =
      System.cmd(
        System.find_executable("mix"),
        ["run", "scripts/labs/helper-corpus/run.exs", "--replay-artifacts", copied],
        stderr_to_stdout: true
      )

    refute status == 0
    assert console =~ "bundle identity changed"

    # Keep the new bundle identity valid, but retain the original result hashes.
    # This reaches the result comparison rather than the bundle identity guard.
    judged = Path.join(tmp, "judged")
    File.cp_r!(source, judged)
    original = Path.join(judged, "segments/oracle-bundle/subject.clj")

    mutated =
      original
      |> File.read!()
      |> String.replace(
        ~S|(defn corpus [input] (return (segments (get input "prompt"))))|,
        ~S|(defn corpus [_input] (return []))|
      )

    assert mutated != File.read!(original)
    original_index = Path.join(judged, "segments/executions.json")
    records = original_index |> File.read!() |> Jason.decode!()
    mutant_dir = Path.join(tmp, "mutant")

    PreludeSearch.capture_helper(
      mutant_dir,
      "segments",
      "prompt.audit",
      "prompt.audit/corpus",
      mutated,
      [%{"input" => hd(records)["input"], "split" => "visible", "branch" => "mutated"}]
    )

    [mutant_record] =
      mutant_dir
      |> Path.join("segments/executions.json")
      |> File.read!()
      |> Jason.decode!()

    File.write!(original, mutated)

    records = Enum.map(records, &Map.put(&1, "bundle_hash", mutant_record["bundle_hash"]))
    File.write!(original_index, Jason.encode!(records, pretty: true))

    assert {:ok, results} = PreludeSearch.replay(judged)
    assert Enum.any?(results, &(&1.unequal != []))
  end
end
