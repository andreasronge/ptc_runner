defmodule PtcRunner.Kernel.PreludeSearchLabTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Labs.PreludeSearch

  @moduletag :nightly

  lab = Path.expand("../../../scripts/labs/prelude-search", __DIR__)
  Code.require_file("support/mutations.exs", lab)
  Code.require_file("support/inputs.exs", lab)
  Code.require_file("support/lab.exs", lab)

  test "Phase 0 re-executes every recorded execution byte-equally" do
    output =
      Path.join(System.tmp_dir!(), "prelude-search-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(output) end)

    assert {:ok, [result]} =
             PreludeSearch.run(
               output: output,
               subjects: ["intervals"],
               seed: 20_260_917,
               executions: 10
             )

    assert result.equal == 10
    assert result.unequal == []
  end
end
