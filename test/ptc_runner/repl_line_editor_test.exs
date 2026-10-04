defmodule PtcRunner.ReplLineEditorTest do
  # async: false — history admission mutates application and OS environment (class D).
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

  describe "history directory admission" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      path = Path.join(cache, "ptc/repl-history")
      File.mkdir_p!(Path.dirname(path))
      previous_path = System.fetch_env!("PATH")
      keys = [:shell_history, :shell_history_path, :shell_history_file_bytes]
      previous_history = Map.new(keys, &{&1, Application.fetch_env(:kernel, &1)})

      on_exit(fn ->
        System.put_env("PATH", previous_path)

        for {key, value} <- previous_history do
          case value do
            {:ok, value} -> Application.put_env(:kernel, key, value)
            :error -> Application.delete_env(:kernel, key)
          end
        end
      end)

      %{history_path: path}
    end

    test "disables history when the history directory is a symlink", context do
      target = Path.join(context.tmp_dir, "shared")
      File.mkdir_p!(target)
      File.ln_s!(target, context.history_path)

      assert :ok = ReplLineEditor.history(:direct, context.history_path)
      assert Application.get_env(:kernel, :shell_history) == :disabled
      assert Bitwise.band(File.stat!(target).mode, 0o777) != 0o700
    end

    test "creates and reuses an owner-only directory", %{history_path: path} do
      assert :ok = ReplLineEditor.history(:direct, path)
      assert Application.get_env(:kernel, :shell_history) == :enabled
      assert Application.get_env(:kernel, :shell_history_path) == String.to_charlist(path)
      assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o700

      File.chmod!(path, 0o755)
      assert :ok = ReplLineEditor.history(:direct, path)
      assert Application.get_env(:kernel, :shell_history) == :enabled
      assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o700
    end

    test "disables history when ownership cannot be verified", context do
      bin = Path.join(context.tmp_dir, "bin")
      File.mkdir_p!(bin)
      id = Path.join(bin, "id")
      File.write!(id, "#!/bin/sh\nexit 1\n")
      File.chmod!(id, 0o700)
      System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
      Application.put_env(:kernel, :shell_history, :enabled)

      assert :ok = ReplLineEditor.history(:direct, context.history_path)
      assert Application.get_env(:kernel, :shell_history) == :disabled
    end

    test "disables history for a foreign owner even when chmod can succeed", context do
      File.mkdir_p!(context.history_path)
      File.chmod!(context.history_path, 0o755)
      bin = Path.join(context.tmp_dir, "bin")
      File.mkdir_p!(bin)
      id = Path.join(bin, "id")
      foreign_uid = File.stat!(context.history_path).uid + 1
      File.write!(id, "#!/bin/sh\nprintf '%s\\n' '#{foreign_uid}'\n")
      File.chmod!(id, 0o700)
      System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

      assert :ok = ReplLineEditor.history(:direct, context.history_path)
      assert Application.get_env(:kernel, :shell_history) == :disabled
      assert Bitwise.band(File.stat!(context.history_path).mode, 0o777) == 0o755
    end

    test "disables history when the directory cannot be created", %{history_path: path} do
      File.write!(path, "not a directory")
      assert :ok = ReplLineEditor.history(:direct, path)
      assert Application.get_env(:kernel, :shell_history) == :disabled
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
