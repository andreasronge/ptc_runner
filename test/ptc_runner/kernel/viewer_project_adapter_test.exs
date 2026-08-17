defmodule PtcRunner.Kernel.ViewerProjectAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.ViewerProjectAdapter

  @demo_manifest "examples/viewer-live-dashboard/ptc.json"

  describe "the shipped demo manifest" do
    setup do
      {:ok, project} = ViewerProjectAdapter.describe(@demo_manifest)
      %{project: project}
    end

    test "reports its label, entry, and the path as configured", %{project: project} do
      assert project.name == "live-dashboard-demo"
      assert project.manifest == @demo_manifest
      assert project.entry == "demo.live/run"
      assert %{"topics" => topics} = project.input
      assert length(topics) == 12
    end

    test "describes the workflow environment with sources for both components", %{
      project: project
    } do
      [workflow | missions] = project.environments
      assert workflow.name == "workflow"
      assert workflow.kind == "workflow"
      assert Enum.map(missions, & &1.name) == ["greet", "stats"]

      assert [%{id: "llm", library: true}, %{id: "demo.live", library: false}] =
               workflow.components

      library = Enum.find(workflow.components, & &1.library)
      assert library.source =~ "(ns llm"
      assert library.path == "priv/preludes/kernel/llm.clj"

      file = Enum.find(workflow.components, &(not &1.library))
      assert file.path == "demo.clj"
      assert file.source =~ "(ns demo.live"
    end

    test "names the provider but claims no tools without a host configuration", %{
      project: project
    } do
      [workflow | _missions] = project.environments
      assert %{providers: [%{name: "deepseek", source: nil}], tools: []} = workflow
    end

    test "emits every catalog limit, with the manifest's overrides as effective", %{
      project: project
    } do
      assert length(project.limits) == length(LimitCatalog.rows())

      by_name = Map.new(project.limits, &{&1.name, &1})

      assert %{effective: 120_000, default: 30_000, unit: :milliseconds} =
               by_name["run_duration_ms"]

      assert %{effective: 110_000, default: 30_000} = by_name["workflow_timeout_ms"]

      untouched = by_name["subordinate_evaluations"]
      assert untouched.effective == untouched.default
    end
  end

  describe "host configuration" do
    @tag :tmp_dir
    test "supplies provider sources and tool effects", %{tmp_dir: dir} do
      manifest = Path.join(dir, "ptc.json")
      write_docs_manifest(manifest)

      host_config = Path.join(dir, "host.json")

      File.write!(
        host_config,
        Jason.encode!(%{
          "install" => %{"docs" => docs_installation()}
        })
      )

      {:ok, project} = ViewerProjectAdapter.describe(manifest, host_config: host_config)

      assert [environment] = project.environments
      assert environment.providers == [%{name: "docs", source: "mcp"}]

      assert environment.tools == [
               %{name: "publish-doc", effect: "write"},
               %{name: "search-docs", effect: "read"}
             ]
    end

    @tag :tmp_dir
    test "uses host ceilings and installed-only limits for the effective limit table", %{
      tmp_dir: dir
    } do
      manifest = Path.join(dir, "ptc.json")
      host_config = Path.join(dir, "host.json")

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{"components" => [], "entry" => "app/run"},
          "input" => %{"value" => %{}},
          "limits" => %{"run_duration_ms" => 90_000}
        })
      )

      File.write!(
        host_config,
        Jason.encode!(%{
          "install" => %{"docs" => docs_installation()},
          "limits" => %{
            "run_duration_ms" => 100_000,
            "local_preflight_timeout_ms" => 9_000
          }
        })
      )

      assert {:ok, project} = ViewerProjectAdapter.describe(manifest, host_config: host_config)
      by_name = Map.new(project.limits, &{&1.name, &1})
      assert by_name["run_duration_ms"].effective == 90_000
      assert by_name["local_preflight_timeout_ms"].effective == 9_000
    end

    @tag :tmp_dir
    test "an unreadable host configuration leaves tools empty rather than failing", %{
      tmp_dir: dir
    } do
      manifest = Path.join(dir, "ptc.json")
      write_docs_manifest(manifest)

      {:ok, project} =
        ViewerProjectAdapter.describe(manifest, host_config: Path.join(dir, "missing.json"))

      assert [%{providers: [%{name: "docs", source: nil}], tools: []}] = project.environments
    end
  end

  describe "missions" do
    @tag :tmp_dir
    test "become their own environments, selecting from the mission provider pool", %{
      tmp_dir: dir
    } do
      manifest = Path.join(dir, "ptc.json")
      File.write!(Path.join(dir, "triage.clj"), "(ns triage)")

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{"components" => [], "entry" => "app/run"},
          "input" => %{"value" => %{}},
          "providers" => %{
            "workflow" => [%{"name" => "planner"}],
            "mission" => [%{"name" => "reader"}, %{"name" => "writer"}]
          },
          "missions" => %{
            "triage" => %{
              "components" => [%{"id" => "triage", "path" => "triage.clj"}],
              "providers" => ["reader"]
            },
            "audit" => %{"components" => []}
          }
        })
      )

      {:ok, project} = ViewerProjectAdapter.describe(manifest)

      assert [workflow, audit, triage] = project.environments
      assert workflow.kind == "workflow"
      assert {audit.name, audit.kind} == {"audit", "mission"}
      assert audit.providers == []

      assert triage.name == "triage"
      assert Enum.map(triage.providers, & &1.name) == ["reader"]
      assert [%{id: "triage", source: "(ns triage)"}] = triage.components
    end
  end

  describe "unusable input" do
    test "reports a missing manifest" do
      assert {:error, :enoent} = ViewerProjectAdapter.describe("does/not/exist.json")
    end

    @tag :tmp_dir
    test "reports a manifest that is not JSON", %{tmp_dir: dir} do
      manifest = Path.join(dir, "ptc.json")
      File.write!(manifest, "not json")

      assert {:error, :invalid_manifest} = ViewerProjectAdapter.describe(manifest)
    end

    @tag :tmp_dir
    test "reports a manifest declaring an unknown limit", %{tmp_dir: dir} do
      manifest = Path.join(dir, "ptc.json")

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{"components" => [], "entry" => "app/run"},
          "limits" => %{"not_a_limit" => 5}
        })
      )

      assert {:error, :invalid_manifest} = ViewerProjectAdapter.describe(manifest)
    end

    @tag :tmp_dir
    test "refuses component sources outside the canonical confined boundary", %{tmp_dir: dir} do
      outside = Path.join(Path.dirname(dir), "viewer-project-outside.clj")
      File.write!(outside, "(ns outside)")
      on_exit(fn -> File.rm(outside) end)

      for {name, source_path} <- [
            {"traversal", "../viewer-project-outside.clj"},
            {"directory", "source-dir"},
            {"invalid-utf8", "invalid.clj"},
            {"oversized", "oversized.clj"}
          ] do
        case name do
          "directory" ->
            File.mkdir!(Path.join(dir, source_path))

          "invalid-utf8" ->
            File.write!(Path.join(dir, source_path), <<255>>)

          "oversized" ->
            File.write!(Path.join(dir, source_path), String.duplicate("x", 2_000_001))

          _other ->
            :ok
        end

        manifest = Path.join(dir, "#{name}.json")

        File.write!(
          manifest,
          Jason.encode!(%{
            "version" => 1,
            "workflow" => %{
              "components" => [%{"id" => "bad.source", "path" => source_path}],
              "entry" => "bad.source/run"
            },
            "input" => %{"value" => %{}}
          })
        )

        assert {:error, :invalid_manifest} = ViewerProjectAdapter.describe(manifest)
      end
    end

    @tag :tmp_dir
    test "refuses a symlinked component source", %{tmp_dir: dir} do
      outside = Path.join(Path.dirname(dir), "viewer-project-symlink-target.clj")
      link = Path.join(dir, "linked.clj")
      File.write!(outside, "(ns linked)")
      File.ln_s!(outside, link)
      on_exit(fn -> File.rm(outside) end)
      manifest = Path.join(dir, "ptc.json")

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{
            "components" => [%{"id" => "linked.source", "path" => "linked.clj"}],
            "entry" => "linked.source/run"
          },
          "input" => %{"value" => %{}}
        })
      )

      assert {:error, :invalid_manifest} = ViewerProjectAdapter.describe(manifest)
    end
  end

  defp docs_installation do
    %{
      "source" => "mcp",
      "installation_revision" => "docs-v1",
      "transport" => %{
        "type" => "stdio",
        "command" => "docs-server",
        "args" => [],
        "inherit_environment" => false,
        "env" => %{}
      },
      "tools" => %{
        "search" => %{"as" => "search-docs", "effect" => "read"},
        "publish" => %{"as" => "publish-doc", "effect" => "write"}
      }
    }
  end

  defp write_docs_manifest(path) do
    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{"components" => [], "entry" => "app/run"},
        "input" => %{"value" => %{}},
        "providers" => %{"workflow" => [%{"name" => "docs"}]}
      })
    )
  end
end
