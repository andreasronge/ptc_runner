defmodule PtcRunner.Kernel.CommandDoctorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandDoctor
  alias PtcRunner.Kernel.OwnerFailure

  test "connect failures preserve sealed owner activity evidence" do
    for provider_activity <- [false, true] do
      failure = OwnerFailure.new!(:execution_session_unavailable, provider_activity, :incomplete)
      diagnostic = CommandDoctor.connect_failure_diagnostic(failure)

      assert diagnostic.phase == :internal
      assert diagnostic.code == :internal_error
      assert diagnostic.provider_activity == provider_activity
    end
  end

  test "connect failures classify invalid owner evidence conservatively" do
    failure = OwnerFailure.new!(:execution_session_unavailable, true, :incomplete)
    forged = %{failure | provider_activity: false}

    assert CommandDoctor.connect_failure_diagnostic(forged).provider_activity
    assert CommandDoctor.connect_failure_diagnostic(:invalid_owner_failure).provider_activity
  end
end
