defmodule PtcRunner.Kernel.RunAdmissionGlobalStateTest do
  use ExUnit.Case, async: false
  import PtcRunner.TestSupport.RunAdmissionFixture

  alias PtcRunner.Kernel.RunAdmission

  test "request death also kills the workflow sandbox" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_runner, :sandbox, :armed],
        &__MODULE__.hold_sandbox/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {caller, ref} = spawn_monitor(fn -> execute(host, fixture) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:sandbox_armed, sandbox}, 5_000
    on_exit(fn -> Process.exit(sandbox, :kill) end)
    sandbox_ref = Process.monitor(sandbox)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^sandbox_ref, :process, ^sandbox, :killed}, 1_000
  end

  def hold_sandbox(_, _, %{live_run: _, pid: pid}, parent) do
    send(parent, {:sandbox_armed, pid})
    receive do: (:unused -> :ok)
  end

  def hold_sandbox(_, _, _, _), do: :ok
end
