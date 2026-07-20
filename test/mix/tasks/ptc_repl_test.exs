defmodule Mix.Tasks.Ptc.ReplTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Repl
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
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

  test "removed configurable history depth fails closed" do
    assert_raise Mix.Error, ~r/invalid ptc.repl options/, fn ->
      Repl.run(["--history-depth", "0", "--manifest", "missing.json"])
    end
  end

  test "describes the fixed log-analysis profile as safe JSONL" do
    output =
      capture_io(fn ->
        Repl.run(["--describe-profile", "log-analysis-v1", "--format", "jsonl"])
      end)

    assert [description] = decode_jsonl(output)
    assert description["type"] == "profile"
    assert description["id"] == "log-analysis-v1"
    assert description["components"] == ["log.core"]
    assert description["namespaces"] == ["log"]
    assert description["resources"]["traces"]["required"] == true
    assert description["frontend"]["output_formats"] == ["clojure", "jsonl"]
    refute output =~ "#Function<"
    refute output =~ File.cwd!()
  end

  @tag :tmp_dir
  test "profile evals share mission state and persist outside the source", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    output =
      capture_io(fn ->
        Repl.run([
          "--profile",
          "log-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "-e",
          "(def runs (log/runs {}))",
          "-e",
          "(count (get runs \"items\"))"
        ])
      end)

    assert output =~ "#'runs\n"
    assert output =~ "1\n"
    assert output =~ "Analysis trace:"
    assert File.ls!(source) == ["seed.jsonl"]
    assert [trace_name] = File.ls!(output_directory)
    assert String.starts_with?(trace_name, "log-analysis-")
    assert String.ends_with?(trace_name, ".jsonl")
    assert log_analysis_session_pids() == before_sessions

    trace_path = Path.join(output_directory, trace_name)
    assert {:ok, trace} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"name" => name, "session_profile" => profile}]}} =
             TraceLog.query(trace, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("ptc.log-analysis.repl")
    assert profile["id"] == "log-analysis-v1"
    assert profile["digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  @tag :tmp_dir
  test "profile load, script, stdin, and interactive inputs use mission evaluation", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    File.mkdir!(source)
    seed_trace(source, "seed")

    for {suffix, input, args, expected} <- [
          {"load", "",
           [
             "--load",
             write_file(directory, "setup.lisp", "(def loaded 41)"),
             "-e",
             "(+ loaded 1)"
           ], "42"},
          {"script", "",
           [write_file(directory, "script.lisp", "(count (get (log/runs {}) \"items\"))")], "1"},
          {"stdin", "(count (get (log/runs {}) \"items\"))", ["-"], "1"},
          {"interactive", "(count (get (log/runs {}) \"items\"))\n", [], "1"}
        ] do
      output_directory = Path.join(directory, suffix)
      File.mkdir!(output_directory)

      command =
        [
          "--profile",
          "log-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory
        ] ++ args

      output = capture_io(input, fn -> Repl.run(command) end)
      assert output =~ expected
      assert Enum.count(File.ls!(output_directory), &String.ends_with?(&1, ".jsonl")) == 1
      Mix.Task.reenable("ptc.repl")
    end
  end

  @tag :tmp_dir
  test "JSONL continue-on-error preserves later feedback and exits unsuccessfully", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/one or more profile evaluations failed/, fn ->
          Repl.run([
            "--profile",
            "log-analysis-v1",
            "--resource",
            "traces=#{source}",
            "--session-trace-dir",
            output_directory,
            "--format",
            "jsonl",
            "--continue-on-error",
            "-e",
            "(def x 40)",
            "-e",
            "missing-value",
            "-e",
            "(+ x 2)"
          ])
        end
      end)

    records = decode_jsonl(output)

    assert Enum.map(records, & &1["type"]) ==
             [
               "session-started",
               "evaluation",
               "evaluation",
               "evaluation",
               "session-closed",
               "command-error"
             ]

    evaluations = Enum.filter(records, &(&1["type"] == "evaluation"))
    assert Enum.map(evaluations, & &1["result"]["status"]) == ["ok", "error", "ok"]
    assert List.last(evaluations)["result"]["value"] == 42
    assert List.first(evaluations)["result"]["value_available"] == true
    assert List.first(evaluations)["result"]["formatted_truncated"] == false
    assert Enum.at(evaluations, 1)["result"]["continuation_effect"] == "preserved"
    assert List.last(records)["evaluation_indexes"] == [2]
    assert File.regular?(Enum.at(records, -2)["trace_path"])
    assert log_analysis_session_pids() == before_sessions
  end

  @tag :tmp_dir
  test "JSONL stops at the first evaluation error without continue-on-error", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/profile evaluation failed/, fn ->
          Repl.run(
            profile_args(source, output_directory) ++
              [
                "--format",
                "jsonl",
                "-e",
                "(def x 40)",
                "-e",
                "missing-value",
                "-e",
                "(+ x 2)"
              ]
          )
        end
      end)

    records = decode_jsonl(output)
    evaluations = Enum.filter(records, &(&1["type"] == "evaluation"))
    assert length(evaluations) == 2
    assert List.last(records)["category"] == "evaluation"
  end

  @tag :tmp_dir
  test "profile mode rejects nested and symlink-parent output directories", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    nested = Path.join(source, "nested")
    alias_root = Path.join(directory, "alias")
    deep = Path.join(source, "deep")
    deep_output = Path.join(deep, "output")
    File.mkdir!(source)
    File.mkdir!(nested)
    File.mkdir!(deep)
    File.mkdir!(deep_output)
    seed_trace(source, "seed")

    assert_raise Mix.Error, ~r/physically separate/, fn ->
      Repl.run(profile_args(source, nested) ++ ["-e", "42"])
    end

    Mix.Task.reenable("ptc.repl")
    File.ln_s!(directory, alias_root)
    aliased_nested = Path.join(alias_root, "source/nested")

    assert_raise Mix.Error, ~r/physically separate/, fn ->
      Repl.run(profile_args(source, aliased_nested) ++ ["-e", "42"])
    end

    Mix.Task.reenable("ptc.repl")
    File.rm!(alias_root)
    File.ln_s!(deep, alias_root)

    assert_raise Mix.Error, ~r/physically separate/, fn ->
      Repl.run(profile_args(source, Path.join(alias_root, "output")) ++ ["-e", "42"])
    end

    assert File.ls!(nested) == []
  end

  @tag :tmp_dir
  test "profile JSONL uses a private temporary output when none is supplied", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    File.mkdir!(source)
    seed_trace(source, "seed")

    output =
      capture_io(fn ->
        Repl.run([
          "--profile",
          "log-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--format",
          "jsonl",
          "-e",
          "(do (def jsonl-source-sentinel 40) 42)"
        ])
      end)

    closed = output |> decode_jsonl() |> Enum.find(&(&1["type"] == "session-closed"))
    trace_path = closed["trace_path"]
    assert File.regular?(trace_path)
    refute output =~ "jsonl-source-sentinel"
    refute File.read!(trace_path) =~ "jsonl-source-sentinel"
    refute Path.dirname(trace_path) == source
    assert Bitwise.band(File.stat!(Path.dirname(trace_path)).mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "profile input and persistence failures terminate session owners", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    input_output = Path.join(directory, "input-output")
    persistence_output = Path.join(directory, "persistence-output")
    File.mkdir!(source)
    File.mkdir!(input_output)
    File.mkdir!(persistence_output)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    capture_io(fn ->
      assert_raise Mix.Error, ~r/could not read the profile script/, fn ->
        Repl.run(profile_args(source, input_output) ++ [Path.join(directory, "missing.lisp")])
      end
    end)

    assert log_analysis_session_pids() == before_sessions
    Mix.Task.reenable("ptc.repl")
    File.chmod!(persistence_output, 0o500)

    try do
      capture_io(fn ->
        assert_raise Mix.Error, ~r/profile trace persistence failed/, fn ->
          Repl.run(profile_args(source, persistence_output) ++ ["-e", "42"])
        end
      end)

      assert log_analysis_session_pids() == before_sessions
    after
      File.chmod!(persistence_output, 0o700)
    end
  end

  test "profile option combinations fail closed" do
    for args <- [
          ["--resource", "traces=tmp"],
          ["--no-continue-on-error", "-e", "42"],
          ["--profile", "unknown", "--resource", "traces=tmp"],
          ["--profile", "log-analysis-v1", "--manifest", "ptc.json", "--resource", "traces=tmp"],
          [
            "--profile",
            "log-analysis-v1",
            "--resource",
            "traces=tmp",
            "--resource",
            "traces=tmp"
          ],
          ["--profile", "log-analysis-v1", "--resource", "other=tmp"],
          ["--profile", "log-analysis-v1", "--resource", "traces=tmp", "--format", "jsonl"],
          [
            "--profile",
            "log-analysis-v1",
            "--resource",
            "traces=tmp",
            "--continue-on-error",
            "-e",
            "42"
          ]
        ] do
      capture_io(fn -> assert_raise Mix.Error, fn -> Repl.run(args) end end)
      Mix.Task.reenable("ptc.repl")
    end
  end

  @tag :tmp_dir
  test "profile files, stdin, and interactive input are bounded before evaluation", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    File.mkdir!(source)
    seed_trace(source, "seed")
    oversized = String.duplicate("x", 65_537)
    oversized_file = write_file(directory, "oversized.lisp", oversized)

    for {input, suffix, args} <- [
          {"", "load", ["--load", oversized_file, "-e", "42"]},
          {"", "script", [oversized_file]},
          {oversized, "stdin", ["-"]},
          {oversized, "interactive", []}
        ] do
      output_directory = Path.join(directory, suffix)
      File.mkdir!(output_directory)

      capture_io(input, fn ->
        assert_raise Mix.Error, ~r/profile .* exceeds the 65536-byte source limit/, fn ->
          Repl.run(profile_args(source, output_directory) ++ args)
        end
      end)

      Mix.Task.reenable("ptc.repl")
    end
  end

  @tag :tmp_dir
  test "profile JSONL works through an actual Mix subprocess", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")

    {output, 0} =
      System.cmd(
        "mix",
        [
          "ptc.repl",
          "--profile",
          "log-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "--format",
          "jsonl",
          "-e",
          "(count (get (log/runs {}) \"items\"))"
        ],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"}]
      )

    records = decode_mix_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]
    assert Enum.at(records, 1)["result"]["value"] == 1
    assert File.regular?(List.last(records)["trace_path"])
  end

  defp profile_args(source, output_directory) do
    [
      "--profile",
      "log-analysis-v1",
      "--resource",
      "traces=#{source}",
      "--session-trace-dir",
      output_directory
    ]
  end

  defp decode_jsonl(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp decode_mix_jsonl(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "==> "))
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_file(directory, name, contents) do
    file = Path.join(directory, name)
    File.write!(file, contents)
    file
  end

  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end

  defp log_analysis_session_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          dictionary[:"$initial_call"] == {PtcRunner.Kernel.LogAnalysisSession, :init, 1}

        nil ->
          false
      end
    end)
    |> Enum.sort()
  end
end
