defmodule PtcRunner.Kernel.CommandDoctorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDoctor
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.OwnerFailure

  @run_ref CommandRunRef.encode(<<0::128>>)

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

  test "a doctor failure outcome correlates its diagnostic and failed row" do
    diagnostic = credential_diagnostic(false)
    result = failure_result(false)

    outcome = CommandOutcome.doctor_failure({:doctor, :connect}, @run_ref, result, diagnostic)

    assert outcome.exit_status == 4
    assert outcome.envelope["status"] == "error"
    assert outcome.envelope["result"] == result
    assert CommandOutcome.valid?(outcome)
    assert CommandContract.valid_envelope?(outcome.envelope)

    assert CommandRenderer.render(outcome) ==
             {:stdout, Jason.encode!(result) <> "\n"}
  end

  test "default doctor rejects an enriched provider failure" do
    {:ok, subject} =
      CommandSubject.provider("model", :local, %{destination: :workflow, index: 0})

    diagnostic =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable,
        subject: subject,
        provider_activity: false
      )

    result =
      failure_result(false)
      |> put_in(["checks", Access.at(3)], %{
        "name" => "provider/model/local",
        "status" => "fail",
        "code" => "adapter_unavailable"
      })
      |> put_in(["checks", Access.at(5)], %{
        "name" => "provider/model/credentials",
        "status" => "skipped",
        "code" => "not_verified_due_to_failure"
      })

    assert CommandContract.valid_doctor_failure_result?(
             result,
             CommandDiagnostic.to_map(diagnostic),
             []
           )

    assert_raise ArgumentError, fn ->
      CommandOutcome.doctor_failure(:doctor, @run_ref, result, diagnostic)
    end
  end

  test "doctor failure result semantics reject every diagnostic correlation mismatch" do
    diagnostic = credential_diagnostic(false)
    primary = CommandDiagnostic.to_map(diagnostic)
    valid = failure_result(false)

    extra_failure = %{
      "name" => "provider/model/connectivity",
      "status" => "fail",
      "code" => "connectivity_unavailable"
    }

    tampered = [
      %{valid | "readiness" => "ready"},
      %{valid | "provider_activity" => true},
      put_in(valid, ["checks", Access.at(5), "code"], "authorization_required"),
      put_in(valid, ["checks", Access.at(5), "name"], "provider/other/credentials"),
      update_in(valid, ["checks"], &(&1 ++ [extra_failure]))
    ]

    for result <- tampered do
      refute CommandContract.valid_doctor_failure_result?(result, primary, [])

      assert_raise ArgumentError, fn ->
        CommandOutcome.doctor_failure({:doctor, :connect}, @run_ref, result, diagnostic)
      end
    end
  end

  test "a failed doctor result cannot validate as a success envelope" do
    envelope = %{
      "schema_version" => 2,
      "command" => "doctor",
      "status" => "ok",
      "run_ref" => @run_ref,
      "result" => failure_result(false)
    }

    refute CommandContract.valid_envelope?(envelope)
  end

  test "the published failure schema rejects an unattributable primary diagnostic" do
    diagnostic = credential_diagnostic(false)

    outcome =
      CommandOutcome.doctor_failure(
        {:doctor, :connect},
        @run_ref,
        failure_result(false),
        diagnostic
      )

    timeout =
      CommandDiagnostic.new!(:active_preflight, :connectivity_timeout, provider_activity: false)

    envelope = %{outcome.envelope | "error" => CommandDiagnostic.to_map(timeout)}
    {:ok, root} = JSV.build(CommandContract.schema(), atoms: false, warnings: :silent)

    assert {:error, _reason} = JSV.validate(envelope, root, cast: false)
  end

  test "doctor failure activity is the union of retained diagnostics" do
    primary = credential_diagnostic(false) |> CommandDiagnostic.to_map()
    secondary = credential_diagnostic(true) |> CommandDiagnostic.to_map()

    assert CommandContract.valid_doctor_failure_result?(
             failure_result(true),
             primary,
             [secondary]
           )

    refute CommandContract.valid_doctor_failure_result?(
             failure_result(false),
             primary,
             [secondary]
           )
  end

  defp credential_diagnostic(provider_activity) do
    {:ok, subject} = CommandSubject.provider("model", :credentials)

    CommandDiagnostic.new!(:active_preflight, :credential_unavailable,
      subject: subject,
      provider_activity: provider_activity
    )
  end

  defp failure_result(provider_activity) do
    %{
      "checks" => [
        %{"name" => "runtime", "status" => "pass", "code" => "supported"},
        %{"name" => "application", "status" => "pass", "code" => "valid"},
        %{"name" => "viewer", "status" => "pass", "code" => "available"},
        %{"name" => "provider/model/local", "status" => "pass", "code" => "available"},
        %{
          "name" => "provider/model/selection",
          "status" => "pass",
          "code" => "declarative"
        },
        %{
          "name" => "provider/model/credentials",
          "status" => "fail",
          "code" => "credential_unavailable"
        },
        %{
          "name" => "provider/model/connectivity",
          "status" => "skipped",
          "code" => "not_verified_due_to_failure"
        }
      ],
      "model_aliases" => [],
      "provider_activity" => provider_activity,
      "readiness" => "failed"
    }
  end
end
