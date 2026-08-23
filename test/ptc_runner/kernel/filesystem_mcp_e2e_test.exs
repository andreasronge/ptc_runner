defmodule PtcRunner.Kernel.FilesystemMCPE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Runs the published `ptc-fs-mcp@0.1.0` package through host installation,
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
  alias PtcRunner.TestSupport.PtcFsMCP
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.TestHelpers

  if reason = TestHelpers.executable_skip_reason(["node", "npm"]) do
    @moduletag skip: reason
  end

  @tag :tmp_dir
  test "host JSON installs a live nested-filesystem capability without Elixir wiring", %{
    tmp_dir: dir
  } do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    cli = PtcFsMCP.install!(dir)
    paths = write_application(dir, node, cli)

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
    assert snapshot["installation_config_digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    refute Map.has_key?(snapshot, "content_snapshot_hash")
    assert length(snapshot["acquisition"]["tools"]) == 4

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
             "listed" => %{"status" => "ok", "value" => listed},
             "found" => %{"status" => "ok", "value" => found},
             "matches" => %{"status" => "ok", "value" => matches},
             "read" => %{"status" => "ok", "value" => read}
           } = values

    assert content_hash?(listed["content_hash"])
    assert Enum.any?(listed["items"], &(&1["path"] == "lib/nested"))
    assert found["items"] == [%{"path" => "lib/nested/target.txt"}]
    assert content_hash?(found["content_hash"])

    assert [%{"path" => "lib/nested/target.txt", "line" => 2, "text" => "needle"}] =
             matches["items"]

    assert content_hash?(matches["content_hash"])
    assert content_hash?(read["content_hash"])

    assert read["items"] == [
             %{
               "byte_offset" => 0,
               "text" => "first\nneedle\nlast\n"
             }
           ]

    assert read["next_cursor"] == nil
    refute inspect(values) =~ "TOP-SECRET"
  end

  defp content_hash?(value) when is_binary(value),
    do: value =~ ~r/\A(?:sha256:)?[0-9a-f]{64}\z/

  defp content_hash?(_value), do: false

  defp write_application(dir, node, cli) do
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
    (let [listed (tool/workspace.list {"path" "lib"})
          found (tool/workspace.find {"query" "target"})
          matches (tool/workspace.search {"query" "needle"})
          read (tool/workspace.read {"path" "lib/nested/target.txt"})]
      (return
        {"listed" listed
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
              cli,
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
            "read_text_file" => %{"as" => "workspace.read", "effect" => "read"}
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
