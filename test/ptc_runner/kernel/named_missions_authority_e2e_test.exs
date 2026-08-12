defmodule PtcRunner.Kernel.NamedMissionsAuthorityE2ETest do
  @moduledoc """
  per-mission provider grants are negative authority, not an instruction.

  Two named missions declared in the manifest. The `writing` space is granted a
  host-declared `write` mapping; the `review` space is granted only a `read`
  mapping. The proof is that the review space cannot reach the write tool at
  all — the grant is absent from its environment, so the program does not even
  compile there.

  The same sample server backs both installations. `effect` is host-owned, so
  declaring one mapping `write` is a host statement about authority, not a
  claim about what the server does.
  """
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @server Path.expand("../../../examples/mcp/filesystem/dist/server.js", __DIR__)

  @tag :tmp_dir
  test "a named mission cannot reach a provider it was not granted", %{tmp_dir: dir} do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node)

    assert {:ok, host} = HostConfig.load(paths.host)
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    assert {:ok, built} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)

    assert {:ok, result} = RunLifecycle.execute({:ok, built})
    values = result.value

    # The writing space holds the write-declared grant and can call it.
    assert get_in(values, ["wrote", "outcome"]) == "returned"
    assert get_in(values, ["wrote", "value", "status"]) == "ok"

    # The review space holds only the read grant. This is not a runtime denial:
    # the tool is absent from that environment's catalogue, so the program does
    # not resolve at all.
    assert %{"review_write_attempt" => attempt} = values
    assert attempt["outcome"] == "evaluation_error"
    assert attempt["kind"] == "unknown_tool"
    assert attempt["details"]["message"] =~ "Unknown tool: notes.commit"
    assert attempt["details"]["message"] =~ "notes.read"
    refute attempt["details"]["capability_activity?"]

    # And the read grant the review space does hold still works.
    assert get_in(values, ["reviewed", "outcome"]) == "returned"
    assert get_in(values, ["reviewed", "value", "status"]) == "ok"
  end

  defp write_application(dir, node) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/note.txt"), "alpha\nbravo\n")

    File.write!(
      Path.join(dir, "workflow.clj"),
      """
      (ns app "Two spaces with different authority.")

      (defn run [_input]
        (let [wrote (kernel/eval-source-in "writing"
                      "(return (tool/notes.commit {\\"path\\" \\"lib/note.txt\\"}))")
              review-write (kernel/eval-source-in "review"
                             "(return (tool/notes.commit {\\"path\\" \\"lib/note.txt\\"}))")
              reviewed (kernel/eval-source-in "review"
                         "(return (tool/notes.read {\\"path\\" \\"lib/note.txt\\"}))")]
          (return
            {"wrote" wrote
             "review_write_attempt" review-write
             "reviewed" reviewed})))
      """
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"id" => "app", "path" => "workflow.clj", "dependencies" => ["kernel"]},
          %{"library" => "kernel"}
        ],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "mission" => [
          %{"name" => "notes_write", "config" => %{"allow" => ["notes.commit"]}},
          %{"name" => "notes_read"}
        ]
      },
      "missions" => %{
        "writing" => %{"providers" => ["notes_write"]},
        "review" => %{"providers" => ["notes_read"]}
      },
      "limits" => %{"evaluation_timeout_ms" => 15_000, "run_duration_ms" => 90_000}
    }

    transport = fn ->
      %{
        "type" => "stdio",
        "command" => node,
        "cwd" => dir,
        "args" => [@server, "--root", dir, "--include", "lib/**"],
        "inherit_environment" => false,
        "env" => %{},
        "start_timeout_ms" => 15_000
      }
    end

    ceilings = %{"timeout_ms" => 15_000, "max_catalog_tools" => 8, "max_result_bytes" => 262_144}

    host = %{
      "install" => %{
        # Host-declared write authority. The server is read-only; `effect` is a
        # host statement about what the runtime must assume, and a server
        # cannot change it.
        "notes_write" => %{
          "source" => "mcp",
          "transport" => transport.(),
          "tools" => %{
            "read_text_file" => %{"as" => "notes.commit", "effect" => "write"}
          },
          "installation_revision" => "notes-write-0.1.0",
          "ceilings" => ceilings
        },
        "notes_read" => %{
          "source" => "mcp",
          "transport" => transport.(),
          "tools" => %{
            "read_text_file" => %{"as" => "notes.read", "effect" => "read"}
          },
          "installation_revision" => "notes-read-0.1.0",
          "ceilings" => ceilings
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
