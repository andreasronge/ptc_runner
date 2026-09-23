defmodule PtcRunner.Kernel.HelperCorpusLabTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag :nightly

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
  end
end
