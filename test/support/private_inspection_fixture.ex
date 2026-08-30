defmodule PtcRunner.TestSupport.PrivateInspectionFixture do
  @moduledoc false

  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.ResultIdentity

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  @doc false
  @spec command_run_ref(non_neg_integer()) :: binary()
  def command_run_ref(seed \\ 0) when is_integer(seed) and seed >= 0 do
    CommandRunRef.encode(<<seed::unsigned-big-128>>)
  end

  @doc false
  def llm_input(arguments) when is_map(arguments) do
    {:ok, request_hash} = LLMReplay.request_hash(arguments)

    %{
      environment: :workflow,
      name: "llm-request",
      arguments: arguments,
      request_hash: request_hash
    }
  end

  def create!(root, run_id \\ "private-run") do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)

    events = canonical_events(run_id)
    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))
    write_inspection!(inspection, run_id, events)

    fixture
  end

  @doc false
  def rewrite_legacy_float_cost!(%{traces: traces, run_id: run_id}) do
    path = Path.join(traces, "#{run_id}.jsonl")

    events =
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    events =
      update_in(events, [Access.at(-1), "data"], fn data ->
        Map.put(data, "usage", %{
          "llm_spend" => %{
            "state" => "available",
            "input" => 1,
            "output" => 2,
            "total_cost" => 0.001326
          }
        })
      end)

    File.write!(path, encode_jsonl(events))
  end

  def create_boundary_failure!(root, run_id \\ "boundary-failure-run") do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)

    events = boundary_failure_events(run_id)
    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))
    write_boundary_failure_inspection!(inspection, run_id, events)

    fixture
  end

  def create_interrupted!(root, run_id \\ "interrupted-private-run") do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)
    events = interrupted_events(run_id)

    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))
    write_interrupted_inspection!(inspection, run_id, events)

    Map.merge(fixture, %{
      interrupted_model_secret: "INTERRUPTED_MODEL_SECRET_#{run_id}",
      interrupted_tool_secret: "INTERRUPTED_TOOL_SECRET_#{run_id}"
    })
  end

  @doc """
  Builds a capture whose reconstruction is ambiguous while nothing is missing.

  Two exchanges answer the same request with the same response, so a third
  request extending that prefix has two maximal predecessors and cannot be
  attributed to either. The run is terminal, drops no events, and captures
  every exchange the trace expects, so `canonical_complete?` is true and
  `missing_exchange_count` is zero: the only failing condition is ambiguity.
  """
  def create_ambiguous!(root, run_id \\ "ambiguous-private-run") do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)

    ids = Enum.map(1..3, &"llm-#{&1}-#{run_id}")

    events =
      [event(run_id, 1, "run-started", %{"missions" => %{}})] ++
        Enum.flat_map(Enum.with_index(ids, 1), fn {capability_id, index} ->
          [
            event(run_id, index * 2, "capability-started", %{
              "capability_id" => capability_id,
              "environment" => "workflow",
              "name" => "llm-request"
            }),
            event(run_id, index * 2 + 1, "capability-stopped", %{
              "capability_id" => capability_id,
              "environment" => "workflow",
              "name" => "llm-request",
              "status" => "ok"
            })
          ]
        end) ++ [event(run_id, 8, "run-stopped", %{"outcome" => "ok"})]

    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))

    user = %{"role" => "user", "content" => "private-prompt-#{run_id}"}
    assistant = %{"role" => "assistant", "content" => "private-answer-#{run_id}"}
    follow_up = %{"role" => "user", "content" => "private-follow-up-#{run_id}"}

    requests = [[user], [user], [user, assistant, follow_up]]

    {sink, handle} = start_sink!(inspection, run_id)

    Enum.each(Enum.zip(ids, requests), fn {capability_id, messages} ->
      arguments = %{"messages" => messages, "system" => "private-system-#{run_id}"}

      emit!(
        sink,
        "capability-input",
        %{capability_id: capability_id},
        llm_input(arguments)
      )

      emit!(sink, "capability-output", %{capability_id: capability_id}, %{
        environment: :workflow,
        name: "llm-request",
        result: %{status: :ok, value: %{"content" => assistant["content"]}}
      })
    end)

    persist_inspection!(sink, handle)

    fixture
  end

  def create_result!(root, value, run_id \\ "private-result-run") do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)
    {:ok, result_hash} = ResultIdentity.strict_json_hash(value)

    events = [
      event(run_id, 1, "run-started", %{"missions" => %{}}),
      event(run_id, 2, "run-stopped", %{"outcome" => "ok", "result_hash" => result_hash})
    ]

    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))

    {sink, handle} = start_sink!(inspection, run_id)

    :ok = InspectionSink.emit(sink, "run-result", %{}, %{result_hash: result_hash, value: value})
    persist_inspection!(sink, handle)

    Map.put(fixture, :result_hash, result_hash)
  end

  def create_model_exchanges!(root, count \\ 40, run_id \\ "large-model-exchanges")
      when is_integer(count) and count > 0 do
    %{traces: traces, inspection: inspection} = fixture = create_directories(root, run_id)

    {events, _messages} =
      Enum.reduce(1..count, {[event(run_id, 1, "run-started", %{"missions" => %{}})], []}, fn
        turn, {events, messages} ->
          capability_id = "llm-#{turn}-#{run_id}"
          user = model_message("user", turn)
          request_messages = messages ++ [user]
          assistant = model_message("assistant", turn)
          sequence = turn * 2

          events =
            events ++
              [
                event(run_id, sequence, "capability-started", %{
                  "capability_id" => capability_id,
                  "environment" => "workflow",
                  "name" => "llm-request"
                }),
                event(run_id, sequence + 1, "capability-stopped", %{
                  "capability_id" => capability_id,
                  "environment" => "workflow",
                  "name" => "llm-request",
                  "status" => "ok"
                })
              ]

          {events, request_messages ++ [assistant]}
      end)

    events = events ++ [event(run_id, count * 2 + 2, "run-stopped", %{"outcome" => "ok"})]
    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))

    {sink, handle} = start_sink!(inspection, run_id)

    _messages =
      Enum.reduce(1..count, [], fn turn, messages ->
        capability_id = "llm-#{turn}-#{run_id}"
        user = model_message("user", turn)
        request_messages = messages ++ [user]
        assistant = model_message("assistant", turn)

        arguments = %{
          "messages" => request_messages,
          "system" => "private-system-#{run_id}"
        }

        emit!(
          sink,
          "capability-input",
          %{capability_id: capability_id},
          llm_input(arguments)
        )

        emit!(sink, "capability-output", %{capability_id: capability_id}, %{
          environment: :workflow,
          name: "llm-request",
          result: %{status: :ok, value: %{"content" => assistant["content"]}}
        })

        request_messages ++ [assistant]
      end)

    persist_inspection!(sink, handle)
    Map.put(fixture, :model_exchange_count, count)
  end

  def rewrite_schema!(directory, schema_version) when is_integer(schema_version) do
    directory
    |> Path.join("*.ptcins")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      <<magic::binary-size(8), format::unsigned-big-16, _schema::unsigned-big-16, rest::binary>> =
        File.read!(path)

      File.write!(
        path,
        <<magic::binary, format::unsigned-big-16, schema_version::unsigned-big-16, rest::binary>>
      )
    end)
  end

  def canonical_events(run_id) do
    [
      event(run_id, 1, "run-started", %{
        "missions" => %{"default" => %{}},
        "workflow_prelude" => prelude_projection("component-#{run_id}")
      }),
      event(run_id, 2, "capability-started", %{
        "capability_id" => "llm-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      event(run_id, 3, "capability-started", %{
        "capability_id" => "tool-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read"
      }),
      workflow_evaluation_event(run_id, 4),
      event(run_id, 5, "evaluation-started", %{
        "evaluation_id" => "eval-#{run_id}",
        "parent_evaluation_id" => "workflow-eval-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "program_kind" => "ptc-lisp",
        "source_hash" => @source_hash,
        "source_bytes" => byte_size(@source)
      }),
      event(run_id, 6, "evaluation-stopped", %{
        "evaluation_id" => "eval-#{run_id}",
        "parent_evaluation_id" => "workflow-eval-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "status" => "returned"
      }),
      event(run_id, 7, "evaluation-stopped", %{
        "evaluation_id" => "workflow-eval-#{run_id}",
        "environment" => "workflow",
        "status" => "error"
      }),
      event(run_id, 8, "run-stopped", %{"outcome" => "failed"})
    ]
  end

  @doc """
  Projects a one-component environment whose only source is the fixture source.

  Framed exactly as the compiler frames it, so a `prelude-source` record
  naming `component_id` can be proven against it rather than merely asserted.
  """
  def prelude_projection(component_id) do
    {:ok, hash} =
      FrozenBundle.identity([
        %{id: component_id, dependencies: [], source_hash: @source_hash}
      ])

    %{
      "component_ids" => [component_id],
      "dependency_indices" => [[]],
      "hash" => hash
    }
  end

  defp boundary_failure_events(run_id) do
    [started | rest] = canonical_events(run_id)

    started =
      put_in(
        started,
        ["data", "missions", "default", "prelude"],
        prelude_projection("mission-component-#{run_id}")
      )

    [started | rest]
  end

  defp write_inspection!(directory, run_id, _events) do
    {sink, handle} = start_sink!(directory, run_id)
    emit_model_exchange!(sink, run_id)

    emit!(
      sink,
      "capability-input",
      %{capability_id: "tool-#{run_id}"},
      tool_input_payload(run_id)
    )

    emit!(
      sink,
      "mcp-request",
      %{capability_id: "tool-#{run_id}", request_id: 7},
      tool_request_payload(7, "private-#{run_id}.txt")
    )

    emit!(sink, "mcp-response", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
      mission_name: "default",
      transport: :stdio,
      body: %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "result" => %{
          "content" => [%{"type" => "text", "text" => "private-tool-result-#{run_id}"}]
        }
      }
    })

    emit!(sink, "capability-output", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      result: %{status: :ok, value: %{"text" => "private-tool-result-#{run_id}"}}
    })

    emit_evaluation_source!(sink, run_id)

    emit!(sink, "prelude-source", %{component_id: "component-#{run_id}"}, %{
      environment: :workflow,
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit_execution_diagnostics!(sink, run_id)

    persist_inspection!(sink, handle)
  end

  defp write_boundary_failure_inspection!(directory, run_id, _events) do
    {sink, handle} = start_sink!(directory, run_id)
    emit_model_exchange!(sink, run_id)
    emit_evaluation_source!(sink, run_id)

    emit!(sink, "evaluation-analysis", %{evaluation_id: "eval-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      prelude_calls: [
        %{ref: "fixture/value", component_id: "mission-component-#{run_id}"}
      ]
    })

    emit!(sink, "prelude-source", %{component_id: "component-#{run_id}"}, %{
      environment: :workflow,
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit!(sink, "prelude-source", %{component_id: "mission-component-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit!(sink, "execution-error", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      kind: :limit_exceeded,
      reason: :terminal_result_exceeded,
      details: %{
        boundary_producer: %{
          evaluation_ids: ["eval-#{run_id}"],
          complete?: true
        }
      }
    })

    persist_inspection!(sink, handle)
  end

  defp emit_model_exchange!(sink, run_id) do
    arguments = %{
      "messages" => [%{"content" => "private-prompt-#{run_id}"}],
      "system" => "private-system-#{run_id}"
    }

    emit!(
      sink,
      "capability-input",
      %{capability_id: "llm-#{run_id}"},
      llm_input(arguments)
    )

    emit!(sink, "capability-output", %{capability_id: "llm-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      result: %{
        status: :ok,
        value: %{
          "answer" => "private-answer-#{run_id}",
          "tool_calls" => [
            %{"id" => "program-#{run_id}", "args" => %{"program" => @source}}
          ]
        }
      }
    })
  end

  defp emit_evaluation_source!(sink, run_id),
    do:
      emit!(
        sink,
        "evaluation-source",
        %{evaluation_id: "eval-#{run_id}"},
        evaluation_source_payload()
      )

  @doc "Payload for the canonical mission tool capability-input record."
  def tool_input_payload(run_id) do
    %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      arguments: %{"path" => "private-#{run_id}.txt"}
    }
  end

  @doc "Payload for one canonical stdio `tools/call` request record."
  def tool_request_payload(request_id, path) do
    %{
      mission_name: "default",
      transport: :stdio,
      body: %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "tools/call",
        "params" => %{"name" => "read", "arguments" => %{"path" => path}}
      }
    }
  end

  @doc "Payload for the canonical mission evaluation-source record."
  def evaluation_source_payload do
    %{
      environment: :mission,
      mission_name: "default",
      program_kind: :"ptc-lisp",
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    }
  end

  @doc "Payload for the canonical workflow prelude-source record."
  def prelude_source_payload do
    %{
      environment: :workflow,
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    }
  end

  defp persist_inspection!(sink, handle) do
    {:ok, seal} = InspectionSink.seal(sink)
    :ok = InspectionArtifact.publish_handle(handle, seal)
    :ok = InspectionSink.stop(sink)
  end

  defp write_interrupted_inspection!(directory, run_id, _events) do
    {sink, handle} = start_sink!(directory, run_id)

    complete_arguments = %{
      "messages" => [%{"content" => "private-prompt-#{run_id}", "role" => "user"}],
      "system" => "private-system-#{run_id}"
    }

    emit!(
      sink,
      "capability-input",
      %{capability_id: "llm-complete-#{run_id}"},
      llm_input(complete_arguments)
    )

    emit!(sink, "capability-output", %{capability_id: "llm-complete-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      result: %{
        status: :ok,
        value: %{"content" => "private-answer-#{run_id}"}
      }
    })

    emit!(sink, "capability-input", %{capability_id: "tool-complete-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      arguments: %{"path" => "private-#{run_id}.txt"}
    })

    emit!(sink, "capability-output", %{capability_id: "tool-complete-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      result: %{status: :ok, value: %{"text" => "private-tool-result-#{run_id}"}}
    })

    interrupted_arguments = %{
      "messages" => [
        %{"content" => "private-prompt-#{run_id}", "role" => "user"},
        %{"content" => "private-answer-#{run_id}", "role" => "assistant"},
        %{"content" => "INTERRUPTED_MODEL_SECRET_#{run_id}", "role" => "user"}
      ],
      "system" => "private-system-#{run_id}"
    }

    emit!(
      sink,
      "capability-input",
      %{capability_id: "llm-interrupted-#{run_id}"},
      llm_input(interrupted_arguments)
    )

    emit!(sink, "capability-input", %{capability_id: "tool-interrupted-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      arguments: %{"path" => "INTERRUPTED_TOOL_SECRET_#{run_id}"}
    })

    persist_inspection!(sink, handle)
  end

  defp start_sink!(directory, run_id) do
    path = Path.join(directory, "#{run_id}.ptcins")
    {:ok, handle} = PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self())

    {:ok, sink} =
      InspectionSink.start(
        run_id: run_id,
        trace_id: "trace-#{run_id}",
        publication_handle: handle
      )

    {sink, handle}
  end

  defp interrupted_events(run_id) do
    [
      event(run_id, 1, "run-started", %{"missions" => %{"default" => %{}}}),
      event(run_id, 2, "capability-started", %{
        "capability_id" => "llm-complete-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      event(run_id, 3, "capability-stopped", %{
        "capability_id" => "llm-complete-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request",
        "status" => "ok"
      }),
      event(run_id, 4, "capability-started", %{
        "capability_id" => "tool-complete-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read"
      }),
      event(run_id, 5, "capability-stopped", %{
        "capability_id" => "tool-complete-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read",
        "status" => "ok"
      }),
      event(run_id, 6, "capability-started", %{
        "capability_id" => "llm-interrupted-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      event(run_id, 7, "capability-started", %{
        "capability_id" => "tool-interrupted-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read"
      }),
      event(run_id, 8, "run-stopped", %{"outcome" => "failed"})
    ]
  end

  def emit_execution_diagnostics!(sink, run_id) do
    emit!(sink, "execution-prints", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      prints: ["private-print-#{run_id}"],
      truncated: false
    })

    emit!(sink, "execution-error", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      kind: :limit_exceeded,
      reason: :timeout,
      details: %{"limit" => "run_duration_ms", "limit_ms" => 1_000}
    })

    emit!(sink, "explicit-failure-value", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      value: nil
    })
  end

  def workflow_evaluation_event(run_id, sequence) do
    event(run_id, sequence, "evaluation-started", %{
      "evaluation_id" => "workflow-eval-#{run_id}",
      "environment" => "workflow",
      "program_kind" => "ptc-lisp",
      "source_hash" => @source_hash,
      "source_bytes" => byte_size(@source)
    })
  end

  defp emit!(sink, type, correlation, payload),
    do: :ok = InspectionSink.emit(sink, type, correlation, payload)

  defp create_directories(root, run_id) do
    fixture = %{
      traces: Path.join(root, "traces"),
      inspection: Path.join(root, "inspection"),
      output: Path.join(root, "analysis-traces"),
      run_id: run_id
    }

    Enum.each([fixture.traces, fixture.inspection, fixture.output], &File.mkdir_p!/1)
    fixture
  end

  defp event(run_id, sequence, type, data) do
    data =
      if type == "run-stopped" do
        Map.put_new(data, "usage", %{
          "llm_budget" => %{"total_tokens" => nil, "cost" => nil}
        })
      else
        data
      end

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" =>
        DateTime.add(~U[2026-07-26 12:00:00Z], sequence, :second) |> DateTime.to_iso8601(),
      "type" => type,
      "data" => data
    }
  end

  defp model_message(role, turn) do
    %{
      "role" => role,
      "content" => "#{role}-#{turn}-" <> String.duplicate("evidence-", 64)
    }
  end

  defp encode_jsonl(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
end
