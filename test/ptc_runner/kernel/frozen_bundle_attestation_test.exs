defmodule PtcRunner.Kernel.FrozenBundleAttestationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Library

  test "concurrent first seals share one attestation key" do
    storage_key = {Attestation, FrozenBundle}
    :persistent_term.erase(storage_key)
    parent = self()
    component = Library.component("kernel") |> elem(1)

    tasks =
      for _index <- 1..64 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:seal -> Kernel.compile_bundle([component]))
        end)
      end

    pids =
      for _index <- 1..64 do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :seal))

    bundles = Enum.map(tasks, fn task -> task |> Task.await(30_000) |> elem(1) end)
    assert Enum.all?(bundles, &FrozenBundle.valid?/1)
  end
end
