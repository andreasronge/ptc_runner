defmodule PtcRunner.Kernel.ReplTraceLifecycleGlobalStateTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ReplSession

  @tag :tmp_dir
  test "a relative trace remains bound to the invocation directory", %{tmp_dir: directory} do
    invocation = Path.join(directory, "invocation")
    later = Path.join(directory, "later")
    File.mkdir!(invocation)
    File.mkdir!(later)

    session =
      File.cd!(invocation, fn ->
        assert {:ok, session} = ReplSession.new(trace_path: "session.jsonl")
        session
      end)

    File.cd!(later, fn ->
      assert {:ok, _events} = ReplSession.close(session)
    end)

    assert File.regular?(Path.join(invocation, "session.jsonl"))
    refute File.exists?(Path.join(later, "session.jsonl"))
  end
end
