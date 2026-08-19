defmodule PtcRunner.Kernel.CommandContract do
  @moduledoc """
  Generated-in-source JSON Schema for the V2 command envelope.

  The checked-in JSON artifact is produced from this module. Diagnostic
  phase/code/retryability/message rows come only from `DiagnosticCatalog`.

  Envelope validation compiles that schema once per VM and reuses the JSV
  root. `schema/0` still materializes the source map for generators and docs.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ContractSchemaDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.DocumentationLibrary
  alias PtcRunner.Kernel.ExampleLibrary
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic

  @id "https://ptc-runner.dev/schemas/ptc-command-envelope-v2.schema.json"
  @envelope_root_key {__MODULE__, :envelope_root}
  @non_run_schema_modes [
    {"help", :help, false, false},
    {"version", :version, false, false},
    {"docs", :docs, false, false},
    {"init", :init, false, false},
    {"validate", :validate, false, false},
    {"doctor", {:doctor, :connect}, :catalog, true},
    {"models", :models, false, false},
    {"unknown", :unknown, false, false}
  ]
  @run_ref "^cmd-[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$(?![\\s\\S])"
  @hash "^[0-9a-f]{64}$(?![\\s\\S])"
  @digest "^sha256:[0-9a-f]{64}$(?![\\s\\S])"
  @alias "^[a-z][a-z0-9._-]{0,127}$(?![\\s\\S])"
  @installation_revision ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @capability_name "^(?:workflow|mission)/[a-z][a-z0-9._/-]{0,127}$(?![\\s\\S])"
  @event_type "^[a-z][a-z0-9-]{0,127}$(?![\\s\\S])"
  @json_pointer "^(?:/(?:[^~/]|~[01])*)*$(?![\\s\\S])"
  @doctor_provider_name ~r/\Aprovider\/(?<alias>[a-z][a-z0-9._-]{0,127})\/(?<operation>local|selection|credentials|authorization|connectivity)\z/
  @artifact_states ~w(not_requested not_written written recovery_written finalization_uncertain failed)
  @recovery_artifact_states ~w(recovery_written finalization_uncertain)
  @recovery_written_publication_codes [
    :trace_publication_failed,
    :inspection_publication_failed,
    :result_publication_failed,
    :destination_collision
  ]
  @finalization_uncertain_publication_codes [:result_publication_failed]
  @unclassified_run_phases [
    :arguments,
    :host,
    :application,
    :bundle,
    :provider_declaration,
    :destination,
    :internal
  ]
  @preclassification_only_phases @unclassified_run_phases -- [:internal]

  @codes_by_phase DiagnosticCatalog.rows()
                  |> Enum.group_by(& &1.phase, & &1.code)
  @host_codes Map.fetch!(@codes_by_phase, :host)
  @application_codes Map.fetch!(@codes_by_phase, :application)
  @static_application_codes @application_codes -- [:override_invalid, :event_identity_conflict]
  @bundle_codes Map.fetch!(@codes_by_phase, :bundle)
  @provider_declaration_codes Map.fetch!(@codes_by_phase, :provider_declaration)
  @destination_codes Map.fetch!(@codes_by_phase, :destination)
  @local_preflight_codes Map.fetch!(@codes_by_phase, :local_preflight)
  @active_preflight_codes Map.fetch!(@codes_by_phase, :active_preflight)
  @doctor_provider_acquisition_codes DiagnosticCatalog.doctor_attributable_rows()
                                     |> Enum.filter(&(&1.phase == :provider_acquisition))
                                     |> Enum.map(& &1.code)
  @result_cleanup_codes Map.fetch!(@codes_by_phase, :result_cleanup)
  @provider_cleanup_codes @result_cleanup_codes --
                            [:result_invalid, :result_contract_failed, :result_limit_exceeded]
  @doctor_failure_codes_by_operation DiagnosticCatalog.doctor_failure_codes_by_operation()
                                     |> Map.new(fn {operation, codes} ->
                                       {Atom.to_string(operation),
                                        Enum.map(codes, &Atom.to_string/1)}
                                     end)
  @doctor_application_failure_codes DiagnosticCatalog.doctor_application_rows()
                                    |> Enum.map(& &1.code)
                                    |> Enum.map(&Atom.to_string/1)
  @version Mix.Project.config() |> Keyword.fetch!(:version)
  @doctor_notice "doctor --connect may perform one or more real provider requests and may incur provider cost"
  @spec schema() :: map()
  def schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => @id,
      "title" => "PtcRunner command envelope V2",
      "oneOf" =>
        Enum.map(@non_run_schema_modes, fn {command, mode, provider_activity, compound?} ->
          error_envelope(command, diagnostic_rows(mode), provider_activity, compound?)
        end) ++
          [
            doctor_failure_envelope(),
            run_error_envelope(
              "unclassified",
              ~w(not_requested not_written),
              closed(~w(state), %{"state" => %{"const" => "not_started"}}),
              "unclassified_diagnostic",
              %{"const" => []}
            ),
            run_error_envelope(
              ~w(normal private),
              @artifact_states -- @recovery_artifact_states,
              execution_schema(),
              "classified_diagnostic"
            ),
            run_recovery_error_envelope(
              "recovery_written",
              "recovery_written_diagnostic"
            ),
            run_recovery_error_envelope(
              "finalization_uncertain",
              "finalization_uncertain_diagnostic"
            ),
            success_envelope("help", help_result_schema()),
            success_envelope("version", version_result_schema()),
            success_envelope("docs", docs_result_schema()),
            success_envelope("init", init_result()),
            success_envelope("validate", validate_result()),
            run_success_envelope(
              "normal",
              closed(~w(result_class value), %{
                "result_class" => %{"const" => "normal"},
                "value" => %{}
              })
            ),
            run_success_envelope(
              "private",
              closed(~w(result_class), %{"result_class" => %{"const" => "private"}})
            ),
            success_envelope("doctor", doctor_success_result()),
            success_envelope("models", models_result())
          ],
      "$defs" => %{
        "unclassified_diagnostic" =>
          diagnostic_schema(
            diagnostic_rows(:run_unclassified),
            false
          ),
        "classified_diagnostic" =>
          diagnostic_schema(
            Enum.reject(
              DiagnosticCatalog.rows(),
              &(&1.phase in @preclassification_only_phases)
            )
          ),
        "recovery_written_diagnostic" =>
          recovery_diagnostic_schema(@recovery_written_publication_codes),
        "finalization_uncertain_diagnostic" =>
          recovery_diagnostic_schema(@finalization_uncertain_publication_codes),
        "execution_diagnostic" =>
          diagnostic_schema(Enum.filter(DiagnosticCatalog.rows(), &(&1.phase == :execution))),
        "usage" => usage_schema(),
        "evaluation_memory" => evaluation_memory_schema()
      }
    }
  end

  # The published envelope refs only the per-branch diagnostic definitions. This
  # union over every catalog row is deliberately not part of the contract: it
  # exists so callers can assert that each row renders to something the
  # generated constants admit, without publishing a definition no branch admits.
  @doc false
  @spec catalog_diagnostic_schema() :: map()
  def catalog_diagnostic_schema, do: diagnostic_schema()

  @doc false
  @spec unclassified_diagnostic_phase?(atom()) :: boolean()
  def unclassified_diagnostic_phase?(phase), do: phase in @unclassified_run_phases

  @doc false
  @spec diagnostic_allowed?(term(), atom(), atom()) :: boolean()
  def diagnostic_allowed?(mode, phase, code) do
    Enum.any?(diagnostic_rows(mode), &(&1.phase == phase and &1.code == code))
  end

  @doc false
  @spec envelope_schema_root() :: {:ok, term()} | {:error, term()}
  def envelope_schema_root, do: compiled_jsv_root(@envelope_root_key, &schema/0)

  @doc false
  @spec valid_envelope?(term()) :: boolean()
  def valid_envelope?(envelope) do
    with true <- JSONValue.value?(envelope),
         {:ok, root} <- envelope_schema_root(),
         {:ok, _validated} <- JSV.validate(envelope, root, cast: false),
         true <- valid_envelope_semantics?(envelope) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  defp valid_envelope_semantics?(%{
         "command" => "doctor",
         "status" => "error",
         "error" => primary,
         "secondary_errors" => secondary,
         "result" => result
       }),
       do: valid_doctor_failure_result?(result, primary, secondary)

  defp valid_envelope_semantics?(%{
         "command" => "doctor",
         "status" => "ok",
         "result" => result
       }),
       do: valid_success_semantics?(:doctor, result)

  defp valid_envelope_semantics?(_envelope), do: true

  @doc false
  @spec valid_success_result?(atom(), term()) :: boolean()
  def valid_success_result?(command, result)
      when command in [:help, :version, :docs, :init, :validate, :doctor, :models] do
    with true <- JSONValue.value?(result),
         {:ok, root} <-
           compiled_jsv_root({__MODULE__, :success_root, command}, fn ->
             success_result_schema(command)
           end),
         {:ok, _validated} <- JSV.validate(result, root, cast: false),
         true <- valid_success_semantics?(command, result) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  def valid_success_result?(_command, _result), do: false

  @doc """
  Validates deterministic success-result ordering not fully expressible in JSON Schema.

  Callers that consume the generated schema must apply this predicate after
  ordinary schema validation for `doctor` and `models` results.
  """
  @spec valid_success_semantics?(atom(), term()) :: boolean()
  def valid_success_semantics?(
        :doctor,
        %{
          "checks" => checks,
          "model_aliases" => model_aliases,
          "provider_activity" => provider_activity,
          "readiness" => readiness,
          "usage" => usage
        }
      ) do
    case checks do
      [
        %{"name" => "runtime"},
        %{"name" => "application"} = application_check,
        %{"name" => "viewer"}
        | provider_checks
      ] ->
        keys = Enum.map(provider_checks, &doctor_provider_key/1)

        common =
          model_aliases_valid?(model_aliases) and
            doctor_usage_valid?(usage, provider_activity, model_aliases) and
            Enum.all?(keys, &is_tuple/1) and
            keys == Enum.sort(keys) and
            keys == Enum.uniq(keys) and
            provider_groups_start_with_local?(keys) and
            provider_groups_match_application?(keys, application_check)

        common and
          case readiness do
            "unverified" ->
              doctor_mode_consistent?(
                :default,
                application_check,
                provider_checks,
                provider_activity
              )

            "ready" ->
              doctor_mode_consistent?(
                :connect,
                application_check,
                provider_checks,
                provider_activity
              )

            _other ->
              false
          end

      _invalid ->
        false
    end
  end

  def valid_success_semantics?(:models, %{"installations" => installations}) do
    aliases = Enum.map(installations, &Map.fetch!(&1, "alias"))

    aliases == Enum.sort(aliases) and aliases == Enum.uniq(aliases) and
      Enum.all?(installations, fn installation ->
        valid_installation_revision?(installation["installation_revision"]) and
          ordered_subset?(installation["accepts_data"], ~w(normal private_inspection)) and
          ordered_subset?(installation["destinations"], ~w(workflow mission))
      end)
  end

  def valid_success_semantics?(command, _result)
      when command in [:help, :version, :docs, :init, :validate],
      do: true

  def valid_success_semantics?(_command, _result), do: false

  @doc false
  @spec valid_doctor_failure_result?(term(), term(), term()) :: boolean()
  def valid_doctor_failure_result?(result, primary, secondary)
      when is_map(result) and is_map(primary) and is_list(secondary) do
    with true <- valid_doctor_result_shape?(result),
         %{
           "checks" => checks,
           "model_aliases" => model_aliases,
           "provider_activity" => provider_activity,
           "readiness" => "failed",
           "usage" => usage
         } <- result,
         [
           %{"name" => "runtime"},
           %{"name" => "application"} = application_check,
           %{"name" => "viewer"}
           | provider_checks
         ] <- checks,
         keys = Enum.map(provider_checks, &doctor_provider_key/1),
         true <- model_aliases_valid?(model_aliases),
         true <- doctor_usage_valid?(usage, provider_activity, model_aliases),
         true <- Enum.all?(keys, &is_tuple/1),
         true <- keys == Enum.sort(keys) and keys == Enum.uniq(keys),
         true <- provider_groups_start_with_local?(keys),
         true <- provider_groups_match_application?(keys, application_check),
         true <-
           doctor_failure_checks_consistent?(
             application_check,
             provider_checks,
             model_aliases,
             primary,
             secondary
           ),
         true <- provider_activity == diagnostic_activity([primary | secondary]) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  def valid_doctor_failure_result?(_result, _primary, _secondary), do: false

  @doc false
  @spec valid_doctor_failure_result?(
          term(),
          term(),
          term(),
          :doctor | {:doctor, :connect}
        ) :: boolean()
  def valid_doctor_failure_result?(result, primary, secondary, command_mode)
      when command_mode in [:doctor, {:doctor, :connect}] do
    valid_doctor_failure_result?(result, primary, secondary) and
      doctor_failure_mode_consistent?(result, primary, secondary, command_mode)
  end

  def valid_doctor_failure_result?(_result, _primary, _secondary, _command_mode), do: false

  defp valid_doctor_result_shape?(result) do
    with true <- JSONValue.value?(result),
         {:ok, root} <-
           compiled_jsv_root({__MODULE__, :doctor_failure_root}, &doctor_failure_result/0),
         {:ok, _validated} <- JSV.validate(result, root, cast: false) do
      true
    else
      _invalid -> false
    end
  end

  defp doctor_failure_checks_consistent?(
         %{"status" => "pass", "code" => "valid"},
         checks,
         _model_aliases,
         primary,
         secondary
       ) do
    default_local_failure_checks_consistent?(checks, primary, secondary) or
      connect_failure_checks_consistent?(checks, primary)
  end

  defp doctor_failure_checks_consistent?(
         %{"status" => "fail", "code" => code},
         checks,
         model_aliases,
         %{"phase" => "application", "code" => code},
         []
       ) do
    code in @doctor_application_failure_codes and
      Enum.all?(checks, &indeterminate_provider_check?/1) and
      Enum.all?(model_aliases, &(&1["selected"] == false and is_nil(&1["default"])))
  end

  defp doctor_failure_checks_consistent?(
         _application,
         _checks,
         _model_aliases,
         _primary,
         _secondary
       ),
       do: false

  defp default_local_failure_checks_consistent?(
         checks,
         %{"phase" => "local_preflight"} = primary,
         []
       ) do
    with {:ok, expected_name, expected_code} <- failure_row_identity(primary),
         failed when failed != [] <- Enum.filter(checks, &(&1["status"] == "fail")),
         true <-
           %{
             "name" => expected_name,
             "status" => "fail",
             "code" => expected_code
           } in failed,
         true <- Enum.all?(failed, &default_local_failure_check?/1) do
      Enum.all?(checks, fn check ->
        check["status"] == "fail" or default_application_provider_check?(check)
      end)
    else
      _invalid -> false
    end
  end

  defp default_local_failure_checks_consistent?(_checks, _primary, _secondary), do: false

  defp connect_failure_checks_consistent?(checks, primary) do
    with {:ok, expected_name, expected_code} <- failure_row_identity(primary),
         [failed] <- Enum.filter(checks, &(&1["status"] == "fail")),
         true <-
           failed == %{
             "name" => expected_name,
             "status" => "fail",
             "code" => expected_code
           } do
      Enum.all?(checks, fn check ->
        check == failed or indeterminate_provider_check?(check) or static_connect_check?(check)
      end)
    else
      _invalid -> false
    end
  end

  defp default_local_failure_check?(%{
         "name" => "provider/" <> name,
         "status" => "fail",
         "code" => code
       }) do
    String.ends_with?(name, "/local") and
      code in Map.get(@doctor_failure_codes_by_operation, "local", [])
  end

  defp default_local_failure_check?(_check), do: false

  defp doctor_failure_mode_consistent?(
         %{"checks" => [_runtime, %{"status" => "fail"}, _viewer | _provider_checks]},
         %{"phase" => "application"},
         [],
         _command_mode
       ),
       do: true

  defp doctor_failure_mode_consistent?(
         %{"checks" => [_runtime, %{"status" => "pass"} = _application, _viewer | checks]},
         primary,
         secondary,
         :doctor
       ),
       do: default_local_failure_checks_consistent?(checks, primary, secondary)

  defp doctor_failure_mode_consistent?(
         %{"checks" => [_runtime, %{"status" => "pass"} = _application, _viewer | checks]},
         primary,
         _secondary,
         {:doctor, :connect}
       ),
       do: connect_failure_checks_consistent?(checks, primary)

  defp doctor_failure_mode_consistent?(_result, _primary, _secondary, _command_mode), do: false

  defp failure_row_identity(%{
         "code" => code,
         "subject" => %{"kind" => "provider", "name" => name, "operation" => operation}
       }) do
    report_operation = if(operation == "acquisition", do: "connectivity", else: operation)

    if report_operation in ~w(local selection credentials authorization connectivity),
      do: {:ok, "provider/#{name}/#{report_operation}", code},
      else: :error
  end

  defp failure_row_identity(_primary), do: :error

  defp indeterminate_provider_check?(%{
         "status" => "skipped",
         "code" => "not_verified_due_to_failure"
       }),
       do: true

  defp indeterminate_provider_check?(_check), do: false

  defp static_connect_check?(%{"name" => name, "status" => "pass", "code" => "available"}),
    do: String.ends_with?(name, "/local")

  defp static_connect_check?(%{
         "name" => name,
         "status" => "pass",
         "code" => "declarative"
       }),
       do: String.ends_with?(name, "/selection")

  defp static_connect_check?(_check), do: false

  defp diagnostic_activity(diagnostics) do
    if Enum.all?(diagnostics, &is_boolean(&1["provider_activity"])),
      do: Enum.any?(diagnostics, & &1["provider_activity"]),
      else: :invalid
  end

  defp model_aliases_valid?(aliases) when is_list(aliases) do
    names = Enum.map(aliases, &Map.get(&1, "alias"))

    names == Enum.sort(Enum.uniq(names)) and
      Enum.all?(aliases, fn row ->
        case {row["selected"], row["default"]} do
          {true, default?} when is_boolean(default?) -> true
          {false, nil} -> true
          _invalid -> false
        end
      end) and
      Enum.count(aliases, &(&1["default"] == true)) <= 1
  end

  defp model_aliases_valid?(_aliases), do: false

  # A command that activated no provider spent nothing, so it may not claim its
  # account is unavailable and it may not report rows for calls it never made.
  # Rows are keyed by alias and revision, sorted and unique, the way a run's are,
  # and every key names a model alias the same report says was selected: spend
  # attributed to a declaration the report does not list is spend a reader
  # cannot check.
  defp doctor_usage_valid?(
         %{"llm_usage_state" => "unavailable", "llm_usage" => nil},
         true,
         _aliases
       ),
       do: true

  defp doctor_usage_valid?(
         %{"llm_usage_state" => "available", "llm_usage" => rows},
         activity,
         aliases
       )
       when is_list(rows) do
    keys = Enum.map(rows, &{&1["alias"], &1["installation_revision"]})

    selected =
      for %{"selected" => true} = row <- aliases,
          do: {row["alias"], row["installation_revision"]}

    keys == Enum.sort(Enum.uniq(keys)) and (activity or rows == []) and
      Enum.all?(keys, &(&1 in selected)) and Enum.all?(rows, &usage_row_coherent?/1)
  end

  defp doctor_usage_valid?(_usage, _activity, _aliases), do: false

  # The counter relationships `LLMUsageSummary` produces: a row exists because
  # calls happened, a probed call that failed leaves no result to report at all,
  # each success either reported usage or did not, and one that did not leaves
  # the total cost incomplete.
  defp usage_row_coherent?(%{
         "calls" => calls,
         "successful_calls" => successful,
         "usage_calls" => measured,
         "missing_usage_calls" => missing,
         "usage" => usage
       })
       when is_map(usage) do
    calls >= 1 and successful == calls and measured + missing == calls and
      (measured > 0 or usage == %{}) and
      (missing == 0 or not Map.has_key?(usage, "total_cost"))
  end

  defp usage_row_coherent?(_row), do: false

  defp valid_installation_revision?(revision) when is_binary(revision),
    do: revision =~ @installation_revision

  defp valid_installation_revision?(_revision), do: false

  defp doctor_provider_key(%{"name" => name}) do
    case Regex.named_captures(@doctor_provider_name, name) do
      %{"alias" => alias_name, "operation" => operation} ->
        {alias_name, doctor_operation_rank(operation)}

      nil ->
        nil
    end
  end

  defp doctor_operation_rank("local"), do: 0
  defp doctor_operation_rank("selection"), do: 1
  defp doctor_operation_rank("credentials"), do: 2
  defp doctor_operation_rank("authorization"), do: 3
  defp doctor_operation_rank("connectivity"), do: 4

  defp provider_groups_start_with_local?(keys) do
    keys
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.all?(fn
      [{_alias_name, 0} | _rest] -> true
      _group -> false
    end)
  end

  defp provider_groups_match_application?(
         keys,
         %{"status" => "pass", "code" => "valid"}
       ) do
    keys
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.all?(&Enum.any?(&1, fn {_alias_name, rank} -> rank == 1 end))
  end

  defp provider_groups_match_application?(
         _keys,
         %{"status" => "skipped", "code" => "not_requested"}
       ),
       do: true

  defp provider_groups_match_application?(_keys, %{"status" => "fail", "code" => code}),
    do: code in @doctor_application_failure_codes

  defp provider_groups_match_application?(_keys, _application_check), do: false

  defp doctor_mode_consistent?(
         :default,
         %{"status" => "skipped", "code" => "not_requested"},
         checks,
         false
       ),
       do: Enum.all?(checks, &default_host_only_provider_check?/1)

  defp doctor_mode_consistent?(
         :default,
         %{"status" => "pass", "code" => "valid"},
         checks,
         false
       ),
       do: Enum.all?(checks, &default_application_provider_check?/1)

  defp doctor_mode_consistent?(
         :connect,
         %{"status" => "pass", "code" => "valid"},
         checks,
         provider_activity
       ) do
    Enum.all?(checks, &connect_provider_check?/1) and
      provider_activity_consistent?(checks, provider_activity)
  end

  defp doctor_mode_consistent?(_mode, _application, _checks, _provider_activity), do: false

  defp default_host_only_provider_check?(%{
         "name" => "provider/" <> name,
         "status" => status,
         "code" => code
       }) do
    case {name |> String.split("/") |> List.last(), status, code} do
      {"local", "skipped", "application_required"} ->
        true

      {operation, "skipped", "requires_connect"}
      when operation in ["credentials", "authorization", "connectivity"] ->
        true

      _other ->
        false
    end
  end

  defp default_host_only_provider_check?(_check), do: false

  defp default_application_provider_check?(%{
         "name" => "provider/" <> name,
         "status" => status,
         "code" => code
       }) do
    case {name |> String.split("/") |> List.last(), status, code} do
      {"local", "pass", "available"} ->
        true

      {"local", "skipped", "active_check_required"} ->
        true

      {"selection", "pass", selection_code}
      when selection_code == "declarative" ->
        true

      {"selection", "skipped", "active_check_required"} ->
        true

      {operation, "skipped", "requires_connect"}
      when operation in ["credentials", "authorization", "connectivity"] ->
        true

      _other ->
        false
    end
  end

  defp default_application_provider_check?(_check), do: false

  defp connect_provider_check?(%{
         "name" => "provider/" <> name,
         "status" => "pass",
         "code" => code
       }) do
    case name |> String.split("/") |> List.last() do
      "local" ->
        code == "available"

      "selection" ->
        code in ["declarative", "available"]

      operation when operation in ["credentials", "authorization", "connectivity"] ->
        code == "available"

      _other ->
        false
    end
  end

  defp connect_provider_check?(_check), do: false

  defp provider_activity_consistent?(checks, provider_activity) do
    cond do
      Enum.any?(checks, &active_provider_success?/1) ->
        provider_activity == true

      Enum.any?(checks, &local_provider_success?/1) ->
        is_boolean(provider_activity)

      true ->
        provider_activity == false
    end
  end

  defp active_provider_success?(%{
         "name" => "provider/" <> name,
         "status" => "pass",
         "code" => "available"
       }) do
    String.ends_with?(name, [
      "/selection",
      "/authorization",
      "/connectivity"
    ])
  end

  defp active_provider_success?(_check), do: false

  defp local_provider_success?(%{
         "name" => "provider/" <> name,
         "status" => "pass",
         "code" => "available"
       }),
       do: String.ends_with?(name, "/local")

  defp local_provider_success?(_check), do: false

  defp ordered_subset?(values, order) do
    ranks = Enum.map(values, fn value -> Enum.find_index(order, &(&1 == value)) end)
    Enum.all?(ranks, &is_integer/1) and ranks == Enum.sort(ranks) and ranks == Enum.uniq(ranks)
  end

  @spec help_result(atom()) :: map()
  def help_result(topic, frontend \\ :standalone) do
    if topic in CommandDeclaration.topics() and frontend in [:standalone, :mix] do
      %{
        "topic" => Atom.to_string(topic),
        "usage" => CommandDeclaration.usage(topic),
        "options" => CommandDeclaration.help_options(topic, frontend),
        "notices" => if(topic == :doctor, do: [@doctor_notice], else: [])
      }
    else
      raise ArgumentError, "invalid help topic"
    end
  end

  @spec version_result() :: map()
  def version_result, do: %{"version" => @version}

  @doc """
  Builds the `docs` result: the served listing, or one embedded page.
  """
  @spec docs_result(binary() | nil) :: map()
  def docs_result(nil), do: %{"pages" => DocumentationLibrary.listing()}

  def docs_result(page) when is_binary(page) do
    case DocumentationLibrary.fetch(page) do
      {:ok, content} -> %{"page" => page, "content" => content}
      :error -> raise ArgumentError, "invalid docs page"
    end
  end

  defp error_envelope(command, rows, provider_activity, compound?) do
    diagnostic = diagnostic_schema(rows, provider_activity)

    closed(
      ~w(schema_version command status run_ref error secondary_errors),
      base_properties([command], "error")
      |> Map.merge(%{
        "error" => diagnostic,
        "secondary_errors" =>
          if(compound?,
            do: %{"type" => "array", "maxItems" => 6, "items" => diagnostic},
            else: %{"const" => []}
          )
      })
    )
  end

  defp doctor_failure_envelope do
    primary_diagnostic = diagnostic_schema(DiagnosticCatalog.doctor_finding_rows())
    secondary_diagnostic = diagnostic_schema(diagnostic_rows({:doctor, :connect}))

    closed(
      ~w(schema_version command status run_ref error secondary_errors result),
      base_properties(["doctor"], "error")
      |> Map.merge(%{
        "error" => primary_diagnostic,
        "secondary_errors" => %{
          "type" => "array",
          "maxItems" => 6,
          "items" => secondary_diagnostic
        },
        "result" => doctor_failure_result()
      })
    )
  end

  defp diagnostic_rows(:run), do: DiagnosticCatalog.rows()

  defp diagnostic_rows(mode) do
    DiagnosticCatalog.rows()
    |> Enum.filter(&diagnostic_pair_allowed?(mode, &1.phase, &1.code))
  end

  defp diagnostic_pair_allowed?(mode, :arguments, code)
       when mode in [
              :init,
              :validate,
              :models,
              :doctor,
              {:doctor, :connect}
            ] and code in [:invalid_arguments, :conflicting_arguments],
       do: true

  # Only the two commands that need a host installation can reach it: `models`
  # reports installed aliases, and `doctor --connect` makes real requests.
  defp diagnostic_pair_allowed?(mode, :arguments, :project_host_undeclared)
       when mode in [:models, :doctor, {:doctor, :connect}],
       do: true

  # Every command that accepts a project document in its positional argument can
  # be refused for one that names itself a project and is not one.
  defp diagnostic_pair_allowed?(mode, :arguments, :project_invalid)
       when mode in [
              :validate,
              :models,
              :doctor,
              {:doctor, :connect},
              :run_unclassified
            ],
       do: true

  # Every command that accepts `--envelope` can be refused for naming a
  # destination that already exists. `:run` admits the whole catalog, and a run
  # refused at admission is reported unclassified.
  defp diagnostic_pair_allowed?(mode, :arguments, :envelope_destination_exists)
       when mode in [
              :init,
              :validate,
              :models,
              :doctor,
              {:doctor, :connect},
              :run_unclassified
            ],
       do: true

  defp diagnostic_pair_allowed?(mode, :arguments, :invalid_arguments)
       when mode in [:help, :version, :docs],
       do: true

  defp diagnostic_pair_allowed?(:docs, :arguments, :docs_page_unknown), do: true
  defp diagnostic_pair_allowed?(:init, :arguments, :example_unknown), do: true

  defp diagnostic_pair_allowed?(:run_unclassified, :arguments, code)
       when code in [:invalid_arguments, :conflicting_arguments],
       do: true

  defp diagnostic_pair_allowed?(:unknown, :arguments, code)
       when code in [:invalid_command, :invalid_arguments],
       do: true

  defp diagnostic_pair_allowed?(mode, :internal, :internal_error)
       when mode in [:help, :version, :docs, :init, :validate, :models, :doctor, :unknown],
       do: true

  defp diagnostic_pair_allowed?({:doctor, :connect}, :internal, :internal_error), do: true
  defp diagnostic_pair_allowed?(:run_unclassified, :internal, :internal_error), do: true

  defp diagnostic_pair_allowed?(:init, :publication, code)
       when code in [
              :initialization_target_exists,
              :initialization_parent_missing,
              :initialization_parent_unusable,
              :initialization_failed
            ],
       do: true

  defp diagnostic_pair_allowed?(mode, :host, code)
       when mode in [:validate, :models, :doctor, {:doctor, :connect}, :run_unclassified] and
              code in @host_codes,
       do: true

  defp diagnostic_pair_allowed?(mode, :application, code)
       when mode in [:validate, :doctor, {:doctor, :connect}] and
              code in @static_application_codes,
       do: true

  defp diagnostic_pair_allowed?(:run_unclassified, :application, code)
       when code in @application_codes,
       do: true

  defp diagnostic_pair_allowed?(:run_unclassified, :destination, code)
       when code in @destination_codes,
       do: true

  defp diagnostic_pair_allowed?(mode, :bundle, code)
       when mode in [:validate, :doctor, {:doctor, :connect}, :run_unclassified] and
              code in @bundle_codes,
       do: true

  defp diagnostic_pair_allowed?(mode, :provider_declaration, code)
       when mode in [:validate, :doctor, {:doctor, :connect}, :run_unclassified] and
              code in @provider_declaration_codes,
       do: true

  defp diagnostic_pair_allowed?(:models, :provider_declaration, :dependency_invalid), do: true

  # A run needs no clause here. `local_preflight` is a classified phase, so a
  # post-marker failure renders through the classified branch, which admits
  # every non-preclassification row. Adding it to `:run_unclassified` instead
  # would admit an envelope that cannot exist: that branch pins
  # `provider_activity` to false and reports execution as not started.
  defp diagnostic_pair_allowed?(mode, :local_preflight, code)
       when mode in [:doctor, {:doctor, :connect}] and code in @local_preflight_codes,
       do: true

  # `validate` reads the fixture file a replay installation declares, so it can
  # report that file being unusable and the phase budget running out while it
  # was read. It acquires nothing: the check is process-free and marks no
  # provider activity, which is why no other local code is admitted here.
  defp diagnostic_pair_allowed?(:validate, :local_preflight, code)
       when code in [:environment_unavailable, :local_check_timeout],
       do: true

  defp diagnostic_pair_allowed?({:doctor, :connect}, :active_preflight, code)
       when code in @active_preflight_codes,
       do: true

  defp diagnostic_pair_allowed?({:doctor, :connect}, :provider_acquisition, code)
       when code in @doctor_provider_acquisition_codes,
       do: true

  defp diagnostic_pair_allowed?({:doctor, :connect}, :result_cleanup, code)
       when code in @provider_cleanup_codes,
       do: true

  defp diagnostic_pair_allowed?(_mode, _phase, _code), do: false

  defp run_error_envelope(artifact_class, states, execution, diagnostic) do
    run_error_envelope(
      artifact_class,
      states,
      execution,
      diagnostic,
      %{
        "type" => "array",
        "maxItems" => 6,
        "items" => ref(diagnostic)
      }
    )
  end

  defp run_error_envelope(artifact_class, states, execution, diagnostic, secondary_errors) do
    closed(
      ~w(schema_version command status run_ref error secondary_errors artifact_state artifact_class execution),
      base_properties(["run"], "error")
      |> Map.merge(%{
        "error" => ref(diagnostic),
        "secondary_errors" => secondary_errors,
        "artifact_state" => artifact_state(states),
        "artifact_class" => enum_or_const(artifact_class),
        "execution" => execution
      })
    )
  end

  defp run_recovery_error_envelope(state, diagnostic) do
    ~w(normal private)
    |> run_error_envelope(
      @artifact_states,
      execution_schema(),
      "classified_diagnostic"
    )
    |> put_in(["properties", "artifact_state"], recovery_artifact_state(state))
    |> Map.put("anyOf", [
      %{
        "properties" => %{
          "error" => ref(diagnostic)
        }
      },
      %{
        "properties" => %{
          "secondary_errors" => %{
            "contains" => ref(diagnostic),
            "minContains" => 1
          }
        }
      }
    ])
  end

  defp recovery_diagnostic_schema(publication_codes) do
    diagnostic_schema(
      Enum.filter(DiagnosticCatalog.rows(), fn row ->
        row.phase == :publication and row.code in publication_codes
      end)
    )
  end

  defp success_envelope(command, result) do
    closed(
      ~w(schema_version command status run_ref result),
      base_properties([command], "ok")
      |> Map.put("result", result)
    )
  end

  defp run_success_envelope(artifact_class, result) do
    closed(
      ~w(schema_version command status run_ref result secondary_errors artifact_state artifact_class execution),
      base_properties(["run"], "ok")
      |> Map.merge(%{
        "result" => result,
        "secondary_errors" => %{"const" => []},
        "artifact_state" => success_artifact_state(artifact_class),
        "artifact_class" => %{"const" => artifact_class},
        "execution" =>
          closed(~w(state outcome diagnostic usage evaluation_memory), %{
            "state" => %{"const" => "finished"},
            "outcome" => %{"const" => "ok"},
            "diagnostic" => %{"type" => "null"},
            "usage" => ref("usage"),
            "evaluation_memory" => ref("evaluation_memory")
          })
      })
    )
  end

  defp base_properties(commands, status) do
    %{
      "schema_version" => %{"const" => 2},
      "command" => %{"enum" => commands},
      "status" => %{"const" => status},
      "run_ref" => %{"type" => "string", "pattern" => @run_ref}
    }
  end

  defp diagnostic_schema(rows \\ DiagnosticCatalog.rows(), provider_activity \\ :catalog) do
    %{
      "oneOf" =>
        Enum.flat_map(rows, fn row ->
          null_source =
            diagnostic_row(
              row,
              %{"type" => "null"},
              %{"type" => "null"},
              %{"type" => "null"},
              provider_activity
            )

          non_null_sources =
            row.phase
            |> DiagnosticCatalog.source_kinds(row.code)
            |> Enum.map(fn kind ->
              diagnostic_row(
                row,
                source_schema(kind),
                path_schema(row, kind),
                span_schema(),
                provider_activity
              )
            end)

          [null_source | non_null_sources]
        end)
    }
  end

  defp diagnostic_row(row, source, path, span, provider_activity) do
    closed(
      ~w(phase code message source path span subject notes retryable provider_activity),
      %{
        "phase" => %{"const" => Atom.to_string(row.phase)},
        "code" => %{"const" => Atom.to_string(row.code)},
        "message" => diagnostic_message_schema(row, source),
        "source" => source,
        "path" => path,
        "span" => span,
        "subject" => subject_schema(row),
        "notes" => %{"const" => []},
        "retryable" => %{"const" => row.retryable},
        "provider_activity" => provider_activity_schema(row, provider_activity)
      }
    )
  end

  defp source_schema(kind)
       when kind in [:host, :application, :external_input, :component_override, :runtime],
       do: source_branch(kind, %{"const" => CommandSource.fixed(kind).name})

  defp source_schema(kind) when kind in [:component, :input_contract, :result_contract] do
    source_branch(kind, %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 1_024,
      "pattern" => ApplicationSource.logical_name_pattern()
    })
  end

  defp source_branch(kind, name_schema) do
    closed(~w(kind name), %{
      "kind" => %{"const" => Atom.to_string(kind)},
      "name" => name_schema
    })
  end

  defp diagnostic_message_schema(%{code: :capability_requirement_missing} = row, _source),
    do: DiagnosticCatalog.message_schema(row)

  defp diagnostic_message_schema(%{code: :provider_tool_missing} = row, _source),
    do: DiagnosticCatalog.message_schema(row)

  defp diagnostic_message_schema(
         %{phase: :execution, code: :runtime_limit_exceeded} = row,
         %{"type" => "null"}
       ),
       do: RuntimeLimitDiagnostic.agent_loop_message_schema(row.message)

  defp diagnostic_message_schema(
         %{phase: :local_preflight, code: code} = row,
         %{"type" => "null"}
       )
       when code in [:environment_unavailable, :fixtures_unreadable],
       do: DiagnosticCatalog.message_schema(row)

  defp diagnostic_message_schema(
         %{phase: :execution, code: :runtime_limit_exceeded} = row,
         %{"properties" => %{"kind" => %{"const" => "runtime"}}}
       ),
       do: RuntimeLimitDiagnostic.runtime_message_schema(row.message)

  defp diagnostic_message_schema(
         %{phase: :execution, code: :run_timeout} = row,
         %{"properties" => %{"kind" => %{"const" => "runtime"}}}
       ),
       do: RuntimeLimitDiagnostic.run_duration_message_schema(row.message)

  defp diagnostic_message_schema(
         %{phase: :result_cleanup, code: :result_contract_failed} = row,
         %{"properties" => %{"kind" => %{"const" => "result_contract"}}}
       ),
       do: ResultContractDiagnostic.message_schema(row.message)

  # Neither of these can name a document: the terminal-result ceiling belongs to
  # the effective limits and the agent option to the shipped loop's own
  # configuration, so both publish their bounded message against a null source.
  defp diagnostic_message_schema(
         %{phase: :result_cleanup, code: :result_limit_exceeded} = row,
         %{"type" => "null"}
       ),
       do: RuntimeLimitDiagnostic.result_limit_message_schema(row.message)

  defp diagnostic_message_schema(
         %{phase: :execution, code: :workflow_failed} = row,
         %{"type" => "null"}
       ),
       do: AgentConfigDiagnostic.message_schema(row.message)

  # Both dynamic messages above are admitted only against a null source, so the
  # sourced branches of the same rows must stay pinned to the catalog literal;
  # otherwise the published schema would accept a pairing the command refuses to
  # build.
  defp diagnostic_message_schema(%{phase: :execution, code: :workflow_failed} = row, _source),
    do: %{"const" => row.message}

  defp diagnostic_message_schema(
         %{phase: :result_cleanup, code: :result_limit_exceeded} = row,
         _source
       ),
       do: %{"const" => row.message}

  # Only a contract source carries a rule-derived message. The application
  # source reports the same code for a malformed `contracts` section, which has
  # no schema document to locate a rule in, so it keeps the catalog literal.
  defp diagnostic_message_schema(
         %{phase: :application, code: :contract_invalid} = row,
         %{"properties" => %{"kind" => %{"const" => kind}}}
       )
       when kind in ["input_contract", "result_contract"],
       do: ContractSchemaDiagnostic.message_schema(row.message)

  defp diagnostic_message_schema(%{phase: :application, code: :contract_invalid} = row, _source),
    do: %{"const" => row.message}

  defp diagnostic_message_schema(row, %{"type" => "null"}), do: %{"const" => row.message}
  defp diagnostic_message_schema(row, _source_schema), do: DiagnosticCatalog.message_schema(row)

  defp path_schema(row, kind) do
    case DiagnosticCatalog.path_policy(row.phase, row.code, kind) do
      :optional ->
        %{
          "oneOf" => [
            %{"type" => "null"},
            %{"type" => "string", "maxLength" => 8_192, "pattern" => @json_pointer}
          ]
        }

      :forbidden ->
        %{"type" => "null"}
    end
  end

  defp span_schema do
    %{
      "oneOf" => [
        %{"type" => "null"},
        closed(~w(start_byte end_byte), %{
          "start_byte" => nonnegative_integer(),
          "end_byte" => nonnegative_integer()
        })
      ]
    }
  end

  defp subject_schema(row) do
    non_null = provider_subject_schema(row)

    case DiagnosticCatalog.subject_policy(row.phase, row.code) do
      :required -> non_null
      :optional -> %{"oneOf" => [%{"type" => "null"}, non_null]}
      :forbidden -> %{"type" => "null"}
    end
  end

  defp provider_subject_schema(row) do
    branches =
      row.phase
      |> DiagnosticCatalog.subject_operations(row.code)
      |> Enum.map(fn operation ->
        closed(~w(kind name operation occurrence), %{
          "kind" => %{"const" => "provider"},
          "name" => %{"type" => "string", "pattern" => @alias},
          "operation" => %{"const" => Atom.to_string(operation)},
          "occurrence" => occurrence_schema(row, operation)
        })
      end)

    case branches do
      [branch] -> branch
      _multiple -> %{"oneOf" => branches}
    end
  end

  defp occurrence_schema(row, operation) do
    occurrence =
      closed(~w(destination index), %{
        "destination" => %{"enum" => ~w(workflow mission)},
        "index" => %{"type" => "integer", "minimum" => 0, "maximum" => 31}
      })

    case DiagnosticCatalog.subject_occurrence_policy(row.phase, row.code, operation) do
      :required -> occurrence
      :optional -> %{"oneOf" => [%{"type" => "null"}, occurrence]}
      :forbidden -> %{"type" => "null"}
    end
  end

  defp provider_activity_schema(_row, false), do: %{"const" => false}

  defp provider_activity_schema(row, :catalog) do
    case DiagnosticCatalog.provider_activity_policy(row.phase, row.code) do
      false -> %{"const" => false}
      true -> %{"const" => true}
      :boolean -> %{"type" => "boolean"}
    end
  end

  defp artifact_state(states) do
    ordinary_states = states -- @recovery_artifact_states

    closed(~w(trace inspection result), %{
      "trace" => %{"enum" => ordinary_states},
      "inspection" => %{"enum" => ordinary_states},
      "result" => %{"enum" => states}
    })
  end

  defp recovery_artifact_state(state) do
    closed(~w(trace inspection result), %{
      "trace" => %{"enum" => @artifact_states -- @recovery_artifact_states},
      "inspection" => %{"enum" => @artifact_states -- @recovery_artifact_states},
      "result" => %{"const" => state}
    })
  end

  defp success_artifact_state("normal") do
    closed(~w(trace inspection result), %{
      "trace" => %{"enum" => ~w(not_requested written)},
      "inspection" => %{"enum" => ~w(not_requested written)},
      "result" => %{"enum" => ~w(not_requested written)}
    })
  end

  defp success_artifact_state("private") do
    closed(~w(trace inspection result), %{
      "trace" => %{"enum" => ~w(not_requested written)},
      "inspection" => %{"enum" => ~w(not_requested written)},
      "result" => %{"const" => "written"}
    })
  end

  defp execution_schema do
    %{
      "oneOf" => [
        closed(~w(state), %{"state" => %{"const" => "not_started"}}),
        closed(~w(state usage evaluation_memory), %{
          "state" => %{"const" => "incomplete"},
          "usage" => nullable_ref("usage"),
          "evaluation_memory" => nullable_ref("evaluation_memory")
        }),
        closed(~w(state outcome diagnostic usage evaluation_memory), %{
          "state" => %{"const" => "finished"},
          "outcome" => %{"const" => "ok"},
          "diagnostic" => %{"type" => "null"},
          "usage" => ref("usage"),
          "evaluation_memory" => ref("evaluation_memory")
        }),
        closed(~w(state outcome diagnostic usage evaluation_memory), %{
          "state" => %{"const" => "finished"},
          "outcome" => %{"const" => "error"},
          "diagnostic" => ref("execution_diagnostic"),
          "usage" => ref("usage"),
          "evaluation_memory" => ref("evaluation_memory")
        })
      ]
    }
  end

  defp usage_schema do
    capability_counts = count_map(@capability_name)
    event_counts = count_map(@event_type, ["$overflow"])

    required =
      ~w(remaining_ms capability_calls subordinate_evaluations evaluations_by_mission protocol_errors evaluation_memory_bytes evaluation_history_bytes evaluation_continuation_bytes events_dropped llm_usage_state llm_usage llm_usage_by_model unattributed_model_calls)

    common = %{
      "remaining_ms" => nonnegative_integer(),
      "capability_calls" => capability_counts,
      "subordinate_evaluations" => nonnegative_integer(),
      "evaluations_by_mission" => count_map(@alias),
      "protocol_errors" => nonnegative_integer(),
      "evaluation_memory_bytes" => nonnegative_integer(),
      "evaluation_history_bytes" => nonnegative_integer(),
      "evaluation_continuation_bytes" => nonnegative_integer(),
      "events_dropped" => event_counts
    }

    %{
      "oneOf" => [
        closed(
          required,
          Map.merge(common, %{
            "llm_usage_state" => %{"const" => "available"},
            "llm_usage" => llm_usage_rows(llm_alias_row_schema()),
            "llm_usage_by_model" => llm_usage_rows(llm_model_row_schema()),
            "unattributed_model_calls" => nonnegative_integer()
          })
        ),
        closed(
          required,
          Map.merge(common, %{
            "llm_usage_state" => %{"const" => "unavailable"},
            "llm_usage" => %{"type" => "null"},
            "llm_usage_by_model" => %{"type" => "null"},
            "unattributed_model_calls" => %{"type" => "null"}
          })
        )
      ]
    }
  end

  defp llm_usage_rows(row),
    do: %{"type" => "array", "maxItems" => 128, "items" => row}

  defp llm_alias_row_schema do
    llm_usage_row_schema(
      ~w(alias installation_revision),
      %{
        "alias" => %{"type" => "string", "pattern" => @alias},
        "installation_revision" => %{"type" => "string", "pattern" => @alias}
      }
    )
  end

  defp llm_model_row_schema do
    llm_usage_row_schema(
      ["resolved_model"],
      %{
        "resolved_model" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 256
        }
      }
    )
  end

  defp llm_usage_row_schema(identity_fields, identity_properties) do
    counters =
      Map.new(~w(calls successful_calls usage_calls missing_usage_calls), fn name ->
        {name, nonnegative_integer()}
      end)

    closed(
      identity_fields ++ Map.keys(counters) ++ ["usage"],
      identity_properties
      |> Map.merge(counters)
      |> Map.put("usage", llm_usage_values_schema())
    )
  end

  defp llm_usage_values_schema do
    token_properties =
      Map.new(~w(input output cache_creation cache_read), fn name ->
        {name, nonnegative_integer()}
      end)

    closed(
      [],
      Map.put(token_properties, "total_cost", %{"type" => "number", "minimum" => 0})
    )
  end

  defp count_map(name_pattern, exceptions \\ []) do
    property_names =
      case exceptions do
        [] ->
          %{"type" => "string", "pattern" => name_pattern}

        values ->
          %{
            "oneOf" => [
              %{"type" => "string", "pattern" => name_pattern},
              %{"type" => "string", "enum" => values}
            ]
          }
      end

    %{
      "type" => "object",
      "propertyNames" => property_names,
      "additionalProperties" => nonnegative_integer(),
      "maxProperties" => 512
    }
  end

  defp evaluation_memory_schema do
    fields =
      Map.new(~w(defined_count history_count memory_bytes history_bytes bytes), fn name ->
        {name, nonnegative_integer()}
      end)

    closed(Map.keys(fields), fields)
  end

  defp help_result_schema do
    %{
      "oneOf" =>
        for topic <- Enum.sort_by(CommandDeclaration.topics(), &Atom.to_string/1),
            frontend <- [:standalone, :mix],
            uniq: true do
          topic
          |> help_result(frontend)
          |> const_object()
        end
    }
  end

  defp version_result_schema, do: version_result() |> const_object()

  # The listing is pinned by identity and order: one positional name constant
  # per served page, an exact length, and no additional entries, so an omitted,
  # reordered, duplicated, or renamed page cannot be sealed. Titles, sizes, and
  # bodies stay structural on purpose — they are derived from the shipped
  # documents, and pinning them here would rebuild this artifact, and fail the
  # staleness gate, on every documentation edit.
  defp docs_result_schema do
    names = DocumentationLibrary.names()

    %{
      "oneOf" => [
        closed(~w(pages), %{
          "pages" => %{
            "type" => "array",
            "minItems" => length(names),
            "maxItems" => length(names),
            "prefixItems" => Enum.map(names, &listed_page_schema/1),
            "items" => false
          }
        }),
        closed(~w(page content), %{
          "page" => %{"enum" => names},
          "content" => %{"type" => "string", "minLength" => 1}
        })
      ]
    }
  end

  defp listed_page_schema(name) do
    closed(~w(name title bytes), %{
      "name" => %{"const" => name},
      "title" => %{"type" => "string", "minLength" => 1},
      "bytes" => %{"type" => "integer", "minimum" => 1}
    })
  end

  # The scaffold's own list, plus one sealed list per embedded example tree, so
  # `--example` cannot publish a top-level entry the contract did not admit.
  defp init_result do
    scaffold = ["AGENTS.md", ".gitignore", "main.clj", "ptc.json", "ptc-project.json"]

    examples =
      Enum.map(ExampleLibrary.names(), fn name ->
        {:ok, created} = ExampleLibrary.created(name)
        %{"const" => created}
      end)

    closed(~w(created), %{
      "created" => %{"oneOf" => [%{"const" => scaffold} | examples]}
    })
  end

  defp validate_result do
    closed(
      ~w(application_content_digest effective_application_digest workflow_bundle_hash mission_bundle_hashes provider_activity),
      %{
        "application_content_digest" => %{"type" => "string", "pattern" => @digest},
        "effective_application_digest" => %{"type" => "string", "pattern" => @digest},
        "workflow_bundle_hash" => %{"type" => "string", "pattern" => @hash},
        "mission_bundle_hashes" => %{
          "type" => "object",
          "propertyNames" => %{"pattern" => "^[a-z][a-z0-9._-]{0,127}$"},
          "additionalProperties" => %{
            "oneOf" => [%{"type" => "null"}, %{"type" => "string", "pattern" => @hash}]
          },
          "maxProperties" => 16
        },
        "provider_activity" => %{"const" => false}
      }
    )
  end

  defp doctor_success_result, do: doctor_result(:success)
  defp doctor_failure_result, do: doctor_result(:failure)

  defp doctor_result(mode) when mode in [:success, :failure] do
    application_pairs =
      if mode == :success do
        [{"pass", "valid"}, {"skipped", "not_requested"}]
      else
        [{"pass", "valid"}] ++ Enum.map(@doctor_application_failure_codes, &{"fail", &1})
      end

    fixed = [
      doctor_fixed_check_schema("runtime", [{"pass", "supported"}, {"warn", "unsupported"}]),
      doctor_fixed_check_schema("application", application_pairs),
      doctor_fixed_check_schema("viewer", [
        {"pass", "available"},
        {"warn", "optional_unavailable"}
      ])
    ]

    closed(~w(checks model_aliases provider_activity readiness usage), %{
      "usage" => doctor_usage_schema(),
      "checks" => %{
        "type" => "array",
        "minItems" => 3,
        "maxItems" => 1_024,
        "prefixItems" => fixed,
        "items" => doctor_provider_check_schema(mode)
      },
      "model_aliases" => %{
        "type" => "array",
        "maxItems" => 128,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ~w(alias source installation_revision default selected),
          "properties" => %{
            "alias" => %{"type" => "string", "pattern" => @alias},
            "source" => %{"enum" => ["llm", "llm_replay", "custom"]},
            "installation_revision" => %{"type" => "string", "pattern" => @alias},
            "default" => %{
              "oneOf" => [%{"type" => "boolean"}, %{"type" => "null"}]
            },
            "selected" => %{"type" => "boolean"},
            "model_selector" => model_selector_schema()
          }
        }
      },
      "provider_activity" => %{"type" => "boolean"},
      "readiness" =>
        if(mode == :success,
          do: %{"enum" => ~w(unverified ready)},
          else: %{"const" => "failed"}
        )
    })
  end

  # The LLM half of the shape a run reports, on the same rows. `doctor --connect`
  # bills a real request per probed occurrence; a command that could not account
  # for what it spent says so with the run's own `unavailable` state rather than
  # reporting zero.
  defp doctor_usage_schema do
    %{
      "oneOf" => [
        closed(~w(llm_usage_state llm_usage), %{
          "llm_usage_state" => %{"const" => "available"},
          "llm_usage" => llm_usage_rows(llm_alias_row_schema())
        }),
        closed(~w(llm_usage_state llm_usage), %{
          "llm_usage_state" => %{"const" => "unavailable"},
          "llm_usage" => %{"type" => "null"}
        })
      ]
    }
  end

  defp doctor_provider_check_schema(mode) do
    providers = [
      {"local",
       [
         {"pass", "available"},
         {"skipped", "application_required"},
         {"skipped", "active_check_required"}
       ]},
      {"selection",
       [
         {"pass", "declarative"},
         {"pass", "available"},
         {"skipped", "active_check_required"}
       ]},
      {"credentials", [{"pass", "available"}, {"skipped", "requires_connect"}]},
      {"authorization", [{"pass", "available"}, {"skipped", "requires_connect"}]},
      {"connectivity", [{"pass", "available"}, {"skipped", "requires_connect"}]}
    ]

    %{
      "oneOf" =>
        Enum.flat_map(providers, fn {operation, pairs} ->
          name = %{
            "type" => "string",
            "pattern" => "^provider/[a-z][a-z0-9._-]{0,127}/#{operation}$(?![\\s\\S])"
          }

          pairs = doctor_check_pairs(mode, operation, pairs)

          Enum.map(pairs, &doctor_check_branch(name, &1))
        end)
    }
  end

  defp doctor_check_pairs(:success, _operation, pairs), do: pairs

  defp doctor_check_pairs(:failure, operation, _success_pairs) do
    settled =
      case operation do
        "local" ->
          [{"pass", "available"}, {"skipped", "active_check_required"}]

        "selection" ->
          [{"pass", "declarative"}, {"skipped", "active_check_required"}]

        operation when operation in ["credentials", "authorization", "connectivity"] ->
          [{"skipped", "requires_connect"}]
      end

    settled ++
      [{"skipped", "not_verified_due_to_failure"}] ++
      Enum.map(Map.get(@doctor_failure_codes_by_operation, operation, []), fn code ->
        {"fail", code}
      end)
  end

  defp doctor_fixed_check_schema(name, pairs) do
    %{"oneOf" => Enum.map(pairs, &doctor_check_branch(%{"const" => name}, &1))}
  end

  defp doctor_check_branch(name, {status, code}) do
    closed(~w(name status code), %{
      "name" => name,
      "status" => %{"const" => status},
      "code" => %{"const" => code}
    })
  end

  defp models_result do
    item =
      closed(
        ~w(alias source installation_revision data_class accepts_data destinations),
        %{
          "alias" => %{"type" => "string", "pattern" => @alias},
          "source" => %{
            "enum" =>
              ~w(mcp llm llm_replay ptc_trace_snapshot ptc_private_trace_snapshot ptc_inspection_snapshot custom)
          },
          "installation_revision" => %{
            "type" => "string",
            "pattern" => @alias
          },
          "data_class" => %{"enum" => ~w(normal private_inspection)},
          "accepts_data" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 2,
            "uniqueItems" => true,
            "items" => %{"enum" => ~w(normal private_inspection)}
          },
          "destinations" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 2,
            "uniqueItems" => true,
            "items" => %{"enum" => ~w(workflow mission)}
          },
          "model_selector" => model_selector_schema()
        }
      )

    closed(~w(installations), %{
      "installations" => %{"type" => "array", "maxItems" => 128, "items" => item}
    })
  end

  # `ModelSelectorDisclosure` withholds endpoint-bearing selectors; the closed
  # envelope refuses one rather than trusting every producer to remember.
  defp model_selector_schema do
    %{
      "type" => "string",
      "maxLength" => 4_096,
      "not" => %{"pattern" => "^openai-compat:"}
    }
  end

  defp success_result_schema(:help), do: help_result_schema()
  defp success_result_schema(:version), do: version_result_schema()
  defp success_result_schema(:docs), do: docs_result_schema()
  defp success_result_schema(:init), do: init_result()
  defp success_result_schema(:validate), do: validate_result()
  defp success_result_schema(:doctor), do: doctor_success_result()
  defp success_result_schema(:models), do: models_result()

  defp nullable_ref(name),
    do: %{"oneOf" => [%{"type" => "null"}, ref(name)]}

  defp ref(name), do: %{"$ref" => "#/$defs/#{name}"}
  defp nonnegative_integer, do: %{"type" => "integer", "minimum" => 0}

  defp enum_or_const(value) when is_binary(value), do: %{"const" => value}
  defp enum_or_const(values) when is_list(values), do: %{"enum" => values}

  defp const_object(map) do
    closed(Map.keys(map), Map.new(map, fn {key, value} -> {key, %{"const" => value}} end))
  end

  defp closed(required, properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
  end

  defp compiled_jsv_root(key, schema_fun) when is_function(schema_fun, 0) do
    case :persistent_term.get(key, :unset) do
      :unset ->
        case JSV.build(schema_fun.(), atoms: false, warnings: :silent) do
          {:ok, root} = ok ->
            :persistent_term.put(key, root)
            ok

          error ->
            error
        end

      root ->
        {:ok, root}
    end
  end
end
