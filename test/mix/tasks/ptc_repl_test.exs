defmodule Mix.Tasks.Ptc.ReplTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Repl
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog

  setup do
    Mix.Task.reenable("ptc.repl")
    :ok
  end

  test "repeated evals preserve definitions, history, and captured output" do
    output =
      capture_io(fn ->
        Repl.run([
          "-e",
          "(def x 40)",
          "-e",
          ~S|(do (println "value") (+ x 2))|,
          "-e",
          "(+ *1 1)"
        ])
      end)

    assert output =~ "#'x\n"
    assert output =~ "value\n42\n43\n"
  end

  test "interactive mode prints output and exits on EOF" do
    output = capture_io("(println 42)\n", fn -> Repl.run([]) end)
    assert output =~ "42\nnil"
    assert output =~ "Goodbye!"
  end

  test "empty stdin is a successful empty script" do
    assert "" = capture_io("", fn -> Repl.run(["-"]) end)
  end

  @tag :tmp_dir
  test "a strict manifest supplies the REPL workflow bundle", %{tmp_dir: directory} do
    component_path = Path.join(directory, "helpers.lisp")
    manifest_path = Path.join(directory, "ptc.json")
    File.write!(component_path, "(ns helpers) (defn answer [] 42)")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.lisp"}],
          "entry" => "helpers/answer"
        },
        "input" => %{"value" => %{}}
      })
    )

    output =
      capture_io(fn -> Repl.run(["--manifest", manifest_path, "-e", "(helpers/answer)"]) end)

    assert output == "42\n"
  end

  @tag :tmp_dir
  test "--trace persists canonical session events through the shared loader", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "repl.jsonl")
    assert "3\n" = capture_io(fn -> Repl.run(["--trace", path, "-e", "(+ 1 2)"]) end)
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok,
            %{
              "items" => [
                %{"complete" => true, "name" => name}
              ]
            }} =
             TraceLog.query(trace_log, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("ptc.repl")
  end

  @tag :tmp_dir
  test "a private manifest restricts the trace before appending events", %{tmp_dir: directory} do
    component_path = Path.join(directory, "helpers.lisp")
    manifest_path = Path.join(directory, "private.json")
    trace_path = Path.join(directory, "private.private.jsonl")
    File.write!(component_path, "(ns helpers) (defn answer [] 42)")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.lisp"}],
          "entry" => "helpers/answer"
        },
        "input" => %{"value" => %{}},
        "events" => %{"policy" => "private"}
      })
    )

    assert "42\n" =
             capture_io(fn ->
               Repl.run(["--manifest", manifest_path, "--trace", trace_path, "-e", "42"])
             end)

    {:ok, stat} = File.stat(trace_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  @tag :tmp_dir
  test "-l evaluates setup before entering the REPL", %{tmp_dir: directory} do
    path = Path.join(directory, "setup.lisp")
    File.write!(path, "(def loaded 41)")
    output = capture_io("(+ loaded 1)\n", fn -> Repl.run(["-l", path]) end)
    assert output =~ "Loaded #{path}"
    assert output =~ "42"
  end

  test "removed upstream and special log options fail closed" do
    assert_raise Mix.Error, ~r/invalid ptc.repl options/, fn ->
      Repl.run(["--log-prelude", "-e", "(+ 1 2)"])
    end
  end

  test "eval and positional script modes are mutually exclusive" do
    assert_raise Mix.Error, ~r/cannot combine --eval with a script/, fn ->
      Repl.run(["-e", "42", "script.lisp"])
    end
  end

  test "history depth is validated before manifest setup" do
    assert_raise Mix.Error, ~r/history-depth must be between 1 and 3/, fn ->
      Repl.run(["--history-depth", "0", "--manifest", "missing.json"])
    end
  end
end
