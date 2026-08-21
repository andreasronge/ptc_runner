defmodule PtcRunner.Kernel.CommandFrontendTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DiagnosticCatalog

  @run_ref "cmd-00000000000000000000000001"

  @human_fixtures Path.expand("../../fixtures/command-human-v2.json", __DIR__)
                  |> File.read!()
                  |> Jason.decode!()

  test "help and version complete without invoking bootstrap" do
    parent = self()

    for argv <- [[], ["help", "run"], ["--version"]] do
      presentation =
        CommandFrontend.execute(argv, :standalone, fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:error, :command_bootstrap_failed}
        end)

      assert presentation.exit_status == 0
      assert presentation.stdout != ""
      assert presentation.stderr == ""
    end

    refute_received :unexpected_bootstrap
  end

  test "repl structural rejections occur before bootstrap without echoing values" do
    parent = self()

    presentation =
      CommandRouter.execute(
        ["repl", "--describe-profile", "run-analysis-v1", "--load", "caller-value"],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end,
        fn _arguments, _runtime ->
          send(parent, :unexpected_repl)
          :ok
        end
      )

    assert presentation.exit_status == 2
    assert presentation.stdout == ""
    assert presentation.stderr =~ "arguments/invalid_arguments"
    refute presentation.stderr =~ "caller-value"
    refute_received :unexpected_bootstrap
    refute_received :unexpected_repl
  end

  test "missing switch values and fixed positional arity render declaration-owned guidance" do
    cases = [
      {[
         "run",
         "ptc.json",
         "--envelope"
       ], :missing_switch_value, "; --envelope requires a value"},
      {[
         "run",
         "ptc.json",
         "--output"
       ], :missing_switch_value, "; --output requires a value"},
      {["run"], :positional_arity, "; usage: ptc run MANIFEST.json|PROJECT.json [OPTIONS]"},
      {[
         "run",
         "ptc.json",
         "extra.json"
       ], :positional_arity, "; usage: ptc run MANIFEST.json|PROJECT.json [OPTIONS]"}
    ]

    for {argv, kind, guidance} <- cases do
      assert {:error, entry} = CommandEntry.open_with_ref(argv, :standalone, @run_ref)
      assert entry.rejection.code == :invalid_arguments
      assert entry.rejection.kind == kind
      assert CommandRenderer.rejection(@run_ref, entry.rejection) =~ guidance
    end
  end

  @tag :tmp_dir
  test "transcript startup and internal failures retain transcript diagnostics", %{tmp_dir: dir} do
    argv = [
      "transcript",
      "run-1",
      "--traces",
      Path.join(dir, "traces"),
      "--inspection",
      Path.join(dir, "inspection"),
      "--private-unattended",
      "--private-output",
      Path.join(dir, "transcript.private.json")
    ]

    startup =
      CommandRouter.execute(
        argv,
        :standalone,
        fn _arguments -> {:error, :command_bootstrap_failed} end,
        fn _arguments, _runtime -> :ok end
      )

    assert startup.exit_status == 70
    assert startup.stderr =~ "error: transcript/startup_failed:"
    refute startup.stderr =~ "repl/"

    internal =
      CommandRouter.execute(
        argv,
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end,
        fn _arguments, _runtime -> raise "private detail" end
      )

    assert internal.exit_status == 70
    assert internal.stderr =~ "error: transcript/internal_error:"
    refute internal.stderr =~ "private detail"
    refute internal.stderr =~ "repl/"
  end

  test "the one-shot frontend rejects repl without invoking bootstrap" do
    parent = self()

    for {argv, code} <- [
          {["repl"], "invalid_command"},
          {["repl", "--caller-secret", "value"], "invalid_arguments"},
          {["repl", "-e", "expr", "script.clj"], "invalid_arguments"}
        ] do
      presentation =
        CommandFrontend.execute(argv, :standalone, fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end)

      assert presentation.exit_status == 2
      assert presentation.outcome.command_mode == :unknown
      assert presentation.outcome.envelope["error"]["phase"] == "arguments"
      assert presentation.outcome.envelope["error"]["code"] == code
    end

    refute_received :unexpected_bootstrap
  end

  test "the one-shot frontend rejects transcript without invoking bootstrap" do
    parent = self()

    presentation =
      CommandFrontend.execute(
        [
          "transcript",
          "run-1",
          "--traces",
          "traces",
          "--inspection",
          "inspection",
          "--private-unattended",
          "--private-output",
          "transcript.json"
        ],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 2
    assert presentation.outcome.command_mode == :unknown

    assert %{"code" => "invalid_command", "phase" => "arguments"} =
             presentation.outcome.envelope["error"]

    refute_received :unexpected_bootstrap
  end

  @tag :tmp_dir
  test "a recoverable startup failure publishes one schema-valid envelope", %{tmp_dir: dir} do
    path = Path.join(dir, "command-envelope.json")

    presentation =
      CommandFrontend.execute(["doctor", "--envelope", path], :standalone, fn _arguments ->
        {:error, :command_bootstrap_failed}
      end)

    assert presentation.exit_status == 70
    assert presentation.stdout == ""

    assert presentation.stderr ==
             "error: internal/internal_error: the command failed internally " <>
               "(run_ref: #{presentation.outcome.envelope["run_ref"]})\n"

    assert presentation.envelope_path == path

    encoded = File.read!(path)
    envelope = Jason.decode!(encoded)
    assert CommandContract.valid_envelope?(envelope)
    assert envelope["command"] == "doctor"
    assert envelope["error"]["phase"] == "internal"
    refute String.ends_with?(encoded, "\n")
  end

  @tag :tmp_dir
  test "a successful envelope publication also renders the public result", %{tmp_dir: dir} do
    application = write_application(dir)
    path = Path.join(dir, "command-envelope.json")

    presentation =
      CommandFrontend.execute(
        ["run", application, "--envelope", path],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 0
    assert presentation.stdout == "{\"answer\":42}\n"
    assert presentation.stderr == ""
    assert presentation.envelope_path == path
    assert File.regular?(path)
  end

  @tag :tmp_dir
  test "an existing envelope destination is refused before the run executes", %{tmp_dir: dir} do
    parent = self()
    application = write_application(dir)
    path = Path.join(dir, "command-envelope.json")
    File.write!(path, "{\"stale\":true}")

    presentation =
      CommandFrontend.execute(
        ["run", application, "--envelope", path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 2
    assert presentation.stdout == ""
    assert presentation.stderr =~ "arguments/envelope_destination_exists"

    assert presentation.stderr =~ "remove it or point --envelope at another path"

    refute presentation.stderr =~ path
    assert presentation.envelope_path == nil
    assert File.read!(path) == "{\"stale\":true}"
    refute_received :unexpected_bootstrap
  end

  @tag :tmp_dir
  test "an envelope request preserves an artifact destination diagnosis", %{tmp_dir: dir} do
    application = write_application(dir)
    envelope_path = Path.join(dir, "command-envelope.json")
    output_path = Path.join([dir, "missing", "result.json"])

    presentation =
      CommandFrontend.execute(
        [
          "run",
          application,
          "--output",
          output_path,
          "--envelope",
          envelope_path
        ],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 7
    assert presentation.stdout == ""
    # The parent directory does not exist, which is the one destination cause
    # with an obvious remedy, so it is named without echoing the path itself.
    assert presentation.stderr =~ "destination/result_directory_missing"
    assert presentation.envelope_path == envelope_path
    assert File.regular?(envelope_path)
    refute presentation.stderr =~ output_path
  end

  @tag :tmp_dir
  test "a manifest schema rejection renders its safe document path", %{tmp_dir: dir} do
    application = write_application(dir)
    manifest = application |> File.read!() |> Jason.decode!()

    invalid_manifest =
      put_in(
        manifest,
        ["workflow", "components", Access.at(0), "path"],
        "../shared/main.clj"
      )

    File.write!(application, Jason.encode!(invalid_manifest))

    presentation =
      CommandFrontend.execute(["validate", application], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 3
    assert presentation.outcome.envelope["error"]["path"] == "/workflow/components/0/path"

    assert presentation.stderr ==
             "error: application/schema_violation: " <>
               "the application manifest violates the pattern schema rule " <>
               "at /workflow/components/0/path (run_ref: #{presentation.outcome.envelope["run_ref"]})\n"

    refute presentation.stderr =~ "../shared/main.clj"
  end

  @tag :tmp_dir
  test "a host schema rejection renders its bounded rule and safe path", %{tmp_dir: dir} do
    application = write_application(dir)
    host = Path.join(dir, "host-schema-rule.json")

    document = %{
      "install" => %{
        "model" => %{
          "source" => "mcp",
          "installation_revision" => "model-v1",
          "transport" => %{"type" => "stdio", "command" => "node"},
          "tools" => %{"read" => %{"as" => "model.read", "effect" => "read"}}
        }
      }
    }

    invalid = put_in(document, ["install", "model", "ceilings"], %{"timeout_ms" => 999_999})

    File.write!(host, Jason.encode!(invalid))

    presentation =
      CommandFrontend.execute(
        ["validate", application, "--host-config", host],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 3
    assert presentation.outcome.envelope["error"]["path"] == "/install/*/ceilings/timeout_ms"

    assert presentation.stderr ==
             "error: host/host_schema_invalid: " <>
               "the host configuration violates the maximum schema rule " <>
               "at /install/*/ceilings/timeout_ms " <>
               "(run_ref: #{presentation.outcome.envelope["run_ref"]})\n"

    refute presentation.stderr =~ "model"
    refute presentation.stderr =~ "999999"
  end

  @tag :tmp_dir
  test "an input contract rejection renders its safe declared path", %{tmp_dir: dir} do
    application = write_application(dir)
    manifest = application |> File.read!() |> Jason.decode!()

    input_schema = %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"]
    }

    invalid_manifest =
      manifest
      |> Map.put("contracts", %{"input_schema" => %{"path" => "input.schema.json"}})
      |> put_in(["input", "value", "answer"], "wrong")

    File.write!(application, Jason.encode!(invalid_manifest))
    File.write!(Path.join(dir, "input.schema.json"), Jason.encode!(input_schema))

    presentation =
      CommandFrontend.execute(["validate", application], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 3
    assert presentation.outcome.envelope["error"]["path"] == "/answer"

    assert presentation.stderr ==
             "error: application/input_contract_failed: " <>
               "the selected input does not satisfy the input contract " <>
               "at /answer (run_ref: #{presentation.outcome.envelope["run_ref"]})\n"
  end

  @tag :tmp_dir
  test "a result contract rejection retains and renders its safe declared path", %{tmp_dir: dir} do
    application = write_application(dir)
    manifest = application |> File.read!() |> Jason.decode!()

    result_schema = %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"]
    }

    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"answer" "wrong"}))|
    )

    File.write!(
      application,
      manifest
      |> Map.put("contracts", %{"result_schema" => %{"path" => "result.schema.json"}})
      |> Jason.encode!()
    )

    File.write!(Path.join(dir, "result.schema.json"), Jason.encode!(result_schema))

    presentation =
      CommandFrontend.execute(["run", application], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 7

    assert presentation.outcome.envelope["error"]["source"] == %{
             "kind" => "result_contract",
             "name" => "result.schema.json"
           }

    assert presentation.outcome.envelope["error"]["path"] == "/answer"

    assert presentation.stderr ==
             "error: result_cleanup/result_contract_failed: " <>
               "the workflow result does not satisfy its contract " <>
               "at /answer (run_ref: #{presentation.outcome.envelope["run_ref"]})\n"
  end

  @tag :tmp_dir
  test "human failures do not render contract-authored control bytes", %{tmp_dir: dir} do
    application = write_application(dir)
    manifest = application |> File.read!() |> Jason.decode!()
    property = "line\n\e[31m"

    input_schema = %{
      "type" => "object",
      "properties" => %{property => %{"type" => "integer"}},
      "required" => [property]
    }

    invalid_manifest =
      manifest
      |> Map.put("contracts", %{"input_schema" => %{"path" => "input.schema.json"}})
      |> put_in(["input", "value"], %{property => "wrong"})

    File.write!(application, Jason.encode!(invalid_manifest))
    File.write!(Path.join(dir, "input.schema.json"), Jason.encode!(input_schema))

    presentation =
      CommandFrontend.execute(["validate", application], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 3
    assert presentation.outcome.envelope["error"]["path"] == "/" <> property

    assert presentation.stderr ==
             "error: application/input_contract_failed: " <>
               "the selected input does not satisfy the input contract " <>
               ~S|at "/line\n\e[31m" | <>
               "(run_ref: #{presentation.outcome.envelope["run_ref"]})\n"

    refute presentation.stderr =~ property
  end

  @tag :tmp_dir
  test "an argv rejection does not deliver an envelope or bootstrap", %{tmp_dir: dir} do
    path = Path.join(dir, "must-not-exist.json")
    parent = self()

    presentation =
      CommandFrontend.execute(
        ["run", "ptc.json", "--unknown", "value", "--envelope", path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 2
    assert presentation.envelope_path == nil
    assert presentation.stderr =~ "; unknown switch; accepted:"
    refute presentation.stderr =~ "--unknown"
    refute File.exists?(path)
    refute_received :unexpected_bootstrap
  end

  @tag :tmp_dir
  test "an existing envelope destination is refused at admission, not overwritten", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "existing.json")
    File.write!(path, "original")

    presentation =
      CommandFrontend.execute(["doctor", "--envelope", path], :standalone, fn _arguments ->
        {:error, :command_bootstrap_failed}
      end)

    assert presentation.exit_status == 2
    assert presentation.stdout == ""

    assert presentation.stderr ==
             "error: arguments/envelope_destination_exists: the envelope destination already " <>
               "exists (run_ref: #{presentation.outcome.envelope["run_ref"]}); " <>
               "remove it or point --envelope at another path\n"

    assert File.read!(path) == "original"
  end

  @tag :tmp_dir
  test "entry rejects resolved envelope collisions before bootstrap or delivery", %{tmp_dir: dir} do
    output = Path.join(dir, "answer.json")

    assert_run_collision(
      [
        "run",
        "ptc.json",
        "--output",
        output,
        "--envelope",
        Path.join([dir, ".", "answer.json"])
      ],
      "--output"
    )

    for {switch, name} <- [
          {"--private-output", "private-answer.json"},
          {"--inspect", "run.inspection.jsonl"}
        ] do
      path = Path.join(dir, name)

      assert_run_collision(
        ["run", "ptc.json", switch, path, "--envelope", path],
        switch
      )
    end

    trace_dir = Path.join(dir, "traces")
    File.mkdir!(trace_dir)

    for suffix <- [".jsonl", ".private.jsonl"] do
      assert_run_collision(
        [
          "run",
          "ptc.json",
          "--trace-dir",
          trace_dir,
          "--envelope",
          Path.join(trace_dir, @run_ref <> suffix)
        ],
        "--trace-dir"
      )
    end

    private_output = Path.join(dir, "private.json")

    assert_run_collision(
      [
        "run",
        "ptc.json",
        "--private-output",
        private_output,
        "--envelope",
        Path.join(dir, ".ptc-private-result-" <> @run_ref <> ".json")
      ],
      "--private-output"
    )
  end

  @tag :tmp_dir
  test "entry anchors destinations once and dispatch uses the captured paths", %{tmp_dir: dir} do
    application = write_application(dir)
    output = Path.join(dir, "captured-result.json")
    decoy = Path.join(dir, "decoy-result.json")
    relative_output = Path.relative_to(output, File.cwd!())

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", application, "--output", relative_output],
               :standalone,
               @run_ref
             )

    assert {%{output: captured_output}, []} = entry.destinations
    assert captured_output == Path.join(File.cwd!(), relative_output)

    arguments = %{
      entry.arguments
      | options: Map.put(entry.arguments.options, :output, decoy)
    }

    assert {:ok, _outcome} =
             CommandEngine.dispatch_entry(
               %{entry | arguments: arguments},
               CommandRuntime.standalone()
             )

    assert File.regular?(output)
    refute File.exists?(decoy)

    target = Path.join(dir, "new-project")
    relative_target = Path.relative_to(target, File.cwd!())

    assert {:ok, init_entry} =
             CommandEntry.open_with_ref(["init", relative_target], :standalone, @run_ref)

    assert init_entry.arguments.directory == Path.join(File.cwd!(), relative_target)
  end

  @tag :tmp_dir
  test "init rejects an envelope at or beneath the resolved target", %{tmp_dir: dir} do
    target = Path.join(dir, "new-project")
    assert_init_collision(["init", target, "--envelope", target])
    assert_init_collision(["init", target, "--envelope", Path.join(target, "envelope.json")])

    real_parent = Path.join(dir, "real")
    linked_parent = Path.join(dir, "linked")
    File.mkdir!(real_parent)
    File.ln_s!(real_parent, linked_parent)

    assert_init_collision([
      "init",
      Path.join(linked_parent, "project"),
      "--envelope",
      Path.join([real_parent, "project", "envelope.json"])
    ])
  end

  test "an invalid envelope path is not reported as a destination collision" do
    for path <- ["", "-"] do
      assert {:error, entry} =
               CommandEntry.open_with_ref(
                 ["run", "ptc.json", "--envelope", path],
                 :standalone,
                 @run_ref
               )

      assert entry.rejection.code == :invalid_arguments
      assert entry.rejection.kind == :invalid_destination
      assert entry.rejection.destination == "--envelope"
      assert entry.rejection.conflicts == []

      assert CommandRenderer.rejection(@run_ref, entry.rejection) ==
               @human_fixtures["failure"]["invalid_destination"]
    end
  end

  @tag :tmp_dir
  test "frontend artifact diagnosis matches canonical phase-six ordering", %{tmp_dir: dir} do
    application = write_application(dir)

    for {name, phase, code, exit_status, collision?} <- [
          {"shared.json", "destination", "invalid_inspection_destination", 7, false},
          {"shared.inspection.jsonl", "arguments", "conflicting_arguments", 2, true}
        ] do
      destination = Path.join(dir, name)
      argv = ["run", application, "--output", destination, "--inspect", destination]

      assert {:ok, preparation} = CommandEngine.prepare(argv)
      assert {:error, direct} = CommandEngine.preflight(preparation)

      presentation =
        CommandFrontend.execute(argv, :standalone, fn _arguments ->
          {:ok, CommandRuntime.standalone()}
        end)

      expected_state = %{
        "trace" => "not_requested",
        "inspection" => "not_written",
        "result" => "not_written"
      }

      assert presentation.exit_status == exit_status
      assert presentation.outcome.envelope["error"]["phase"] == phase
      assert presentation.outcome.envelope["error"]["code"] == code
      assert presentation.outcome.envelope["artifact_state"] == expected_state
      assert direct.exit_status == exit_status
      assert direct.envelope["error"]["phase"] == phase
      assert direct.envelope["error"]["code"] == code
      assert direct.envelope["artifact_state"] == expected_state

      if collision? do
        assert presentation.stderr =~
                 "two destinations name the same file: --inspect and --output"
      else
        refute presentation.stderr =~ "two destinations name the same file"
      end

      refute presentation.stderr =~ destination
      refute Jason.encode!(direct.envelope) =~ destination
    end
  end

  @tag :tmp_dir
  test "private output rejects its reserved recovery filename", %{tmp_dir: dir} do
    recovery = Path.join(dir, ".ptc-private-result-#{@run_ref}.json")
    application = write_application(dir)
    manifest = application |> File.read!() |> Jason.decode!()

    File.write!(
      application,
      Jason.encode!(Map.put(manifest, "events", %{"policy" => "private"}))
    )

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", application, "--private-output", recovery],
               :standalone,
               @run_ref
             )

    assert entry.rejection == nil

    presentation =
      CommandFrontend.present_entry(entry, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 2
    assert presentation.outcome.envelope["error"]["phase"] == "arguments"
    assert presentation.outcome.envelope["error"]["code"] == "conflicting_arguments"

    assert presentation.outcome.envelope["artifact_state"] == %{
             "trace" => "not_requested",
             "inspection" => "not_requested",
             "result" => "not_written"
           }

    assert presentation.stderr == @human_fixtures["failure"]["private_output_recovery_collision"]
    refute presentation.stderr =~ recovery
    refute File.exists?(recovery)
  end

  @tag :tmp_dir
  test "entry defers collisions with a privacy-dependent trace suffix", %{tmp_dir: dir} do
    output = Path.join(dir, @run_ref <> ".private.jsonl")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", "ptc.json", "--trace-dir", dir, "--output", output],
               :standalone,
               @run_ref
             )

    assert entry.rejection == nil
  end

  @tag :tmp_dir
  test "classified trace collisions render both declaration-owned switches", %{tmp_dir: dir} do
    for {policy, suffix, result_switch} <- [
          {:normal, ".jsonl", "--output"},
          {:private, ".private.jsonl", "--private-output"}
        ] do
      root = Path.join(dir, Atom.to_string(policy))
      traces = Path.join(root, "traces")
      File.mkdir_p!(traces)
      application = write_application(root)

      if policy == :private do
        manifest = application |> File.read!() |> Jason.decode!()

        File.write!(
          application,
          Jason.encode!(Map.put(manifest, "events", %{"policy" => "private"}))
        )
      end

      collision = Path.join(traces, @run_ref <> suffix)

      assert {:ok, entry} =
               CommandEntry.open_with_ref(
                 [
                   "run",
                   application,
                   "--trace-dir",
                   traces,
                   result_switch,
                   collision
                 ],
                 :standalone,
                 @run_ref
               )

      presentation =
        CommandFrontend.present_entry(entry, fn _arguments ->
          {:ok, CommandRuntime.standalone()}
        end)

      assert presentation.exit_status == 2

      assert presentation.stderr =~
               "two destinations name the same file: --trace-dir and #{result_switch}"

      refute presentation.stderr =~ collision
    end
  end

  @tag :tmp_dir
  test "an unavailable trace directory keeps the canonical diagnosis before a lexical collision",
       %{
         tmp_dir: dir
       } do
    root = Path.join(dir, "unavailable-trace")
    File.mkdir!(root)
    application = write_application(root)
    traces = Path.join(root, "missing")
    output = Path.join(traces, @run_ref <> ".jsonl")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", application, "--trace-dir", traces, "--output", output],
               :standalone,
               @run_ref
             )

    presentation =
      CommandFrontend.present_entry(entry, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == 7
    assert presentation.outcome.envelope["error"]["code"] == "trace_directory_missing"
    assert presentation.stderr =~ "destination/trace_directory_missing"
    assert presentation.stderr =~ "--trace-dir must be an existing normal directory"
    refute presentation.stderr =~ "two destinations name the same file"
    refute presentation.stderr =~ traces
  end

  test "help and version reject envelope as an undeclared switch" do
    for argv <- [
          ["help", "run", "--envelope", "result.json"],
          ["version", "--envelope", "result.json"],
          ["--version", "--envelope", "result.json"]
        ] do
      presentation =
        CommandFrontend.execute(argv, :standalone, fn _arguments ->
          flunk("bootstrap must not run")
        end)

      assert presentation.exit_status == 2
      assert presentation.stderr =~ "; unknown switch; accepted:"
      refute presentation.stderr =~ "result.json"
    end
  end

  test "success projections match the byte-exact human fixtures" do
    artifacts = %{
      "trace" => "not_requested",
      "inspection" => "not_requested",
      "result" => "not_requested"
    }

    private_artifacts = %{artifacts | "result" => "written"}

    usage = usage_fixture()

    memory = %{
      "defined_count" => 0,
      "history_count" => 0,
      "memory_bytes" => 0,
      "history_bytes" => 0,
      "bytes" => 0
    }

    doctor_default = Jason.decode!(@human_fixtures["success"]["doctor_default"])
    doctor_connect = Jason.decode!(@human_fixtures["success"]["doctor_connect"])

    rows = %{
      "run_normal" =>
        CommandOutcome.run_success(
          @run_ref,
          :normal,
          %{"b" => 2, "a" => 1},
          artifacts,
          usage,
          memory
        ),
      "run_private" =>
        CommandOutcome.run_success(
          @run_ref,
          :private,
          nil,
          private_artifacts,
          usage,
          memory
        ),
      "validate" =>
        CommandOutcome.success(:validate, @run_ref, %{
          "application_content_digest" => "sha256:" <> String.duplicate("0", 64),
          "effective_application_digest" => "sha256:" <> String.duplicate("1", 64),
          "workflow_bundle_hash" => String.duplicate("2", 64),
          "mission_bundle_hashes" => %{},
          "provider_activity" => false
        }),
      "doctor_default" => CommandOutcome.success(:doctor, @run_ref, doctor_default),
      "doctor_connect" => CommandOutcome.success({:doctor, :connect}, @run_ref, doctor_connect),
      "models" => CommandOutcome.success(:models, @run_ref, %{"installations" => []}),
      "init" =>
        CommandOutcome.success(:init, @run_ref, %{
          "created" => ["AGENTS.md", ".gitignore", "main.clj", "ptc.json", "ptc-project.json"]
        }),
      "docs_listing" => CommandOutcome.success(:docs, @run_ref, CommandContract.docs_result(nil)),
      "help_root" => CommandOutcome.success(:help, @run_ref, CommandContract.help_result(:root)),
      "help_run" => CommandOutcome.success(:help, @run_ref, CommandContract.help_result(:run)),
      "version" => CommandOutcome.success(:version, @run_ref, CommandContract.version_result())
    }

    for {name, outcome} <- rows do
      assert CommandRenderer.render(outcome) == {:stdout, @human_fixtures["success"][name]}
    end
  end

  test "every catalog phase matches its byte-exact failure fixture" do
    phases = DiagnosticCatalog.rows() |> Enum.map(& &1.phase) |> Enum.uniq()

    for phase <- phases do
      outcome = catalog_outcome(phase)
      assert {:stderr, line} = CommandRenderer.render(outcome)
      assert line == @human_fixtures["failure"][Atom.to_string(phase)]
    end
  end

  test "human failures render the complete provider subject" do
    {:ok, credential_subject} = CommandSubject.provider("deepseek", :credentials)

    credential_outcome =
      valid_outcome(
        CommandDiagnostic.new!(:active_preflight, :credential_unavailable,
          subject: credential_subject
        )
      )

    assert CommandRenderer.render(credential_outcome) ==
             {:stderr,
              "error: active_preflight/credential_unavailable: " <>
                "provider/deepseek/credentials: a required provider credential is unavailable " <>
                "(run_ref: #{@run_ref}); export it, pass --env-file PATH, or use a host file credential\n"}

    {:ok, selection_subject} =
      CommandSubject.provider("workspace", :selection, %{destination: :mission, index: 2})

    selection_outcome =
      valid_outcome(
        CommandDiagnostic.new!(:provider_declaration, :selection_invalid,
          subject: selection_subject
        )
      )

    assert CommandRenderer.render(selection_outcome) ==
             {:stderr,
              "error: provider_declaration/selection_invalid: " <>
                "provider/workspace/selection at mission[2]: the provider selection is invalid " <>
                "(run_ref: #{@run_ref})\n"}
  end

  test "structured argument rejections and envelope publication match exact fixtures" do
    for {name, argv} <- [
          {"unknown_switch", ["run", "ptc.json", "--caller-secret", "value"]},
          {"unknown_switch", ["run", "ptc.json", "--trace", "trace.jsonl"]}
        ] do
      assert {:error, entry} = CommandEntry.open_with_ref(argv, :standalone, @run_ref)

      assert CommandRenderer.rejection(@run_ref, entry.rejection) ==
               @human_fixtures["failure"][name]
    end

    assert CommandRenderer.envelope_failure(@run_ref) ==
             @human_fixtures["failure"]["envelope_publication"]
  end

  test "a normal string result uses compact JSON and escapes embedded newlines" do
    outcome =
      CommandOutcome.run_success(
        @run_ref,
        :normal,
        "first\nsecond",
        %{
          "trace" => "not_requested",
          "inspection" => "not_requested",
          "result" => "not_requested"
        },
        usage_fixture(),
        %{
          "defined_count" => 0,
          "history_count" => 0,
          "memory_bytes" => 0,
          "history_bytes" => 0,
          "bytes" => 0
        }
      )

    assert CommandRenderer.render(outcome) ==
             {:stdout, @human_fixtures["success"]["string_newline"]}
  end

  test "renderer fallback retains the sealed run reference" do
    outcome = catalog_outcome(:arguments)
    invalid = %{outcome | attestation: <<>>}

    assert CommandRenderer.render(invalid) ==
             {:stderr,
              "error: internal/internal_error: internal command failure " <>
                "(run_ref: #{@run_ref})\n"}
  end

  defp assert_run_collision(argv, conflicting_switch) do
    assert {:error, entry} = CommandEntry.open_with_ref(argv, :standalone, @run_ref)
    assert entry.envelope_path == nil
    assert entry.arguments == nil
    assert entry.rejection.code == :conflicting_arguments
    assert entry.rejection.kind == :destination_collision
    assert entry.rejection.conflicts == [conflicting_switch, "--envelope"]

    expected =
      String.replace(
        @human_fixtures["failure"]["destination_collision"],
        "--output and --envelope",
        "#{conflicting_switch} and --envelope"
      )

    assert CommandRenderer.rejection(@run_ref, entry.rejection) == expected
  end

  defp assert_init_collision(argv) do
    assert {:error, entry} = CommandEntry.open_with_ref(argv, :standalone, @run_ref)
    assert entry.envelope_path == nil
    assert entry.arguments == nil
    assert entry.rejection.code == :conflicting_arguments
    assert entry.rejection.kind == :init_destination_collision
    assert entry.rejection.conflicts == ["--envelope"]

    assert CommandRenderer.rejection(@run_ref, entry.rejection) ==
             @human_fixtures["failure"]["init_destination_collision"]
  end

  defp write_application(directory) do
    File.write!(
      Path.join(directory, "main.clj"),
      "(ns main) (defn run [input] (return input))"
    )

    manifest = Path.join(directory, "ptc.json")

    File.write!(
      manifest,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{"answer" => 42}}
      })
    )

    manifest
  end

  defp catalog_outcome(phase) do
    DiagnosticCatalog.rows()
    |> Enum.filter(&(&1.phase == phase))
    |> Enum.find_value(fn row ->
      operations = DiagnosticCatalog.subject_operations(row.phase, row.code)

      subjects =
        [nil] ++
          Enum.flat_map(operations, fn operation ->
            for occurrence <- [nil, %{destination: :workflow, index: 0}],
                {:ok, subject} <- [CommandSubject.provider("provider", operation, occurrence)],
                do: subject
          end)

      Enum.find_value(subjects, fn subject ->
        Enum.find_value([false, true], fn activity ->
          diagnostic_outcome(row, subject, activity)
        end)
      end)
    end) || flunk("no renderable diagnostic for catalog phase #{phase}")
  end

  defp diagnostic_outcome(row, subject, activity) do
    case CommandDiagnostic.new(row.phase, row.code,
           subject: subject,
           provider_activity: activity
         ) do
      {:ok, diagnostic} -> valid_outcome(diagnostic)
      {:error, :invalid_command_diagnostic} -> false
    end
  end

  defp valid_outcome(diagnostic) do
    CommandOutcome.error(:run, @run_ref, diagnostic)
  rescue
    ArgumentError -> valid_classified_outcome(diagnostic)
  end

  defp valid_classified_outcome(diagnostic) do
    CommandOutcome.run_classified_error(
      @run_ref,
      :normal,
      diagnostic,
      [],
      %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "not_requested"
      },
      %{"state" => "incomplete", "usage" => nil, "evaluation_memory" => nil}
    )
  rescue
    ArgumentError -> false
  end

  defp usage_fixture do
    %{
      "remaining_ms" => 0,
      "capability_calls" => %{},
      "subordinate_evaluations" => 0,
      "evaluations_by_mission" => %{},
      "protocol_errors" => 0,
      "agent_protocol_errors" => 0,
      "evaluation_memory_bytes" => 0,
      "evaluation_history_bytes" => 0,
      "evaluation_continuation_bytes" => 0,
      "events_dropped" => %{},
      "capability_refusals" => %{},
      "llm_usage_state" => "available",
      "llm_usage" => [],
      "llm_usage_by_model" => [],
      "unattributed_model_calls" => 0
    }
  end
end
