defmodule PtcRunnerMcp.SandboxPhase0Test do
  @moduledoc """
  Phase 0 acceptance tests for §11.2 / §11.3 / §11.6 / §12.1.

  These tests exercise `PtcRunnerMcp.Sandbox.execute/4` directly and
  assert on its **unwrapped** `{kind, payload}` shape. The wrap into
  the MCP envelope is the request handler's job (see
  `PtcRunnerMcp.Tools.call_validated/3` and the §11.3 decoration
  seam) and is covered end-to-end by the existing `tools_test.exs`
  suite. Asserting on the tuple here keeps each test focused on the
  Sandbox-level concern (`:tools` opt, limit forwarding) without
  also coupling to envelope-shape changes that Phase 1a will make
  to the *handler* path.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §11.2, §11.3, §11.6, §12.1.
  """
  # The "Limits consumption" describe block below mutates
  # process-wide `Limits` state via persistent_term, so this test
  # module is async: false to prevent interleaving with other suites
  # that read the limits map.
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Sandbox

  describe "Sandbox.execute/4 :tools opt (§11.2)" do
    test "accepts tools: [] and behaves identically to omitting the opt" do
      result_with_tools = Sandbox.execute("(+ 1 2)", %{}, nil, tools: [])
      result_without_tools = Sandbox.execute("(+ 1 2)", %{}, nil, [])

      # Both must succeed and produce identical unwrapped payloads.
      # `result`, `prints`, `feedback`, `truncated` are all
      # deterministic for `(+ 1 2)`.
      assert {:ok, payload_with} = result_with_tools
      assert {:ok, payload_without} = result_without_tools

      assert payload_with["status"] == "ok"
      assert payload_with["result"] == "user=> 3"
      assert payload_with == payload_without
    end

    test "accepts tools: [] alongside link: true" do
      # The existing `:link` opt and the new `:tools` opt coexist in
      # the same keyword list — neither should clobber the other.
      assert {:ok, payload} = Sandbox.execute("(+ 1 2)", %{}, nil, tools: [], link: true)
      assert payload["result"] == "user=> 3"
    end
  end

  describe "Sandbox.execute/4 unwrapped result shape (§11.3)" do
    # §11.3 decoration seam: `Sandbox.execute/4` returns
    # `{:ok | :error, structured_payload}` — string-keyed v1 R22/R23
    # map, not a wrapped envelope. The MCP request handler
    # (`Tools.call_validated/3`) wraps via `Envelope.success/1` /
    # `Envelope.error_envelope/1`. Phase 1a will insert
    # `upstream_calls` decoration between the two steps.

    test "success returns {:ok, R22 payload} (no isError / structuredContent wrapping)" do
      result = Sandbox.execute("(+ 1 2)", %{}, nil, tools: [])

      assert {:ok, payload} = result
      # Bare R22 keys, not the envelope's `"isError"`/`"structuredContent"`.
      assert payload["status"] == "ok"
      assert payload["result"] == "user=> 3"
      refute Map.has_key?(payload, "isError")
      refute Map.has_key?(payload, "structuredContent")
      refute Map.has_key?(payload, "content")
    end

    test "(fail v) returns {:error, R23 payload} with reason: fail" do
      result = Sandbox.execute("(fail {:reason :nope})", %{}, nil, tools: [])

      assert {:error, payload} = result
      assert payload["status"] == "error"
      assert payload["reason"] == "fail"
      refute Map.has_key?(payload, "isError")
      refute Map.has_key?(payload, "structuredContent")
    end
  end

  describe "Limits.program_timeout_ms / program_memory_limit_bytes consumption (§11.6)" do
    # Codex P2 finding (`f5acd6d` review): the flags `--program-timeout-ms`
    # and `--program-memory-limit-bytes` are persisted by
    # `Application.apply_limits/1` but `Sandbox.execute/4` must
    # actually forward them into `Lisp.run/2`'s `:timeout` and
    # `:max_heap` opts. These tests assert that lowering the limit
    # changes program execution behavior — they would have caught
    # the dead-flag bug.

    alias PtcRunnerMcp.Limits

    setup do
      original = Limits.get()
      on_exit(fn -> Limits.set(original) end)
      :ok
    end

    # Ackermann(3, 8): the same workload `sandbox_test.exs:75-100`
    # uses to validate the v1 timeout DoD. ≥1 s of pure CPU under any
    # plausible 64-bit BEAM, deeply recursive and non-list-allocating.
    # Reused here because we need the same unconditionally-slow
    # workload to prove `program_timeout_ms` flows through.
    @ackermann "((fn ack [m n] " <>
                 "(cond (= m 0) (+ n 1) " <>
                 "(= n 0) (ack (- m 1) 1) " <>
                 ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"

    test "program_timeout_ms < execution time → {:error, timeout payload}" do
      # `ack(3, 8)` ≥1 s wall-clock ≫ 200 ms cap → timeout fires.
      # 256 MB heap ≫ ack(3, 8) recursion depth → no GC race
      # (eliminates the timeout-vs-memory race entirely).
      #
      # 200 ms is strictly less than `Lisp.run/2`'s hard-coded
      # 1000 ms default, so the `=~ "200ms"` substring assertion is
      # the discriminator that proves the configured value flows
      # through. A dead flag would either say "1000ms" or finish in
      # ~1.x s of computation.
      Limits.set(%{
        Limits.defaults()
        | program_timeout_ms: 200,
          program_memory_limit_bytes: 256 * 1024 * 1024
      })

      result = Sandbox.execute(@ackermann, %{}, nil, tools: [])

      assert {:error, payload} = result
      assert payload["status"] == "error"
      assert payload["reason"] == "timeout"
      assert payload["message"] =~ "200ms"
    end

    test "program_memory_limit_bytes < heap usage → {:error, memory_limit payload}" do
      # 1M cons cells ≥16 MB on any 64-bit BEAM regardless of cell
      # layout — >60× margin over the 256 KB cap. The
      # `raised program_memory_limit_bytes lets the workload finish`
      # test below proves the configured value, not Lisp.run/2's
      # hard-coded 10 MB default, is what fires here.
      Limits.set(Map.put(Limits.defaults(), :program_memory_limit_bytes, 256 * 1024))

      result = Sandbox.execute("(count (range 0 1000000))", %{}, nil, tools: [])

      assert {:error, payload} = result
      assert payload["status"] == "error"
      assert payload["reason"] == "memory_limit"
    end

    test "raised program_memory_limit_bytes lets the workload finish" do
      # Discriminator for the memory test: the same 1M-cell program
      # that trips a 256 KB cap MUST succeed under a 256 MB cap.
      # Together with the limit-trips test above this proves the
      # configured byte count is what fires, not Lisp.run/2's
      # hard-coded 10 MB default (a dead flag would either always
      # fail at 10 MB or never fail regardless of the cap).
      Limits.set(Map.put(Limits.defaults(), :program_memory_limit_bytes, 256 * 1024 * 1024))

      result = Sandbox.execute("(count (range 0 1000000))", %{}, nil, tools: [])

      assert {:ok, payload} = result
      assert payload["result"] == "user=> 1000000"
    end

    test "default limits leave program execution unchanged" do
      # Regression guard: with the v1 defaults restored, a normal
      # program completes successfully and is not falsely starved.
      Limits.set(Limits.defaults())

      result = Sandbox.execute("(+ 1 2)", %{}, nil, tools: [])

      assert {:ok, payload} = result
      assert payload["result"] == "user=> 3"
    end

    test "sub-word program_memory_limit_bytes does not silently disable the cap" do
      # Codex P2 finding (`43c6e0d` review): `div(bytes, @bytes_per_word)`
      # for any `bytes in 1..(@bytes_per_word - 1)` rounds to 0, and
      # `:erlang.process_flag(:max_heap_size, 0)` means "no limit"
      # in the BEAM — the cap is silently disabled, the opposite of
      # intent. The forwarder MUST clamp to the BEAM's minimum
      # (`@min_max_heap_words` in `sandbox.ex`) so tiny byte counts
      # produce a tight cap that trips on any non-trivial allocation.
      #
      # Without the `max(@min_max_heap_words, ...)` clamp this
      # program runs to completion (1M-cell list fits comfortably
      # under "no cap") and `reason == "memory_limit"` fails.
      Limits.set(Map.put(Limits.defaults(), :program_memory_limit_bytes, 4))

      result = Sandbox.execute("(count (range 0 1000000))", %{}, nil, tools: [])

      assert {:error, payload} = result
      assert payload["status"] == "error"
      assert payload["reason"] == "memory_limit"
    end

    test "parallel worker limits preserve the MCP aggregate memory budget" do
      max_heap_words = div(10 * 1024 * 1024, :erlang.system_info(:wordsize))

      opts = Sandbox.parallel_limit_opts(max_heap_words)

      assert opts[:max_parallel_workers] == 8
      assert opts[:worker_max_heap] > 0
      assert opts[:worker_max_heap] * opts[:max_parallel_workers] <= max_heap_words
    end

    test "tiny MCP memory budgets use the tightest single-worker cap" do
      opts = Sandbox.parallel_limit_opts(233)

      assert opts[:max_parallel_workers] == 1
      assert opts[:worker_max_heap] == 233
    end
  end
end
