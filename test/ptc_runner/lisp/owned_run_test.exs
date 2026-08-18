defmodule PtcRunner.Lisp.OwnedRunTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 0]

  alias PtcRunner.Lisp

  test "run_owned watchdog-kills the sandbox on caller death even if link: false is passed" do
    {caller, caller_ref} =
      spawn_monitor(fn ->
        receive do
          :go -> Lisp.run_owned(long_running_body(), timeout: 30_000, link: false)
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert 1 = :erlang.trace(caller, true, [:procs])
    send(caller, :go)

    assert_receive {:trace, ^caller, :spawn, compile_worker, _mfa}, 2_000
    compile_ref = Process.monitor(compile_worker)
    assert_receive {:DOWN, ^compile_ref, :process, ^compile_worker, _reason}, 2_000

    assert_receive {:trace, ^caller, :spawn, eval_worker, _mfa}, 2_000
    eval_ref = Process.monitor(eval_worker)

    on_exit(fn ->
      if Process.alive?(eval_worker), do: Process.exit(eval_worker, :kill)
    end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
    assert_receive {:DOWN, ^eval_ref, :process, ^eval_worker, :killed}, 2_000
  end
end
