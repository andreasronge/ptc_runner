defmodule PtcRunner.Kernel.CommandOutcome do
  @moduledoc """
  Sealed command result returned to frontends.

  It carries a validated V3 envelope and status. Frontends must call
  `to_map/1` at the rendering boundary so a mutated or caller-authored struct
  cannot be emitted. Outcomes never write a stream, raise through Mix, halt the
  VM, or exit the operating-system process.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DiagnosticCatalog

  @non_run_modes [
    :help,
    :version,
    :docs,
    :init,
    :validate,
    :doctor,
    {:doctor, :connect},
    :models,
    :unknown
  ]
  @success_modes [
    :help,
    :version,
    :docs,
    :init,
    :validate,
    :doctor,
    {:doctor, :connect},
    :models
  ]
  @static_modes [:help, :version, :docs, :init, :validate, :doctor, :models, :unknown]
  @exit_statuses [0, 2, 3, 4, 5, 6, 7, 70]
  @artifact_names ~w(trace inspection result)
  @unclassified_artifact_states ~w(not_requested not_written)
  @operation_order [
    :declaration,
    :selection,
    :local,
    :application,
    :credentials,
    :authorization,
    :connectivity,
    :acquisition,
    :execution,
    :cleanup
  ]
  @operation_rank @operation_order |> Enum.with_index() |> Map.new()

  @enforce_keys [:command_mode, :envelope, :exit_status, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type command_mode ::
          :help
          | :version
          | :docs
          | :init
          | :validate
          | :run
          | :doctor
          | {:doctor, :connect}
          | :models
          | :unknown
  @type t :: %__MODULE__{
          command_mode: command_mode(),
          envelope: map(),
          exit_status: 0 | 2 | 3 | 4 | 5 | 6 | 7 | 70,
          attestation: binary()
        }

  @spec error(command_mode(), binary(), CommandDiagnostic.t(), [CommandDiagnostic.t()]) :: t()
  def error(command, run_ref, diagnostic, secondary \\ [])

  def error(:run, run_ref, %CommandDiagnostic{} = diagnostic, secondary) do
    run_error(
      run_ref,
      diagnostic,
      Map.new(@artifact_names, &{&1, "not_requested"}),
      secondary
    )
  end

  def error(command_mode, run_ref, %CommandDiagnostic{} = diagnostic, secondary)
      when is_list(secondary) and length(secondary) <= 6 do
    if CommandRunRef.valid?(run_ref) and CommandDiagnostic.valid?(diagnostic) and
         command_mode in @non_run_modes and
         (command_mode == {:doctor, :connect} or secondary == []) and
         valid_mode_diagnostics?(command_mode, [diagnostic | secondary]) and
         valid_compound_diagnostics?(diagnostic, secondary) do
      seal(
        command_mode,
        error_envelope(command_mode, run_ref, diagnostic, secondary),
        diagnostic.exit_status
      )
    else
      raise ArgumentError, "invalid closed command outcome"
    end
  end

  @doc false
  @spec doctor_failure(
          :doctor | {:doctor, :connect},
          binary(),
          map(),
          CommandDiagnostic.t(),
          [CommandDiagnostic.t()]
        ) :: t()
  def doctor_failure(command_mode, run_ref, result, diagnostic, secondary \\ [])

  def doctor_failure(command_mode, run_ref, result, %CommandDiagnostic{} = diagnostic, secondary)
      when command_mode in [:doctor, {:doctor, :connect}] and is_map(result) and
             is_list(secondary) and length(secondary) <= 6 do
    rendered_primary = CommandDiagnostic.to_map(diagnostic)
    rendered_secondary = Enum.map(secondary, &CommandDiagnostic.to_map/1)

    if CommandRunRef.valid?(run_ref) and
         (command_mode == {:doctor, :connect} or secondary == []) and
         doctor_failure_mode_allowed?(command_mode, diagnostic) and
         valid_mode_diagnostics?(command_mode, [diagnostic | secondary]) and
         valid_compound_diagnostics?(diagnostic, secondary) and
         CommandContract.valid_doctor_failure_result?(
           result,
           rendered_primary,
           rendered_secondary,
           command_mode
         ) do
      envelope =
        command_mode
        |> error_envelope(run_ref, diagnostic, secondary)
        |> Map.put("result", result)

      seal(command_mode, envelope, diagnostic.exit_status)
    else
      raise ArgumentError, "invalid closed doctor failure outcome"
    end
  end

  def doctor_failure(_command_mode, _run_ref, _result, _diagnostic, _secondary),
    do: raise(ArgumentError, "invalid closed doctor failure outcome")

  @spec run_error(
          binary(),
          CommandDiagnostic.t(),
          %{required(binary()) => binary()},
          [CommandDiagnostic.t()]
        ) :: t()
  def run_error(run_ref, %CommandDiagnostic{} = diagnostic, artifact_state, secondary \\ [])
      when is_map(artifact_state) and is_list(secondary) and length(secondary) <= 6 do
    if CommandRunRef.valid?(run_ref) and CommandDiagnostic.valid?(diagnostic) and
         valid_unclassified_artifact_state?(artifact_state) and
         secondary == [] and
         valid_unclassified_diagnostics?([diagnostic | secondary]) and
         valid_compound_diagnostics?(diagnostic, secondary) do
      envelope =
        error_envelope(:run, run_ref, diagnostic, secondary)
        |> Map.merge(%{
          "artifact_state" => artifact_state,
          "artifact_class" => "unclassified",
          "execution" => %{"state" => "not_started"}
        })

      seal(:run, envelope, diagnostic.exit_status)
    else
      raise ArgumentError, "invalid closed command outcome"
    end
  end

  @doc false
  @spec run_success(binary(), :normal | :private, term(), map(), map(), map()) :: t()
  def run_success(run_ref, result_class, value, artifact_state, usage, evaluation_memory)
      when result_class in [:normal, :private] and is_map(artifact_state) and is_map(usage) and
             is_map(evaluation_memory) do
    result =
      case result_class do
        :normal -> %{"result_class" => "normal", "value" => value}
        :private -> %{"result_class" => "private"}
      end

    envelope = %{
      "schema_version" => 3,
      "command" => "run",
      "status" => "ok",
      "run_ref" => run_ref,
      "result" => result,
      "secondary_errors" => [],
      "artifact_state" => artifact_state,
      "artifact_class" => Atom.to_string(result_class),
      "execution" => %{
        "state" => "finished",
        "outcome" => "ok",
        "diagnostic" => nil,
        "usage" => usage,
        "evaluation_memory" => evaluation_memory,
        "last_evaluation_error" => nil
      }
    }

    seal(:run, envelope, 0)
  end

  @doc false
  @spec run_classified_error(
          binary(),
          :normal | :private,
          CommandDiagnostic.t(),
          [CommandDiagnostic.t()],
          map(),
          map()
        ) :: t()
  def run_classified_error(
        run_ref,
        result_class,
        %CommandDiagnostic{} = diagnostic,
        secondary,
        artifact_state,
        execution
      )
      when result_class in [:normal, :private] and is_list(secondary) and
             length(secondary) <= 6 and is_map(artifact_state) and is_map(execution) do
    if CommandRunRef.valid?(run_ref) and CommandDiagnostic.valid?(diagnostic) and
         Enum.all?(secondary, &CommandDiagnostic.valid?/1) and
         valid_mode_diagnostics?(:run, [diagnostic | secondary]) and
         valid_compound_diagnostics?(diagnostic, secondary) do
      envelope =
        error_envelope(:run, run_ref, diagnostic, secondary)
        |> Map.merge(%{
          "artifact_state" => artifact_state,
          "artifact_class" => Atom.to_string(result_class),
          "execution" => execution
        })

      seal(:run, envelope, diagnostic.exit_status)
    else
      raise ArgumentError, "invalid closed command outcome"
    end
  end

  @spec success(command_mode(), binary(), map()) :: t()
  def success(command_mode, run_ref, result) when is_map(result) do
    public_command = public_command(command_mode)

    if command_mode in @success_modes and CommandRunRef.valid?(run_ref) and
         CommandContract.valid_success_result?(public_command, result) do
      seal(
        command_mode,
        %{
          "schema_version" => 3,
          "command" => Atom.to_string(public_command),
          "status" => "ok",
          "run_ref" => run_ref,
          "result" => result
        },
        0
      )
    else
      raise ArgumentError, "invalid closed command outcome"
    end
  end

  def success(_command, _run_ref, _result),
    do: raise(ArgumentError, "invalid closed command outcome")

  @doc """
  Checks the complete sealed outcome, including its exact fields, V3 envelope,
  command mode, exit status, and in-VM construction attestation.
  """
  @spec valid?(term()) :: boolean()
  def valid?(
        %__MODULE__{
          command_mode: command_mode,
          envelope: envelope,
          exit_status: exit_status,
          attestation: attestation
        } = outcome
      ) do
    Enum.sort(Map.keys(outcome)) == @field_keys and
      valid_command_mode?(command_mode) and
      exit_status in @exit_statuses and
      CommandContract.valid_envelope?(envelope) and
      valid_envelope_mode?(command_mode, envelope, exit_status) and
      Attestation.valid?(__MODULE__, payload(outcome), attestation)
  end

  def valid?(_outcome), do: false

  @doc "Returns the validated V3 envelope for rendering."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = outcome) do
    if valid?(outcome),
      do: outcome.envelope,
      else: raise(ArgumentError, "invalid closed command outcome")
  end

  def to_map(_outcome), do: raise(ArgumentError, "invalid closed command outcome")

  defp error_envelope(command_mode, run_ref, diagnostic, secondary) do
    %{
      "schema_version" => 3,
      "command" => command_mode |> public_command() |> Atom.to_string(),
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(diagnostic),
      "secondary_errors" => Enum.map(secondary, &CommandDiagnostic.to_map/1)
    }
  end

  defp seal(command_mode, envelope, exit_status) do
    outcome = %__MODULE__{
      command_mode: command_mode,
      envelope: envelope,
      exit_status: exit_status,
      attestation: <<>>
    }

    sealed = %{outcome | attestation: Attestation.attest(__MODULE__, payload(outcome))}

    if valid?(sealed),
      do: sealed,
      else: raise(ArgumentError, "invalid closed command outcome")
  end

  defp payload(outcome), do: {outcome.command_mode, outcome.envelope, outcome.exit_status}

  defp public_command({:doctor, :connect}), do: :doctor
  defp public_command(command) when is_atom(command), do: command
  defp public_command(_command), do: nil

  defp valid_command_mode?(:run), do: true
  defp valid_command_mode?(mode), do: mode in @non_run_modes

  defp valid_mode_diagnostics?(mode, diagnostics) do
    Enum.all?(diagnostics, fn
      %CommandDiagnostic{} = diagnostic ->
        CommandDiagnostic.valid?(diagnostic) and
          CommandContract.diagnostic_allowed?(mode, diagnostic.phase, diagnostic.code) and
          valid_mode_activity?(mode, diagnostic.provider_activity)

      _invalid ->
        false
    end)
  end

  defp valid_mode_activity?(mode, false) when mode in @static_modes, do: true
  defp valid_mode_activity?(mode, _activity) when mode in @static_modes, do: false
  defp valid_mode_activity?({:doctor, :connect}, activity), do: is_boolean(activity)
  defp valid_mode_activity?(:run, activity), do: is_boolean(activity)

  defp valid_envelope_mode?(
         :run,
         %{
           "command" => "run",
           "status" => "ok",
           "run_ref" => run_ref,
           "result" => %{"result_class" => result_class},
           "artifact_class" => result_class,
           "secondary_errors" => []
         },
         0
       ),
       do: CommandRunRef.valid?(run_ref) and result_class in ["normal", "private"]

  defp valid_envelope_mode?(
         command_mode,
         %{
           "command" => "doctor",
           "status" => "error",
           "run_ref" => run_ref,
           "error" => primary,
           "secondary_errors" => secondary,
           "result" => result
         },
         exit_status
       )
       when command_mode in [:doctor, {:doctor, :connect}] and is_list(secondary) do
    CommandRunRef.valid?(run_ref) and
      doctor_failure_mode_allowed?(command_mode, primary) and
      valid_rendered_diagnostics?(command_mode, [primary | secondary]) and
      rendered_exit_status(primary) == exit_status and
      CommandContract.valid_doctor_failure_result?(result, primary, secondary, command_mode)
  end

  defp valid_envelope_mode?(
         command_mode,
         %{
           "command" => command,
           "status" => "ok",
           "run_ref" => run_ref,
           "result" => result
         },
         0
       ) do
    public_command = public_command(command_mode)

    command_mode in @success_modes and
      command == Atom.to_string(public_command) and
      CommandRunRef.valid?(run_ref) and
      CommandContract.valid_success_result?(public_command, result) and
      valid_success_mode?(command_mode, result)
  end

  defp valid_envelope_mode?(
         command_mode,
         %{
           "command" => command,
           "status" => "error",
           "run_ref" => run_ref,
           "error" => primary,
           "secondary_errors" => secondary
         },
         exit_status
       )
       when is_list(secondary) do
    command == command_mode |> public_command() |> Atom.to_string() and
      CommandRunRef.valid?(run_ref) and
      valid_rendered_diagnostics?(command_mode, [primary | secondary]) and
      rendered_exit_status(primary) == exit_status
  end

  defp valid_envelope_mode?(_command_mode, _envelope, _exit_status), do: false

  defp doctor_failure_mode_allowed?(:doctor, %CommandDiagnostic{phase: :application}), do: true

  defp doctor_failure_mode_allowed?(:doctor, %CommandDiagnostic{phase: :local_preflight}),
    do: true

  defp doctor_failure_mode_allowed?(:doctor, %{"phase" => "application"}), do: true
  defp doctor_failure_mode_allowed?(:doctor, %{"phase" => "local_preflight"}), do: true
  defp doctor_failure_mode_allowed?({:doctor, :connect}, _diagnostic), do: true
  defp doctor_failure_mode_allowed?(_command_mode, _diagnostic), do: false

  defp valid_rendered_diagnostics?(command_mode, diagnostics) do
    Enum.all?(diagnostics, fn diagnostic ->
      with %{"phase" => phase, "code" => code, "provider_activity" => activity} <- diagnostic,
           %{phase: catalog_phase, code: catalog_code} <-
             Enum.find(
               DiagnosticCatalog.rows(),
               &(Atom.to_string(&1.phase) == phase and Atom.to_string(&1.code) == code)
             ) do
        CommandContract.diagnostic_allowed?(command_mode, catalog_phase, catalog_code) and
          valid_mode_activity?(command_mode, activity)
      else
        _invalid -> false
      end
    end)
  end

  defp rendered_exit_status(%{"phase" => phase, "code" => code}) do
    case Enum.find(
           DiagnosticCatalog.rows(),
           &(Atom.to_string(&1.phase) == phase and Atom.to_string(&1.code) == code)
         ) do
      %{exit_status: exit_status} -> exit_status
      nil -> nil
    end
  end

  defp rendered_exit_status(_diagnostic), do: nil

  defp valid_success_mode?(:doctor, %{
         "checks" => checks,
         "provider_activity" => false,
         "readiness" => "unverified"
       }),
       do: valid_doctor_checks?(:default, checks)

  defp valid_success_mode?({:doctor, :connect}, %{
         "checks" => checks,
         "provider_activity" => provider_activity,
         "readiness" => "ready"
       }),
       do: is_boolean(provider_activity) and valid_doctor_checks?(:connect, checks)

  defp valid_success_mode?(mode, _result) when mode in [:doctor, {:doctor, :connect}], do: false
  defp valid_success_mode?(mode, _result) when mode in @success_modes, do: true

  defp valid_doctor_checks?(mode, [_runtime, application, _viewer | provider_checks]) do
    case doctor_application_state(mode, application) do
      {:ok, application_state} ->
        provider_groups_match_application?(provider_checks, application_state) and
          Enum.all?(
            provider_checks,
            &valid_doctor_provider_check?(mode, application_state, &1)
          )

      :error ->
        false
    end
  end

  defp valid_doctor_checks?(_mode, _checks), do: false

  defp provider_groups_match_application?(checks, :present) do
    checks
    |> Enum.chunk_by(&provider_alias/1)
    |> Enum.all?(&Enum.any?(&1, fn check -> provider_operation(check) == "selection" end))
  end

  defp provider_groups_match_application?(_checks, :absent), do: true

  defp provider_alias(%{"name" => "provider/" <> name}) do
    name |> String.split("/") |> List.first()
  end

  defp provider_alias(_check), do: nil

  defp provider_operation(%{"name" => "provider/" <> name}) do
    name |> String.split("/") |> List.last()
  end

  defp provider_operation(_check), do: nil

  defp doctor_application_state(:default, %{
         "name" => "application",
         "status" => "pass",
         "code" => "valid"
       }),
       do: {:ok, :present}

  defp doctor_application_state(:default, %{
         "name" => "application",
         "status" => "skipped",
         "code" => "not_requested"
       }),
       do: {:ok, :absent}

  defp doctor_application_state(:connect, %{
         "name" => "application",
         "status" => "pass",
         "code" => "valid"
       }),
       do: {:ok, :present}

  defp doctor_application_state(_mode, _check), do: :error

  defp valid_doctor_provider_check?(mode, application_state, %{
         "name" => "provider/" <> name,
         "status" => status,
         "code" => code
       }) do
    operation = name |> String.split("/") |> List.last()

    case {mode, application_state, operation, status, code} do
      {:default, :absent, "local", "skipped", "application_required"} ->
        true

      {:default, :absent, operation, "skipped", "requires_connect"}
      when operation in ["credentials", "authorization", "connectivity"] ->
        true

      {:default, :present, "local", "pass", "available"} ->
        true

      {:default, :present, "local", "skipped", "active_check_required"} ->
        true

      {:default, :present, "selection", "pass", "declarative"} ->
        true

      {:default, :present, "selection", "skipped", "active_check_required"} ->
        true

      {:default, :present, operation, "skipped", "requires_connect"}
      when operation in ["credentials", "authorization", "connectivity"] ->
        true

      {:connect, :present, "local", "pass", "available"} ->
        true

      {:connect, :present, "selection", "pass", code}
      when code in ["declarative", "available"] ->
        true

      {:connect, :present, operation, "pass", "available"}
      when operation in ["credentials", "authorization", "connectivity"] ->
        true

      _other ->
        false
    end
  end

  defp valid_doctor_provider_check?(_mode, _application_state, _check), do: false

  defp valid_unclassified_artifact_state?(artifact_state) do
    map_size(artifact_state) == length(@artifact_names) and
      Enum.all?(@artifact_names, fn name ->
        Map.get(artifact_state, name) in @unclassified_artifact_states
      end)
  end

  defp valid_unclassified_diagnostics?(diagnostics),
    do:
      Enum.all?(
        diagnostics,
        &(CommandContract.diagnostic_allowed?(:run_unclassified, &1.phase, &1.code) and
            &1.provider_activity == false)
      )

  @doc false
  @spec valid_compound_diagnostics?(CommandDiagnostic.t(), [CommandDiagnostic.t()]) :: boolean()
  def valid_compound_diagnostics?(_primary, []), do: true

  def valid_compound_diagnostics?(primary, secondary) do
    diagnostics = [primary | secondary]
    identities = Enum.map(diagnostics, &diagnostic_identity/1)

    Enum.all?(secondary, &CommandDiagnostic.valid?/1) and
      identities == Enum.uniq(identities) and
      unique_compound_categories?(diagnostics) and
      ordered_by_precedence?(diagnostics)
  end

  defp unique_compound_categories?(diagnostics) do
    categories =
      Enum.map(diagnostics, fn diagnostic ->
        DiagnosticCatalog.compound_category(diagnostic.phase, diagnostic.code)
      end)

    Enum.all?(categories, &is_atom/1) and categories == Enum.uniq(categories)
  end

  defp ordered_by_precedence?(diagnostics) do
    keys = Enum.map(diagnostics, &precedence_key/1)
    Enum.all?(keys, &match?({:ok, _key}, &1)) and keys == Enum.sort(keys)
  end

  defp precedence_key(%CommandDiagnostic{} = diagnostic) do
    with {:ok, catalog_key} <-
           DiagnosticCatalog.compound_precedence(diagnostic.phase, diagnostic.code) do
      {:ok, {catalog_key, subject_order(diagnostic.subject)}}
    end
  end

  defp diagnostic_identity(%CommandDiagnostic{} = diagnostic),
    do: {diagnostic.phase, diagnostic.code, canonical_subject(diagnostic.subject)}

  defp canonical_subject(nil), do: nil
  defp canonical_subject(%CommandSubject{} = subject), do: CommandSubject.to_map(subject)

  defp subject_order(nil), do: {0, "", 0, 0, 0}

  defp subject_order(%CommandSubject{} = subject) do
    {destination, index} =
      case subject.occurrence do
        %{destination: :workflow, index: index} -> {0, index}
        %{destination: :mission, index: index} -> {1, index}
        nil -> {0, 0}
      end

    {1, subject.name, destination, index, Map.fetch!(@operation_rank, subject.operation)}
  end
end
