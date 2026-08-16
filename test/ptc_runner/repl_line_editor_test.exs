defmodule PtcRunner.ReplLineEditorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.ReplLineEditor

  # ExUnit runs without a terminal, so these exercise the fallback the editor
  # takes on every non-interactive path: piped input, scripts, and CI.

  test "runs the loop in the calling process and returns its value" do
    caller = self()

    capture_io(fn ->
      assert ReplLineEditor.run(:direct, fn -> {:done, self()} end) == {:done, caller}
    end)
  end

  test "announces the REPL once, naming the command that leaves it" do
    output = capture_io(fn -> ReplLineEditor.run(:direct, fn -> :ok end) end)

    assert output =~ ":quit"
    assert [_before, _after] = String.split(output, ReplLineEditor.banner())
  end

  test "leaves shell history untouched without a terminal" do
    Application.delete_env(:kernel, :shell_history)
    on_exit(fn -> Application.delete_env(:kernel, :shell_history) end)

    capture_io(fn -> ReplLineEditor.run(:direct, fn -> :ok end) end)

    assert Application.get_env(:kernel, :shell_history) == nil
  end

  test "raises out of the loop in the caller, so command teardown still sees it" do
    assert_raise RuntimeError, "loop failed", fn ->
      capture_io(fn -> ReplLineEditor.run(:direct, fn -> raise "loop failed" end) end)
    end
  end

  describe "history policy" do
    test "a direct session persists submitted lines" do
      assert ReplLineEditor.persists_history?(:direct)
    end

    # A manifest session can carry a private event policy and sensitive input;
    # its lines must not reach the user cache.
    test "a manifest session does not" do
      refute ReplLineEditor.persists_history?(:manifest)
    end
  end
end
