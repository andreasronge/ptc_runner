defmodule PtcRunner.TestSupport.ReplFrontendFixtures do
  @moduledoc false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.MixCommandAdapter

  def run_repl(args, frontend_opts \\ []),
    do: MixCommandAdapter.run_task(["repl" | args], frontend_opts).outcome

  def profile_args(source, output_directory) do
    [
      "--profile",
      "run-analysis-v1",
      "--resource",
      "traces=#{source}",
      "--session-trace-dir",
      output_directory
    ]
  end

  def decode_jsonl(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # ex_dna:disable-for-next-line — REPL boundary tests keep their trace fixture explicit
  def seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{missions: %{}})

    :ok =
      EventSink.emit(sink, "run-stopped", %{
        outcome: :ok,
        reason: nil,
        usage: %{llm_budget: %{"total_tokens" => nil, "cost" => nil}}
      })

    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end

  def write_missing_credential_repl(directory) do
    File.write!(Path.join(directory, "credential-main.clj"), "(ns app) (defn run [x] (return x))")
    File.write!(Path.join(directory, "credential-review.clj"), "(ns review)")
    manifest_path = Path.join(directory, "credential-repl.json")
    host_path = Path.join(directory, "credential-repl-host.json")

    workflow_declarations = [
      %{"name" => "alpha"},
      %{"name" => "omega"}
    ]

    mission_declarations = [
      %{"name" => "workspace-alpha"},
      %{"name" => "workspace-omega"}
    ]

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "credential-main.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{
          "review" => %{
            "components" => [%{"id" => "review", "path" => "credential-review.clj"}],
            "providers" => ["workspace-alpha", "workspace-omega"]
          }
        },
        "input" => %{"value" => %{}},
        "providers" => %{
          "workflow" => workflow_declarations,
          "mission" => mission_declarations
        }
      })
    )

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{
          "alpha-key" => %{"env" => "PTC_REPL_ABSENT_ALPHA_KEY"},
          "omega-key" => %{"env" => "PTC_REPL_ABSENT_OMEGA_KEY"}
        },
        "install" => %{
          "alpha" => repl_llm_installation("alpha-key"),
          "omega" => repl_llm_installation("omega-key"),
          "workspace-alpha" => repl_mcp_installation("alpha-key"),
          "workspace-omega" => repl_mcp_installation("omega-key")
        }
      })
    )

    {manifest_path, host_path}
  end

  def repl_llm_installation(credential) do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "repl-missing-credential-v1",
      "model" => "openrouter:test/model",
      "credential" => credential
    }
  end

  def repl_mcp_installation(credential) do
    %{
      "source" => "mcp",
      "installation_revision" => "repl-missing-credential-v1",
      "transport" => %{
        "type" => "stdio",
        "command" => System.find_executable("sh"),
        "env" => %{"TOKEN" => %{"binding" => credential}}
      },
      "tools" => %{"read" => %{"as" => "#{credential}.read", "effect" => "read"}}
    }
  end
end
