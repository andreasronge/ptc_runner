defmodule PtcRunner.Kernel.ViewerProjectAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.ViewerProjectAdapter

  @demo_manifest "docs/plans/viewer-live-run-demo/ptc.json"

  describe "the shipped demo manifest" do
    setup do
      {:ok, project} = ViewerProjectAdapter.describe(@demo_manifest)
      %{project: project}
    end

    test "reports its label, entry, and the path as configured", %{project: project} do
      assert project.name == "live-dashboard-demo"
      assert project.manifest == @demo_manifest
      assert project.entry == "demo.live/run"
    end

    test "describes the workflow environment with sources for both components", %{
      project: project
    } do
      assert [workflow] = project.environments
      assert workflow.name == "workflow"
      assert workflow.kind == "workflow"

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
      assert [%{providers: [%{name: "deepseek", source: nil}], tools: []}] = project.environments
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

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{"components" => [], "entry" => "app/run"},
          "providers" => %{"workflow" => [%{"name" => "docs"}]}
        })
      )

      host_config = Path.join(dir, "host.json")

      File.write!(
        host_config,
        Jason.encode!(%{
          "install" => %{
            "docs" => %{
              "source" => "mcp",
              "tools" => %{
                "search" => %{"as" => "search-docs", "effect" => "read"},
                "publish" => %{"as" => "publish-doc", "effect" => "write"}
              }
            }
          }
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
    test "an unreadable host configuration leaves tools empty rather than failing", %{
      tmp_dir: dir
    } do
      manifest = Path.join(dir, "ptc.json")

      File.write!(
        manifest,
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{"components" => [], "entry" => "app/run"},
          "providers" => %{"workflow" => [%{"name" => "docs"}]}
        })
      )

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
      assert Enum.map(audit.providers, & &1.name) == ["reader", "writer"]

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
  end
end
