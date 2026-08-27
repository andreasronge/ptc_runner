defmodule PtcRunner.TestSupport.CommandEngineFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.TestSupport.TestHelpers

  @zero_entropy <<0::128>>
  @stdio_root Path.expand("../..", __DIR__)
  @stdio_fixture Path.expand("mcp_stdio_source_fixture.sh", __DIR__)

  def authorization_subject(:environment_file_not_found), do: nil

  def authorization_subject(_code) do
    {:ok, subject} = CommandSubject.provider("workspace", :local)
    subject
  end

  def assert_error(argv, phase, code) do
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(argv)

    assert outcome.envelope["error"]["phase"] == phase
    assert outcome.envelope["error"]["code"] == code
    assert outcome.envelope["error"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
    outcome
  end

  def assert_schema_valid(envelope) do
    assert {:ok, root} = CommandContract.envelope_schema_root()
    assert {:ok, _validated} = JSV.validate(envelope, root, cast: false)
  end

  def assert_schema_invalid(envelope) do
    assert {:ok, root} = CommandContract.envelope_schema_root()
    assert {:error, _reason} = JSV.validate(envelope, root, cast: false)
  end

  def diagnostic_for_row(row) do
    case DiagnosticCatalog.subject_policy(row.phase, row.code) do
      :required ->
        [operation | _rest] = DiagnosticCatalog.subject_operations(row.phase, row.code)

        occurrence =
          case DiagnosticCatalog.subject_occurrence_policy(row.phase, row.code, operation) do
            :forbidden -> nil
            _allowed -> %{destination: :workflow, index: 0}
          end

        {:ok, subject} =
          CommandSubject.provider("safe", operation, occurrence)

        CommandDiagnostic.new!(row.phase, row.code,
          subject: subject,
          provider_activity: diagnostic_activity(row.phase, row.code)
        )

      _policy ->
        CommandDiagnostic.new!(row.phase, row.code,
          provider_activity: diagnostic_activity(row.phase, row.code)
        )
    end
  end

  def diagnostic_activity(phase, code),
    do: DiagnosticCatalog.provider_activity_policy(phase, code) == true

  def model_result(alias_name) do
    %{
      "alias" => alias_name,
      "source" => "llm",
      "installation_revision" => "revision",
      "data_class" => "normal",
      "accepts_data" => ["normal"],
      "destinations" => ["workflow"]
    }
  end

  def project_limit_exceeded(reason, details) do
    usage = %{
      remaining_ms: 60_000,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 0,
      evaluations_by_mission: %{},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      capability_refusals: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil},
      llm_spend: %{"state" => "empty"}
    }

    evidence = %{
      result:
        {:error,
         %Error{
           kind: :limit_exceeded,
           reason: reason,
           details: details,
           usage: usage
         }}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    CommandRunOutcome.project(
      evidence,
      settlement,
      CommandRunRef.encode(@zero_entropy),
      true
    )
  end

  def usage_fixture do
    %{
      "remaining_ms" => 0,
      "capability_calls" => %{"workflow/read-file" => 1},
      "subordinate_evaluations" => 0,
      "evaluations_by_mission" => %{"default" => 0},
      "protocol_errors" => 0,
      "agent_protocol_errors" => 0,
      "evaluation_memory_bytes" => 0,
      "evaluation_history_bytes" => 0,
      "evaluation_continuation_bytes" => 0,
      "events_dropped" => %{"provider-call" => 2},
      "capability_refusals" => %{},
      "llm_budget" => %{"total_tokens" => nil, "cost" => nil},
      "llm_spend" => %{"state" => "empty"},
      "llm_usage_state" => "available",
      "llm_usage" => [],
      "llm_usage_by_model" => [],
      "unattributed_model_calls" => 0
    }
  end

  def run_success_fixture(artifact_class, result) do
    %{
      "schema_version" => 3,
      "command" => "run",
      "status" => "ok",
      "run_ref" => CommandRunRef.encode(@zero_entropy),
      "result" => result,
      "secondary_errors" => [],
      "artifact_state" => %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "not_requested"
      },
      "artifact_class" => artifact_class,
      "execution" => %{
        "state" => "finished",
        "outcome" => "ok",
        "diagnostic" => nil,
        "usage" => usage_fixture(),
        "evaluation_memory" => evaluation_memory_fixture(),
        "last_evaluation_error" => nil
      }
    }
  end

  def evaluation_memory_fixture do
    %{
      "defined_count" => 0,
      "history_count" => 0,
      "memory_bytes" => 0,
      "history_bytes" => 0,
      "bytes" => 0
    }
  end

  def valid_manifest(overrides \\ %{}) do
    TestHelpers.valid_manifest(overrides)
  end

  def valid_host_config do
    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{"type" => "stdio", "command" => "node"},
          "tools" => %{
            "read" => %{"as" => "workspace.read", "effect" => "read"}
          }
        }
      }
    }
  end

  def inert_stdio_installation(revision) do
    %{
      "source" => "mcp",
      "installation_revision" => revision,
      "transport" => %{
        "type" => "stdio",
        "command" => "ptc-nonexistent-executable-9f3a"
      },
      "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
    }
  end

  # A real MCP stdio server, offline and deterministic. It is the only shipped
  # recipe whose descriptor carries both an audited-local check and
  # `connectivity_mode: :acquisition`, which is what lets a connect at this
  # boundary settle two rows that default doctor cannot settle at all. `marker`
  # records the JSON-RPC methods the server actually served.
  def connect_host_config(marker, mode \\ nil) do
    args =
      if is_nil(mode),
        do: [@stdio_fixture, marker],
        else: [@stdio_fixture, marker, mode, "PRIVATE_LAUNCH_ARGUMENT"]

    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "connect-stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => System.find_executable("sh"),
            "cwd" => @stdio_root,
            "args" => args,
            "start_timeout_ms" => 5_000
          },
          "tools" => %{
            "structured" => %{
              "as" => "workspace.structured",
              "effect" => "write",
              "model_visible" => true
            }
          },
          "ceilings" => %{"timeout_ms" => 5_000}
        }
      }
    }
  end

  def stdio_host_config(command, launcher, cwd) do
    %{
      "runtime" => %{"stdio_launcher" => launcher},
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => command,
            "cwd" => cwd,
            "inherit_environment" => false,
            "env" => %{"TOKEN" => %{"binding" => "token"}}
          },
          "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
        }
      }
    }
  end

  def doctor_application(directory, name, providers) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => provider_entries(Keyword.get(providers, :workflow, [])),
        "mission" => provider_entries(Keyword.get(providers, :mission, []))
      }
    }

    manifest =
      case Keyword.get(providers, :limits) do
        nil -> manifest
        limits -> Map.put(manifest, "limits", limits)
      end

    write_application(directory, name, manifest)
  end

  # One credentialed MCP installation per transport shape. The credential is the
  # subject of every test that uses these, so the surrounding document is
  # shared rather than restated.
  def stdio_credential_host(environment_name) do
    %{
      "credentials" => %{"key" => %{"env" => environment_name}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => System.find_executable("sh"),
            "env" => %{"TOKEN" => %{"binding" => "key"}}
          },
          "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
        }
      }
    }
  end

  def bearer_credential_host(credential_file) do
    %{
      "credentials" => %{"tok" => %{"file" => credential_file}},
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "installation_revision" => "remote-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://127.0.0.1:1/mcp",
            "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
          },
          "tools" => %{"read" => %{"as" => "remote.read", "effect" => "read"}},
          "ceilings" => %{"timeout_ms" => 2_000}
        }
      }
    }
  end

  def env_credential_host do
    %{
      "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
      "install" => %{"model" => live_llm_installation()}
    }
  end

  def literal_credential_host(value, model \\ "openrouter:test/model")
      when is_binary(value) and is_binary(model) do
    %{
      "credentials" => %{"key" => %{"literal" => value}},
      "install" => %{"model" => live_llm_installation(model)}
    }
  end

  defp live_llm_installation(model \\ "openrouter:test/model") do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "model-v1",
      "model" => model,
      "credential" => "key"
    }
  end

  def provider_entries(names) do
    Enum.map(names, fn
      {name, config} -> %{"name" => name, "config" => config}
      name -> %{"name" => name, "config" => %{}}
    end)
  end

  def write_host_config(directory, name, bytes) when is_binary(bytes) do
    path = Path.join(directory, "#{name}.host.json")
    File.write!(path, bytes)
    path
  end

  def write_host_config(directory, name, config),
    do: write_host_config(directory, name, Jason.encode!(config))

  def catalog_for(registry) do
    {:ok, catalog} =
      InstallationCatalog.new(%{}, installed_limits: registry.installed_limits)

    catalog
  end

  def prepared_metadata(prepared) do
    Map.take(prepared, [
      :provider_declarations,
      :effective_data_class,
      :effective_flow,
      :effective_event_policy,
      :effective_application_projection,
      :effective_application_digest,
      :installation_config_digests,
      :post_selection_context
    ])
  end

  def validate_success_result(overrides \\ %{}) do
    Map.merge(
      %{
        "application_content_digest" => "sha256:" <> String.duplicate("0", 64),
        "effective_application_digest" => "sha256:" <> String.duplicate("1", 64),
        "installation_config_digests" => %{},
        "workflow_bundle_hash" => String.duplicate("2", 64),
        "mission_bundle_hashes" => %{},
        "mission_grants" => %{},
        "provider_activity" => false
      },
      overrides
    )
  end

  def host_installation_owners do
    marker = {PtcRunner.Kernel.HostInstallationOwner, :authority}

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keymember?(dictionary, marker, 0)
        nil -> false
      end
    end)
    |> MapSet.new()
  end

  def write_application(directory, name, manifest, extra_documents \\ []) do
    root = Path.join(directory, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "main.clj"), "(ns app) (defn run [input] (return input))")

    Enum.each(extra_documents, fn {logical_name, bytes} ->
      File.write!(Path.join(root, logical_name), bytes)
    end)

    bytes = if is_binary(manifest), do: manifest, else: Jason.encode!(manifest)
    path = Path.join(root, "ptc.json")
    File.write!(path, bytes)
    path
  end
end
