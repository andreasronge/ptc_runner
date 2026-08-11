defmodule PtcRunner.Kernel.OwnerFailureTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.OwnerFailure

  test "conservative evidence preserves valid values and treats invalid values as active" do
    for provider_activity <- [false, true] do
      failure = OwnerFailure.new!(:execution_session_unavailable, provider_activity, :not_started)

      assert {:execution_session_unavailable, ^provider_activity, :not_started} =
               OwnerFailure.evidence_or_unknown(failure, :internal_error, :incomplete)
    end

    failure = OwnerFailure.new!(:execution_session_unavailable, false, :not_started)
    forged = %{failure | provider_activity: true}

    assert {:internal_error, true, :incomplete} =
             OwnerFailure.evidence_or_unknown(forged, :internal_error, :incomplete)
  end
end
