defmodule PtcRunner.Examples.KernelInspectionLab do
  @moduledoc false

  alias PtcRunner.Examples.KernelInspectionLab.MCPFixture
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder

  @task "Use every available read-only fixture and return their results in one map."
  @filesystem_server Path.expand("../../mcp/filesystem/dist/server.js", __DIR__)

  @direct_program ~S|(let [file (tool/filesystem.read {"path" "value.txt"}) native (tool/native-echo {"value" "fixture"}) structured (tool/remote.structured {"query" "fixture"}) text (tool/remote.text {"query" "fixture"}) failed (tool/remote.fail {"query" "fixture"})] (return {"file" file "native" native "structured" structured "text" text "failed" failed}))|
  @wrapper_program ~S|(return {"file" (lab.tools/read-file) "native" (lab.tools/echo) "structured" (lab.tools/remote-structured) "text" (lab.tools/remote-text) "failed" (lab.tools/remote-failure)})|

  def run(output_dir) when is_binary(output_dir) do
    output_dir = Path.expand(output_dir)
    :ok = File.mkdir_p(output_dir)
    fixture = MCPFixture.start(&mcp_response/1)

    try do
      with {:ok, direct} <-
             run_journey(output_dir, fixture.endpoint, "direct", @direct_program, false),
           {:ok, wrapper} <-
             run_journey(output_dir, fixture.endpoint, "wrapper", @wrapper_program, true) do
        {:ok, [direct, wrapper]}
      end
    after
      fixture.close.()
    end
  end

  defp run_journey(output_dir, endpoint, name, program, wrapper?) do
    directory = Path.join(output_dir, name)
    :ok = File.mkdir(directory)
    # The conventional project artifact root: exactly these four children, each
    # owner-only. Laying the journey out this way lets `ptc viewer` read it
    # directly, and gives the private inspection artifact a parent as
    # restrictive as the artifact itself.
    artifacts = Path.join(directory, "artifacts")
    traces = Path.join(artifacts, "traces")
    inspection = Path.join(artifacts, "inspection")
    files = Path.join(directory, "files")
    :ok = File.mkdir(artifacts)
    :ok = File.chmod(artifacts, 0o700)

    Enum.each(~w(envelopes inspection results traces), fn child ->
      child_path = Path.join(artifacts, child)
      :ok = File.mkdir!(child_path)
      :ok = File.chmod(child_path, 0o700)
    end)

    File.mkdir!(files)
    :ok = File.write(Path.join(files, "value.txt"), "fixture-file")
    :ok = File.write(Path.join(directory, "workflow.clj"), workflow_source())

    mission_components =
      if wrapper? do
        :ok = File.write(Path.join(directory, "mission.clj"), mission_source())
        [%{"id" => "lab.tools", "path" => "mission.clj"}]
      else
        []
      end

    manifest = manifest(name, mission_components, wrapper?)
    manifest_path = Path.join(directory, "ptc.json")
    trace_path = Path.join(traces, "run.jsonl")
    inspection_path = Path.join(inspection, "run.inspection.jsonl")
    :ok = File.write(manifest_path, Jason.encode!(manifest))
    registry = registry(endpoint, program, wrapper?, directory)

    with {:ok, request} <-
           ApplicationPackage.request_directory(manifest_path,
             installed_limits: registry.installed_limits,
             inspection_capture: true
           ),
         {:ok, built} <-
           RunBuilder.build(request, registry,
             trace_path: trace_path,
             inspect: inspection_path
           ),
         {:ok, result} <- execute_and_publish(built),
         {:ok, records} <- InspectionArtifact.load(inspection_path) do
      {:ok,
       %{
         name: name,
         result: result,
         trace: trace_path,
         inspection: inspection_path,
         run_id: records |> hd() |> Map.fetch!("run_id")
       }}
    end
  end

  defp execute_and_publish(%{publication_authority: authority} = built) do
    case RunBuilder.execute_built(built) do
      {:ok, outcome} ->
        result = published_result(outcome, authority)
        prefer_cleanup_error(result, PublicationAuthority.close(authority))

      {:error, _reason} = error ->
        prefer_cleanup_error(error, PublicationAuthority.abort(authority))
    end
  end

  defp published_result(outcome, authority) do
    case RunBuilder.publish_execution_report(outcome, authority) do
      {:ok, %{result: {:ok, result}}} -> {:ok, result}
      {:ok, %{result: {:error, reason}}} -> {:error, reason}
      {:error, %{error: error, result: result}} -> publication_error(error, result)
      {:error, %{error: error}} -> publication_error(error)
      {:error, _report} -> {:error, :invalid_execution_outcome}
    end
  end

  defp publication_error({:result_contract_failed, _details} = error), do: {:error, error}

  defp publication_error({:error, {:result_contract_failed, _details} = error}),
    do: {:error, error}

  defp publication_error(%PtcRunner.Kernel.Error{} = error), do: {:error, error}

  defp publication_error({stage, reason}) when stage in [:trace, :inspection, :result],
    do: {:error, {persistence_failure(stage), reason}}

  defp publication_error(error), do: {:error, error}

  defp publication_error({stage, reason}, result) when stage in [:trace, :inspection, :result],
    do: {:error, {persistence_failure(stage), reason, result}}

  defp publication_error(error, result), do: {:error, {error, result}}

  defp persistence_failure(:trace), do: :trace_persistence_failed
  defp persistence_failure(:inspection), do: :inspection_persistence_failed
  defp persistence_failure(:result), do: :result_persistence_failed

  defp prefer_cleanup_error(_result, {:error, _reason} = cleanup), do: cleanup
  defp prefer_cleanup_error(result, :ok), do: result

  defp registry(endpoint, program, wrapper?, directory) do
    turn = :atomics.new(1, signed: false)

    scripted =
      staged_provider(fn config, _context ->
        if config == %{} do
          with {:ok, capability} <-
                 LLMCapability.new(
                   requester: fn _request ->
                     current = :atomics.add_get(turn, 1, 1)
                     generated = if current == 1, do: "(missing/function)", else: program
                     {:ok, model_response(generated, current)}
                   end
                 ),
               do: {:ok, %{capabilities: [capability]}}
        else
          {:error, :invalid_scripted_model_config}
        end
      end)

    native =
      staged_provider(fn config, _context ->
        if config in [%{}, %{"model_visible" => false}] do
          with {:ok, capability} <-
                 Capability.new(
                   name: "native-echo",
                   description: "Return one fixture string through the native provider seam",
                   model_visible: Map.get(config, "model_visible", true),
                   effect: :read,
                   input_schema: %{
                     "type" => "object",
                     "properties" => %{"value" => %{"type" => "string"}},
                     "required" => ["value"]
                   },
                   output_schema: %{
                     "type" => "object",
                     "properties" => %{"echo" => %{"type" => "string"}},
                     "required" => ["echo"]
                   },
                   callback: fn %{"value" => value} -> {:ok, %{"echo" => value}} end
                 ),
               do: {:ok, %{capabilities: [capability]}}
        else
          {:error, :invalid_native_config}
        end
      end)

    mcp =
      MCPSource.builder(
        transport: {:streamable_http, endpoint: endpoint, allow_insecure_loopback: true},
        tools: %{
          "structured" => %{as: "remote.structured", effect: :read},
          "text" => %{as: "remote.text", effect: :read},
          "fail" => %{as: "remote.fail", effect: :read}
        },
        timeout_ms: 2_000,
        max_result_bytes: 64_000
      )

    node = System.find_executable("node") || raise "Node.js is required for the inspection lab"
    {:ok, executable} = File.read(node)

    filesystem =
      MCPSource.builder(
        transport:
          {:stdio,
           executable: node,
           executable_sha256: :crypto.hash(:sha256, executable),
           cwd: directory,
           args: [@filesystem_server, "--root", "files", "--include", "**"],
           env: %{},
           start_timeout_ms: 15_000},
        tools: %{
          "read_text_file" => %{
            as: "filesystem.read",
            effect: :read,
            model_visible: not wrapper?
          }
        },
        timeout_ms: 15_000,
        max_result_bytes: 64_000,
        installation_revision: "filesystem-sample-0.2.0"
      )

    {:ok, registry} =
      ProviderRegistry.new(%{
        "fixture-model" => scripted,
        "filesystem" => filesystem,
        "fixture-native" => native,
        "fixture-mcp" => mcp
      })

    registry
  end

  defp staged_provider(acquire) do
    ProviderRegistry.staged(fn config, context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> acquire.(config, context) end} end
       }}
    end)
  end

  defp manifest(name, mission_components, wrapper?) do
    visibility = if wrapper?, do: %{"model_visible" => false}, else: %{}

    %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"library" => "agent.core"},
          %{"id" => "lab.workflow", "path" => "workflow.clj", "dependencies" => ["agent.core"]}
        ],
        "entry" => "lab.workflow/run"
      },
      "missions" => %{
        "default" => %{
          "components" => mission_components,
          "data" => %{},
          "providers" => ["filesystem", "fixture-native", "fixture-mcp"]
        }
      },
      "input" => %{"value" => %{"task" => @task}},
      "providers" => %{
        "workflow" => [%{"name" => "fixture-model", "config" => %{}}],
        "mission" => [
          %{"name" => "filesystem", "config" => %{}},
          %{"name" => "fixture-native", "config" => visibility},
          %{
            "name" => "fixture-mcp",
            "config" => %{
              "allow" => ["remote.structured", "remote.text", "remote.fail"],
              "model_visible" =>
                if(wrapper?,
                  do: [],
                  else: ["remote.structured", "remote.text", "remote.fail"]
                ),
              "timeout_ms" => 2_000,
              "max_result_bytes" => 64_000
            }
          }
        ]
      },
      "limits" => %{"evaluation_timeout_ms" => 10_000, "run_duration_ms" => 60_000},
      "events" => %{"run_id" => "inspection-lab-#{name}"},
      "labels" => %{"name" => "inspection-lab-#{name}", "tags" => %{"mode" => name}}
    }
  end

  defp workflow_source do
    ~S|(ns lab.workflow "Credential-free scripted inspection entry." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 2}))|
  end

  defp mission_source do
    ~S|(ns lab.tools "Small prompt-visible wrapper over unchanged mission capabilities." {:visibility :prompt})

