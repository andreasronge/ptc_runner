defmodule PtcRunner.Kernel.PtcFsMCPStdioTest do
  @moduledoc """
  Reproduces the MCP stdio inspection and mutation-state defects against the
  published `ptc-fs-mcp` package over a hermetic spawn.
  """

  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.TestSupport.PtcFsMCP
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.TestHelpers

  if reason = TestHelpers.executable_skip_reason(["node", "npm"]) do
    @moduletag skip: reason
  end

  @tag :tmp_dir
  test "ptc-fs-mcp startup stderr is inspected and a refused write is not indeterminate", %{
    tmp_dir: dir
  } do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    cli = PtcFsMCP.install!(dir)
    paths = write_application(dir, node, cli)
    inspection_path = Path.join(dir, "run.inspection.jsonl")

    assert {:ok, host} = HostConfig.load(paths.host)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, result} =
             paths.manifest
             |> ApplicationPackage.request_directory(
               installed_limits: registry.installed_limits,
               inspection_capture: true
             )
             |> RunLifecycle.build(registry, inspect: inspection_path)
             |> RunLifecycle.execute()

    failure = get_in(result.value, ["value", "value"])

    assert %{
             "status" => "error",
             "kind" => "provider_error",
             "reason" => "domain_error",
             "retryable?" => false
           } = failure

    refute Map.has_key?(failure, "mutation_state")

    assert {:ok, records} = InspectionArtifact.load(inspection_path)
    stderrs = Enum.filter(records, &(&1["record_type"] == "mcp-stderr"))

    assert Enum.any?(stderrs, fn record ->
             record["payload"]["transport"] == "stdio" and
               record["payload"]["text"] =~ "write_text_file will refuse every call"
           end)
  end

  defp write_application(dir, node, cli) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/target.txt"), "first\nneedle\nlast\n")

    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"mission" "default" "kind" :source "source" (get input "program")})))|
    )

    program = ~S|(return (tool/workspace.write {"path" "../escaped.txt" "content" "nope"}))|

    manifest = %{
      "$schema" => Path.expand("priv/schemas/ptc-application-manifest.schema.json"),
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "missions" => %{
        "default" => %{
          "components" => [],
          "data" => %{},
          "providers" => ["workspace"]
        }
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{
        "mission" => [%{"name" => "workspace", "config" => %{"allow" => ["workspace.write"]}}]
      },
      "limits" => %{"evaluation_timeout_ms" => 15_000, "run_duration_ms" => 60_000}
    }

    host = %{
      "$schema" => Path.expand("priv/schemas/ptc-host-config.schema.json"),
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => node,
            "cwd" => dir,
            "args" => [cli, "--root", dir, "--include", "lib/**"],
            "inherit_environment" => false,
            "env" => %{},
            "start_timeout_ms" => 15_000
          },
          "tools" => %{
            "write_text_file" => %{"as" => "workspace.write", "effect" => "write"}
          },
          "installation_revision" => "ptc-fs-mcp-0.1.0",
          "ceilings" => %{
            "timeout_ms" => 15_000,
            "max_catalog_tools" => 8,
            "max_result_bytes" => 262_144
          }
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "ptc-host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))
    %{manifest: manifest_path, host: host_path}
  end
end
