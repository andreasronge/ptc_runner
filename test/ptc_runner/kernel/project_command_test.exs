defmodule PtcRunner.Kernel.ProjectCommandTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime

  @tag :tmp_dir
  test "an initialized project runs through its single project document", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, %CommandOutcome{envelope: %{"status" => "ok", "run_ref" => run_ref} = envelope}} =
             CommandEngine.dispatch(["run", project])

    assert envelope["result"]["value"] == %{"greeting" => "hello world"}

    assert [trace] = Path.wildcard(Path.join([target, ".ptc", "traces", "*.jsonl"]))
    assert File.regular?(trace)

    envelope = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    assert Jason.decode!(File.read!(envelope))["run_ref"] == run_ref
  end

  @tag :tmp_dir
  test "preparation remains read-only and creates the project artifact layout only at dispatch",
       %{
         tmp_dir: directory
       } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    artifact_root = Path.join(target, ".ptc")

    assert {:ok, preparation} = CommandEngine.prepare(["run", project])
    refute File.exists?(artifact_root)
    assert :ok = CommandPreparation.close(preparation)

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    assert File.dir?(artifact_root)
  end

  @tag :tmp_dir
  test "a first-run application failure still publishes its project envelope", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    assert {:error, %CommandOutcome{envelope: outcome}} =
             CommandEngine.dispatch(["run", project_path])

    assert outcome["error"]["phase"] == "application"
    envelope_path = Path.join([target, ".ptc", "envelopes", outcome["run_ref"] <> ".json"])
    assert Jason.decode!(File.read!(envelope_path))["error"]["phase"] == "application"
  end

  @tag :tmp_dir
  test "the frontend publishes a first-run failure envelope from project defaults", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    presentation =
      CommandFrontend.execute(["run", project_path], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.outcome.envelope["error"]["phase"] == "application"
    assert File.regular?(presentation.envelope_path)
  end

  @tag :tmp_dir
  test "project defaults are merged and explicit command values win", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    explicit_traces = Path.join(target, "explicit-traces")
    File.mkdir!(explicit_traces)
    run_ref = "cmd-00000000000000000000000000"

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", project, "--trace-dir", explicit_traces],
               :mix,
               run_ref
             )

    assert entry.arguments.application == Path.join(target, "ptc.json")
    assert entry.arguments.options.trace_dir == explicit_traces
    assert entry.envelope_path == Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
  end

  @tag :tmp_dir
  test "explicit --envelope still writes the project ledger envelope", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    copy = Path.join(directory, "one.json")

    presentation =
      CommandFrontend.execute(
        ["run", project, "--envelope", copy],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 0
    assert presentation.envelope_path == copy
    assert File.regular?(copy)

    run_ref = presentation.outcome.envelope["run_ref"]
    ledger = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    assert File.regular?(ledger)
    assert Jason.decode!(File.read!(ledger))["run_ref"] == run_ref
    assert Jason.decode!(File.read!(copy))["run_ref"] == run_ref
  end

  @tag :tmp_dir
  test "project ledger policy does not make an explicit envelope direct-engine authority", %{
    tmp_dir: directory
  } do
    for {name, operation} <- [
          prepare: &CommandEngine.prepare/1,
          dispatch: &CommandEngine.dispatch/1
        ] do
      target = Path.join(directory, Atom.to_string(name))
      assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
      project = Path.join(target, "ptc-project.json")
      copy = Path.join(directory, "#{name}-explicit.json")

      assert {:error, %CommandOutcome{} = outcome} =
               operation.(["run", project, "--envelope", copy])

      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      refute File.exists?(copy)
      refute File.exists?(Path.join(target, ".ptc"))
    end
  end

  @tag :tmp_dir
  test "validate --envelope does not write the project run ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    copy = Path.join(directory, "validate.json")

    presentation =
      CommandFrontend.execute(
        ["validate", project, "--envelope", copy],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 0
    assert File.regular?(copy)
    assert Path.wildcard(Path.join([target, ".ptc", "envelopes", "*.json"])) == []
  end

  @tag :tmp_dir
  test "a permissive pre-existing artifact root names the directory and owner-only rule", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o755)

    presentation =
      CommandFrontend.execute(
        ["run", project],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ root
    assert presentation.stderr =~ "owner-only (0700)"
    assert presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "a permissive artifact child names that directory and the owner-only rule", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    for child <- ~w(envelopes inspection results traces) do
      path = Path.join(root, child)
      File.mkdir!(path)
      File.chmod!(path, 0o755)
    end

    presentation =
      CommandFrontend.execute(
        ["run", project],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ Path.join(root, "envelopes")
    assert presentation.stderr =~ "owner-only (0700)"
    assert presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "a missing artifact-root ancestor names the directory and the mkdir remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")
    missing = Path.join(target, "missing-artifact-parent")

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/destination_parent_unavailable"
    assert presentation.stderr =~ missing
    assert presentation.stderr =~ "mkdir -p #{missing}"
    refute presentation.stderr =~ "owner-only (0700)"
    refute File.exists?(missing)
  end

  # The shallowest missing ancestor is what failed, but creating only it fails
  # again on the next level; the remedy has to name the whole parent.
  @tag :tmp_dir
  test "several missing artifact-root levels still yield a remedy that works", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "outer/inner/.ptc")
    outer = Path.join(target, "outer")
    inner = Path.join(outer, "inner")

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "#{outer} does not exist"
    assert presentation.stderr =~ "mkdir -p #{inner}"

    File.mkdir_p!(inner)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    assert File.dir?(Path.join(inner, ".ptc"))
  end

  @tag :tmp_dir
  test "an artifact-root parent other users can replace names the mode remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "permissive-parent/.ptc")
    parent = Path.join(target, "permissive-parent")
    File.mkdir!(parent)
    File.chmod!(parent, 0o777)

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/destination_parent_unsafe"
    assert presentation.stderr =~ "#{parent} is writable by group or other"
    assert presentation.stderr =~ "chmod go-w #{parent}"
    refute presentation.stderr =~ "mkdir -p"
  end

  # The embedding entry point must report an unusable artifact root, not raise:
  # `publication` has no `invalid_destination` row for it to name. The root is
  # also where the envelope would go, so the ledger is lost with it.
  @tag :tmp_dir
  test "dispatch reports an unusable artifact root instead of raising", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["error"]["phase"] == "destination"
    assert envelope["error"]["code"] == "invalid_destination"
  end

  # A run that already finished must not be reported as never started: an
  # embedding caller would retry effects that already happened.
  @tag :tmp_dir
  test "an unpublishable envelope keeps the finished run's evidence", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])

    # Owner-only but not writable: the layout still passes every artifact-root
    # check, so the ledger fails only after the run has already finished.
    ledger = Path.join([target, ".ptc", "envelopes"])
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["artifact_class"] != "unclassified"
    assert envelope["execution"]["state"] == "finished"
    assert envelope["execution"]["outcome"] == "ok"
  end

  # A run that failed for its own reason must still say the audit envelope was
  # lost, or the two failures are indistinguishable to an embedding caller.
  @tag :tmp_dir
  test "a failed run whose envelope is also lost reports both", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])

    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    ledger = Path.join([target, ".ptc", "envelopes"])
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["status"] == "error"
  end

  # Without an envelope the run has no last-resort channel for the named
  # ancestor, so the same refusal arrives as a destination diagnostic. Pinned
  # here because the reference states the difference.
  @tag :tmp_dir
  test "a project without an envelope still refuses a missing artifact-root ancestor", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      project
      |> put_in(["artifacts", "root"], "missing-artifact-parent/.ptc")
      |> put_in(["artifacts", "envelope"], false)

    File.write!(project_path, Jason.encode!(project))

    presentation = run_project(project_path)

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/invalid_destination"
    refute File.exists?(Path.join(target, "missing-artifact-parent"))
  end

  # A sticky world-writable directory — /tmp is the everyday one — is accepted,
  # so it must not be reported as an unsafe ancestor.
  @tag :tmp_dir
  test "a sticky world-writable artifact-root parent is accepted", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "sticky-parent/.ptc")
    parent = Path.join(target, "sticky-parent")
    File.mkdir!(parent)
    # Erlang's change_mode carries only the low nine bits, so the sticky bit
    # this case is about has to be set through chmod itself.
    assert {_output, 0} = System.cmd("chmod", ["1777", parent])

    presentation = run_project(project_path)

    assert presentation.stderr == ""
    assert presentation.exit_status == 0
    assert File.dir?(Path.join(parent, ".ptc"))
  end

  @tag :tmp_dir
  test "--envelope into a missing parent names destination_parent_unavailable", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    missing_parent = Path.join(directory, "missing")
    copy = Path.join(missing_parent, "out.json")

    presentation =
      CommandFrontend.execute(
        ["run", project, "--envelope", copy],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/destination_parent_unavailable"
    assert presentation.stderr =~ missing_parent
  end

  @tag :tmp_dir
  test "project-backed repl preserves the manifest grammar", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--eval", "(+ 1 2)"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :manifest) ==
             Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :eval) == "(+ 1 2)"
  end

  @tag :tmp_dir
  test "project-backed repl preserves an explicit mission selector", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--mission", "review", "--eval", "42"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.options.mission == "review"
    assert Keyword.get(entry.arguments.ordered_options, :mission) == "review"
  end

  @tag :tmp_dir
  test "inspect-only project repl injects only the application manifest", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      Map.put(project, "host", %{
        "path" => "ptc-host.json",
        "env_file" => %{"path" => "missing.env"}
      })

    File.write!(project_path, Jason.encode!(project))

    File.write!(
      Path.join(target, "ptc-host.json"),
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_INSPECT_ONLY_ABSENT_KEY"}},
        "install" => %{}
      })
    )

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project_path, "--inspect-only", "--eval", "(+ 1 2)"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.options.inspect_only == true
    refute Map.has_key?(entry.arguments.options, :host_config)
    refute Keyword.has_key?(entry.arguments.frontend_options, :env_file)
  end

  @tag :tmp_dir
  test "inspect-only project repl rejects analysis profiles", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project,
                 "--inspect-only",
                 "--profile",
                 "run-analysis-v1"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.rejection.command == :repl
    assert entry.rejection.code == :conflicting_arguments
  end

  @tag :tmp_dir
  test "project-backed analysis derives artifact resources and preserves overrides", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")

    project =
      project_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["artifacts", "inspection"], true)

    File.write!(project_path, Jason.encode!(project))

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "private-run-analysis-v2",
                 "--private-unattended",
                 "--eval",
                 "(analysis/runs {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(entry.arguments.ordered_options, :resource) == [
             "traces=#{Path.join([target, ".ptc", "traces"])}",
             "inspection=#{Path.join([target, ".ptc", "inspection"])}"
           ]

    assert {:ok, catalog_entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "private-run-catalog-v1",
                 "--private-unattended",
                 "--eval",
                 "(analysis/catalog {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(catalog_entry.arguments.ordered_options, :resource) == [
             "traces=#{Path.join([target, ".ptc", "traces"])}",
             "inspection=#{Path.join([target, ".ptc", "inspection"])}"
           ]

    explicit = Path.join(target, "captured-traces")

    assert {:ok, overridden} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "run-analysis-v1",
                 "--resource",
                 "traces=#{explicit}",
                 "--eval",
                 "(analysis/runs {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(overridden.arguments.ordered_options, :resource) == [
             "traces=#{explicit}"
           ]
  end

  test "the repl option terminator leaves project-looking script arguments positional" do
    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--", "--project=missing.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--project=missing.json"
    assert entry.arguments.project == nil
  end

  @tag :tmp_dir
  test "project-backed repl inserts defaults before the option terminator", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--", "--manifest"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--manifest"
    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.project.config.path == project
  end

  @tag :tmp_dir
  test "passive doctor accepts a project and does not require its missing environment file", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      Map.put(project, "host", %{
        "path" => "missing-host.json",
        "env_file" => %{"path" => "missing.env"}
      })

    File.write!(project_path, Jason.encode!(project))

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["doctor", project_path, "--"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    refute Keyword.has_key?(entry.arguments.frontend_options, :env_file)
    assert entry.arguments.options.host_config == Path.join(target, "missing-host.json")
  end

  @tag :tmp_dir
  test "invalid project documents retain their schema diagnostic for every project command", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    base = target |> Path.join("ptc-project.json") |> File.read!() |> Jason.decode!()

    documents = [
      {"wrong-type", put_in(base, ["artifacts", "trace"], "yes"), "/artifacts/trace",
       "type schema rule"},
      {"unknown-key", Map.put(base, "artifactz", %{}), "", "unknown property"},
      {"missing-required", Map.delete(base, "application"), "/application",
       "missing a required property"}
    ]

    for {name, document, expected_path, message_fragment} <- documents,
        {command, suffix} <- [
          {"validate", []},
          {"run", []},
          {"doctor", []},
          {"doctor", ["--connect"]},
          {"models", []}
        ] do
      path = Path.join(target, "#{name}.json")
      File.write!(path, Jason.encode!(document))

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch([command, path | suffix])

      assert outcome.envelope["error"]["code"] == "project_schema_invalid",
             "#{command} #{name}"

      assert outcome.envelope["error"]["phase"] == "project"
      assert outcome.envelope["error"]["path"] == expected_path
      assert outcome.envelope["error"]["message"] =~ message_fragment

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "project",
               "name" => "ptc-project.json"
             }

      refute Jason.encode!(outcome.envelope) =~ directory
    end

    duplicate_path = Path.join(target, "duplicate-key.json")

    File.write!(
      duplicate_path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json","path":"other.json"}})
    )

    for {command, suffix} <- [
          {"validate", []},
          {"run", []},
          {"doctor", []},
          {"doctor", ["--connect"]},
          {"models", []}
        ] do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch([command, duplicate_path | suffix])

      assert outcome.envelope["error"]["phase"] == "project"
      assert outcome.envelope["error"]["code"] == "project_schema_invalid"
      assert outcome.envelope["error"]["path"] == "/application"
      assert outcome.envelope["error"]["message"] =~ "duplicate property"
      refute Jason.encode!(outcome.envelope) =~ directory
    end
  end

  @tag :tmp_dir
  test "oversized project documents publish envelopes without bootstrapping", %{
    tmp_dir: directory
  } do
    project_path = Path.join(directory, "oversized-project.json")

    File.write!(
      project_path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"padding":") <>
        String.duplicate("x", 300_000) <> ~s("})
    )

    parent = self()

    for command <- ~w(validate run doctor models) do
      envelope_path = Path.join(directory, "#{command}-oversized-envelope.json")

      presentation =
        CommandFrontend.execute(
          [command, project_path, "--envelope", envelope_path],
          :standalone,
          fn _arguments ->
            send(parent, :unexpected_bootstrap)
            {:ok, CommandRuntime.standalone()}
          end
        )

      assert presentation.exit_status == 3
      assert presentation.envelope_path == envelope_path
      assert presentation.outcome.envelope["error"]["phase"] == "project"
      assert presentation.outcome.envelope["error"]["code"] == "project_schema_invalid"
      assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
      refute_received :unexpected_bootstrap
    end
  end

  @tag :tmp_dir
  test "invalid host-requiring projects publish envelopes before a trailing terminator", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())
    parent = self()

    for {name, argv} <- [
          {"models", ["models", project_path]},
          {"doctor", ["doctor", project_path, "--connect"]}
        ] do
      envelope_path = Path.join(directory, "#{name}-invalid-project-envelope.json")

      presentation =
        CommandFrontend.execute(
          argv ++ ["--envelope", envelope_path, "--"],
          :standalone,
          fn _arguments ->
            send(parent, :unexpected_bootstrap)
            {:ok, CommandRuntime.standalone()}
          end
        )

      assert presentation.exit_status == 3
      assert presentation.envelope_path == envelope_path
      assert presentation.outcome.envelope["error"]["phase"] == "project"
      assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
      refute_received :unexpected_bootstrap
    end
  end

  @tag :tmp_dir
  test "an invalid project is admitted far enough to publish an explicit envelope", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())

    for argv <- [["models", project_path], ["doctor", project_path, "--connect"]] do
      assert {:ok, entry} =
               CommandEntry.open_with_ref(
                 argv,
                 :standalone,
                 "cmd-00000000000000000000000000"
               )

      assert entry.diagnostic.phase == :project
      refute Map.has_key?(entry.arguments.options, :host_config)
    end

    envelope_path = Path.join(directory, "invalid-project-envelope.json")
    parent = self()

    assert {:error, %CommandOutcome{} = direct} =
             CommandEngine.prepare(["run", project_path, "--envelope", envelope_path])

    assert direct.envelope["error"]["phase"] == "arguments"
    assert direct.envelope["error"]["code"] == "invalid_arguments"
    refute File.exists?(envelope_path)

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 3
    assert presentation.envelope_path == envelope_path
    assert presentation.outcome.envelope["error"]["phase"] == "project"
    assert presentation.outcome.envelope["error"]["path"] == "/artifacts/trace"
    assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
    refute_received :unexpected_bootstrap

    published = File.read!(envelope_path)

    refused =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert refused.exit_status == 2
    assert refused.envelope_path == nil
    assert refused.outcome.envelope["error"]["code"] == "envelope_destination_exists"
    assert File.read!(envelope_path) == published
    refute_received :unexpected_bootstrap
  end

  @tag :tmp_dir
  test "invalid project content does not turn malformed argv into an admitted failure", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())

    envelope_path = Path.join(directory, "must-not-exist.json")
    parent = self()

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--unknown", "value", "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 2
    assert presentation.envelope_path == nil
    assert presentation.outcome.envelope["error"]["phase"] == "arguments"
    assert presentation.stderr =~ "; unknown switch; accepted:"
    refute File.exists?(envelope_path)
    refute_received :unexpected_bootstrap

    for rest <- [
          ["--host-config", "host.json", "--bogus"],
          ["--host-config", "first.json", "--host-config", "second.json"]
        ] do
      assert {:error, expected} = CommandParser.parse(["models" | rest], :standalone)

      assert {:error, entry} =
               CommandEntry.open_with_ref(
                 ["models", project_path | rest],
                 :standalone,
                 "cmd-00000000000000000000000000"
               )

      assert entry.rejection == expected
    end
  end

  @tag :tmp_dir
  test "a project declaring no host says so rather than blaming the arguments", %{
    tmp_dir: directory
  } do
    # `ptc init` scaffolds no host block, so the two commands that need one are
    # reached with exactly the argument form their own --help prints. Blaming
    # the command line sends the reader back to the syntax, which was correct.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    for argv <- [["models", project], ["doctor", project, "--connect"]] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)

      assert outcome.envelope["error"]["code"] == "project_host_undeclared"
      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["message"] =~ "declares no host block"
    end
  end

  @tag :tmp_dir
  test "an explicit --host-config still serves a project that declares no host", %{
    tmp_dir: directory
  } do
    # The rejection must name a missing declaration, not forbid the command, so
    # the documented alternative in `ptc models --help` keeps working.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    host_path = Path.join(target, "ptc-host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_PROJECT_ABSENT_KEY"}},
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

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["models", "--host-config", host_path])

    assert [%{"alias" => "model"}] = outcome.envelope["result"]["installations"]

    # A project and a --host-config are documented alternatives, so combining
    # them stays an argument fault rather than silently ignoring the project.
    assert {:error, %CommandOutcome{} = combined} =
             CommandEngine.dispatch(["models", project, "--host-config", host_path])

    assert combined.envelope["error"]["code"] == "invalid_arguments"
  end

  @tag :tmp_dir
  test "a real argument fault is not reported as the missing host", %{tmp_dir: directory} do
    # The parser decides before the missing declaration is considered, so a
    # switch fault still reports itself instead of being explained away by the
    # project — which would send the reader to edit a file over a typo.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    for argv <- [
          ["models", project, "--bogus"],
          ["doctor", project, "--connect", "--bogus"],
          ["models", project, "--", "extra"],
          ["doctor", project, "--", "extra"],
          ["models", project, "--", "--host-config", "host.json"]
        ] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
    end
  end

  @tag :tmp_dir
  test "repl rejects ambiguous project authority modes", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--manifest", "other.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.rejection.code == :conflicting_arguments
  end

  defp project_with_artifact_root(target, root) do
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    File.write!(project_path, Jason.encode!(put_in(project, ["artifacts", "root"], root)))
    project_path
  end

  defp run_project(project_path) do
    CommandFrontend.execute(
      ["run", project_path],
      :standalone,
      fn _arguments -> {:ok, CommandRuntime.standalone()} end
    )
  end
end
