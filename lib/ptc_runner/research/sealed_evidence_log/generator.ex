defmodule PtcRunner.Research.SealedEvidenceLog.Generator do
  @moduledoc """
  Lazy corpus generators for the sealed-log prototype.

  Large artifacts are written into caller-owned temporary directories. Nothing
  here constructs a complete record list for the payload ladder: each record is
  yielded, encoded, written, and released before the next is built.
  """

  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Research.SealedEvidenceLog.Codec
  alias PtcRunner.Research.SealedEvidenceLog.Format

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  @spec mixed_run(binary()) :: %{records: [map()], trace_facts: map(), trace_analysis: map()}
  def mixed_run(run_id \\ "mixed-run") when is_binary(run_id) do
    trace_id = "trace-#{run_id}"
    first_source = "(return 1)"
    second_source = "(return 2)"
    result = %{"answer" => 42}

    records = [
      record(run_id, trace_id, 1, "capability-input", %{"capability_id" => "llm-1"}, %{
        "environment" => "workflow",
        "name" => "llm-request",
        "arguments" => %{
          "messages" => [%{"role" => "user", "content" => "start"}],
          "system" => "sys"
        }
      }),
      record(run_id, trace_id, 2, "capability-output", %{"capability_id" => "llm-1"}, %{
        "environment" => "workflow",
        "name" => "llm-request",
        "result" => %{
          "status" => "ok",
          "value" => %{
            "content" => "tooling",
            "tool_calls" => [
              %{"args" => %{"program" => first_source}},
              %{"args" => %{"program" => second_source}}
            ]
          }
        }
      }),
      record(run_id, trace_id, 3, "capability-input", %{"capability_id" => "llm-2"}, %{
        "environment" => "workflow",
        "name" => "llm-request",
        "arguments" => %{
          "messages" => [
            %{"role" => "user", "content" => "start"},
            %{
              "role" => "assistant",
              "content" => "tooling",
              "tool_calls" => [
                %{"args" => %{"program" => first_source}},
                %{"args" => %{"program" => second_source}}
              ]
            },
            %{"role" => "tool", "content" => "1"}
          ],
          "system" => "sys"
        }
      }),
      record(run_id, trace_id, 4, "capability-output", %{"capability_id" => "llm-2"}, %{
        "environment" => "workflow",
        "name" => "llm-request",
        "result" => %{"status" => "ok", "value" => %{"content" => "done"}}
      }),
      record(run_id, trace_id, 5, "capability-input", %{"capability_id" => "tool-1"}, %{
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "search",
        "arguments" => %{"q" => "secret"}
      }),
      record(run_id, trace_id, 6, "capability-output", %{"capability_id" => "tool-1"}, %{
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "search",
        "result" => %{"status" => "ok", "value" => "hit"}
      }),
      evaluation_source(run_id, trace_id, 7, "evaluation-1", first_source, "default"),
      evaluation_analysis(run_id, trace_id, 8, "evaluation-1", "default"),
      evaluation_source(run_id, trace_id, 9, "evaluation-2", second_source, "writer"),
      prelude(run_id, trace_id, 10, "shared.api", "workflow", nil),
      prelude(run_id, trace_id, 11, "shared.api", "mission", "default"),
      record(
        run_id,
        trace_id,
        12,
        "mcp-request",
        %{"capability_id" => "tool-1", "request_id" => 1},
        %{
          "transport" => "stdio",
          "body" => %{"method" => "tools/call"},
          "mission_name" => "default"
        }
      ),
      record(
        run_id,
        trace_id,
        13,
        "mcp-response",
        %{"capability_id" => "tool-1", "request_id" => 1},
        %{
          "transport" => "stdio",
          "body" => %{"result" => "ok"},
          "mission_name" => "default"
        }
      ),
      record(run_id, trace_id, 14, "execution-prints", %{"evaluation_id" => "workflow-eval"}, %{
        "environment" => "workflow",
        "prints" => ["hello"],
        "truncated" => false
      }),
      record(run_id, trace_id, 15, "execution-error", %{"evaluation_id" => "workflow-eval"}, %{
        "environment" => "workflow",
        "kind" => "eval-error",
        "reason" => "boom",
        "details" => %{}
      }),
      record(
        run_id,
        trace_id,
        16,
        "explicit-failure-value",
        %{"evaluation_id" => "workflow-eval"},
        %{
          "environment" => "workflow",
          "value" => "failed"
        }
      ),
      record(run_id, trace_id, 17, "run-result", %{}, %{
        "result_hash" => result_hash(result),
        "value" => result
      })
    ]

    facts = %{
      "terminal?" => true,
      "events_dropped?" => false,
      "expected_model_exchange_ids" => ["llm-1", "llm-2"],
      "parent_evaluation_ids" => %{
        "evaluation-1" => "workflow-1",
        "evaluation-2" => "workflow-2"
      },
      "evaluation_statuses" => %{"workflow-eval" => "error"}
    }

    %{
      records: records,
      trace_facts: facts,
      trace_analysis: %{
        "trace_snapshot_hash" => "trace-source",
        "runs" => %{run_id => facts}
      }
    }
  end

  @spec second_run(binary()) :: %{records: [map()], trace_facts: map()}
  def second_run(run_id \\ "other-run") do
    trace_id = "trace-#{run_id}"

    %{
      records: [
        record(run_id, trace_id, 1, "execution-prints", %{"evaluation_id" => "wf"}, %{
          "environment" => "workflow",
          "prints" => ["x"],
          "truncated" => false
        })
      ],
      trace_facts: %{"terminal?" => true, "events_dropped?" => false}
    }
  end

  @spec dense_filter_run(binary(), pos_integer()) :: %{records: [map()], trace_facts: map()}
  def dense_filter_run(run_id, count) when is_integer(count) and count > 0 do
    trace_id = "trace-#{run_id}"

    records =
      Enum.map(1..count, fn index ->
        evaluation_source(
          run_id,
          trace_id,
          index,
          "evaluation-#{index}",
          "(return #{index})",
          "default"
        )
      end)

    parents =
      Map.new(1..count, fn index ->
        {"evaluation-#{index}", "parent-#{rem(index, 3)}"}
      end)

    %{
      records: records,
      trace_facts: %{
        "parent_evaluation_ids" => parents,
        "terminal?" => true,
        "events_dropped?" => false
      }
    }
  end

  @spec count_stream(binary(), pos_integer()) :: Enumerable.t()
  def count_stream(run_id, count) when is_integer(count) and count > 0 do
    trace_id = "trace-#{run_id}"

    Stream.map(1..count, fn sequence ->
      record(
        run_id,
        trace_id,
        sequence,
        "execution-prints",
        %{"evaluation_id" => "wf-#{sequence}"},
        %{
          "environment" => "workflow",
          "prints" => ["p"],
          "truncated" => false
        }
      )
    end)
  end

  @spec payload_stream(binary(), pos_integer(), pos_integer()) :: Enumerable.t()
  def payload_stream(run_id, frame_count, frame_bytes)
      when is_integer(frame_count) and frame_count > 0 and is_integer(frame_bytes) and
             frame_bytes > 0 do
    trace_id = "trace-#{run_id}"
    padding = payload_padding(run_id, trace_id, frame_bytes)

    Stream.map(1..frame_count, fn sequence ->
      evaluation_source(
        run_id,
        trace_id,
        sequence,
        "evaluation-#{sequence}",
        :binary.copy(padding),
        "default"
      )
    end)
  end

  @spec choose_frame_bytes(pos_integer()) :: pos_integer()
  def choose_frame_bytes(max_record_bytes) when is_integer(max_record_bytes) do
    min(max_record_bytes, 64 * 1024 * 1024)
  end

  @spec empty_trace_facts() :: map()
  def empty_trace_facts, do: %{"terminal?" => true, "events_dropped?" => false}

  defp payload_padding(run_id, trace_id, frame_bytes) do
    pad = max(frame_bytes - 256, 1)
    adjust_padding(run_id, trace_id, frame_bytes, pad, 8)
  end

  defp adjust_padding(run_id, trace_id, frame_bytes, pad, attempts_left) do
    source = String.duplicate("x", max(pad, 1))
    record = evaluation_source(run_id, trace_id, 1, "evaluation-1", source, "default")
    {:ok, encoded} = Codec.encode_record(record)
    {:ok, frame} = Format.encode_frame(encoded)
    size = byte_size(frame)

    cond do
      size == frame_bytes ->
        source

      attempts_left <= 0 ->
        source

      true ->
        adjust_padding(
          run_id,
          trace_id,
          frame_bytes,
          pad + (frame_bytes - size),
          attempts_left - 1
        )
    end
  end

  defp evaluation_source(run_id, trace_id, sequence, evaluation_id, source, mission) do
    record(
      run_id,
      trace_id,
      sequence,
      "evaluation-source",
      %{"evaluation_id" => evaluation_id},
      %{
        "environment" => "mission",
        "mission_name" => mission,
        "program_kind" => "ptc-lisp",
        "source" => source,
        "source_hash" => :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
        "source_bytes" => byte_size(source)
      }
    )
  end

  defp evaluation_analysis(run_id, trace_id, sequence, evaluation_id, mission) do
    record(
      run_id,
      trace_id,
      sequence,
      "evaluation-analysis",
      %{"evaluation_id" => evaluation_id},
      %{
        "environment" => "mission",
        "mission_name" => mission,
        "prelude_calls" => [
          %{"component_id" => "shared.api", "ref" => "call-1"}
        ]
      }
    )
  end

  defp prelude(run_id, trace_id, sequence, component_id, environment, mission_name) do
    payload =
      %{
        "environment" => environment,
        "source" => @source,
        "source_hash" => @source_hash,
        "source_bytes" => byte_size(@source)
      }
      |> maybe_mission(mission_name)

    record(
      run_id,
      trace_id,
      sequence,
      "prelude-source",
      %{"component_id" => component_id},
      payload
    )
  end

  defp maybe_mission(payload, nil), do: payload
  defp maybe_mission(payload, mission_name), do: Map.put(payload, "mission_name", mission_name)

  defp record(run_id, trace_id, sequence, type, correlation, payload) do
    %{
      "schema_version" => Format.schema_version(),
      "run_id" => run_id,
      "trace_id" => trace_id,
      "sequence" => sequence,
      "timestamp" => timestamp(sequence),
      "record_type" => type,
      "correlation" => correlation,
      "payload" => payload
    }
  end

  defp timestamp(sequence) do
    seconds = rem(sequence, 50)

    "2026-08-25T12:00:" <> String.pad_leading(Integer.to_string(seconds), 2, "0") <> "Z"
  end

  defp result_hash(value) do
    {:ok, hash} = ResultIdentity.strict_json_hash(value)
    hash
  end
end
