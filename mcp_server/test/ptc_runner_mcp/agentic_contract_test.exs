defmodule PtcRunnerMcp.AgenticContractTest do
  use ExUnit.Case, async: true

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
end
