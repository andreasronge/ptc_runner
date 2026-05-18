defmodule Mix.Tasks.Ptc.InstallBabashkaTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ptc.InstallBabashka

  test "rejects unsafe version strings before downloading" do
    for version <- ["../1.4.192", "1.4.192/asset", "v1.4.192", "1.4"] do
      Mix.Task.reenable("ptc.install_babashka")

      assert_raise Mix.Error, ~r/Invalid Babashka version/, fn ->
        InstallBabashka.run(["--version", version, "--force"])
      end
    end
  end
end
