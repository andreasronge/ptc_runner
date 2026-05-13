defmodule PtcRunnerMcp.TelemetryPhase1aTest do
  @moduledoc """
  Phase 1a tests for the `[:ptc_runner_mcp, :upstream, :call, :*]`
  telemetry event family per `Plans/ptc-runner-mcp-aggregator.md` §10.

  Asserts:

    * `:start` and `:stop` events fire around every `(tool/mcp-call ...)`
      attempt, with metadata `caller: :mcp` (FIXED, NOT widened),
      `profile: :mcp_aggregator`, `server`, `tool`.
    * `:stop` carries `status: :ok | :error` and (on error) `reason`.
    * Default metadata does NOT include raw upstream args / raw
      upstream results (§10 last paragraph: default-off payload capture).
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{Limits, Tools}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry(@registry_name)
    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())

    handler_id = "phase1a-telemetry-#{System.unique_integer([:positive])}"

    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_runner_mcp, :upstream, :call, :start],
          [:ptc_runner_mcp, :upstream, :call, :stop],
          [:ptc_runner_mcp, :upstream, :call, :exception]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      stop_existing_registry(@registry_name)
      Limits.set(Limits.defaults())
    end)

    :ok
  end

  defp put_fake(name, tools) do
    config = %{
      tools: Map.new(tools, fn {n, fun} -> {n, {%{name: n, input_schema: %{}}, fun}} end)
    }

    Registry.put_fake(name, config, @registry_name)
  end

  describe "[:ptc_runner_mcp, :upstream, :call, :*]" do
    test ":start + :stop emit on a successful call" do
      :ok = put_fake("alpha", %{"echo" => fn args, _ -> {:ok, args} end})

      _env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {:k "v"}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :start], _, start_meta}

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], stop_meas,
                      stop_meta}

      assert start_meta.caller == :mcp
      assert start_meta.profile == :mcp_aggregator
      assert start_meta.server == "alpha"
      assert start_meta.tool == "echo"

      assert stop_meta.caller == :mcp
      assert stop_meta.profile == :mcp_aggregator
      assert stop_meta.status == :ok

      assert is_integer(stop_meas.duration)
    end

    test ":stop carries reason on world-fault error" do
      :ok = put_fake("alpha", %{"err" => fn _, _ -> {:error, :upstream_error, "boom"} end})

      _env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "err" :args {}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], _, meta}
      assert meta.status == :error
      assert meta.reason == :upstream_error
    end

    # §16 (decomposed cold-start telemetry): the `:stop` event splits
    # the wall-clock total into ensure-started cost (cold-start
    # spawn + handshake) and call cost (steady-state `tools/call`),
    # so operators can attribute regressions to one or the other.
    # Both fields are always present, both on success and on
    # world-fault, with `0` when the corresponding phase didn't run.
    test ":stop carries decomposed ensure_duration_ms + call_duration_ms" do
      :ok = put_fake("alpha", %{"echo" => fn args, _ -> {:ok, args} end})

      _env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {:k "v"}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], _, stop_meta}

      assert is_integer(stop_meta.ensure_duration_ms) and stop_meta.ensure_duration_ms >= 0
      assert is_integer(stop_meta.call_duration_ms) and stop_meta.call_duration_ms >= 0
    end

    test ":stop carries decomposed durations on world-fault too" do
      :ok = put_fake("alpha", %{"err" => fn _, _ -> {:error, :upstream_error, "boom"} end})

      _env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "err" :args {}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], _, meta}
      assert meta.status == :error
      assert is_integer(meta.ensure_duration_ms) and meta.ensure_duration_ms >= 0
      assert is_integer(meta.call_duration_ms) and meta.call_duration_ms >= 0
    end

    test "default metadata does NOT include raw args or raw results" do
      :ok =
        put_fake("alpha", %{
          "echo" => fn _, _ -> {:ok, %{"secret" => "should-not-leak"}} end
        })

      _env =
        Tools.call_with_gate(%{
          "program" =>
            ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {:secret_in "hidden"}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :start], _, start_meta}
      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], _, stop_meta}

      # No raw `args` / `result` keys in metadata: §10 default-off.
      refute Map.has_key?(start_meta, :args)
      refute Map.has_key?(start_meta, :arguments)
      refute Map.has_key?(stop_meta, :result)
      refute Map.has_key?(stop_meta, :raw_result)

      # Sanity: serializing the metadata also doesn't surface the
      # secret value (anywhere in the metadata tree, not just at
      # top level).
      refute inspect(start_meta) =~ "should-not-leak"
      refute inspect(start_meta) =~ "hidden"
      refute inspect(stop_meta) =~ "should-not-leak"
      refute inspect(stop_meta) =~ "hidden"
    end

    test "request_id is threaded into upstream telemetry metadata (§10)" do
      # Operators correlating a failing upstream call back to the
      # originating MCP `tools/call` request use `request_id` as
      # the join key. Pre-fix: `Tools.execute_with_aggregator/4`
      # did not accept a `:request_id` opt, so
      # `AggregatorTools.build/2` defaulted `request_id` to `nil`
      # and the upstream telemetry metadata carried `request_id: nil`
      # even when the caller had a real id.
      :ok = put_fake("alpha", %{"echo" => fn args, _ -> {:ok, args} end})

      # Drive the path that JsonRpc.async_tools_call uses:
      # `Tools.call_validated/4` with a `:request_id` opt.
      request_id = "test-request-#{System.unique_integer([:positive])}"

      _envelope =
        Tools.call_validated(
          ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {:k "v"}})|,
          %{},
          nil,
          request_id: request_id
        )

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :start], _, start_meta}

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :stop], _, stop_meta}

      # Pre-fix: both metas had `request_id: nil`. Post-fix: the
      # request id flows from JsonRpc → Tools → AggregatorTools
      # closure → telemetry span metadata.
      assert start_meta.request_id == request_id
      assert stop_meta.request_id == request_id
    end

    test "request_id defaults to nil for in-process callers without one" do
      :ok = put_fake("alpha", %{"echo" => fn args, _ -> {:ok, args} end})

      # `Tools.call_with_gate/1` doesn't carry a request id (used
      # by tests / direct in-process callers) — the metadata
      # gracefully degrades to `request_id: nil` rather than
      # crashing or omitting the key.
      _envelope =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {}})|
        })

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :call, :start], _, start_meta}
      assert start_meta.request_id == nil
    end
  end
end
