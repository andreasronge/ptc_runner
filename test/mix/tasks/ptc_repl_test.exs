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

  test "--log-prelude exposes the current REPL turn log to Lisp" do
    Mix.Task.reenable("ptc.repl")

    output =
      capture_io(fn ->
        Repl.run([
          "--log-prelude",
          "-e",
          "(def x 1)",
          "-e",
          ~S|(get (log/programs (get (first (get (log/sessions) "items")) "correlation_id")) "items")|
        ])
      end)

    assert output =~ "#'x"
    assert output =~ ~S|["(def x 1)"]|
  end

  test "--log-prelude is mutually exclusive with --prelude" do
    Mix.Task.reenable("ptc.repl")

    assert_raise Mix.Error, ~r/--log-prelude is mutually exclusive with --prelude/, fn ->
      Repl.run(["--log-prelude", "--prelude", "somewhere.clj", "-e", "(+ 1 2)"])
    end
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
