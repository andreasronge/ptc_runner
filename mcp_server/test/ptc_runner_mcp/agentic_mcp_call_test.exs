defmodule PtcRunnerMcp.AgenticMcpCallTest do
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunnerMcp.Agentic.{Ledger, McpCall}
  alias PtcRunnerMcp.{AggregatorConfig, Limits}
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Fake
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    Fake.stop("alpha")
    stop_existing_registry(@registry_name)
    Catalog.clear_frozen()
    AggregatorConfig.set(AggregatorConfig.defaults())
    Limits.set(Limits.defaults())

    on_exit(fn ->
      Fake.stop("alpha")
      stop_existing_registry(@registry_name)
      Catalog.clear_frozen()
      AggregatorConfig.set(AggregatorConfig.defaults())
      Limits.set(Limits.defaults())
    end)

    :ok
  end

  describe "normalization" do
    test "accepts string and keyword keys and defaults missing args" do
      assert {:ok, %{server: "alpha", tool: "search", args: %{}}} =
               McpCall.normalize_args(%{"server" => "alpha", tool: "search"})

      assert {:ok, %{server: "alpha", tool: "search", args: %{"q" => "auth"}}} =
               McpCall.normalize_args(%{server: "alpha", tool: "search", args: %{"q" => "auth"}})
    end

    test "rejects unknown and duplicate normalized keys" do
      assert {:error, message} =
               McpCall.normalize_args(%{"server" => "alpha", "tool" => "search", "extra" => true})

      assert message =~ "unknown key"

      assert {:error, message} =
               McpCall.normalize_args(%{
                 :server => "beta",
                 "server" => "alpha",
                 "tool" => "search"
               })

      assert message =~ "duplicate key"
    end
  end

  describe "effect classification" do
    test "read-only aggregator posture records every call as read" do
      :ok = AggregatorConfig.set(%{read_only: true})

      assert McpCall.classify_effect(%{"annotations" => %{"destructiveHint" => true}}) == :read
      assert McpCall.classify_effect(nil) == :read
    end

    test "uses upstream annotations when aggregator is not read-only" do
      :ok = AggregatorConfig.set(%{read_only: false})

      assert McpCall.classify_effect(%{"annotations" => %{"readOnlyHint" => true}}) == :read

      assert McpCall.classify_effect(%{annotations: %{"destructiveHint" => true}}) == :write

      assert McpCall.classify_effect(%{"annotations" => %{}}) == :unknown
      assert McpCall.classify_effect(nil) == :unknown
    end
  end

  describe "call wrapper" do
    setup do
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Catalog.freeze("alpha:\n  ok\n  err")
      :ok
    end

    test "returns a tagged success map and completes the ledger entry" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, %{"answer" => 42}} end})
      {:ok, ledger} = Ledger.start_link()

      result =
        McpCall.call(
          %{"server" => "alpha", "tool" => "ok", "args" => %{}},
          ledger: ledger,
          registry: @registry_name,
          turn: 2
        )

      assert result == %{ok: true, value: %{"answer" => 42}}

      assert [
               %{
                 server: "alpha",
                 tool: "ok",
                 status: :ok,
                 effect: :read,
                 turn: 2,
                 result_bytes: result_bytes
               }
             ] = Ledger.entries(ledger)

      assert result_bytes > 0
    end

    test "accepts a dynamic turn provider" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, true} end})
      {:ok, ledger} = Ledger.start_link()
      {:ok, turn_tracker} = Agent.start_link(fn -> 3 end)

      assert %{ok: true, value: true} =
               McpCall.call(
                 %{"server" => "alpha", "tool" => "ok", "args" => %{}},
                 ledger: ledger,
                 registry: @registry_name,
                 turn: fn -> Agent.get(turn_tracker, & &1) end
               )

      assert [%{turn: 3}] = Ledger.entries(ledger)
    end

    test "falls back to turn one for an invalid dynamic turn provider" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, true} end})
      {:ok, ledger} = Ledger.start_link()

      assert %{ok: true, value: true} =
               McpCall.call(
                 %{"server" => "alpha", "tool" => "ok", "args" => %{}},
                 ledger: ledger,
                 registry: @registry_name,
                 turn: fn -> nil end
               )

      assert [%{turn: 1}] = Ledger.entries(ledger)
    end

    test "records attempted entries before completing in-flight calls" do
      :ok = AggregatorConfig.set(%{read_only: true})
      parent = self()

      :ok =
        put_fake("alpha", %{
          "ok" => fn _, _ ->
            send(parent, {:upstream_entered, self()})

            receive do
              :release_upstream -> {:ok, "done"}
            after
              1_000 -> {:error, :timeout, "test timed out"}
            end
          end
        })

      {:ok, ledger} = Ledger.start_link()

      task =
        Task.async(fn ->
          McpCall.call(
            %{"server" => "alpha", "tool" => "ok", "args" => %{}},
            ledger: ledger,
            registry: @registry_name
          )
        end)

      assert_receive {:upstream_entered, upstream_pid}

      assert [
               %{
                 server: "alpha",
                 tool: "ok",
                 status: :attempted,
                 effect: :read
               }
             ] = Ledger.entries(ledger)

      send(upstream_pid, :release_upstream)
      assert Task.await(task) == %{ok: true, value: "done"}
      assert [%{status: :ok}] = Ledger.entries(ledger)
    end

    test "returns a tagged world fault map and completes the ledger entry as error" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = put_fake("alpha", %{"err" => fn _, _ -> {:error, :timeout, "too slow"} end})
      {:ok, ledger} = Ledger.start_link()

      result =
        McpCall.call(
          %{server: "alpha", tool: "err", args: %{}},
          ledger: ledger,
          registry: @registry_name
        )

      assert result == %{ok: false, reason: "timeout", message: "too slow"}

      assert [
               %{
                 server: "alpha",
                 tool: "err",
                 status: :error,
                 effect: :read,
                 error_reason: "timeout",
                 error: "too slow"
               }
             ] = Ledger.entries(ledger)
    end

    test "enforces the per-program upstream call cap across one built tool closure" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, true} end})
      {:ok, ledger} = Ledger.start_link()
      %{"mcp-call" => mcp_call} = McpCall.build(ledger, registry: @registry_name, max_calls: 1)

      args = %{"server" => "alpha", "tool" => "ok", "args" => %{}}

      assert mcp_call.(args) == %{ok: true, value: true}
      assert mcp_call.(args) == %{ok: false, reason: "cap_exhausted", message: "cap_exhausted"}

      assert [
               %{status: :ok},
               %{status: :error, error_reason: "cap_exhausted", error: "cap_exhausted"}
             ] = Ledger.entries(ledger)
    end

    test "programmer faults before dispatch reject without ledger entries" do
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, true} end})
      {:ok, ledger} = Ledger.start_link()

      assert_raise ExecutionError, ~r/unknown key/, fn ->
        McpCall.call(
          %{"server" => "alpha", "tool" => "ok", "bad" => true},
          ledger: ledger,
          registry: @registry_name
        )
      end

      assert Ledger.entries(ledger) == []
    end
  end

  describe "side_effecting_attempted?/1" do
    test "treats attempted write and unknown entries as side-effecting" do
      refute Ledger.side_effecting_attempted?([
               %{effect: :read, status: :attempted}
             ])

      assert Ledger.side_effecting_attempted?([
               %{effect: :read, status: :ok},
               %{effect: :write, status: :attempted}
             ])

      assert Ledger.side_effecting_attempted?([
               %{effect: :unknown, status: :error}
             ])
    end
  end

  defp put_fake(name, tools) do
    Registry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {name, fun} ->
          schema = %{
            name: name,
            input_schema: %{},
            annotations: %{"readOnlyHint" => true, "destructiveHint" => false}
          }

          {name, {schema, fun}}
        end)
    }
  end
end
