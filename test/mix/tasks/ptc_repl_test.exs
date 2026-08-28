defmodule PtcRunner.ReplFrontendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.NamespaceDiagnostic
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.TestSupport.PrivateInspectionFixture

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

  test "direct REPL uses configurable bounded structural previews" do
    payload = String.duplicate("x", 10_000)
    source = ~s|{"aaa_payload" "#{payload}" "status" "ok" "trace_id" "trace-1"}|

    output =
      capture_io(fn ->
        run_repl(["--preview-chars", "256", "-e", source])
      end)

    assert output =~ ~S|"status"|
    assert output =~ ~S|"trace_id"|
    assert output =~ "preview truncated"
    refute output =~ String.duplicate("x", 1_000)
    assert output |> String.split("\n", trim: true) |> hd() |> String.length() <= 256
  end

  test "direct eval reports the first surplus closer to developers" do
    output =
      capture_io(:stderr, fn ->
        error = assert_raise Mix.Error, fn -> run_repl(["-e", "(+ 1 2))"]) end

        assert error.message =~
                 "Error (parse_error): unbalanced parentheses: 1 extra ')' " <>
                   "(first at line 1, column 8)"
      end)

    assert output ==
             "Error (parse_error): unbalanced parentheses: 1 extra ')' " <>
               "(first at line 1, column 8)\n"
  end

  test "direct eval uses the public arithmetic renderer" do
    output =
      capture_io(:stderr, fn ->
        error = assert_raise Mix.Error, fn -> run_repl(["-e", "(/ 1 0)"]) end

        assert error.message =~ "Error (arithmetic_error): division by zero"
        refute error.message =~ "PtcRunner.Lisp"
      end)

    assert output =~ "Error (arithmetic_error): division by zero"
    refute output =~ "PtcRunner.Lisp"
  end

  test "direct eval retains canonical unknown-namespace guidance" do
    expected =
      "Error (invalid_form): " <> NamespaceDiagnostic.message("kernel")

    output =
      capture_io(:stderr, fn ->
        error =
          assert_raise Mix.Error, fn ->
            run_repl(["-e", ~S|(kernel/mission-model-context "reader")|])
          end

        assert String.starts_with?(
                 error.message,
                 "error: repl/command_failed: Error (invalid_form): " <>
                   "unknown namespace kernel/"
               )
      end)

    assert output == expected <> "\n"
  end

  test "direct eval renders a type_error kind only once" do
    output =
      capture_io(:stderr, fn ->
        error =
          assert_raise Mix.Error, fn ->
            run_repl(["-e", ~S|(str/split "a-VERDICT-b" "VERDICT")|])
          end

        assert String.starts_with?(
                 error.message,
                 "error: repl/command_failed: Error (type_error): split: " <>
                   "delimiter must be a regex pattern"
               )

        refute error.message =~ "type_error: type_error"
      end)

    assert output ==
             "Error (type_error): split: delimiter must be a regex pattern, " <>
               "got plain string \"VERDICT\"\n"
  end

  test "interactive mode prints output and exits on EOF" do
    output = capture_io("(println 42)\n", fn -> run_repl([]) end)
    assert output =~ "42\nnil"
    assert output =~ "Goodbye!"
  end

  test "direct interactive sessions exceed the ordinary evaluation ceiling with or without a TTY" do
    input = Enum.map_join(1..140, "", &"#{&1}\n")

    for terminal_attached? <- [false, true] do
      output =
        capture_io(input, fn ->
          run_repl([], terminal_attached: terminal_attached?)
        end)

      assert output =~ "140\n"
      assert output =~ "Goodbye!"
      refute output =~ "subordinate_evaluations limit"
    end
  end

  @tag :tmp_dir
  test "a setup load followed by the direct line loop receives the interactive profile", %{
    tmp_dir: directory
  } do
    setup = Path.join(directory, "setup.clj")
    File.write!(setup, "(def loaded 42)")
    input = String.duplicate("loaded\n", 129)

    output = capture_io(input, fn -> run_repl(["--load", setup]) end)

    assert output =~ "Loaded #{setup}"
    assert output =~ "42\n"
    assert output =~ "Goodbye!"
    refute output =~ "subordinate_evaluations limit"
  end

  test "direct repeated eval retains the ordinary session ceiling" do
    arguments = Enum.flat_map(1..129, &["--eval", Integer.to_string(&1)])

    stderr =
      capture_io(:stderr, fn ->
        _stdout =
          capture_io(fn ->
            error = assert_raise Mix.Error, fn -> run_repl(arguments) end

            assert error.message =~
                     "subordinate_evaluations limit 128 was exceeded"

            refute error.message =~ "manifest"
          end)
      end)

    assert stderr =~ "subordinate_evaluations limit 128 was exceeded"
    refute stderr =~ "manifest"
  end

  @tag :tmp_dir
  test "a terminal session failure prints once and stops before another prompt", %{
    tmp_dir: directory
  } do
    manifest = Path.join(directory, "terminal-limit.json")
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [input] (return input))")

    File.write!(
      manifest,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{}},
        "limits" => %{"subordinate_evaluations" => 1}
      })
    )

    output =
      capture_io("101\n202\n303\n", fn ->
        error =
          assert_raise Mix.Error, fn ->
            run_repl(["--manifest", manifest], terminal_attached: false)
          end

        assert error.message =~ "subordinate_evaluations limit 1 was exceeded"
      end)

    assert length(String.split(output, "ptc> ")) - 1 == 2
    assert output =~ "101\n"
    refute output =~ "303\n"
    refute output =~ "subordinate_evaluations limit"
  end

  test "Lisp doc replaces the removed :doc meta-command" do
    output = capture_io(":doc >\n(doc \">\")\n:quit\n", fn -> run_repl([]) end)

    assert output =~ "Unknown command. Available: :help, :quit"
    assert output =~ "(> x y & more)"
    assert output =~ "Numeric only; a reached non-numeric operand signals :type_error."
  end

  test "attached interactive sessions hint at the canonical discovery functions" do
    output = capture_io(":help\n:quit\n", fn -> run_repl([], terminal_attached: true) end)

    assert output =~
             ~S|Explore functions with (apropos "term") and (doc "name"); inspect attached APIs with (dir), (export-meta "ns/name"), and (source ns/name).|

    assert output =~ "Commands:\n  :help"

    detached = capture_io(":quit\n", fn -> run_repl([], terminal_attached: false) end)
    noninteractive = capture_io(fn -> run_repl(["-e", "42"], terminal_attached: true) end)

    refute detached =~ "Explore functions with"
    refute noninteractive =~ "Explore functions with"
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
  test "a manifest mission session uses mission components and data without workflow access", %{
    tmp_dir: directory
  } do
    manifest_path = Path.join(directory, "ptc.json")

    File.write!(
      Path.join(directory, "workflow.clj"),
      "(ns workflow) (defn secret [] 99) (defn run [input] (return input))"
    )

    File.write!(
      Path.join(directory, "review.clj"),
      "(ns review) (defn answer [] data/answer)"
    )

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "workflow", "path" => "workflow.clj"}],
          "entry" => "workflow/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "review.clj"}],
            "data" => %{"answer" => 42}
          }
        },
        "input" => %{"value" => %{}}
      })
    )

    output =
      capture_io(fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--mission",
          "review",
          "--preview-chars",
          "256",
          "-e",
          "(review/answer)",
          "-e",
          "(dir)",
          "-e",
          ~s|{"payload" "#{String.duplicate("x", 10_000)}" "status" "ok"}|
        ])
      end)

    assert output =~ "42\n"
    assert output =~ ~s(["review"])
    assert output =~ "preview truncated"
    assert output =~ ~S|"status"|
    refute output =~ String.duplicate("x", 1_000)
    refute output =~ "workflow/secret"

    assert_raise Mix.Error, ~r/unknown namespace workflow\//, fn ->
      run_repl([
        "--manifest",
        manifest_path,
        "--mission",
        "review",
        "-e",
        "(workflow/secret)"
      ])
    end
  end

  @tag :tmp_dir
  test "an unknown manifest mission lists declared names before opening a session", %{
    tmp_dir: directory
  } do
    manifest_path = Path.join(directory, "ptc.json")
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{"writing" => %{}, "review" => %{}, "default" => %{}},
        "input" => %{"value" => %{}}
      })
    )

    assert_raise Mix.Error,
                 ~r/unknown mission "revie"; declared: default, review, writing/,
                 fn ->
                   run_repl([
                     "--manifest",
                     manifest_path,
                     "--mission",
                     "revie",
                     "-e",
                     "42"
                   ])
                 end
  end

  @tag :tmp_dir
  test "an unknown namespace in a workflow session names the switch that opens a mission", %{
    tmp_dir: directory
  } do
    manifest_path = write_workflow_repl_manifest(directory)

    # The analyzer lists thirty-odd language namespaces and names no mission,
    # because a workflow session carries none. Which switch would add them is a
    # REPL fact the analyzer cannot know.
    error =
      assert_raise Mix.Error, fn ->
        run_repl(["--manifest", manifest_path, "-e", "(review/summarize 1)"])
      end

    assert error.message =~ "unknown namespace review/"
    assert error.message =~ "--mission NAME"
    assert error.message =~ "declared: review, writing"
  end

  @tag :tmp_dir
  test "calling the granted workflow input in a workflow session still names the switch that opens a mission",
       %{tmp_dir: directory} do
    manifest_path = write_workflow_repl_manifest(directory)

    error =
      assert_raise Mix.Error, fn ->
        run_repl(["--manifest", manifest_path, "-e", "(data/input)"])
      end

    assert error.message =~ "data/input is not callable"
    assert error.message =~ "--mission NAME"
    assert error.message =~ "declared: review, writing"
  end

  @tag :tmp_dir
  test "an ungranted data name in a workflow session is rejected and still names the switch",
       %{tmp_dir: directory} do
    manifest_path = write_workflow_repl_manifest(directory)

    # Strict workflow lookup answers before callability, so the miss -- not
    # `not_callable` -- is what has to carry the hint.
    error =
      assert_raise Mix.Error, fn ->
        run_repl(["--manifest", manifest_path, "-e", "(data/tickets)"])
      end

    assert error.message =~ "data/tickets is not a granted data name"
    assert error.message =~ "Granted: data/input"
    assert error.message =~ "--mission NAME"
    assert error.message =~ "declared: review, writing"
  end

  @tag :tmp_dir
  test "a workflow session does not hint --mission for an error that merely quotes the grant diagnostic",
       %{tmp_dir: directory} do
    manifest_path = write_workflow_repl_manifest(directory)

    error =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "-e",
          ~S|(let [x "data/foo is not a granted data name. Granted: x"] (x))|
        ])
      end

    assert error.message =~ "value is not callable"
    refute error.message =~ "--mission NAME"
  end

  @tag :tmp_dir
  test "a bare misspelled data name in a workflow session is rejected instead of answering nil",
       %{
         tmp_dir: directory
       } do
    manifest_path = write_workflow_repl_manifest(directory)

    error =
      assert_raise Mix.Error, fn ->
        run_repl(["--manifest", manifest_path, "-e", "data/inupt"])
      end

    assert error.message =~ "data/inupt is not a granted data name"
    assert error.message =~ "Granted: data/input"
  end

  @tag :tmp_dir
  test "a workflow session does not hint --mission for an unrelated not_callable string", %{
    tmp_dir: directory
  } do
    manifest_path = write_workflow_repl_manifest(directory)

    error =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "-e",
          ~S|(let [x "not callable: data/tickets"] (x))|
        ])
      end

    assert error.message =~ "value is not callable"
    refute error.message =~ "--mission NAME"
  end

  @tag :tmp_dir
  test "a mission session resolves data grants, rejects misses, and does not render called values",
       %{
         tmp_dir: directory
       } do
    manifest_path = Path.join(directory, "ptc.json")
    sentinel = "SECRET_TICKET_SENTINEL"
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    File.write!(
      Path.join(directory, "review.clj"),
      "(ns review) (defn answer [] data/tickets)"
    )

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "review.clj"}],
            "data" => %{"tickets" => [sentinel], "orders" => []}
          }
        },
        "input" => %{"value" => %{}}
      })
    )

    output =
      capture_io(fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--mission",
          "review",
          "-e",
          "data/tickets"
        ])
      end)

    assert output =~ sentinel

    missing =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--mission",
          "review",
          "-e",
          "data/nosuch"
        ])
      end

    assert missing.message =~ "data/nosuch is not a granted data name"
    assert missing.message =~ "data/orders"
    assert missing.message =~ "data/tickets"
    refute missing.message =~ sentinel

    called =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--mission",
          "review",
          "-e",
          "(data/tickets)"
        ])
      end

    assert called.message =~ "data/tickets is not callable"
    refute called.message =~ sentinel
  end

  @tag :tmp_dir
  test "kernel/eval-source from a workflow session names --mission instead of :busy", %{
    tmp_dir: directory
  } do
    manifest_path = Path.join(directory, "ptc.json")
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["kernel"]},
            %{"library" => "kernel"}
          ],
          "entry" => "app/run"
        },
        "missions" => %{"writing" => %{}, "review" => %{}},
        "input" => %{"value" => %{}}
      })
    )

    error =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "-e",
          ~S|(kernel/eval-source "review" "(return 1)")|
        ])
      end

    assert error.message =~ "Error (mission_session_required):"
    assert error.message =~ "--mission NAME"
    assert error.message =~ "declared: review, writing"
    refute error.message =~ "evaluation_in_progress"
  end

  @tag :tmp_dir
  test "a direct session with no declared mission adds no switch it cannot honour", %{
    tmp_dir: _directory
  } do
    error = assert_raise Mix.Error, fn -> run_repl(["-e", "(review/summarize 1)"]) end

    assert error.message =~ "unknown namespace review/"
    refute error.message =~ "--mission"
  end

  test "--mission is manifest-only and cannot select a code-owned profile" do
    assert_raise Mix.Error, ~r/--mission requires --manifest/, fn ->
      run_repl(["--mission", "review", "-e", "42"])
    end

    assert_raise Mix.Error, ~r/--mission cannot be combined with --profile/, fn ->
      run_repl([
        "--mission",
        "review",
        "--profile",
        "run-analysis-v1",
        "--resource",
        "traces=/missing",
        "-e",
        "42"
      ])
    end
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
  test "a missing environment file renders its concrete cause", %{
    tmp_dir: directory
  } do
    # The REPL takes --env-file too and preserves the same closed cause as run
    # and doctor rather than collapsing it into the generic file constraint.
    manifest_path = Path.join(directory, "env.json")
    File.write!(Path.join(directory, "main.clj"), "(ns main) (defn run [input] (return input))")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{}},
        "providers" => %{"workflow" => [%{"name" => "model"}], "mission" => []}
      })
    )

    host_path = Path.join(directory, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_REPL_ABSENT_KEY"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    assert_raise Mix.Error, ~r/named environment file does not exist/, fn ->
      run_repl([
        "--manifest",
        manifest_path,
        "--host-config",
        host_path,
        "--env-file",
        Path.join(directory, "absent.env"),
        "-e",
        "(+ 1 2)"
      ])
    end
  end

  @tag :tmp_dir
  test "a missing provider credential retains the run diagnostic and remedy", %{
    tmp_dir: directory
  } do
    {manifest_path, host_path} = write_missing_credential_repl(directory)

    for {mission_args, expected_subject} <- [
          {[], "alpha"},
          {["--mission", "review"], "workspace-alpha"}
        ] do
      error =
        assert_raise Mix.Error, fn ->
          run_repl(
            [
              "--manifest",
              manifest_path,
              "--host-config",
              host_path,
              "-e",
              "(+ 1 2)"
            ] ++ mission_args
          )
        end

      assert error.message =~
               "error: repl/command_failed: active_preflight/credential_unavailable: " <>
                 "provider/#{expected_subject}/credentials: a required provider credential is unavailable; " <>
                 "export it, pass --env-file PATH, or use a host file credential"

      refute error.message =~ "PTC_REPL_ABSENT"
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

  @tag :tmp_dir
  test "-l prints a trailing return as its value", %{tmp_dir: directory} do
    path = Path.join(directory, "setup.clj")
    File.write!(path, "(def loaded 41)\n(return (+ loaded 1))\n")

    output = capture_io(fn -> run_repl(["-l", path, "-e", "loaded"]) end)

    assert output == "42\nLoaded #{path}\n41\n"
    refute output =~ "__ptc_return__"
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

  test "describes the fixed run-analysis profile as safe JSONL" do
    output =
      capture_io(fn ->
        run_repl(["--describe-profile", "run-analysis-v1", "--format", "jsonl"])
      end)

    assert [description] = decode_jsonl(output)
    assert description["type"] == "profile"
    assert description["id"] == "run-analysis-v1"
    assert description["components"] == ["cap", "analysis"]
    assert description["namespaces"] == ["analysis", "cap"]
    assert description["resources"]["traces"]["required"] == true
    assert description["frontend"]["output_formats"] == ["clojure", "jsonl"]
    refute output =~ "#Function<"
    refute output =~ File.cwd!()
  end

  test "unknown profiles report the accepted profile ids" do
    assert_raise Mix.Error,
                 ~r/unsupported session profile; accepted: private-run-analysis-v1, private-run-catalog-v1, run-analysis-v1/,
                 fn ->
                   run_repl(["--describe-profile", "missing-profile"])
                 end
  end

  @tag :tmp_dir
  test "the private catalog profile pages safe rows through the JSONL entry point", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(directory)

    output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "private-run-catalog-v1",
          "--resource",
          "traces=#{fixture.traces}",
          "--resource",
          "inspection=#{fixture.inspection}",
          "--session-trace-dir",
          fixture.output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          "(analysis/catalog {})"
        ])
      end)

    records = decode_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]
    assert hd(records)["profile_id"] == "private-run-catalog-v1"
    assert hd(records)["capture"]["catalog"]["row_count"] == 1

    assert %{
             "items" => [%{"run_id" => run_id, "state" => "admissible"}],
             "catalog_digest" => digest,
             "excluded_files" => excluded_files,
             "truncated" => false,
             "omitted_count" => 0,
             "next_cursor" => nil
           } = Enum.at(records, 1)["result"]["value"]

    assert run_id == fixture.run_id
    assert is_binary(digest)
    assert is_integer(excluded_files)
  end

  test "private profile frontend policy fails before opening declared sources" do
    missing_resources = [
      "--profile",
      "private-run-analysis-v1",
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
        assert_raise Mix.Error, message, fn ->
          run_repl(missing_resources ++ suffix, terminal_attached: false)
        end
      end)
    end
  end

  test "private_unattended admits eval and jsonl output, reaching source preflight" do
    args = [
      "--profile",
      "private-run-analysis-v1",
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
      "private-run-analysis-v1",
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
  test "inspection analysis recursively reads a private V8 trace and correlated result", %{
    tmp_dir: directory
  } do
    value = %{"answer" => 42}
    fixture = PrivateInspectionFixture.create_result!(directory, value, "post-mortem")
    normal_path = Path.join(fixture.traces, "post-mortem.jsonl")
    private_path = Path.join(fixture.traces, "post-mortem.private.jsonl")
    File.rename!(normal_path, private_path)

    output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "private-run-analysis-v1",
          "--resource",
          "traces=#{fixture.traces}",
          "--resource",
          "inspection=#{fixture.inspection}",
          "--session-trace-dir",
          fixture.output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          ~s|(return (analysis/open "#{fixture.run_id}"))|
        ])
      end)

    records = decode_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]

    assert %{
             "run" => %{
               "run_id" => "post-mortem",
               "source" => "private",
               "result_hash" => result_hash
             },
             "result" => %{
               "available?" => true,
               "run_id" => "post-mortem",
               "value" => ^value,
               "result_hash" => result_hash
             }
           } = Enum.at(records, 1)["result"]["value"]

    assert result_hash == fixture.result_hash
  end

  @tag :tmp_dir
  test "private analysis reads the complete prefix of an interrupted run", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create_interrupted!(directory, "interrupted-debugger")
    normal_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")
    private_path = Path.join(fixture.traces, "#{fixture.run_id}.private.jsonl")
    File.rename!(normal_path, private_path)

    output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "private-run-analysis-v1",
          "--resource",
          "traces=#{fixture.traces}",
          "--resource",
          "inspection=#{fixture.inspection}",
          "--session-trace-dir",
          fixture.output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          ~s|(analysis/open "#{fixture.run_id}")|,
          "-e",
          ~s|(analysis/read "#{fixture.run_id}" {"collection" "model_exchanges"})|,
          "-e",
          ~s|(analysis/read "#{fixture.run_id}" {"collection" "capability_calls"})|,
          "-e",
          ~s|(analysis/read "#{fixture.run_id}" {"collection" "turns"})|
        ])
      end)

    records = decode_jsonl(output)

    assert Enum.map(records, & &1["type"]) == [
             "session-started",
             "evaluation",
             "evaluation",
             "evaluation",
             "evaluation",
             "session-closed"
           ]

    [opened, model_page, capability_page, turns_page] =
      records
      |> Enum.filter(&(&1["type"] == "evaluation"))
      |> Enum.map(&get_in(&1, ["result", "value"]))

    assert opened["inspection"]["counts"] == %{
             "capability_calls" => 2,
             "capability_exceptions" => 0,
             "effective_preludes" => 0,
             "evaluation_analyses" => 0,
             "execution_errors" => 0,
             "execution_prints" => 0,
             "explicit_failure_values" => 0,
             "generated_sources" => 0,
             "incomplete_capability_calls" => 1,
             "incomplete_model_exchanges" => 1,
             "model_exchanges" => 2,
             "provider_exchanges" => 0
           }

    assert Enum.map(model_page["items"], & &1["complete?"]) == [true, false]
    assert Enum.map(capability_page["items"], & &1["complete?"]) == [true, false]

    assert get_in(List.last(model_page["items"]), ["arguments", "messages"]) |> List.last() ==
             %{"content" => fixture.interrupted_model_secret, "role" => "user"}

    assert get_in(List.last(capability_page["items"]), ["arguments", "path"]) ==
             fixture.interrupted_tool_secret

    assert turns_page["evidence"]["missing_exchange_count"] == 1

    assert Enum.map(turns_page["items"], & &1["capability_id"]) == [
             "llm-complete-#{fixture.run_id}"
           ]

    closed = List.last(records)
    encoded_trace = File.read!(closed["trace_path"])
    refute encoded_trace =~ fixture.interrupted_model_secret
    refute encoded_trace =~ fixture.interrupted_tool_secret
  end

  @tag :tmp_dir
  test "private analysis isolates inspection paired with a damaged trace", %{
    tmp_dir: directory
  } do
    healthy = PrivateInspectionFixture.create!(directory, "healthy")
    damaged = PrivateInspectionFixture.create!(directory, "damaged")
    PrivateInspectionFixture.rewrite_legacy_float_cost!(damaged)

    output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "private-run-analysis-v1",
          "--resource",
          "traces=#{healthy.traces}",
          "--resource",
          "inspection=#{healthy.inspection}",
          "--session-trace-dir",
          healthy.output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          "(analysis/runs {})"
        ])
      end)

    records = decode_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]

    assert List.first(records)["capture"] == %{
             "inspection" => %{"file_count" => 2, "run_count" => 1},
             "traces" => %{"file_count" => 2, "run_count" => 1}
           }

    assert %{
             "items" => [%{"run_id" => "healthy"}],
             "isolation" => %{
               "component_count" => 1,
               "known_run_count" => 1,
               "reasons" => [%{"reason" => "malformed_event"}],
               "examples" => [%{"sources" => ["damaged.jsonl"]}]
             }
           } = Enum.at(records, 1)["result"]["value"]
  end

  @tag :tmp_dir
  test "inspection profile setup explains an unsupported artifact schema", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(directory, "old-schema")
    PrivateInspectionFixture.rewrite_schema!(fixture.inspection, 4)

    message =
      ~r/ptc repl profile setup failed: malformed_source/

    capture_io(fn ->
      assert_raise Mix.Error, message, fn ->
        run_repl([
          "--profile",
          "private-run-analysis-v1",
          "--resource",
          "traces=#{fixture.traces}",
          "--resource",
          "inspection=#{fixture.inspection}",
          "--session-trace-dir",
          fixture.output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          "(return 42)"
        ])
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
          "run-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "-e",
          "(def runs (analysis/runs {}))",
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
    assert String.starts_with?(trace_name, "run-analysis-")
    assert String.ends_with?(trace_name, ".jsonl")
    assert log_analysis_session_pids() == before_sessions

    trace_path = Path.join(output_directory, trace_name)
    assert {:ok, trace} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"name" => name, "session_profile" => profile}]}} =
             TraceLog.query(trace, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("ptc.run-analysis.repl")
    assert profile["id"] == "run-analysis-v1"
    assert profile["digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  @tag :tmp_dir
  test "one public profile evaluation publishes its value atomically", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    traces = Path.join(directory, "analysis-traces")
    results = Path.join(directory, "results")
    Enum.each([source, traces, results], &File.mkdir!/1)
    seed_trace(source, "seed")
    output = Path.join(results, "overview.json")
    relative_output = Path.relative_to(output, File.cwd!())

    assert Path.type(relative_output) == :relative

    capture_io(fn ->
      run_repl([
        "--profile",
        "run-analysis-v1",
        "--resource",
        "traces=#{source}",
        "--session-trace-dir",
        traces,
        "--output",
        relative_output,
        "-e",
        ~s|(analysis/open "seed")|
      ])
    end)

    assert %{"run" => %{"run_id" => "seed"}} = output |> File.read!() |> Jason.decode!()
    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o600
  end

  @tag :tmp_dir
  test "one unattended private profile evaluation requires private output", %{tmp_dir: directory} do
    fixture = PrivateInspectionFixture.create!(directory, "private-output")
    results = Path.join(directory, "results")
    File.mkdir!(results)
    output = Path.join(results, "conversation.private.json")

    capture_io(fn ->
      run_repl([
        "--profile",
        "private-run-analysis-v1",
        "--resource",
        "traces=#{fixture.traces}",
        "--resource",
        "inspection=#{fixture.inspection}",
        "--session-trace-dir",
        fixture.output,
        "--private-unattended",
        "--private-output",
        output,
        "-e",
        ~s|(analysis/read "#{fixture.run_id}" {"collection" "turns" "limit" 100})|
      ])
    end)

    assert %{"items" => [_]} = output |> File.read!() |> Jason.decode!()
    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o600
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
           [write_file(directory, "script.clj", "(count (get (analysis/runs {}) \"items\"))")],
           "1"},
          {"stdin", "(count (get (analysis/runs {}) \"items\"))", ["-"], "1"},
          {"interactive", "(count (get (analysis/runs {}) \"items\"))\n", [], "1"}
        ] do
      output_directory = Path.join(directory, suffix)
      File.mkdir!(output_directory)

      command =
        [
          "--profile",
          "run-analysis-v1",
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
  test "profile meta-command typos and context guidance never crash the session", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")

    output =
      capture_io(":def pmap\n:context\n:quit\n", fn ->
        run_repl(profile_args(source, output_directory), terminal_attached: true)
      end)

    assert output =~ "Unknown command. Available: :help, :quit"
    assert output =~ ":context is available only in a manifest mission REPL"
    assert output =~ "Analysis trace:"

    assert output =~
             ~S|Explore functions with (apropos "term") and (doc "name"); inspect attached APIs with (dir), (export-meta "ns/name"), and (source ns/name).|
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
            "run-analysis-v1",
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
  test "profile mode names the conflicting pair and its physical relationship", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    nested = Path.join(source, "nested")
    alias_root = Path.join(directory, "alias")
    deep = Path.join(source, "deep")
    deep_output = Path.join(deep, "output")
    outer = Path.join(directory, "outer")
    inner_source = Path.join(outer, "inner-source")
    File.mkdir!(source)
    File.mkdir!(nested)
    File.mkdir!(deep)
    File.mkdir!(deep_output)
    File.mkdir!(outer)
    File.mkdir!(inner_source)
    File.ln_s!(directory, alias_root)
    seed_trace(source, "seed")
    seed_trace(inner_source, "seed")

    cases = [
      {"equal", source, source,
       "directories for --resource traces and --session-trace-dir must be physically " <>
         "separate; they resolve to the same physical directory"},
      {"nested", source, nested,
       "directories for --resource traces and --session-trace-dir must be physically " <>
         "separate; --resource traces contains --session-trace-dir"},
      {"reverse nested", inner_source, outer,
       "directories for --resource traces and --session-trace-dir must be physically " <>
         "separate; --session-trace-dir contains --resource traces"},
      {"symlink alias", source, Path.join(alias_root, "source"),
       "directories for --resource traces and --session-trace-dir must be physically " <>
         "separate; they resolve to the same physical directory"},
      {"symlink parent", source, Path.join(alias_root, "source/deep/output"),
       "directories for --resource traces and --session-trace-dir must be physically " <>
         "separate; --resource traces contains --session-trace-dir"}
    ]

    for {label, traces, session_trace_dir, message} <- cases do
      error =
        assert_raise Mix.Error, fn ->
          run_repl(profile_args(traces, session_trace_dir) ++ ["-e", "42"])
        end

      assert error.message =~ message, "#{label} case reported: #{error.message}"
      refute error.message =~ directory
    end

    assert File.ls!(nested) == []
    assert File.ls!(deep_output) == []
  end

  test "profile mode attributes a conflict with the auto-created session trace directory" do
    # No --session-trace-dir, so the session trace directory is generated under
    # the system temporary directory - which this resource contains.
    error =
      assert_raise Mix.Error, fn ->
        run_repl([
          "--profile",
          "run-analysis-v1",
          "--resource",
          "traces=#{System.tmp_dir!()}",
          "-e",
          "42"
        ])
      end

    assert error.message =~
             "directories for --resource traces and the auto-created session trace " <>
               "directory must be physically separate; --resource traces contains " <>
               "the auto-created session trace directory"

    refute error.message =~ System.tmp_dir!()
  end

  @tag :tmp_dir
  test "profile mode attributes source and result destination conflicts to their own options",
       %{tmp_dir: directory} do
    fixture = PrivateInspectionFixture.create!(directory, "separation")
    nested_inspection = Path.join(fixture.traces, "inspection")
    File.mkdir!(nested_inspection)

    private_args = [
      "--profile",
      "private-run-analysis-v1",
      "--private-unattended",
      "-e",
      "42"
    ]

    resources = fn traces, inspection ->
      ["--resource", "traces=#{traces}", "--resource", "inspection=#{inspection}"]
    end

    error =
      assert_raise Mix.Error, fn ->
        run_repl(
          private_args ++
            resources.(fixture.traces, nested_inspection) ++
            ["--session-trace-dir", fixture.output]
        )
      end

    assert error.message =~
             "directories for --resource inspection and --resource traces must be " <>
               "physically separate; --resource traces contains --resource inspection"

    # A --private-output whose parent sits inside an input directory is attributed
    # to --private-output, never generically to the input.
    error =
      assert_raise Mix.Error, fn ->
        run_repl(
          private_args ++
            resources.(fixture.traces, fixture.inspection) ++
            [
              "--session-trace-dir",
              fixture.output,
              "--private-output",
              Path.join(fixture.traces, "result.private.json")
            ]
        )
      end

    assert error.message =~
             "directories for --resource traces and --private-output must be physically " <>
               "separate; they resolve to the same physical directory"

    refute File.exists?(Path.join(fixture.traces, "result.private.json"))
    refute error.message =~ directory
  end

  @tag :tmp_dir
  test "profile mode leaves non-conflicting sibling directories accepted", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    results = Path.join(directory, "results")
    Enum.each([source, output_directory, results], &File.mkdir!/1)
    seed_trace(source, "seed")

    result = Path.join(results, "value.json")

    capture_io(fn ->
      run_repl(profile_args(source, output_directory) ++ ["--output", result, "-e", "42"])
    end)

    assert File.read!(result) |> Jason.decode!() == 42
  end

  @tag :tmp_dir
  test "profile mode names a session trace and result destination conflict", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")

    result = Path.join(output_directory, "value.json")

    error =
      assert_raise Mix.Error, fn ->
        run_repl(profile_args(source, output_directory) ++ ["--output", result, "-e", "42"])
      end

    assert error.message =~
             "directories for --session-trace-dir and --output must be physically " <>
               "separate; they resolve to the same physical directory"

    refute File.exists?(result)
    refute error.message =~ directory
  end

  @tag :tmp_dir
  test "profile mode reports the same first conflicting pair when several conflict", %{
    tmp_dir: directory
  } do
    # traces contains inspection, the session trace directory, and the
    # --private-output parent, so four pairs conflict at once. Input pairs are
    # ordered before the session trace and the result destination, so the
    # reported pair is stable rather than incidental.
    fixture = PrivateInspectionFixture.create!(directory, "ordering")

    argv = [
      "--profile",
      "private-run-analysis-v1",
      "--private-unattended",
      "--resource",
      "traces=#{directory}",
      "--resource",
      "inspection=#{fixture.inspection}",
      "--session-trace-dir",
      fixture.output,
      "--private-output",
      Path.join(fixture.traces, "value.private.json"),
      "-e",
      "42"
    ]

    messages =
      for _attempt <- 1..3 do
        assert_raise(Mix.Error, fn -> run_repl(argv) end).message
      end

    for message <- messages do
      assert message =~
               "directories for --resource inspection and --resource traces must be " <>
                 "physically separate; --resource traces contains --resource inspection"
    end
  end

  @tag :tmp_dir
  test "profile JSONL reports a directory conflict as structured roles", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    nested = Path.join(source, "nested")
    File.mkdir!(source)
    File.mkdir!(nested)
    seed_trace(source, "seed")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, fn ->
          run_repl(profile_args(source, nested) ++ ["--format", "jsonl", "-e", "42"])
        end
      end)

    assert [record] = decode_jsonl(output)

    assert record["schema_version"] == 1
    assert record["type"] == "command-error"
    assert record["category"] == "cli"

    assert record["message"] ==
             "directories for --resource traces and --session-trace-dir must be physically " <>
               "separate; --resource traces contains --session-trace-dir"

    assert record["directory_conflict"] == %{
             "left_role" => "resource.traces",
             "right_role" => "session_trace",
             "relation" => "left_contains_right"
           }

    refute output =~ directory
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
          "run-analysis-v1",
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
          ["--profile", "run-analysis-v1", "--manifest", "ptc.json", "--resource", "traces=tmp"],
          [
            "--profile",
            "run-analysis-v1",
            "--resource",
            "traces=tmp",
            "--resource",
            "traces=tmp"
          ],
          ["--profile", "run-analysis-v1", "--resource", "other=tmp"],
          ["--profile", "run-analysis-v1", "--resource", "traces=tmp", "--format", "jsonl"],
          [
            "--profile",
            "run-analysis-v1",
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

  # One real `mix ptc repl` OS process (~2.2 s). In-process JSONL cases in
  # this file cover session records; this pins the Mix task's stdout.
  @tag :tmp_dir
  @tag :nightly
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
          "run-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "--format",
          "jsonl",
          "-e",
          "(count (get (analysis/runs {}) \"items\"))"
        ],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"}]
      )

    records = decode_mix_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]
    assert Enum.at(records, 1)["result"]["value"] == 1
    assert File.regular?(List.last(records)["trace_path"])
  end

  defp run_repl(args, frontend_opts \\ []),
    do: MixCommandAdapter.run_task(["repl" | args], frontend_opts).outcome

  defp profile_args(source, output_directory) do
    [
      "--profile",
      "run-analysis-v1",
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

  defp write_workflow_repl_manifest(directory) do
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")
    manifest_path = Path.join(directory, "ptc.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{"writing" => %{}, "review" => %{}},
        "input" => %{"value" => %{}}
      })
    )

    manifest_path
  end

  defp write_missing_credential_repl(directory) do
    File.write!(Path.join(directory, "credential-main.clj"), "(ns app) (defn run [x] (return x))")
    File.write!(Path.join(directory, "credential-review.clj"), "(ns review)")
    manifest_path = Path.join(directory, "credential-repl.json")
    host_path = Path.join(directory, "credential-repl-host.json")

    workflow_declarations = [
      %{"name" => "alpha"},
      %{"name" => "omega"}
    ]

    mission_declarations = [
      %{"name" => "workspace-alpha"},
      %{"name" => "workspace-omega"}
    ]

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "credential-main.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "credential-review.clj"}],
            "providers" => ["workspace-alpha", "workspace-omega"]
          }
        },
        "input" => %{"value" => %{}},
        "providers" => %{
          "workflow" => workflow_declarations,
          "mission" => mission_declarations
        }
      })
    )

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{
          "alpha-key" => %{"env" => "PTC_REPL_ABSENT_ALPHA_KEY"},
          "omega-key" => %{"env" => "PTC_REPL_ABSENT_OMEGA_KEY"}
        },
        "install" => %{
          "alpha" => repl_llm_installation("alpha-key"),
          "omega" => repl_llm_installation("omega-key"),
          "workspace-alpha" => repl_mcp_installation("alpha-key"),
          "workspace-omega" => repl_mcp_installation("omega-key")
        }
      })
    )

    {manifest_path, host_path}
  end

  defp repl_llm_installation(credential) do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "repl-missing-credential-v1",
      "model" => "openrouter:test/model",
      "credential" => credential
    }
  end

  defp repl_mcp_installation(credential) do
    %{
      "source" => "mcp",
      "installation_revision" => "repl-missing-credential-v1",
      "transport" => %{
        "type" => "stdio",
        "command" => System.find_executable("sh"),
        "env" => %{"TOKEN" => %{"binding" => credential}}
      },
      "tools" => %{"read" => %{"as" => "#{credential}.read", "effect" => "read"}}
    }
  end

  # ex_dna:disable-for-next-line — boundary test keeps its trace fixture local and explicit
  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{missions: %{}})

    :ok =
      EventSink.emit(sink, "run-stopped", %{
        outcome: :ok,
        reason: nil,
        usage: %{llm_budget: %{"total_tokens" => nil, "cost" => nil}}
      })

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
