defmodule PtcRunner.Kernel.GitHubMCPE2ETest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc

  @moduletag :e2e
  @repository_commit "1f5361d24a72a822633e650a28159058f17c815b"

  @tag :tmp_dir
  test "host JSON checks and calls the pinned GitHub MCP server without leaking credentials", %{
    tmp_dir: dir
  } do
    binary = required_environment!("PTC_TEST_GITHUB_MCP_BINARY")
    token = required_environment!("PTC_TEST_GITHUB_TOKEN")
    paths = write_application(dir, binary)

    envelope_path = Path.join(dir, "command-envelope.json")

    run_output =
      capture_io(fn ->
        Mix.Task.reenable("ptc")

        Ptc.run([
          "run",
          paths.manifest,
          "--host-config",
          paths.host,
          "--trace-dir",
          Path.dirname(paths.trace),
          "--envelope",
          envelope_path
        ])
      end)

    envelope = envelope_path |> File.read!() |> Jason.decode!()
    assert Jason.decode!(run_output) == envelope["result"]["value"]
    assert envelope["status"] == "ok"

    assert %{
             "status" => "ok",
             "value" => %{
               "outcome" => "returned",
               "value" => %{
                 "status" => "ok",
                 "value" => %{"resources" => [%{"text" => readme} | _]}
               }
             }
           } = envelope["result"]["value"]

    assert readme =~ "# PtcRunner"
    refute run_output =~ token
    refute File.read!(envelope_path) =~ token
    trace = Path.join(Path.dirname(paths.trace), envelope["run_ref"] <> ".jsonl")
    refute File.read!(trace) =~ token
    refute_server_process(binary)
  end

  defp write_application(dir, binary) do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"mission" "default" "kind" :source "source" (get input "program")})))|
    )

    program = """
    (return
      (tool/github.get-file
        {"owner" "andreasronge"
         "repo" "ptc_runner"
         "path" "README.md"
         "sha" "#{@repository_commit}"}))
    """

    manifest = %{
      "$schema" => Path.expand("priv/schemas/ptc-application-manifest.schema.json"),
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{
        "mission" => [
          %{
            "name" => "github",
            "config" => %{
              "allow" => ["github.get-file"],
              "timeout_ms" => 15_000,
              "max_result_bytes" => 250_000
            }
          }
        ]
      },
      "limits" => %{
        "evaluation_timeout_ms" => 15_000,
        "run_duration_ms" => 60_000
      }
    }

    host = %{
      "$schema" => Path.expand("priv/schemas/ptc-host-config.schema.json"),
      "credentials" => %{
        "github_token" => %{"env" => "PTC_TEST_GITHUB_TOKEN"}
      },
      "install" => %{
        "github" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => binary,
            "cwd" => ".",
            "args" => [
              "stdio",
              "--read-only",
              "--tools=get_file_contents"
            ],
            "inherit_environment" => false,
            "env" => %{
              "GITHUB_PERSONAL_ACCESS_TOKEN" => %{"binding" => "github_token"}
            },
            "start_timeout_ms" => 10_000
          },
          "tools" => %{
            "get_file_contents" => %{
              "as" => "github.get-file",
              "effect" => "read",
              "description" => "Read one path at an immutable GitHub commit.",
              "model_visible" => true
            }
          },
          "installation_revision" => "github-mcp-server-v1.7.0",
          "ceilings" => %{
            "timeout_ms" => 15_000,
            "max_catalog_tools" => 16,
            "max_result_bytes" => 250_000
          }
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "ptc-host.json")
    trace_path = Path.join(dir, "run.jsonl")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))

    %{manifest: manifest_path, host: host_path, trace: trace_path}
  end

  defp required_environment!(name) do
    case System.fetch_env(name) do
      {:ok, value} when byte_size(value) > 0 -> value
      _missing -> flunk("#{name} is required for the GitHub MCP E2E")
    end
  end

  defp refute_server_process(binary) do
    {processes, 0} = System.cmd("ps", ["-axo", "command="])

    refute processes
           |> String.split("\n", trim: true)
           |> Enum.any?(&String.starts_with?(&1, binary <> " "))
  end
end