(defn read-file [] (tool/filesystem.read {"path" "value.txt"}))
(defn echo [] (tool/native-echo {"value" "fixture"}))
(defn remote-structured [] (tool/remote.structured {"query" "fixture"}))
(defn remote-text [] (tool/remote.text {"query" "fixture"}))
(defn remote-failure [] (tool/remote.fail {"query" "fixture"}))|
  end

  defp model_response(program, turn) do
    %{
      content: nil,
      tool_calls: [
        %{id: "scripted-call-#{turn}", name: "run_ptc_lisp", args: %{"program" => program}}
      ],
      tokens: %{
        input: 1_000 + turn,
        output: 20 + turn,
        cache_read: if(turn == 2, do: 100, else: 0),
        total_cost: 0.0001 * turn
      }
    }
  end

  defp mcp_response(%{body: %{"method" => "server/discover", "id" => id}}) do
    json(id, %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{body: %{"method" => "tools/list", "id" => id}}) do
    json(id, %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "structured",
          "description" => "Return one structured fixture value",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          },
          "outputSchema" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "integer"}},
            "required" => ["value"]
          }
        },
        %{
          "name" => "text",
          "description" => "Return one text fixture value",
          "inputSchema" => input_schema()
        },
        %{
          "name" => "fail",
          "description" => "Return one MCP domain error",
          "inputSchema" => input_schema()
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{
         body: %{"method" => "tools/call", "id" => id, "params" => %{"name" => "structured"}}
       }),
       do:
         json(id, %{
           "resultType" => "complete",
           "structuredContent" => %{"value" => 42},
           "content" => []
         })

  defp mcp_response(%{
         body: %{"method" => "tools/call", "id" => id, "params" => %{"name" => "text"}}
       }),
       do:
         json(id, %{
           "resultType" => "complete",
           "content" => [%{"type" => "text", "text" => "fixture-text"}]
         })

  defp mcp_response(%{
         body: %{"method" => "tools/call", "id" => id, "params" => %{"name" => "fail"}}
       }),
       do: json(id, %{"resultType" => "complete", "isError" => true, "content" => []})

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  end

  defp json(id, result, headers \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    {200, headers ++ [{"content-type", "application/json"}], body}
  end
end
