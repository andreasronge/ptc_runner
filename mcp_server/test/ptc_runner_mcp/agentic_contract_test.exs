defmodule PtcRunnerMcp.AgenticContractTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Agentic
  alias PtcRunnerMcp.Agentic.{Ledger, Projection}
  alias PtcRunnerMcp.AgenticConfig

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

    first = Ledger.record_attempt(ledger, "github", "search_issues", %{"q" => "auth"}, :read, 1)
    second = Ledger.record_attempt(ledger, "github", "create_issue", %{}, :unknown, 1)

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

    assert [
             %{
               "server" => "github",
               "tool" => "search_issues",
               "status" => "ok",
               "effect" => "read",
               "duration_ms" => 12,
               "result_bytes" => 40,
               "turn" => 1
             },
             %{
               "server" => "github",
               "tool" => "create_issue",
               "status" => "error",
               "effect" => "unknown",
               "reason" => "timeout",
               "error" => "request timed out",
               "turn" => 1
             }
           ] = Projection.ledger_entries(entries)
  end

  test "root agentic tool wrapper records unknown side-effect attempt before dispatch" do
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
end
