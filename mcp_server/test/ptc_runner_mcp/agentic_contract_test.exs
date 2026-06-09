defmodule PtcRunnerMcp.AgenticContractTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Upstream.{Result, Runtime}
  alias PtcRunnerMcp.Agentic
  alias PtcRunnerMcp.Agentic.{Ledger, Projection}
  alias PtcRunnerMcp.AgenticConfig
  alias PtcRunnerMcp.RootUpstreamRuntime

  @schema Path.expand("../fixtures/openapi/observatory.openapi.json", __DIR__)

  # Minimal runtime stub registered under the root-runtime name. It answers
  # both classifier sources so the regression test fails on the old MCP-local
  # classifier (which read `:catalog_snapshot`) and passes on the canonical
  # `PtcRunner.Upstream.Effect.classify/3` (which reads `Runtime.upstream/2`).
  defmodule ConflictingHintRuntime do
    @moduledoc false
    use GenServer

    @server "github"
    @tool "create_issue"
    @annotations %{"readOnlyHint" => true, "destructiveHint" => true}

    def start_link(_opts),
      do: GenServer.start_link(__MODULE__, %{}, name: PtcRunnerMcp.RootUpstreamRuntime.name())

    @impl GenServer
    def init(state), do: {:ok, state}

    # Canonical path: `Effect.classify/3` -> `Runtime.upstream/2`.
    @impl GenServer
    def handle_call({:upstream, @server}, _from, state),
      do: {:reply, %{tools: [%{"name" => @tool, "annotations" => @annotations}]}, state}

    def handle_call({:upstream, _name}, _from, state), do: {:reply, nil, state}

    # Old path: MCP-local classifier walked `:catalog_snapshot`.
    def handle_call(:catalog_snapshot, _from, state) do
      snapshot = [
        %{"name" => @server, "tools" => [%{"name" => @tool, "annotations" => @annotations}]}
      ]

      {:reply, snapshot, state}
    end

    # Success-path overview scrubs through the runtime; nothing secret here.
    def handle_call({:scrub, term}, _from, state), do: {:reply, term, state}
  end

  test "agentic config carries Phase 0 SubAgent-backed defaults" do
    defaults = AgenticConfig.defaults()

    assert defaults.max_turns == 1
    assert defaults.retry_turns == 0
    refute defaults.allow_writes
    assert defaults.subagent_config_path == nil
    assert defaults.capability_summary_max_bytes == 800
    assert defaults.capability_summary_path == nil
    assert defaults.system_prompt == %{prefix: nil, suffix: nil}
  end

  test "partial side effects reason is defined in one projection module" do
    assert Projection.partial_side_effects() == :partial_side_effects
    assert Projection.reason_string(:partial_side_effects) == "partial_side_effects"
  end

  test "ledger records attempt order and detects write or unknown effects" do
    {:ok, ledger} = Ledger.start_link()

    first = Ledger.record_attempt(ledger, "github", "search_issues", :read)
    second = Ledger.record_attempt(ledger, "github", "create_issue", :unknown)

    :ok = Ledger.complete_success(ledger, first, duration_ms: 12, result_bytes: 40)
    :ok = Ledger.complete_error(ledger, second, "timeout", "request timed out", duration_ms: 50)

    entries = Ledger.entries(ledger)

    assert [
             %{server: "github", tool: "search_issues", status: :ok, effect: :read},
             %{
               server: "github",
               tool: "create_issue",
               status: :error,
               effect: :unknown,
               error_reason: "timeout"
             }
           ] = entries

    assert Ledger.side_effecting_attempted?(entries)

    projected = Projection.ledger_entries(entries)

    assert [
             %{
               "server" => "github",
               "tool" => "search_issues",
               "status" => "ok",
               "effect" => "read",
               "duration_ms" => 12,
               "result_bytes" => 40
             },
             %{
               "server" => "github",
               "tool" => "create_issue",
               "status" => "error",
               "effect" => "unknown",
               "reason" => "timeout",
               "error" => "request timed out"
             }
           ] = projected

    # The slimmed wire shape drops `turn` and `args_hash` (no truthful
    # current semantics); assert their absence, not just the present subset.
    refute Enum.any?(projected, &Map.has_key?(&1, "turn"))
    refute Enum.any?(projected, &Map.has_key?(&1, "args_hash"))
  end

  test "root agentic tool wrapper records unknown side-effect attempt before dispatch" do
    # The success-overview path scrubs through the configured root runtime, so
    # the wrapper must run under one (as it always does in production). A
    # secret-free runtime leaves the value untouched, so the overview is
    # identical to the unscrubbed shape.
    Runtime.stop(RootUpstreamRuntime.name())

    {:ok, _pid} =
      Runtime.start_supervised(
        config: %{},
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    on_exit(fn -> Runtime.stop(RootUpstreamRuntime.name()) end)

    {:ok, ledger} = Ledger.start_link()
    parent = self()

    tools =
      Agentic.root_tools_with_ledger(
        %{
          "call" => fn _args ->
            send(parent, {:attempted_during_dispatch, Ledger.side_effecting_attempted?(ledger)})
            %{ok: true, value: %{"done" => true}}
          end
        },
        ledger
      )

    assert tools["call"].(%{server: "github", tool: "create_issue", args: %{title: "x"}}) == %{
             ok: true,
             value: %{"done" => true}
           }

    assert_receive {:attempted_during_dispatch, true}

    assert [
             %{
               server: "github",
               tool: "create_issue",
               status: :ok,
               effect: :unknown,
               result_overview: %{
                 "value_kind" => "json",
                 "shape" => "map keys=[\"done\"] count=1"
               }
             }
           ] = Ledger.entries(ledger)

    assert [
             %{
               "server" => "github",
               "tool" => "create_issue",
               "status" => "ok",
               "value_kind" => "json",
               "shape" => "map keys=[\"done\"] count=1"
             }
           ] = Projection.upstream_results(Ledger.entries(ledger))
  end

  test "root agentic tool wrapper records read-only annotated upstream calls as read" do
    Runtime.stop(RootUpstreamRuntime.name())

    {:ok, _pid} =
      Runtime.start_supervised(
        config: root_config(),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    on_exit(fn -> Runtime.stop(RootUpstreamRuntime.name()) end)

    {:ok, ledger} = Ledger.start_link()
    parent = self()

    tools =
      Agentic.root_tools_with_ledger(
        %{
          "call" => fn _args ->
            send(parent, {:attempted_during_dispatch, Ledger.side_effecting_attempted?(ledger)})
            %{ok: true, value: %{"done" => true}}
          end
        },
        ledger
      )

    assert tools["call"].(%{
             server: "observatory",
             tool: "list-traces",
             args: %{"limit" => 1}
           }) == %{ok: true, value: %{"done" => true}}

    assert_receive {:attempted_during_dispatch, false}

    assert [
             %{
               server: "observatory",
               tool: "list-traces",
               status: :ok,
               effect: :read
             }
           ] = Ledger.entries(ledger)
  end

  test "success overview redacts upstream credentials via runtime scrub" do
    Runtime.stop(RootUpstreamRuntime.name())

    {:ok, _pid} =
      Runtime.start_supervised(
        config: redacting_config(),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    on_exit(fn -> Runtime.stop(RootUpstreamRuntime.name()) end)

    {:ok, ledger} = Ledger.start_link()

    tools =
      Agentic.root_tools_with_ledger(
        %{"call" => fn _args -> Result.success(%{"token" => "SECRET"}) end},
        ledger
      )

    tools["call"].(%{server: "vault", tool: "read_secret", args: %{"path" => "db"}})

    [entry] = Ledger.entries(ledger)
    preview = entry.result_overview["preview"]

    assert preview =~ "[REDACTED]"
    refute preview =~ "SECRET"

    # `upstream_results[]` is the wire-facing surface; it must inherit the
    # same scrubbed overview, not the raw value.
    [result] = Projection.upstream_results(Ledger.entries(ledger))
    assert result["preview"] =~ "[REDACTED]"
    refute result["preview"] =~ "SECRET"
  end

  test "ledger classifies conflicting read+destructive hints as unknown side effect" do
    # A tool annotated `readOnlyHint: true` AND `destructiveHint: true` is
    # ambiguous and must fail closed. The canonical `PtcRunner.Upstream.Effect`
    # classifier returns `:unknown` for this; the deleted MCP-local classifier
    # checked `readOnlyHint` first and wrongly returned `:read`, which let an
    # interrupted destructive call slip past the continuation guard.
    Runtime.stop(RootUpstreamRuntime.name())
    start_supervised!(ConflictingHintRuntime)
    on_exit(fn -> Runtime.stop(RootUpstreamRuntime.name()) end)

    {:ok, ledger} = Ledger.start_link()

    tools =
      Agentic.root_tools_with_ledger(
        %{"call" => fn _args -> Result.success(%{"ok" => true}) end},
        ledger
      )

    tools["call"].(%{server: "github", tool: "create_issue", args: %{"title" => "x"}})

    assert [%{server: "github", tool: "create_issue", effect: :unknown}] = Ledger.entries(ledger)
    assert Ledger.side_effecting_attempted?(ledger)

    assert [%{"effect" => "unknown"}] = Projection.ledger_entries(Ledger.entries(ledger))
  end

  defp redacting_config do
    %{"credentials" => %{"token" => %{"source" => "literal", "value" => "SECRET"}}}
  end

  defp root_config do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => "https://observatory.example",
          "schema_file" => @schema,
          "include_operations" => ["list_traces"]
        }
      }
    }
  end
end
