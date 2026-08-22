defmodule PtcRunner.Kernel.ReplLimitProfileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ReplLimitProfile

  test "the direct interactive profile widens only session lifetime and retained events" do
    ordinary = Limits.defaults()
    installed = Limits.installed_defaults()
    direct = ReplLimitProfile.direct_interactive()

    assert {:ok, run_duration} = LimitCatalog.fetch(:run_duration_ms)
    assert {:ok, evaluations} = LimitCatalog.fetch(:subordinate_evaluations)
    assert direct.run_duration_ms == run_duration.maximum
    assert direct.subordinate_evaluations == evaluations.maximum

    assert direct.normal_event_count == installed.normal_event_count
    assert direct.normal_event_bytes == installed.normal_event_bytes

    assert Map.drop(Map.from_struct(direct), [
             :run_duration_ms,
             :subordinate_evaluations,
             :normal_event_count,
             :normal_event_bytes
           ]) ==
             Map.drop(Map.from_struct(ordinary), [
               :run_duration_ms,
               :subordinate_evaluations,
               :normal_event_count,
               :normal_event_bytes
             ])
  end
end
