defmodule PtcRunner.ReplFrontendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.MixCommandAdapter

  @stdio_root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

  test "repeated evals preserve definitions, history, and captured output" do
    output =
      capture_io(fn ->
        run_repl([
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
    output = capture_io("(println 42)\n", fn -> run_repl([]) end)
    assert output =~ "42\nnil"
    assert output =~ "Goodbye!"
  end

  test ":doc exposes numeric comparison failures" do
    output = capture_io(":doc >\n", fn -> run_repl([]) end)

    assert output =~ "(> x y & more)"
    assert output =~ "Numeric only; a reached non-numeric operand signals :type_error."
  end

  test "empty stdin is a successful empty script" do
    assert "" = capture_io("", fn -> run_repl(["-"]) end)
  end

  test "manifest-only host authority is rejected by direct mode" do
    assert_raise Mix.Error, ~r/arguments\/invalid_arguments/, fn ->
      run_repl(["--host-config", "missing-host.json", "-e", "42"])
    end
  end

  @tag :tmp_dir
  test "a strict manifest supplies the REPL workflow bundle", %{tmp_dir: directory} do
    component_path = Path.join(directory, "helpers.clj")
    manifest_path = Path.join(directory, "ptc.json")

    File.write!(
      component_path,
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"value" => %{}}
      })
    )

    output =
      capture_io(fn -> run_repl(["--manifest", manifest_path, "-e", "(helpers/answer)"]) end)

    assert output == "42\n"
  end

  @tag :tmp_dir
  test "--trace persists canonical session events through the shared loader", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "repl.jsonl")
    assert "3\n" = capture_io(fn -> run_repl(["--trace", path, "-e", "(+ 1 2)"]) end)
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
  test "direct trace destinations fail before opening a session", %{tmp_dir: directory} do
    assert_raise Mix.Error, ~r/ptc repl setup failed: :trace_preflight_failed/, fn ->
      run_repl(["--trace", directory, "-e", "(+ 1 2)"])
    end
  end

  @tag :tmp_dir
  test "a private manifest rejects eval before authorizing its trace", %{tmp_dir: directory} do
    component_path = Path.join(directory, "helpers.clj")
    manifest_path = Path.join(directory, "private.json")
    trace_path = Path.join(directory, "private.private.jsonl")

    File.write!(
      component_path,
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"value" => %{}},
        "events" => %{"policy" => "private"}
      })
    )

    assert_raise Mix.Error, ~r/private manifest REPL is interactive-only/, fn ->
      run_repl([
        "--manifest",
        manifest_path,
        "--trace",
        trace_path,
        "--private-terminal",
        "-e",
        "42"
      ])
    end

    refute File.exists?(trace_path)
  end

  @tag :tmp_dir
  test "a provider-backed manifest requires host authority before runtime work", %{
    tmp_dir: directory
  } do
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    manifest_path = Path.join(directory, "provider.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [%{"name" => "workspace", "config" => %{}}],
          "mission" => []
        },
        "input" => %{"value" => %{}}
      })
    )

    assert_raise Mix.Error, ~r/provider-backed manifest requires --host-config/, fn ->
      run_repl(["--manifest", manifest_path, "-e", "42"])
    end
  end

  @tag :tmp_dir
  test "a host-backed manifest acquires once and reuses one provider session", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "provider-lifecycle")
    manifest_path = Path.join(directory, "provider-repl.json")
    host_path = Path.join(directory, "ptc-host.json")

    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [],
          "mission" => [
            %{"name" => "workspace", "config" => %{"allow" => ["workspace.structured"]}}
          ]
        },
        "input" => %{"value" => %{}},
        "limits" => %{"evaluation_timeout_ms" => 5_000, "run_duration_ms" => 20_000}
      })
    )

    File.write!(
      host_path,
      Jason.encode!(%{
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "repl-stdio-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "cwd" => @stdio_root,
              "args" => [@stdio_fixture, marker, "mark-close"],
              "start_timeout_ms" => 5_000
            },
            "tools" => %{
              "structured" => %{
                "as" => "workspace.structured",
                "effect" => "write",
                "model_visible" => true
              }
            },
            "ceilings" => %{"timeout_ms" => 5_000}
          }
        }
      })
    )

    output =
      capture_io(fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--host-config",
          host_path,
          "-e",
          "(def x 41)",
          "-e",
          "(+ x 1)"
        ])
      end)

    assert output =~ "#'x\n42\n"

    lifecycle = marker |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lifecycle, &String.ends_with?(&1, ":server/discover")) == 1
    assert Enum.count(lifecycle, &String.ends_with?(&1, ":tools/list")) == 2
    assert Enum.count(lifecycle, &(&1 == "session-closed")) == 1
  end

  @tag :tmp_dir
  test "-l evaluates setup before entering the REPL", %{tmp_dir: directory} do
    path = Path.join(directory, "setup.clj")
    File.write!(path, "(def loaded 41)")
    output = capture_io("(+ loaded 1)\n", fn -> run_repl(["-l", path]) end)
    assert output =~ "Loaded #{path}"
    assert output =~ "42"
  end

  test "removed upstream and special log options fail closed" do
    assert_raise Mix.Error, ~r/unknown switch; accepted:/, fn ->
      run_repl(["--log-prelude", "-e", "(+ 1 2)"])
    end
  end

  test "eval and positional script modes are mutually exclusive" do
    assert_raise Mix.Error, ~r/arguments\/conflicting_arguments/, fn ->
      run_repl(["-e", "42", "script.clj"])
    end
  end

  test "removed configurable history depth fails closed" do
    assert_raise Mix.Error, ~r/unknown switch; accepted:/, fn ->
      run_repl(["--history-depth", "0", "--manifest", "missing.json"])
    end
  end

  test "describes the fixed log-analysis profile as safe JSONL" do
    output =
      capture_io(fn ->
        run_repl(["--describe-profile", "log-analysis-v2", "--format", "jsonl"])
      end)

    assert [description] = decode_jsonl(output)
    assert description["type"] == "profile"
    assert description["id"] == "log-analysis-v2"
    assert description["components"] == ["cap", "log.core", "log.analysis"]
    assert description["namespaces"] == ["cap", "log", "log.analysis"]
    assert description["resources"]["traces"]["required"] == true
    assert description["frontend"]["output_formats"] == ["clojure", "jsonl"]
    refute output =~ "#Function<"
    refute output =~ File.cwd!()
  end

  test "unknown profiles report the accepted profile ids" do
    assert_raise Mix.Error,
                 ~r/unsupported session profile; accepted: inspection-analysis-v2, log-analysis-v2/,
                 fn ->
                   run_repl(["--describe-profile", "missing-profile"])
                 end
  end

  test "private profile frontend policy fails before opening declared sources" do
    missing_resources = [
      "--profile",
      "inspection-analysis-v2",
      "--resource",
      "traces=/definitely/missing/private-traces",
      "--resource",
      "inspection=/definitely/missing/private-inspection",
      "--session-trace-dir",
      "/definitely/missing/private-output"
    ]

    for {suffix, message} <- [
          {[], ~r/requires --private-terminal/},
          {["--private-terminal"], ~r/requires attached stdin and stdout terminals/},
          {["--private-terminal", "-e", "42"], ~r/interactive-only/},
          {["--private-terminal", "--format", "jsonl"], ~r/arguments\/invalid_arguments/},
          {["--private-terminal", "--private-unattended"], ~r/conflicting_arguments/}
        ] do
      capture_io(fn ->
        assert_raise Mix.Error, message, fn -> run_repl(missing_resources ++ suffix) end
      end)
    end
  end

  test "private_unattended admits eval and jsonl output, reaching source preflight" do
    args = [
      "--profile",
      "inspection-analysis-v2",
      "--resource",
      "traces=/definitely/missing/private-traces",
      "--resource",
      "inspection=/definitely/missing/private-inspection",
      "--session-trace-dir",
      "/definitely/missing/private-output",
      "--private-unattended",
      "--format",
      "jsonl",
      "-e",
      "(+ 1 1)"
    ]

    capture_io(fn ->
      assert_raise Mix.Error, ~r/must be existing directories/, fn -> run_repl(args) end
    end)
  end

  test "private_unattended with jsonl and no input is rejected, not silently interactive" do
    args = [
      "--profile",
      "inspection-analysis-v2",
      "--resource",
      "traces=/definitely/missing/private-traces",
      "--resource",
      "inspection=/definitely/missing/private-inspection",
      "--session-trace-dir",
      "/definitely/missing/private-output",
      "--private-unattended",
      "--format",
      "jsonl"
    ]

    capture_io(fn ->
      assert_raise Mix.Error, ~r/arguments\/invalid_arguments/, fn ->
        run_repl(args)
      end
    end)
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
        run_repl([
          "--profile",
          "log-analysis-v2",
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

    assert output =~ "Captured traces: 1 file, 1 run"
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
    assert profile["id"] == "log-analysis-v2"
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
             write_file(directory, "setup.clj", "(def loaded 41)"),
             "-e",
             "(+ loaded 1)"
           ], "42"},
          {"script", "",
           [write_file(directory, "script.clj", "(count (get (log/runs {}) \"items\"))")], "1"},
          {"stdin", "(count (get (log/runs {}) \"items\"))", ["-"], "1"},
          {"interactive", "(count (get (log/runs {}) \"items\"))\n", [], "1"}
        ] do
      output_directory = Path.join(directory, suffix)
      File.mkdir!(output_directory)

      command =
        [
          "--profile",
          "log-analysis-v2",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory
        ] ++ args

      output = capture_io(input, fn -> run_repl(command) end)
      assert output =~ expected
      assert Enum.count(File.ls!(output_directory), &String.ends_with?(&1, ".jsonl")) == 1
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
          run_repl([
            "--profile",
            "log-analysis-v2",
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

    assert List.first(records)["capture"] == %{
             "traces" => %{"file_count" => 1, "run_count" => 1}
           }

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
          run_repl(
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
  test "a resource directory whose traces sit one level down is refused", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    nested = Path.join(source, "run-tag")
    File.mkdir_p!(nested)
    File.mkdir!(output_directory)
    seed_trace(nested, "seed")

    assert_raise Mix.Error,
                 ~r/the traces resource directory contains no \*\.jsonl trace files at its own level/,
                 fn ->
                   run_repl(profile_args(source, output_directory) ++ ["-e", "42"])
                 end

    assert File.ls!(output_directory) == []
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
      run_repl(profile_args(source, nested) ++ ["-e", "42"])
    end

    File.ln_s!(directory, alias_root)
    aliased_nested = Path.join(alias_root, "source/nested")

    assert_raise Mix.Error, ~r/physically separate/, fn ->
      run_repl(profile_args(source, aliased_nested) ++ ["-e", "42"])
    end

    File.rm!(alias_root)
    File.ln_s!(deep, alias_root)

    assert_raise Mix.Error, ~r/physically separate/, fn ->
      run_repl(profile_args(source, Path.join(alias_root, "output")) ++ ["-e", "42"])
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
        run_repl([
          "--profile",
          "log-analysis-v2",
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
        run_repl(profile_args(source, input_output) ++ [Path.join(directory, "missing.clj")])
      end
    end)

    assert log_analysis_session_pids() == before_sessions
    File.chmod!(persistence_output, 0o500)

    try do
      capture_io(fn ->
        assert_raise Mix.Error, ~r/profile trace persistence failed/, fn ->
          run_repl(profile_args(source, persistence_output) ++ ["-e", "42"])
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
          ["--profile", "log-analysis-v2", "--manifest", "ptc.json", "--resource", "traces=tmp"],
          [
            "--profile",
            "log-analysis-v2",
            "--resource",
            "traces=tmp",
            "--resource",
            "traces=tmp"
          ],
          ["--profile", "log-analysis-v2", "--resource", "other=tmp"],
          ["--profile", "log-analysis-v2", "--resource", "traces=tmp", "--format", "jsonl"],
          [
            "--profile",
            "log-analysis-v2",
            "--resource",
            "traces=tmp",
            "--continue-on-error",
            "-e",
            "42"
          ]
        ] do
      capture_io(fn -> assert_raise Mix.Error, fn -> run_repl(args) end end)
    end
  end

  @tag :tmp_dir
  @tag :slow
  test "profile files, stdin, and interactive input are bounded before evaluation", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    File.mkdir!(source)
    seed_trace(source, "seed")
    oversized = String.duplicate("x", 65_537)
    oversized_file = write_file(directory, "oversized.clj", oversized)

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
          run_repl(profile_args(source, output_directory) ++ args)
        end
      end)
    end
  end

  @tag :tmp_dir
  @tag :slow
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
          "ptc",
          "repl",
          "--profile",
          "log-analysis-v2",
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

  defp run_repl(args), do: MixCommandAdapter.run_task(["repl" | args]).outcome

  defp profile_args(source, output_directory) do
    [
      "--profile",
      "log-analysis-v2",
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

  # ex_dna:disable-for-next-line — boundary test keeps its trace fixture local and explicit
  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{missions: %{}})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end

  defp log_analysis_session_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          dictionary[:"$initial_call"] == {PtcRunner.Kernel.AnalysisSession, :init, 1}

        nil ->
          false
      end
    end)
    |> Enum.sort()
  end
end
