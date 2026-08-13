defmodule PtcRunner.Kernel.FilesystemMCPE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Runs the committed TypeScript filesystem sample through host installation,
  manifest selection, MCP stdio, and the PTC-Lisp mission boundary.

  The server is intentionally not represented by an Elixir provider builder:
  this is the acceptance proof that a new filesystem capability can arrive
  without changing the runtime.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @server Path.expand("../../../examples/mcp/filesystem/dist/server.js", __DIR__)

  @tag :tmp_dir
  test "host JSON installs an immutable nested-filesystem capability without Elixir wiring", %{
    tmp_dir: dir
  } do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node)

    assert {:ok, host} = HostConfig.load(paths.host)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, built} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)

    assert [snapshot] = built.config.connector_snapshots
    assert snapshot["provider"] == "workspace"
    assert snapshot["declaration"]["source"] == "mcp"
    assert snapshot["acquisition"]["protocol"] == "mcp-2026-07-28"
    assert snapshot["acquisition"]["transport"] == "stdio"
    assert snapshot["acquisition"]["launcher_protocol_version"] == 1
    assert snapshot["acquisition"]["launcher_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["acquisition"]["server_executable_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert length(snapshot["acquisition"]["tools"]) == 5

    assert {:ok, result} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()

    assert %{
             "status" => "ok",
             "value" => %{"outcome" => "returned", "value" => values}
           } = result.value

    assert %{
             "info" => %{"status" => "ok", "value" => info},
             "listed" => %{"status" => "ok", "value" => listed},
             "found" => %{"status" => "ok", "value" => found},
             "matches" => %{"status" => "ok", "value" => matches},
             "read" => %{"status" => "ok", "value" => read}
           } = values

    snapshot_hash = info["snapshot_hash"]
    assert snapshot["content_snapshot_hash"] == snapshot_hash
    assert info["file_count"] == 2
    assert listed["snapshot_hash"] == snapshot_hash
    assert Enum.any?(listed["items"], &(&1["path"] == "lib/nested"))
    assert found["items"] == [%{"path" => "lib/nested/target.txt"}]

    assert [%{"path" => "lib/nested/target.txt", "line" => 2, "text" => "needle"}] =
             matches["items"]

    assert read["snapshot_hash"] == snapshot_hash
    assert read["lines"] == [%{"line" => 2, "text" => "needle"}]
    refute inspect(values) =~ "TOP-SECRET"
  end

  @tag :tmp_dir
  test "an invalid content identity closes provider assembly", %{tmp_dir: dir} do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node)

    host =
      paths.host
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["install", "workspace", "snapshot_identity", "field"], "missing_hash")

    File.write!(paths.host, Jason.encode!(host))
    assert {:ok, decoded} = HostConfig.load(paths.host)

    assert {:ok, registry} =
             HostInstallation.catalog(decoded)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(decoded, catalog)
             end)

    assert {:error, :mcp_invalid_snapshot_identity} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
  end

  defp write_application(dir, node) do
    File.mkdir_p!(Path.join(dir, "lib/nested"))
    File.mkdir_p!(Path.join(dir, "lib/private"))
    File.write!(Path.join(dir, "lib/readme.txt"), "visible\n")
    File.write!(Path.join(dir, "lib/nested/target.txt"), "first\nneedle\nlast\n")
    File.write!(Path.join(dir, "lib/private/secret.txt"), "TOP-SECRET\n")

    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"mission" "default" "kind" :source "source" (get input "program")})))|
    )

    program = """
    (let [info (tool/workspace.snapshot-info {})
          listed (tool/workspace.list {"path" "lib"})
          found (tool/workspace.find {"query" "target"})
          matches (tool/workspace.search {"query" "needle"})
          read (tool/workspace.read
                 {"path" "lib/nested/target.txt" "start_line" 2 "line_count" 1})]
      (return
        {"info" info
         "listed" listed
         "found" found
         "matches" matches
         "read" read}))
    """

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
      "providers" => %{"mission" => [%{"name" => "workspace"}]},
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
            "args" => [
              @server,
              "--root",
              dir,
              "--include",
              "lib/**",
              "--exclude",
              "lib/private/**"
            ],
            "inherit_environment" => false,
            "env" => %{},
            "start_timeout_ms" => 15_000
          },
          "tools" => %{
            "list_directory" => %{"as" => "workspace.list", "effect" => "read"},
            "search_files" => %{"as" => "workspace.find", "effect" => "read"},
            "search_text" => %{"as" => "workspace.search", "effect" => "read"},
            "read_text_file" => %{"as" => "workspace.read", "effect" => "read"},
            "snapshot_info" => %{
              "as" => "workspace.snapshot-info",
              "effect" => "read"
            }
          },
          "snapshot_identity" => %{
            "tool" => "snapshot_info",
            "field" => "snapshot_hash"
          },
          "installation_revision" => "filesystem-sample-0.1.0",
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
