defmodule PtcRunnerMcp.AggregatorPhase1bTest do
  @moduledoc """
  Phase 1b cross-name concurrency test (mandatory DoD per §12.3.3).

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §4.4 + §12.3.3.

  Two cold Fake upstreams configured with `init_delay_ms: 200` are
  invoked concurrently from one program via `pmap`. Pre-Phase-1b the
  Registry's single `handle_call` ran `attempt_start/3`, so cross-
  name cold starts globally serialized: total wall-clock ≈
  sum(delays) ≈ 400 ms. Phase 1b moves cold-start work into per-name
  `Connection` workers; their mailboxes are independent, so the two
  cold starts run in parallel and total wall-clock ≈ max(delays) ≈
  200 ms.

  We assert a 1.5× tolerance over `max(delays)` (= 300 ms). The
  pre-fix path takes ≥ 400 ms, well outside this bound — the test
  fails deterministically without the Connection split.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Limits, Tools}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry()

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())

    on_exit(fn ->
      stop_existing_registry()
      Limits.set(Limits.defaults())
    end)

    :ok
  end

  defp stop_existing_registry do
    case Process.whereis(@registry_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  describe "cross-name concurrency (§12.3.3 mandatory DoD)" do
    test "two cold upstreams (300 ms init each) complete in < 1.5 × max(delays)" do
      # Per the prompt's lessons-learned: pick delays large enough
      # that wall-clock signal is unmistakable on warm BEAM. 300ms
      # gives a 450ms bound with a parallel-actual ≈ 300–340ms;
      # the serial pre-fix path is ≥ 600ms (50%+ outside the bound).
      delay_ms = 300

      # Per-test unique names. `Fake.Names` is process-wide; this
      # async: false test still runs concurrently with async: true
      # tests that hit the same Registry, so literal "alpha"/"beta"
      # races their `Fake.Names` lookups. See longer rationale in
      # `upstream_registry_phase1a_test.exs`.
      alpha = "alpha-#{System.unique_integer([:positive])}"
      beta = "beta-#{System.unique_integer([:positive])}"

      :ok =
        Registry.put_fake(
          alpha,
          %{
            init_delay_ms: delay_ms,
            tools: %{
              "ping" =>
                {%{name: "ping", input_schema: %{}}, fn _args, _opts -> {:ok, "alpha-pong"} end}
            }
          },
          @registry_name
        )

      :ok =
        Registry.put_fake(
          beta,
          %{
            init_delay_ms: delay_ms,
            tools: %{
              "ping" =>
                {%{name: "ping", input_schema: %{}}, fn _args, _opts -> {:ok, "beta-pong"} end}
            }
          },
          @registry_name
        )

      # The program issues two concurrent (tool/mcp-call ...) calls
      # via pmap, one per upstream. Each cold-starts its own
      # Connection's Fake (200 ms). Pre-Phase-1b: the Registry's
      # serial `handle_call` runs `attempt_start/3` for the two
      # names, so wall-clock ≈ 400 ms. Phase 1b: Connection
      # mailboxes are independent — wall-clock ≈ 200 ms.
      program = """
      (pmap (fn [server]
              (tool/mcp-call {:server server :tool "ping" :args {}}))
            [#{Jason.encode!(alpha)} #{Jason.encode!(beta)}])
      """

      started = System.monotonic_time(:millisecond)
      env = Tools.call_with_gate(%{"program" => program})
      elapsed = System.monotonic_time(:millisecond) - started

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"

      entries = env["structuredContent"]["upstream_calls"]
      assert length(entries) == 2

      Enum.each(entries, fn e ->
        assert e["status"] == "ok"
      end)

      # The §12.3.3 assertion: wall-clock total < 1.5 × max(delays).
      # On a warm BEAM with two 200 ms cold starts running in
      # parallel, elapsed ≈ 200–250 ms. Pre-fix it would be ≥ 400 ms,
      # deterministically outside the bound.
      bound = trunc(1.5 * delay_ms)

      assert elapsed < bound,
             "expected wall-clock < #{bound} ms (1.5 × max(delays)), got #{elapsed} ms"

      # And, as a sanity floor, elapsed MUST be at least max(delays)
      # — we genuinely paid for the cold start, just once instead of
      # twice. Use a 0.8× margin to keep the assertion deterministic
      # on fast schedulers.
      floor = trunc(0.8 * delay_ms)

      assert elapsed >= floor,
             "expected wall-clock ≥ #{floor} ms (0.8 × max(delays)), got #{elapsed} ms"
    end
  end
end
