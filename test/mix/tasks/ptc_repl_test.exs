defmodule Mix.Tasks.Ptc.ReplTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Repl

  test "interactive repl prints captured println output before return value" do
    output =
      capture_io("(println 42)\n", fn ->
        Repl.run([])
      end)

    assert output =~ "42\nnil"
  end

  test "-e prints captured println output before return value" do
    output =
      capture_io(fn ->
        Repl.run(["-e", ~S|(do (println "first") (println "second"))|])
      end)

    assert output == "first\nsecond\nnil\n"
  end

  test "-l prints captured println output before entering repl" do
    path = Path.join(System.tmp_dir!(), "ptc-repl-load-#{System.unique_integer([:positive])}.clj")
    File.write!(path, ~S|(println "loaded output")|)

    try do
      output =
        capture_io("\n", fn ->
          Repl.run(["-l", path])
        end)

      assert output =~ "loaded output\nLoaded #{path}"
    after
      File.rm(path)
    end
  end
end
