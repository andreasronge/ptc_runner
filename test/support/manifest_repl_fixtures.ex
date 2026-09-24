defmodule PtcRunner.TestSupport.ManifestReplFixtures do
  @moduledoc false

  # Shared by ManifestReplTest (async) and ManifestReplGlobalStateTest.

  @stdio_root Path.expand("../..", __DIR__)
  @stdio_fixture Path.expand("mcp_stdio_source_fixture.sh", __DIR__)

  def write_mcp_application(directory, marker, run_duration_ms, mode) do
    write_component(directory)
    manifest = Path.join(directory, "mcp.json")
    host = Path.join(directory, "mcp-host.json")

    File.write!(
      manifest,
      Jason.encode!(
        manifest_document(:normal, %{
          "workflow" => [],
          "mission" => [
            %{"name" => "workspace", "config" => %{"allow" => ["workspace.structured"]}}
          ]
        })
        |> Map.put("limits", %{
          "evaluation_timeout_ms" => 20_000,
          "run_duration_ms" => run_duration_ms
        })
      )
    )

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "manifest-repl-stdio-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "cwd" => @stdio_root,
              "args" => [@stdio_fixture, marker, mode],
              "start_timeout_ms" => 5_000,
              # The close marker is written by the fixture's EXIT trap, which a
              # SIGKILL after the default 250 ms grace skips on a loaded machine.
              "grace_ms" => 5_000
            },
            "tools" => %{
              "structured" => %{
                "as" => "workspace.structured",
                "effect" => "write",
                "model_visible" => true
              }
            },
            "ceilings" => %{"timeout_ms" => 20_000}
          }
        }
      })
    )

    {manifest, host}
  end

  def write_component(directory) do
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [input] (return input))")
  end

  def manifest_document(policy, providers) do
    %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "providers" => providers,
      "input" => %{"value" => %{}},
      "events" => %{"policy" => Atom.to_string(policy)}
    }
  end
end
