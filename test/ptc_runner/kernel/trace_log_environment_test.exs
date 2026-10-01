defmodule PtcRunner.Kernel.TraceLogEnvironmentTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.TraceLog

  @tag :tmp_dir
  test "append and bound publication helpers do not inherit credentials", %{tmp_dir: directory} do
    shell = System.find_executable("sh")
    original_path = System.get_env("PATH")
    sentinel = "PTC_TRACE_CHILD_SENTINEL"
    original_sentinel = System.get_env(sentinel)
    probe = Path.join(directory, "probe")
    File.mkdir!(probe)
    report = Path.join(probe, "observations")

    # The executable seam observes the environment before running the real helper.
    # Only the sentinel is recorded; never dump the host's environment.
    File.write!(Path.join(probe, "sh"), """
    #!#{shell}
    printf '%s:%s\\n' "$3" "${#{sentinel}-absent}" >> "#{report}"
    exec "#{shell}" "$@"
    """)

    File.chmod!(Path.join(probe, "sh"), 0o700)
    System.put_env("PATH", probe <> ":" <> original_path)
    System.put_env(sentinel, "credential-sentinel")

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env(sentinel, original_sentinel)
    end)

    assert :ok = TraceLog.append_jsonl(Path.join(directory, "append.jsonl"), [])
    {:ok, stat} = File.stat(directory)

    assert :ok =
             TraceLog.publish_jsonl(Path.join(directory, "published.jsonl"), [],
               expected_parent_identity: {stat.major_device, stat.minor_device, stat.inode}
             )

    observations = File.read!(report)
    assert observations =~ "ptc-trace-append-lock:absent\n"
    assert observations =~ "--:absent\n"
    refute observations =~ "credential-sentinel"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
