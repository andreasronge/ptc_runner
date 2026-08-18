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

  test "doctor usage semantics reject a fabricated or misattributed account" do
    diagnostic = credential_diagnostic(true)
    primary = CommandDiagnostic.to_map(diagnostic)

    # One alias selected at two destinations, where only one probe came back
    # with tokens: the row that carries a measurement and an unmeasured call at
    # once, so its cost is deliberately incomplete.
    measured = %{
      "alias" => "model",
      "installation_revision" => "model-v1",
      "calls" => 2,
      "successful_calls" => 2,
      "usage_calls" => 1,
      "missing_usage_calls" => 1,
      "usage" => %{"input" => 12}
    }

    selected = %{
      "alias" => "model",
      "source" => "llm",
      "installation_revision" => "model-v1",
      "default" => true,
      "selected" => true
    }

    valid =
      failure_result(true)
      |> Map.put("model_aliases", [selected])
      |> put_in(["usage"], %{"llm_usage_state" => "available", "llm_usage" => [measured]})

    assert CommandContract.valid_doctor_failure_result?(valid, primary, [])

    tampered = [
      # Spend attributed to a declaration the same report does not list.
      put_in(valid, ["usage", "llm_usage", Access.at(0), "alias"], "other"),
      put_in(valid, ["usage", "llm_usage", Access.at(0), "installation_revision"], "other-v1"),
      put_in(valid, ["model_aliases", Access.at(0), "selected"], false)
      |> put_in(["model_aliases", Access.at(0), "default"], nil),
      # Counters that no measurement could have produced.
      put_in(valid, ["usage", "llm_usage", Access.at(0), "calls"], 0),
      put_in(valid, ["usage", "llm_usage", Access.at(0), "successful_calls"], 1),
      put_in(valid, ["usage", "llm_usage", Access.at(0), "usage_calls"], 0),
      put_in(valid, ["usage", "llm_usage", Access.at(0), "missing_usage_calls"], 0),
      # Tokens summed from calls that reported none.
      valid
      |> put_in(["usage", "llm_usage", Access.at(0), "usage_calls"], 0)
      |> put_in(["usage", "llm_usage", Access.at(0), "missing_usage_calls"], 2),
      # A call that reported no tokens cannot leave a complete cost behind.
      put_in(valid, ["usage", "llm_usage", Access.at(0), "usage"], %{"total_cost" => 3.0e-6})
    ]

    for result <- tampered do
      refute CommandContract.valid_doctor_failure_result?(result, primary, [])
    end
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
      "readiness" => "failed",
      "usage" => failure_usage(provider_activity)
    }
  end

  # A failure that activated a provider may have been billed for work no result
  # accounts for; one that activated none spent nothing.
  defp failure_usage(true), do: %{"llm_usage_state" => "unavailable", "llm_usage" => nil}
  defp failure_usage(false), do: %{"llm_usage_state" => "available", "llm_usage" => []}
end
