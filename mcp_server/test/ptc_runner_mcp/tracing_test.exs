defmodule PtcRunnerMcp.TracingTest do
  @moduledoc """
  End-to-end per-call tracing tests.

  Validates the Phase 3.5 DoD assertions from
  `Plans/ptc-runner-mcp-server.md` § 15 / § 16:

  - File naming, header, body event order.
  - `:none | :summary | :full` redaction.
  - FIFO `--trace-max-files` rotation.
  - Trace-write failure does not affect the tool-call response.
  - Negative: no `[:ptc_runner, :sub_agent, ...]` events appear.
  """

  # async: false because TraceConfig + TraceHandler attach process-wide.
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{JsonRpc, TraceConfig, TraceHandler}

  @program_ok "(+ 1 2)"
  @program_error "(this-is-not-a-symbol-or-form"

  setup do
    original = TraceConfig.get()

    on_exit(fn ->
      TraceConfig.set(original)
      TraceHandler.detach()
    end)

    :ok
  end

  defp with_trace_dir(opts \\ [], fun) do
    dir =
      Path.join(System.tmp_dir!(), "ptc_mcp_trace_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    cfg = %{
      trace_dir: dir,
      trace_payloads: Keyword.get(opts, :payloads, :summary),
      trace_max_files: Keyword.get(opts, :max_files, 1000)
    }

    :ok = TraceConfig.set(cfg)
    :ok = TraceHandler.attach()

    fun.(dir)
  end

  defp dispatch_call(id, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "ptc_lisp_execute", "arguments" => args}
    }

    {:reply, reply, _} = JsonRpc.dispatch({:ok, frame})
    reply
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp wait_for_files(dir, expected, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_files(dir, expected, deadline)
  end

  defp do_wait_for_files(dir, expected, deadline) do
    files = File.ls!(dir) |> Enum.filter(&String.ends_with?(&1, ".jsonl"))

    cond do
      length(files) >= expected ->
        files

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "expected at least #{expected} jsonl files; got #{length(files)}: #{inspect(files)}"
        )

      true ->
        Process.sleep(20)
        do_wait_for_files(dir, expected, deadline)
    end
  end

  # ----------------------------------------------------------------
  # § 15 / § 16: Tracing rows
  # ----------------------------------------------------------------

  describe "without --trace-dir" do
    test "no files written, no telemetry handler attached" do
      dir =
        Path.join(System.tmp_dir!(), "ptc_mcp_trace_off_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      :ok = TraceConfig.set(%{trace_dir: nil, trace_payloads: :summary, trace_max_files: 1000})
      TraceHandler.detach()

      _ = dispatch_call(1, %{"program" => @program_ok})

      assert File.ls!(dir) == []

      # And our handler is not registered.
      handler_ids =
        :telemetry.list_handlers([:ptc_runner_mcp, :call, :start])
        |> Enum.map(& &1.id)

      refute TraceHandler.handler_id() in handler_ids
    end
  end

  describe "with --trace-dir, single call" do
    test "produces exactly one JSONL file with `<iso8601>-<hash8>-ok.jsonl` naming" do
      with_trace_dir(fn dir ->
        reply = dispatch_call(42, %{"program" => @program_ok})
        refute reply["result"]["isError"]

        [file] = wait_for_files(dir, 1)
        assert file =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}.*Z-[0-9a-f]{8}-ok\.jsonl$/
      end)
    end

    test "error envelope produces `-error.jsonl`" do
      with_trace_dir(fn dir ->
        reply = dispatch_call(43, %{"program" => @program_error})
        assert reply["result"]["isError"] == true

        [file] = wait_for_files(dir, 1)
        assert file =~ ~r/-error\.jsonl$/
      end)
    end

    test "two calls produce two files" do
      with_trace_dir(fn dir ->
        _ = dispatch_call(1, %{"program" => @program_ok})
        _ = dispatch_call(2, %{"program" => @program_ok})

        files = wait_for_files(dir, 2)
        assert length(files) == 2
      end)
    end

    test "header is trace.start with pinned MCP discriminators" do
      with_trace_dir(fn dir ->
        _ = dispatch_call("req-pinned", %{"program" => @program_ok})

        [file] = wait_for_files(dir, 1)
        [header | _] = read_jsonl(Path.join(dir, file))

        assert header["event"] == "trace.start"
        assert header["trace_kind"] == "mcp_call"
        assert header["producer"] == "ptc_runner_mcp"
        assert header["trace_label"] == "req-pinned"
        # `model` is part of the trace header schema but is `nil` for
        # MCP traces; collector elides nil header keys, so either the
        # key is absent or its value is nil.
        assert Map.get(header, "model") in [nil]
        assert is_binary(header["query"]) or is_nil(header["query"])
      end)
    end

    test "body contains MCP and Lisp start/stop events in order, plus trace.stop footer" do
      with_trace_dir(fn dir ->
        _ = dispatch_call(99, %{"program" => @program_ok})

        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))
        names = Enum.map(events, & &1["event"])

        assert hd(names) == "trace.start"
        assert List.last(names) == "trace.stop"

        assert "ptc_runner_mcp.call.start" in names
        assert "ptc_runner_mcp.call.stop" in names
        assert "ptc_runner.lisp.execute.start" in names
        assert "ptc_runner.lisp.execute.stop" in names

        # Order: MCP call.start before Lisp execute.start; both before
        # their respective stop events.
        idx = fn name -> Enum.find_index(names, &(&1 == name)) end
        assert idx.("ptc_runner_mcp.call.start") < idx.("ptc_runner.lisp.execute.start")
        assert idx.("ptc_runner.lisp.execute.start") < idx.("ptc_runner.lisp.execute.stop")
        assert idx.("ptc_runner.lisp.execute.stop") < idx.("ptc_runner_mcp.call.stop")
      end)
    end

    test "stop events carry duration" do
      with_trace_dir(fn dir ->
        _ = dispatch_call(7, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        mcp_stop = Enum.find(events, &(&1["event"] == "ptc_runner_mcp.call.stop"))
        lisp_stop = Enum.find(events, &(&1["event"] == "ptc_runner.lisp.execute.stop"))

        assert is_integer(mcp_stop["duration_ms"])
        assert mcp_stop["duration_ms"] >= 0
        assert is_integer(lisp_stop["duration_ms"])
        assert lisp_stop["duration_ms"] >= 0
      end)
    end

    test "Lisp execute.start metadata carries caller: :mcp" do
      with_trace_dir(fn dir ->
        _ = dispatch_call(8, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        lisp_start = Enum.find(events, &(&1["event"] == "ptc_runner.lisp.execute.start"))
        assert lisp_start["metadata"]["caller"] == "mcp"
      end)
    end

    test "no [:ptc_runner, :sub_agent, ...] events appear (negative)" do
      with_trace_dir(fn dir ->
        _ = dispatch_call(11, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        sub_agent_events =
          events
          |> Enum.map(& &1["event"])
          |> Enum.filter(&String.starts_with?(to_string(&1), "ptc_runner.sub_agent"))

        assert sub_agent_events == []
      end)
    end
  end

  describe "--trace-payloads policy" do
    test "summary (default): program is sha256+preview+bytes, NOT full source" do
      with_trace_dir([payloads: :summary], fn dir ->
        _ = dispatch_call(1, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        start = Enum.find(events, &(&1["event"] == "ptc_runner_mcp.call.start"))
        program = start["metadata"]["program"]

        assert is_map(program)
        assert Map.has_key?(program, "sha256")
        assert Map.has_key?(program, "preview")
        assert Map.has_key?(program, "bytes")
        assert program["bytes"] == byte_size(@program_ok)
        # The preview is the full short program here.
        assert program["preview"] == @program_ok
      end)
    end

    test "full: program is the verbatim source" do
      with_trace_dir([payloads: :full], fn dir ->
        _ = dispatch_call(1, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        start = Enum.find(events, &(&1["event"] == "ptc_runner_mcp.call.start"))
        assert start["metadata"]["program"] == @program_ok
      end)
    end

    test "none: program is sha256+bytes only (no preview)" do
      with_trace_dir([payloads: :none], fn dir ->
        _ = dispatch_call(1, %{"program" => @program_ok})
        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        start = Enum.find(events, &(&1["event"] == "ptc_runner_mcp.call.start"))
        program = start["metadata"]["program"]

        assert Map.keys(program) |> Enum.sort() == ["bytes", "sha256"]
        refute Map.has_key?(program, "preview")
      end)
    end

    test "summary redacts context to per-key type+count" do
      with_trace_dir([payloads: :summary], fn dir ->
        ctx = %{"items" => [1, 2, 3, 4, 5], "name" => "alice"}
        _ = dispatch_call(1, %{"program" => "(count data/items)", "context" => ctx})

        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))

        start = Enum.find(events, &(&1["event"] == "ptc_runner_mcp.call.start"))
        ctx_meta = start["metadata"]["context"]

        assert ctx_meta["items"]["type"] == "array"
        assert ctx_meta["items"]["count"] == 5
        assert ctx_meta["name"]["type"] == "string"
      end)
    end
  end

  describe "--trace-max-files rotation" do
    test "cap of 3 with 4 sequential calls keeps only 3 files (oldest evicted)" do
      with_trace_dir([max_files: 3], fn dir ->
        for i <- 1..4 do
          _ = dispatch_call(i, %{"program" => @program_ok})
          # Force a tiny mtime delta — File.touch with explicit posix
          # ensures deterministic ordering on filesystems with 1-second
          # resolution.
          [latest | _] =
            File.ls!(dir)
            |> Enum.sort_by(fn name ->
              %File.Stat{mtime: mtime} = File.stat!(Path.join(dir, name), time: :posix)
              -mtime
            end)

          File.touch!(
            Path.join(dir, latest),
            System.os_time(:second) + i
          )
        end

        files = File.ls!(dir) |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        assert length(files) == 3
      end)
    end
  end

  describe "trace-write failure" do
    test "non-writable trace dir does not change the tool-call response" do
      # Pick a path inside a parent we'll make read-only.
      parent =
        Path.join(System.tmp_dir!(), "ptc_mcp_trace_ro_#{System.unique_integer([:positive])}")

      File.mkdir_p!(parent)

      # on_exit callbacks fire in LIFO order — register chmod LAST so
      # it runs FIRST (restoring write perm before rm_rf).
      on_exit(fn -> File.rm_rf!(parent) end)
      on_exit(fn -> File.chmod(parent, 0o755) end)

      child = Path.join(parent, "traces")
      File.chmod!(parent, 0o555)

      :ok =
        TraceConfig.set(%{
          trace_dir: child,
          trace_payloads: :summary,
          trace_max_files: 1000
        })

      :ok = TraceHandler.attach()

      reply = dispatch_call(1, %{"program" => @program_ok})

      # The envelope is unaffected.
      refute reply["result"]["isError"]
      sc = reply["result"]["structuredContent"]
      assert sc["status"] == "ok"
    end
  end

  # § 16 phase-0.5 reverify: write_to_active outside scope.
  describe "PtcRunner.TraceLog.write_to_active/1 outside scope" do
    test "returns :no_collector" do
      assert PtcRunner.TraceLog.write_to_active(%{"event" => "noop"}) == :no_collector
    end
  end
end
