defmodule PtcRunner.Kernel.PreSinkFailureCauseTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  import PtcRunner.TestSupport.CommandEngineFixtures

  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDoctor
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandProjectDiagnostic
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.OwnerFailure

  @run_ref CommandRunRef.encode(<<0::128>>)

  @tag :tmp_dir
  test "run and doctor connect preserve unknown environment callback causes", %{tmp_dir: dir} do
    host = write_host_config(dir, "environment", env_credential_host())
    application = doctor_application(dir, "environment", workflow: ["model"])

    for {callback, cause} <- [
          {fn -> {:error, :eio} end, "filesystem_error"},
          {fn -> {:error, :eacces} end, "permission"},
          {fn -> raise ArgumentError, "private exception message" end, "unexpected_exception"},
          {fn -> throw({:private, dir}) end, "unexpected_exception"},
          {fn -> {:error, {:private, dir}} end, "unexpected_exception"}
        ],
        argv <- [
          ["run", application, "--host-config", host],
          ["doctor", application, "--host-config", host, "--connect"]
        ] do
      {:ok, runtime} = CommandRuntime.new(environment_setup: callback)
      assert {:error, outcome} = CommandEngine.dispatch(argv, runtime)
      assert_public_cause(outcome, "internal_error", cause, dir)
      refute outcome.envelope["error"]["provider_activity"]
    end
  end

  @tag :tmp_dir
  test "a named document read failure carries a filesystem cause", %{tmp_dir: dir} do
    assert {:error, outcome} =
             CommandEngine.dispatch(["validate", Path.join(dir, "missing.json")])

    assert_public_cause(outcome, "application_not_found", "filesystem_error", dir)
  end

  @tag :tmp_dir
  test "an unreadable document is not retried as an application", %{tmp_dir: dir} do
    path = Path.join(dir, "unreadable.json")
    File.write!(path, <<255>>)
    assert {:error, outcome} = CommandEngine.dispatch(["validate", path])
    assert_public_cause(outcome, "application_unavailable", "invalid_configuration", dir)
  end

  @tag :tmp_dir
  test "doctor local service construction retains configuration causes", %{tmp_dir: dir} do
    host = write_host_config(dir, "local", valid_host_config())
    {:ok, arguments} = CommandParser.parse(["doctor", "--host-config", host])
    runtime = %{CommandRuntime.standalone() | provider_application_mode: :invalid}
    assert {:error, outcome} = CommandDoctor.dispatch(arguments, @run_ref, runtime)
    assert_public_cause(outcome, "internal_error", "invalid_configuration", dir)
  end

  test "schema worker unavailability survives project command projection" do
    for reason <- [:timeout, :cancelled, :heap_exceeded, :worker_failed] do
      diagnostic = CommandProjectDiagnostic.project({:schema_validation_unavailable, reason})
      outcome = CommandOutcome.error(:validate, @run_ref, diagnostic)

      assert_public_cause(
        outcome,
        "schema_validation_unavailable",
        "resource_unavailable",
        "private"
      )
    end
  end

  test "provider admission and owner failures survive run outcome projection" do
    for {reason, cause} <- [
          {:invalid_provider_execution, "invalid_configuration"},
          {:execution_session_unavailable, "resource_unavailable"},
          {{:private, "private payload"}, "unexpected_exception"}
        ] do
      assert {:error, outcome} =
               CommandRunOutcome.operation_failure(
                 @run_ref,
                 reason,
                 :normal,
                 CommandDestination.requested_artifact_state(%{}),
                 false,
                 :not_started
               )

      assert_public_cause(outcome, "internal_error", cause, "private payload")
    end
  end

  test "doctor owner settlement preserves causes and activity" do
    for activity <- [false, true] do
      failure = OwnerFailure.new!(:execution_session_unavailable, activity, :incomplete)
      diagnostic = CommandDoctor.connect_failure_diagnostic(failure)
      outcome = CommandOutcome.error({:doctor, :connect}, @run_ref, diagnostic)
      assert_public_cause(outcome, "internal_error", "resource_unavailable", "private")
      assert outcome.envelope["error"]["provider_activity"] == activity
    end
  end

  defp assert_public_cause(outcome, code, cause, private) do
    assert outcome.exit_status != 0
    assert outcome.envelope["schema_version"] == 5
    assert outcome.envelope["error"]["code"] == code
    assert outcome.envelope["error"]["cause"] == cause
    assert_schema_valid(outcome.envelope)
    encoded = Jason.encode!(outcome.envelope)
    refute encoded =~ private
    refute encoded =~ "ArgumentError"
    refute encoded =~ "stacktrace"
  end
end
