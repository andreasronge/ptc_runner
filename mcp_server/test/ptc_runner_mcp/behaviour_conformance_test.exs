defmodule PtcRunnerMcp.BehaviourConformanceTest do
  @moduledoc """
  Phase 1b shared behaviour-conformance suite. Per
  `Plans/ptc-runner-mcp-aggregator.md` §6.3 + §13.3 last bullet:
  `Upstream.Stdio` MUST pass the same suite of behaviour
  conformance tests as `Upstream.Fake`.

  This module parameterizes a small core suite over both impls.
  Each test is dispatched twice — once with `impl: Fake` and once
  with `impl: Stdio` — using a `setup_all` hook to compute the
  per-impl scaffolding (start fixture, build a happy-path config,
  build an error-config, build an oversized-response config).

  The assertions are deliberately tight to the §6.3 invariants —
  they don't probe impl-internal details.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.{Fake, Stdio}

  @mock_path "test/support/mock_server.exs"

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp project_root, do: File.cwd!()

  # ---------- Per-impl scaffolding ----------

  # Each scaffolding triple returns:
  #   * the impl module under test
  #   * a 1-arity `config_fn` building a config with the requested
  #     scenario (an atom keyword), so the test body is identical
  #     across impls.

  defp fake_scaffold do
    config_fn = fn
      :happy ->
        %{
          tools: %{
            "echo" =>
              {%{name: "echo", input_schema: %{}}, fn args, _ -> {:ok, %{"echo" => args}} end},
            "slow" =>
              {%{name: "slow", input_schema: %{}},
               fn _, _ ->
                 :timer.sleep(500)
                 {:ok, "should never see this"}
               end},
            "big" =>
              {%{name: "big", input_schema: %{}},
               fn _, _ -> {:ok, String.duplicate("x", 5_000)} end}
          }
        }

      :error_response ->
        %{
          tools: %{
            "echo" =>
              {%{name: "echo", input_schema: %{}},
               fn _, _ -> {:error, :upstream_error, "404 Not Found"} end}
          }
        }

      :init_fail ->
        %{init_result: {:error, :upstream_unavailable, "fake init failed"}}
    end

    %{impl: Fake, config_fn: config_fn, kind: :fake}
  end

  defp stdio_scaffold do
    base = fn env_overrides ->
      %{
        command: "mix",
        args: ["run", "--no-start", "--no-compile", @mock_path],
        env: env_overrides,
        cd: project_root(),
        handshake_timeout_ms: 15_000
      }
    end

    config_fn = fn
      :happy -> base.(%{})
      :error_response -> base.(%{"MOCK_TOOL_ERROR" => "404 Not Found"})
      :init_fail -> base.(%{"MOCK_INIT_FAIL" => "1"})
    end

    %{impl: Stdio, config_fn: config_fn, kind: :stdio}
  end

  defp start_impl!(scaffold, scenario) do
    name = unique_name("conform-#{scaffold.kind}")
    config = scaffold.config_fn.(scenario)

    case scaffold.impl.start_link(name, config) do
      {:ok, pid} ->
        ExUnit.Callbacks.on_exit(fn ->
          try do
            scaffold.impl.stop(name)
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok, name, pid}

      err ->
        {:error, err}
    end
  end

  # ---------- The shared assertions ----------
  #
  # Each assertion is a 1-arity function that takes the `scaffold`
  # map and runs the scenario. The test list at the bottom of the
  # module then iterates over the impls and executes each
  # assertion. Naming uses the scaffold `:kind` so failures point
  # to the offending impl.

  defp assert_happy_path(scaffold) do
    {:ok, name, _pid} = start_impl!(scaffold, :happy)

    {:ok, schemas} = scaffold.impl.list_tools(name)
    names = Enum.map(schemas, & &1.name) |> Enum.sort()
    assert "echo" in names

    assert {:ok, _result} =
             scaffold.impl.call(name, "echo", %{"msg" => "hi"},
               timeout: 10_000,
               max_response_bytes: 1_000_000
             )
  end

  defp assert_error_response(scaffold) do
    {:ok, name, _pid} = start_impl!(scaffold, :error_response)

    assert {:error, :upstream_error, detail} =
             scaffold.impl.call(name, "echo", %{}, timeout: 5_000, max_response_bytes: 1_000_000)

    assert detail =~ "404"
  end

  defp assert_timeout_enforcement(scaffold) do
    # The "slow" tool's delay is impl-dependent: Fake's slow fun
    # has a `:timer.sleep(500)` baked in; Stdio mocks delay every
    # call via `MOCK_TOOL_DELAY_MS` env var. Both produce a
    # ≥ 500 ms upstream wait against a 50 ms call-side timeout
    # (10× margin); the §6.3 invariant — `call/4` MUST honor
    # `:timeout` — fires before the upstream replies.
    name = unique_name("conform-#{scaffold.kind}-timeout")

    config =
      case scaffold.kind do
        :fake ->
          scaffold.config_fn.(:happy)

        :stdio ->
          base = scaffold.config_fn.(:happy)
          Map.put(base, :env, Map.merge(base.env, %{"MOCK_TOOL_DELAY_MS" => "500"}))
      end

    {:ok, _pid} = scaffold.impl.start_link(name, config)
    on_exit_stop_impl(scaffold.impl, name)

    started = System.monotonic_time(:millisecond)

    result =
      scaffold.impl.call(name, "slow", %{}, timeout: 50, max_response_bytes: 1_000_000)

    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, :timeout, _} = result
    assert elapsed < 400, "expected timeout < 400ms, got #{elapsed}ms"
  end

  defp assert_oversize_enforcement(scaffold) do
    # Different mocks set up "big" differently — Fake returns a 5KB
    # string, Stdio MockServer needs MOCK_OVERSIZED_RESPONSE. To
    # keep the assertion shared, we use the impl-specific scaffold
    # for `:big` only when the kind is `:stdio` (because Stdio's
    # mock requires an env var to produce oversized output).
    name = unique_name("conform-#{scaffold.kind}-big")

    config =
      case scaffold.kind do
        :fake ->
          scaffold.config_fn.(:happy)

        :stdio ->
          base = scaffold.config_fn.(:happy)
          Map.put(base, :env, Map.merge(base.env, %{"MOCK_OVERSIZED_RESPONSE" => "5000"}))
      end

    {:ok, _pid} = scaffold.impl.start_link(name, config)
    on_exit_stop_impl(scaffold.impl, name)

    assert {:error, :response_too_large, _} =
             scaffold.impl.call(name, "big", %{}, timeout: 5_000, max_response_bytes: 100)
  end

  defp assert_init_failure(scaffold) do
    name = unique_name("conform-#{scaffold.kind}-initfail")
    config = scaffold.config_fn.(:init_fail)

    assert {:error, {:upstream_unavailable, detail}} = scaffold.impl.start_link(name, config)
    assert is_binary(detail)
  end

  defp assert_stop_idempotent(scaffold) do
    {:ok, name, _pid} = start_impl!(scaffold, :happy)
    assert :ok = scaffold.impl.stop(name)
    assert :ok = scaffold.impl.stop(name)

    # And on a never-started name:
    assert :ok = scaffold.impl.stop("never-#{System.unique_integer([:positive])}")
  end

  defp on_exit_stop_impl(impl, name) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        impl.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # ---------- Generated tests ----------
  #
  # `for` at compile-time emits one `test` per (impl, assertion)
  # pair. Stdio tests carry a longer timeout because spawning the
  # mock subprocess via `mix run` takes ~1s on cold scheduler.

  for scaffold <- [
        %{impl: Fake, kind: :fake},
        %{impl: Stdio, kind: :stdio}
      ] do
    @scaffold_kind scaffold.kind

    @tag timeout: 30_000
    test "happy path: list_tools + call (#{@scaffold_kind})" do
      assert_happy_path(scaffold_for(unquote(@scaffold_kind)))
    end

    @tag timeout: 30_000
    test "error response → :upstream_error (#{@scaffold_kind})" do
      assert_error_response(scaffold_for(unquote(@scaffold_kind)))
    end

    @tag timeout: 30_000
    test "per-call :timeout enforced (#{@scaffold_kind})" do
      assert_timeout_enforcement(scaffold_for(unquote(@scaffold_kind)))
    end

    @tag timeout: 30_000
    test ":max_response_bytes enforced → :response_too_large (#{@scaffold_kind})" do
      assert_oversize_enforcement(scaffold_for(unquote(@scaffold_kind)))
    end

    @tag timeout: 30_000
    test "init failure surfaces as {:error, {:upstream_unavailable, _}} (#{@scaffold_kind})" do
      assert_init_failure(scaffold_for(unquote(@scaffold_kind)))
    end

    @tag timeout: 30_000
    test "stop/1 is idempotent (#{@scaffold_kind})" do
      assert_stop_idempotent(scaffold_for(unquote(@scaffold_kind)))
    end
  end

  defp scaffold_for(:fake), do: fake_scaffold()
  defp scaffold_for(:stdio), do: stdio_scaffold()
end
