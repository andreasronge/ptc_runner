defmodule PtcRunnerMcp.DebugRecorderTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.DebugRecorder.record_outcome/4` — the
  recognized-tool dispatch hook that builds a redacted call record and
  hands it to `PtcRunnerMcp.DebugBuffer`. These drive the real path
  end-to-end: `record_outcome/4` → `DebugBuffer.record/1` → ETS ring →
  read back via `DebugBuffer.get/1` / `recent/1`.

  The recorder mutates process-global state (the named `DebugBuffer`
  GenServer + ETS, and `:persistent_term` for `DebugConfig` /
  `TraceConfig`, plus the named `Credentials` redaction-set table in
  one test). So `async: false` with full reset in `setup` / `on_exit`.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Credentials, DebugBuffer, DebugConfig, DebugRecorder, TraceConfig, Version}

  setup do
    original_debug = DebugConfig.get()
    original_trace = TraceConfig.get()

    on_exit(fn ->
      DebugConfig.set(original_debug)
      TraceConfig.set(original_trace)
    end)

    :ok
  end

  # Start a buffer, enable the debug tool, and set the payload level.
  defp start_recording(opts \\ []) do
    level = Keyword.get(opts, :level, :summary)
    DebugConfig.set(%{enabled: true, ring_size: 50, max_response_bytes: 65_536})
    TraceConfig.set(%{trace_payloads: level})
    pid = start_supervised!({DebugBuffer, [ring_size: 50, name: DebugBuffer]})
    pid
  end

  # `record_outcome/4`'s effect is a `DebugBuffer.record/1` cast; force a
  # sync read to flush the mailbox before asserting.
  defp flush, do: DebugBuffer.count()

  defp eval_params(args \\ %{}) do
    %{"name" => "lisp_eval", "arguments" => args}
  end

  defp task_params(args \\ %{}) do
    %{"name" => "lisp_task", "arguments" => args}
  end

  describe "gating: no-op paths" do
    test "records nothing and returns :ok when --debug-tool is disabled" do
      DebugConfig.set(%{enabled: false, ring_size: 50, max_response_bytes: 65_536})
      _pid = start_supervised!({DebugBuffer, [ring_size: 50, name: DebugBuffer]})

      assert :ok =
               DebugRecorder.record_outcome("req-1", eval_params(%{"program" => "(+ 1 1)"}), %{
                 "structuredContent" => %{"status" => "ok"}
               })

      flush()
      assert DebugBuffer.count() == 0
    end

    test "records nothing for an unrecognized tool name" do
      start_recording()

      assert :ok =
               DebugRecorder.record_outcome(
                 "req-1",
                 %{"name" => "lisp_debug", "arguments" => %{}},
                 %{"structuredContent" => %{"status" => "ok"}}
               )

      flush()
      assert DebugBuffer.count() == 0
    end

    test "records nothing for an unknown_tool rejection envelope" do
      start_recording()

      envelope = %{"structuredContent" => %{"reason" => "unknown_tool"}}
      assert :ok = DebugRecorder.record_outcome("req-1", task_params(), envelope)

      flush()
      assert DebugBuffer.count() == 0
    end

    test "swallows and returns :ok even when the params shape is unexpected" do
      start_recording()
      # A non-map params would crash `recognized?/1`'s `Map.get` if not
      # guarded; the rescue/catch contract guarantees :ok regardless.
      assert :ok = DebugRecorder.record_outcome("req-1", :not_a_map, %{})
      flush()
      assert DebugBuffer.count() == 0
    end
  end

  describe "recognized?/1" do
    test "is true for lisp_eval / lisp_task / session tools, false otherwise" do
      assert DebugRecorder.recognized?(%{"name" => "lisp_eval"})
      assert DebugRecorder.recognized?(%{"name" => "lisp_task"})
      assert DebugRecorder.recognized?(%{"name" => "lisp_session_eval"})
      refute DebugRecorder.recognized?(%{"name" => "lisp_debug"})
      refute DebugRecorder.recognized?(%{"name" => "tools/list"})
      refute DebugRecorder.recognized?(%{})
      refute DebugRecorder.recognized?("not a map")
    end
  end

  describe "lisp_eval success record" do
    test "captures tool, status, redacted program/context, and protocol version" do
      start_recording(level: :none)

      params =
        eval_params(%{
          "program" => "(+ 1 2)",
          "context" => %{"a" => 1}
        })

      envelope = %{
        "structuredContent" => %{
          "status" => "ok",
          "result" => ~s({"x":1}),
          "prints" => ["line one", "line two"]
        }
      }

      assert :ok = DebugRecorder.record_outcome("req-eval", params, envelope, duration_ms: 17)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-eval")
      assert rec.tool == "lisp_eval"
      assert rec.status == :ok
      assert rec.reason == nil
      assert rec.is_error == false
      assert rec.duration_ms == 17
      assert rec.protocol_version == Version.primary()
      # `:none` level redacts the program to sha256 + bytes.
      assert %{"sha256" => sha, "bytes" => 7} = rec.program
      assert byte_size(sha) == 64
      assert rec.context == %{"<bytes>" => byte_size(~s({"a":1}))}
      assert rec.result_bytes == byte_size(~s({"x":1}))
      assert rec.prints_count == 2
      # lisp_eval never carries an agentic block.
      assert rec.agentic == nil
    end

    test "signature_present? reflects a non-nil signature argument" do
      start_recording()

      params =
        eval_params(%{
          "program" => "(+ 1 1)",
          "signature" => %{"type" => "object"}
        })

      assert :ok =
               DebugRecorder.record_outcome("req-sig", params, %{
                 "structuredContent" => %{"status" => "ok"}
               })

      flush()
      assert {:ok, rec} = DebugBuffer.get("req-sig")
      assert rec.signature_present? == true
    end
  end

  describe "non-executed programs are not retained" do
    test "args_error drops program/context even though args were present" do
      start_recording(level: :full)

      params =
        eval_params(%{
          "program" => "(this is unbounded raw input)",
          "context" => %{"big" => "blob"}
        })

      envelope = %{
        "structuredContent" => %{"status" => "error", "reason" => "args_error"}
      }

      assert :ok = DebugRecorder.record_outcome("req-argerr", params, envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-argerr")
      assert rec.status == :error
      assert rec.reason == "args_error"
      # Not executed → program/context are NOT stored, even under :full.
      assert rec.program == nil
      assert rec.context == nil
    end

    test "a runtime_error DID execute, so program/context are retained" do
      start_recording(level: :full)

      params = eval_params(%{"program" => "(boom)", "context" => %{"k" => "v"}})

      envelope = %{
        "structuredContent" => %{"status" => "error", "reason" => "runtime_error"}
      }

      assert :ok = DebugRecorder.record_outcome("req-rterr", params, envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-rterr")
      assert rec.status == :error
      assert rec.reason == "runtime_error"
      # Executed → :full retains the raw program + context verbatim.
      assert rec.program == "(boom)"
      assert rec.context == %{"k" => "v"}
    end
  end

  describe "status/reason derivation" do
    test "isError without a structured status maps to :error" do
      start_recording()

      envelope = %{"isError" => true, "content" => [%{"type" => "text", "text" => "x"}]}
      assert :ok = DebugRecorder.record_outcome("req-iserr", eval_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-iserr")
      assert rec.is_error == true
      assert rec.status == :error
      assert rec.reason == nil
    end

    test "a __lisp_debug_structured override wins over structuredContent" do
      start_recording()

      envelope = %{
        "__lisp_debug_structured" => %{"status" => "error", "reason" => "timeout"},
        "structuredContent" => %{"status" => "ok"}
      }

      assert :ok = DebugRecorder.record_outcome("req-override", eval_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-override")
      assert rec.status == :error
      assert rec.reason == "timeout"
    end
  end

  describe "request_id bounding" do
    test "an over-long request id is truncated with a size marker" do
      start_recording()

      big_id = String.duplicate("a", 300)
      assert :ok = DebugRecorder.record_outcome(big_id, eval_params(), %{"isError" => false})
      flush()

      [rec] = DebugBuffer.recent(limit: 1)
      assert rec.request_id =~ "…(300B id, truncated)"
      assert String.starts_with?(rec.request_id, String.duplicate("a", 64))
    end

    test "a non-string request id is stringified" do
      start_recording()

      assert :ok = DebugRecorder.record_outcome(12_345, eval_params(), %{"isError" => false})
      flush()

      assert {:ok, rec} = DebugBuffer.get("12345")
      assert rec.request_id == "12345"
    end
  end

  describe "upstream_calls redaction" do
    test "keeps only scalar fields and drops free-text error/detail" do
      start_recording()

      envelope = %{
        "structuredContent" => %{
          "status" => "ok",
          "upstream_calls" => [
            %{
              "server" => "github",
              "tool" => "search",
              "status" => "ok",
              "duration_ms" => 12,
              "reason" => nil,
              "result_bytes" => 2048,
              "oversize" => false,
              "error" => "secret-bearing free text we must drop"
            }
          ]
        }
      }

      assert :ok = DebugRecorder.record_outcome("req-uc", eval_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-uc")
      assert [entry] = rec.upstream_calls

      assert entry == %{
               "server" => "github",
               "tool" => "search",
               "status" => "ok",
               "duration_ms" => 12,
               "reason" => nil,
               "result_bytes" => 2048,
               "oversize" => false
             }

      # The free-text `error` detail is never carried into the ring.
      refute Map.has_key?(entry, "error")
    end

    test "normalizes a negative result_bytes to nil and coerces oversize to a bool" do
      start_recording()

      envelope = %{
        "structuredContent" => %{
          "status" => "ok",
          "upstream_calls" => [
            %{"server" => "s", "tool" => "t", "status" => "error", "result_bytes" => -5}
          ]
        }
      }

      assert :ok = DebugRecorder.record_outcome("req-norm", eval_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-norm")
      assert [entry] = rec.upstream_calls
      assert entry["result_bytes"] == nil
      assert entry["oversize"] == false
    end
  end

  describe "redaction via the Credentials redactor (defense in depth)" do
    test "a registered secret embedded in the program is scrubbed under :full" do
      # Boot Credentials so the redaction-set ETS table exists; register a
      # plaintext secret, then assert the recorder's :full program redaction
      # ran it through `Redactor.scrub/1`.
      start_supervised!({Credentials, [bindings: %{}]})
      secret = "sk-live-" <> String.duplicate("z", 32)
      :ok = Credentials.register_redaction_secrets([secret])

      start_recording(level: :full)

      program = "(http/get #{inspect(secret)})"
      params = eval_params(%{"program" => program})

      envelope = %{"structuredContent" => %{"status" => "ok"}}
      assert :ok = DebugRecorder.record_outcome("req-secret", params, envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-secret")
      refute rec.program =~ secret
      assert rec.program =~ "[REDACTED]"
    end
  end

  describe "ptc_metrics passthrough" do
    test "copies the envelope ptc_metrics block verbatim and nil when absent" do
      start_recording()

      metrics = %{
        "upstream_result_bytes" => 1000,
        "final_result_bytes" => 100,
        "payload_reduction_ratio" => 10.0
      }

      with_metrics = %{"structuredContent" => %{"status" => "ok", "ptc_metrics" => metrics}}
      assert :ok = DebugRecorder.record_outcome("req-m1", eval_params(), with_metrics)

      without = %{"structuredContent" => %{"status" => "ok"}}
      assert :ok = DebugRecorder.record_outcome("req-m2", eval_params(), without)
      flush()

      assert {:ok, r1} = DebugBuffer.get("req-m1")
      assert r1.ptc_metrics == metrics

      assert {:ok, r2} = DebugBuffer.get("req-m2")
      assert r2.ptc_metrics == nil
    end
  end

  describe "agentic block math (lisp_task)" do
    test "derives planner/execution proxies: rejects = calls - turns, retries = turns - 1" do
      start_recording()

      envelope = %{
        "structuredContent" => %{
          "status" => "ok",
          "program" => "(do :work)",
          "planner" => %{"calls" => 5, "duration_ms" => 250},
          "execution" => %{"turn_count" => 3, "duration_ms" => 900}
        }
      }

      params = task_params(%{"program" => "(do :work)"})
      assert :ok = DebugRecorder.record_outcome("req-task", params, envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-task")
      assert rec.tool == "lisp_task"
      a = rec.agentic
      assert a.planner_status == :ok
      assert a.planner_duration_ms == 250
      # 5 calls - 3 turns = 2 rejects.
      assert a.planner_rejects == 2
      # 3 turns - 1 = 2 retries.
      assert a.retries == 2
      assert a.program_bytes == byte_size("(do :work)")
    end

    test "planner error and a single turn give zero rejects/retries" do
      start_recording()

      envelope = %{
        "structuredContent" => %{
          "status" => "error",
          "reason" => "planner_error",
          "planner" => %{"error" => "bad plan", "calls" => 1},
          "execution" => %{"turn_count" => 1}
        }
      }

      assert :ok = DebugRecorder.record_outcome("req-task-err", task_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-task-err")
      a = rec.agentic
      assert a.planner_status == :error
      # max(1 - 1, 0) = 0 rejects; turns == 1 → 0 retries.
      assert a.planner_rejects == 0
      assert a.retries == 0
      # No program field → program_bytes is nil.
      assert a.program_bytes == nil
    end

    test "a lisp_task with neither planner nor execution has a nil agentic block" do
      start_recording()

      # `busy`/validation-style task: no planner/execution → nil agentic.
      envelope = %{"structuredContent" => %{"status" => "error", "reason" => "busy"}}
      assert :ok = DebugRecorder.record_outcome("req-task-busy", task_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-task-busy")
      assert rec.tool == "lisp_task"
      assert rec.agentic == nil
    end

    test "non-integer turn/calls fields degrade to zero rejects/retries, not a crash" do
      start_recording()

      envelope = %{
        "structuredContent" => %{
          "status" => "ok",
          "planner" => %{"calls" => "n/a"},
          "execution" => %{"turn_count" => nil}
        }
      }

      assert :ok = DebugRecorder.record_outcome("req-task-bad", task_params(), envelope)
      flush()

      assert {:ok, rec} = DebugBuffer.get("req-task-bad")
      a = rec.agentic
      assert a.planner_rejects == 0
      assert a.retries == 0
    end
  end
end
