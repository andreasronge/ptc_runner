defmodule PtcRunner.Kernel.InspectOnlyReplTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectOnlyRepl
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.ReplDiagnosticCatalog

  test "Lisp.run_native inspect_only blocks tool calls" do
    assert {:error, blocked} =
             Lisp.run_native(~S|(tool/kernel-eval {:mission "x" :kind :source :source "1"})|,
               inspect_only: true
             )

    assert blocked.fail.reason == :inspect_only_unavailable
  end

  test "Kernel.run inspect_only does not invoke capabilities" do
    parent = self()

    {:ok, add} =
      Capability.new(
        name: "add",
        input_schema: %{"type" => "object", "additionalProperties" => true},
        callback: fn _arguments ->
          send(parent, :invoked)
          {:ok, %{"sum" => 3}}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [add])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "inspect-only-kernel-run")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        inspect_only: true
      )

    assert {:error, error} =
             Kernel.run("(return (tool/add {:left 1 :right 2}))", config)

    assert error.reason == :inspect_only_unavailable
    refute_received :invoked
  end

  @tag :tmp_dir
  test "opens a compile-and-inspect session without providers", %{tmp_dir: directory} do
    manifest_path = write_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path)

    assert %{kind: :workflow, declared_missions: [], inspect_only: true} =
             ReplSession.mode_info(session)

    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["helpers"]
    assert {:ok, answer, session} = ReplSession.eval(session, "(helpers/answer)")
    assert answer.return == 42

    assert {:error, blocked, session} =
             ReplSession.eval(
               session,
               ~S|(tool/kernel-eval {:mission "review" :kind :source :source "(return 1)"})|
             )

    assert blocked.fail.reason == :inspect_only_unavailable
    assert blocked.fail.message =~ "cannot use Kernel, provider, or capability routes"
    assert {:ok, _} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "mission inspect-only cannot see workflow component IDs", %{tmp_dir: directory} do
    manifest_path = write_mission_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path, mission: "review")

    assert %{kind: :mission, mission: "review", inspect_only: true} =
             ReplSession.mode_info(session)

    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["review"]
    assert {:ok, missing, session} = ReplSession.eval(session, ~S|(component "helpers")|)
    assert missing.return == nil
    assert {:ok, _} = ReplSession.close(session)
  end

  test "classify! keeps inspect_only_unavailable closed" do
    diagnostic = ReplDiagnosticCatalog.classify!(:inspect_only_unavailable)
    assert diagnostic.code == :inspect_only_unavailable
    assert diagnostic.message =~ "inspect-only"
    assert {:error, :unknown_repl_diagnostic} = ReplDiagnosticCatalog.classify(:unknown_tool)

    assert_raise ArgumentError, fn ->
      ReplDiagnosticCatalog.classify!(:unknown_tool)
    end
  end

  test "startup notice names a compile-and-inspect environment" do
    assert InspectOnlyRepl.startup_notice() ==
             "compile-and-inspect environment; not a runnable application environment"
  end

  @tag :tmp_dir
  test "inspect-only attaches tool-backed components and evaluates pure exports", %{
    tmp_dir: directory
  } do
    manifest_path = write_tool_backed_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path)
    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["helpers"]
    assert {:ok, answer, session} = ReplSession.eval(session, "(helpers/answer)")
    assert answer.return == 42

    assert {:error, blocked, session} = ReplSession.eval(session, "(helpers/lookup)")
    assert blocked.fail.reason == :inspect_only_unavailable
    assert {:ok, _} = ReplSession.close(session)

    assert {:ok, package, _input} =
             ApplicationPackage.acquire_directory(manifest_path,
               installed_limits: Limits.installed_defaults(),
               omit_input: true
             )

    deadline = System.monotonic_time(:millisecond) + 5_000

    assert {:ok, bundle} = BundleCompiler.compile(package.workflow_components, deadline)

    assert {:ok, _intern, catalog} =
             ComponentCatalog.build(package.workflow_components, bundle)

    assert {:error, {:missing_capability_requirement, ["search"]}} =
             WorkflowEnvironment.new(bundle: bundle, catalog: catalog)

    assert {:ok, inspect_only} =
             WorkflowEnvironment.new(
               bundle: bundle,
               catalog: catalog,
               inspect_only: true
             )

    assert inspect_only.inspect_only
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "inspect-only-mismatch")

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: inspect_only,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink
             )
  end

  @tag :tmp_dir
  test "inspect-only opens when the declared input file is missing", %{tmp_dir: directory} do
    manifest_path = write_missing_input_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path)
    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["helpers"]
    assert {:ok, _} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "workflow inspect-only ignores a broken unselected mission", %{tmp_dir: directory} do
    manifest_path = write_broken_mission_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path)

    assert %{kind: :workflow, declared_missions: ["broken"], inspect_only: true} =
             ReplSession.mode_info(session)

    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["helpers"]
    assert {:ok, _} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "mission inspect-only ignores a broken unselected workflow", %{tmp_dir: directory} do
    manifest_path = write_broken_workflow_manifest(directory)

    assert {:ok, session} = InspectOnlyRepl.open(manifest_path, mission: "review")
    assert {:ok, listed, session} = ReplSession.eval(session, "(components)")
    assert listed.return == ["review"]
    assert {:ok, _} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "interactive inspect-only keeps an explicit narrower manifest lifetime", %{
    tmp_dir: directory
  } do
    manifest_path = write_narrow_lifetime_manifest(directory)

    assert {:ok, package, _input} =
             ApplicationPackage.acquire_directory(manifest_path,
               installed_limits: Limits.installed_defaults(),
               omit_input: true,
               repl_interactive_loop: true
             )

    assert package.limits.run_duration_ms == 30_000
    assert {:ok, session} = InspectOnlyRepl.open(manifest_path, interactive_loop: true)
    assert {:ok, _} = ReplSession.close(session)
  end

  defp write_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"value" => %{}}
      })
    )

    path
  end

  # ex_dna:disable-for-next-line — Mix CLI and Kernel inspect-only tests keep independent fixtures
  defp write_mission_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    File.write!(Path.join(directory, "review.clj"), "(ns review) (defn answer [] 1)")
    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "review.clj"}]
          }
        },
        "input" => %{"value" => %{}}
      })
    )

    path
  end

  defp write_tool_backed_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      """
      (ns helpers)
      (defn answer [] 42)
      (defn lookup [] (tool/search {:query "x"}))
      (defn run [input] (return input))
      """
    )

    write_workflow_manifest(directory)
  end

  defp write_missing_input_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"path" => "missing-input.json"}
      })
    )

    path
  end

  defp write_broken_mission_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    File.write!(Path.join(directory, "broken.clj"), "(ns broken")
    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "missions" => %{
          "broken" => %{
            "components" => [%{"id" => "broken", "path" => "broken.clj"}]
          }
        },
        "input" => %{"value" => %{}}
      })
    )

    path
  end

  defp write_broken_workflow_manifest(directory) do
    File.write!(Path.join(directory, "broken.clj"), "(ns helpers")
    File.write!(Path.join(directory, "review.clj"), "(ns review) (defn answer [] 1)")
    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "broken.clj"}],
          "entry" => "helpers/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "review.clj"}]
          }
        },
        "input" => %{"value" => %{}}
      })
    )

    path
  end

  defp write_narrow_lifetime_manifest(directory) do
    File.write!(
      Path.join(directory, "helpers.clj"),
      "(ns helpers) (defn answer [] 42) (defn run [input] (return input))"
    )

    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"value" => %{}},
        "limits" => %{"run_duration_ms" => 30_000}
      })
    )

    path
  end

  defp write_workflow_manifest(directory) do
    path = Path.join(directory, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "helpers", "path" => "helpers.clj"}],
          "entry" => "helpers/run"
        },
        "input" => %{"value" => %{}}
      })
    )

    path
  end
end
