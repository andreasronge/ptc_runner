defmodule PtcRunnerMcp.UpstreamFakePhase1aTest do
  @moduledoc """
  Phase 1a behaviour conformance tests for `PtcRunnerMcp.Upstream.Fake`.

  Exercises the §6.3 invariants directly against the Fake (not through
  the Registry / executor) so failures here are diagnosable in
  isolation:

    * `start_link/2` succeeds with `init_result: :ok` and fails with
      `init_result: {:error, :upstream_unavailable, _}`.
    * `list_tools/1` returns the configured schemas.
    * `call/4` enforces `:timeout` deterministically.
    * `call/4` enforces `:max_response_bytes` before handing the value back.
    * `call/4` never raises — even when the configured fun throws.
    * `stop/1` is idempotent.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §6.3, §13.2.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.Fake

  setup do
    # Each test uses a unique name to avoid Registry collisions in
    # parallel runs.
    name = "fake-#{System.unique_integer([:positive])}"
    on_exit(fn -> Fake.stop(name) end)
    {:ok, name: name}
  end

  describe "start_link/2" do
    test "returns {:ok, pid} with default config", %{name: name} do
      assert {:ok, pid} = Fake.start_link(name, %{})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "honors init_result error", %{name: name} do
      result =
        Fake.start_link(name, %{init_result: {:error, :upstream_unavailable, "simulated"}})

      assert {:error, {:upstream_unavailable, "simulated"}} = result
    end
  end

  describe "list_tools/1" do
    test "returns configured schemas", %{name: name} do
      config = %{
        tools: %{
          "search" =>
            {%{name: "search", input_schema: %{}, description: "Search"},
             fn _args, _opts -> {:ok, []} end},
          "echo" => {%{name: "echo", input_schema: %{}}, fn args, _opts -> {:ok, args} end}
        }
      }

      {:ok, _pid} = Fake.start_link(name, config)
      {:ok, schemas} = Fake.list_tools(name)

      names = Enum.map(schemas, & &1.name) |> Enum.sort()
      assert names == ["echo", "search"]
    end

    test "returns error when upstream is not running" do
      assert {:error, :upstream_unavailable, detail} =
               Fake.list_tools("missing-#{:rand.uniform(99_999_999)}")

      assert detail =~ "not running"
    end
  end

  describe "call/4 :timeout enforcement" do
    test "returns :timeout when call exceeds the supplied timeout", %{name: name} do
      slow = fn _args, _opts ->
        :timer.sleep(500)
        {:ok, %{"slept" => 500}}
      end

      config = %{tools: %{"slow" => {%{name: "slow", input_schema: %{}}, slow}}}
      {:ok, _pid} = Fake.start_link(name, config)

      # 50ms timeout vs 500ms work → ≥10× margin so this is not
      # wall-clock-flaky. The discriminator: a *broken* timeout would
      # block the test for 500ms; we instead get a clean error in <100ms.
      started = System.monotonic_time(:millisecond)
      result = Fake.call(name, "slow", %{}, timeout: 50, max_response_bytes: 1024)
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, :timeout, detail} = result
      assert detail =~ "exceeded timeout"
      # Generous 5× headroom on the timeout itself; a regression
      # that fails to honor :timeout would block 500+ ms.
      assert elapsed < 250, "expected timeout in <250ms, got #{elapsed}ms"
    end

    test "completes normally when work finishes within timeout", %{name: name} do
      fast = fn _args, _opts -> {:ok, "fast"} end
      config = %{tools: %{"fast" => {%{name: "fast", input_schema: %{}}, fast}}}
      {:ok, _pid} = Fake.start_link(name, config)

      assert {:ok, "fast"} =
               Fake.call(name, "fast", %{}, timeout: 5_000, max_response_bytes: 1024)
    end
  end

  describe "call/4 :max_response_bytes enforcement" do
    test "returns :response_too_large when JSON-encoded response exceeds cap", %{name: name} do
      payload = String.duplicate("x", 5_000)
      fun = fn _args, _opts -> {:ok, payload} end
      config = %{tools: %{"big" => {%{name: "big", input_schema: %{}}, fun}}}
      {:ok, _pid} = Fake.start_link(name, config)

      assert {:error, :response_too_large, detail} =
               Fake.call(name, "big", %{}, timeout: 5_000, max_response_bytes: 1_000)

      assert detail =~ "exceeds max_response_bytes"
    end

    test "passes through when response fits", %{name: name} do
      fun = fn _args, _opts -> {:ok, "ok"} end
      config = %{tools: %{"small" => {%{name: "small", input_schema: %{}}, fun}}}
      {:ok, _pid} = Fake.start_link(name, config)

      assert {:ok, "ok"} =
               Fake.call(name, "small", %{}, timeout: 5_000, max_response_bytes: 1_000)
    end
  end

  describe "call/4 never raises (§6.3 invariant)" do
    test "configured fun raising → {:error, :upstream_error, detail}", %{name: name} do
      raising = fn _args, _opts -> raise "kaboom" end

      config = %{tools: %{"raise" => {%{name: "raise", input_schema: %{}}, raising}}}
      {:ok, _pid} = Fake.start_link(name, config)

      assert {:error, :upstream_error, detail} =
               Fake.call(name, "raise", %{}, timeout: 1_000, max_response_bytes: 1024)

      assert detail =~ "kaboom"
    end

    test "configured fun returning {:error, reason, detail} → propagates", %{name: name} do
      fun = fn _args, _opts -> {:error, :upstream_error, "404 Not Found"} end
      config = %{tools: %{"err" => {%{name: "err", input_schema: %{}}, fun}}}
      {:ok, _pid} = Fake.start_link(name, config)

      assert {:error, :upstream_error, "404 Not Found"} =
               Fake.call(name, "err", %{}, timeout: 1_000, max_response_bytes: 1024)
    end

    test "unknown tool name → {:error, :upstream_error, _}", %{name: name} do
      {:ok, _pid} = Fake.start_link(name, %{})

      assert {:error, :upstream_error, _detail} =
               Fake.call(name, "unknown", %{}, timeout: 1_000, max_response_bytes: 1024)
    end
  end

  describe "stop/1 idempotency" do
    test "stop on a running fake returns :ok", %{name: name} do
      {:ok, _pid} = Fake.start_link(name, %{})
      assert :ok = Fake.stop(name)
    end

    test "stop on a missing fake returns :ok", %{name: name} do
      # Never started, but stop is still idempotent.
      assert :ok = Fake.stop(name)
    end

    test "double-stop is :ok", %{name: name} do
      {:ok, _pid} = Fake.start_link(name, %{})
      assert :ok = Fake.stop(name)
      assert :ok = Fake.stop(name)
    end
  end
end
