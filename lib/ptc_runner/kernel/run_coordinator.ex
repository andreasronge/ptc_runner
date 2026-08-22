defmodule PtcRunner.Kernel.RunCoordinator do
  @moduledoc """
  Path-free preparation and one-shot execution.

  Bundle compilation and public-entry validation run before provider
  declarations. Provider declaration checks inspect only installed aliases;
  they never invoke a builder, credential resolver, preflight callback, OAuth
  context, store, process, or network operation.

  One-shot execution consumes the prepared run inside an execution-session
  owner. That owner constructs both sinks, keeps responding to caller death
  while a subordinate worker performs provider setup and runs the Kernel, and
  returns only sealed, filesystem-path-free execution evidence. Publication
  remains a separate caller operation.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.CompileDiagnostic
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LocalPreflight
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.MissionReplTarget
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.Kernel.SelectionRulesDiagnostic
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.LiveStatus.Target

  @mission_compile_timeout_ms 5_000
  @mission_bundles_bytes 4_000_000

  @spec prepare(RunRequest.t(), InstallationCatalog.t()) ::
          {:ok, PreparedRun.t()} | {:error, CommandDiagnostic.t()}
  def prepare(%RunRequest{} = request, %InstallationCatalog{} = catalog) do
    with true <- RunRequest.valid?(request),
         true <- InstallationCatalog.valid?(catalog),
         true <- catalog.installed_limits == request.package.installed_limits,
         compile_deadline = System.monotonic_time(:millisecond) + @mission_compile_timeout_ms,
         {:ok, workflow_bundle} <-
           compile_required(request.package.workflow_components, compile_deadline),
         {:ok, mission_bundles} <-
           compile_named_missions(
             request.package.missions,
             compile_deadline,
             external_size(workflow_bundle),
             request.package.workflow_components,
             workflow_bundle
           ),
         :ok <- validate_entry(workflow_bundle, request.package.entry),
         :ok <-
           validate_entry_missions(
             workflow_bundle,
             request.package.entry,
             request.package.missions
           ),
         {:ok, declarations} <-
           prepare_providers(request, workflow_bundle, mission_bundles, catalog),
         {:ok, derived} <-
           derive_provider_plan(request, workflow_bundle, mission_bundles, declarations),
         declarations <- add_post_selection_context(declarations, derived.post_selection_context),
         prepared_declarations <- prepared_declarations(declarations),
         {:ok, prepared} <-
           ProviderActivity.start_owned(fn activity ->
             PreparedRun.new(
               request,
               workflow_bundle,
               mission_bundles,
               "(#{request.package.entry} data/input)",
               activity,
               catalog,
               Map.put(derived, :provider_declarations, prepared_declarations)
             )
           end) do
      {:ok, prepared}
    else
      false -> {:error, diagnostic(:internal, :internal_error)}
      {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  rescue
    _exception -> {:error, diagnostic(:internal, :internal_error)}
  catch
    _kind, _reason -> {:error, diagnostic(:internal, :internal_error)}
  end

  def prepare(_request, _registry),
    do: {:error, diagnostic(:internal, :internal_error)}

  @doc """
  Runs the audited-local phase-7 step for one sealed preparation.

  This is the fail-fast runtime entry to that step. Applicability is derived
  from the sealed trio rather than supplied, so no caller can narrow the work,
  and the result is only success or one catalogued diagnostic. Default doctor
  uses `local_check_findings/3` below to retain attributable per-occurrence
  failures for its report. Both entries anchor one deadline for the whole step.

  Every active command crosses it before provider activity is marked: run and
  `doctor --connect` through `ProviderExecution`. Manifest-backed REPL
  opening crosses the same step before provider activity, through
  `ProviderExecution.open_repl/6` when providers are selected and directly for
  provider-free manifests. Direct and analysis-profile REPL sessions do not
  acquire a manifest application or its providers and therefore do not enter
  this coordinator step.
  """
  @spec local_checks(
          PreparedRun.t() | nil,
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def local_checks(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services
      ) do
    LocalPreflight.run(prepared, catalog, services, local_deadline(prepared))
  end

  # A command that prepared no application selected no occurrence, so there is
  # nothing to derive a check from. This clause exists so the decision stays
  # here rather than in a frontend choosing whether to call the step at all.
  def local_checks(nil, %InstallationCatalog{} = catalog, %ProviderRuntimeServices{}),
    do: if(InstallationCatalog.valid?(catalog), do: :ok, else: internal_error())

  def local_checks(_prepared, _catalog, _services), do: internal_error()

  @doc false
  @spec local_checks(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          MissionReplTarget.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def local_checks(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services,
        %MissionReplTarget{} = target
      ) do
    LocalPreflight.run(prepared, catalog, services, local_deadline(prepared), target)
  end

  def local_checks(_prepared, _catalog, _services, _target), do: internal_error()

  @doc """
  Runs the declaration-owned local input checks for `validate`.

  `validate` acquires no provider and marks no activity, but a replay
  installation names a fixture file the declaration owns. Reading it here is
  the same class of work as compiling the components the manifest names, and
  keeps `validate` from passing a host document whose fixtures `run` cannot
  load.
  """
  @spec declared_input_checks(
          PreparedRun.t() | nil,
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def declared_input_checks(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services
      ) do
    LocalPreflight.run_declared_inputs(prepared, catalog, services, local_deadline(prepared))
  end

  def declared_input_checks(nil, %InstallationCatalog{} = catalog, %ProviderRuntimeServices{}),
    do: if(InstallationCatalog.valid?(catalog), do: :ok, else: internal_error())

  def declared_input_checks(_prepared, _catalog, _services), do: internal_error()

  @doc """
  Collects every attributable audited-local finding for default doctor.

  This uses the same sealed declarations, callbacks, and absolute phase budget
  as `local_checks/3`, but retains ordinary failures instead of stopping at the
  first one so doctor can settle every provider-local row.
  """
  @spec local_check_findings(
          PreparedRun.t() | nil,
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) :: {:ok, [CommandDiagnostic.t()]} | {:error, CommandDiagnostic.t()}
  def local_check_findings(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services
      ) do
    LocalPreflight.collect(prepared, catalog, services, local_deadline(prepared))
  end

  def local_check_findings(nil, %InstallationCatalog{} = catalog, %ProviderRuntimeServices{}),
    do: if(InstallationCatalog.valid?(catalog), do: {:ok, []}, else: internal_error())

  def local_check_findings(_prepared, _catalog, _services), do: internal_error()

  defp internal_error, do: {:error, diagnostic(:internal, :internal_error)}

  defp local_deadline(prepared) do
    Deadline.new(prepared.request.package.limits.local_preflight_timeout_ms)
  end

  @doc false
  @spec execute(PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | term()}
  def execute(%PreparedRun{} = prepared, authority), do: execute(prepared, authority, nil)
  def execute(_prepared, _authority), do: {:error, :invalid_prepared_run}

  @doc false
  @spec execute(PreparedRun.t(), PublicationAuthority.t(), Target.t() | nil) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | term()}
  def execute(%PreparedRun{} = prepared, authority, live_status),
    do: open_free(prepared, authority, :run, live_status)

  def execute(_prepared, _authority, _live_status), do: {:error, :invalid_prepared_run}

  defp open_free(prepared, authority, operation, live_status) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.authorized?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations != [] ->
        {:error, :provider_session_required}

      true ->
        with {:ok, owner} <-
               ExecutionSessionOwner.start(
                 prepared,
                 authority,
                 self(),
                 nil,
                 nil,
                 operation,
                 live_status
               ),
             do: ExecutionSessionOwner.await(owner)
    end
  end

  @doc false
  @spec execute(
          PreparedRun.t(),
          PublicationAuthority.t(),
          ProviderExecution.t(),
          (binary() -> term()) | nil
        ) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def execute(%PreparedRun{} = prepared, authority, provider_execution, notifier)
      when is_nil(notifier) or is_function(notifier, 1),
      do: execute(prepared, authority, provider_execution, notifier, nil)

  def execute(_prepared, _authority, _provider_execution, _notifier),
    do: {:error, :invalid_prepared_run}

  @doc false
  @spec execute(
          PreparedRun.t(),
          PublicationAuthority.t(),
          ProviderExecution.t(),
          (binary() -> term()) | nil,
          Target.t() | nil
        ) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def execute(%PreparedRun{} = prepared, authority, provider_execution, notifier, live_status)
      when is_nil(notifier) or is_function(notifier, 1),
      do: open_active(prepared, authority, provider_execution, notifier, :run, live_status)

  def execute(_prepared, _authority, _provider_execution, _notifier, _live_status),
    do: {:error, :invalid_prepared_run}

  # Internal only, like its `execute/4` neighbour.
  # `PtcRunner.Kernel.CommandEngine` dispatches `doctor --connect` through it.
  # Connectivity answers for selected occurrences, so unlike a run it has no
  # provider-free form: a preparation selecting no provider is refused here, and
  # the command answers for it without opening an operation at all.
  #
  # It takes no authorization notifier and refuses an execution carrying
  # authorization targets, because a connectivity check must never open an interactive
  # authorization or ask a human for anything. The refusal is deliberate rather
  # than a silent downgrade to the non-interactive path: a caller that asked for
  # authorization and got a connectivity check that skipped it would be told the wrong thing.
  @doc false
  @spec connect(PreparedRun.t(), PublicationAuthority.t(), ProviderExecution.t()) ::
          {:ok, ConnectivityResult.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def connect(%PreparedRun{} = prepared, authority, provider_execution),
    do: open_active(prepared, authority, provider_execution, nil, :connect, nil)

  def connect(_prepared, _authority, _provider_execution),
    do: {:error, :invalid_prepared_run}

  defp open_active(prepared, authority, provider_execution, notifier, operation, live_status) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.authorized?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations == [] ->
        {:error, :invalid_provider_execution}

      not ProviderExecution.bound_to_prepared?(provider_execution, prepared) ->
        {:error, :invalid_provider_execution}

      true ->
        with {:ok, owner} <-
               ExecutionSessionOwner.start(
                 prepared,
                 authority,
                 self(),
                 provider_execution,
                 notifier,
                 operation,
                 live_status
               ),
             do: ExecutionSessionOwner.await(owner)
    end
  end

  defp compile_required(components, deadline_ms) do
    case BundleCompiler.compile(components, deadline_ms) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, bundle_diagnostic(reason, components)}
    end
  end

  defp compile_named_missions(
         missions,
         deadline_ms,
         initial_bytes,
         workflow_components,
         workflow_bundle
       ) do
    case BundleCompiler.compile_named(
           missions,
           deadline_ms,
           initial_bytes,
           @mission_bundles_bytes,
           [{workflow_components, workflow_bundle}]
         ) do
      {:ok, bundles} -> {:ok, bundles}
      {:error, {failure, components}} -> {:error, bundle_diagnostic(failure, components)}
    end
  end

  defp external_size(nil), do: 0
  defp external_size(bundle), do: :erlang.external_size(bundle)

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [
              :bundle_limit_exceeded,
              :bundle_artifact_exceeded,
              :bundle_diagnostic_exceeded,
              :bundle_compile_heap_exceeded,
              :bundle_compile_timeout
            ],
       do: diagnostic(:bundle, :bundle_limit_exceeded, source_opts(failure, components))

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [:component_compile_error, :bundle_compile_error, :bundle_compile_failed] do
    {code, opts} = compile_diagnostic(failure, components)
    diagnostic(:bundle, code, opts)
  end

  defp bundle_diagnostic(failure, components),
    do: diagnostic(:bundle, :bundle_invalid, source_opts(failure, components))

  defp source_opts(%{id: id} = failure, components) when is_binary(id) do
    case Enum.find(components, &match?(%Component{id: ^id}, &1)) do
      %Component{} = component -> component_source_opts(component, Map.get(failure, :span))
      nil -> []
    end
  end

  defp source_opts(_failure, _components), do: []

  defp compile_diagnostic(failure, components) do
    reason = Map.get(failure, :compile_reason)
    source = source_opts(failure, components)

    case compile_message(failure, components) do
      {:ok, message} ->
        {compile_diagnostic_code(reason), source ++ [message: message]}

      :error when reason == :unknown_namespace ->
        {:compile_failed, source}

      :error ->
        {compile_diagnostic_code(reason), source}
    end
  end

  defp compile_message(
         %{id: id, compile_reason: reason, compile_details: details},
         components
       )
       when is_binary(id) do
    case Enum.find(components, &match?(%Component{id: ^id}, &1)) do
      %Component{source: source} when is_binary(source) ->
        CompileDiagnostic.rebuild(reason, details, source)

      _missing ->
        :error
    end
  end

  defp compile_message(_failure, _components), do: :error

  defp compile_diagnostic_code(:parse_error), do: :syntax_invalid
  defp compile_diagnostic_code(:unbound_var), do: :undefined_variable
  defp compile_diagnostic_code(:duplicate_ref), do: :duplicate_definition
  defp compile_diagnostic_code(:unknown_namespace), do: :unknown_namespace
  defp compile_diagnostic_code(_reason), do: :compile_failed

  # Provenance is bound to the exact component bytes the compiler read, which
  # is what admits a span at all: `CommandDiagnostic` refuses one whose end
  # offset exceeds the source's attested byte bound.
  defp component_source_opts(%Component{id: id, origin: origin, source: bytes}, span) do
    name =
      cond do
        ApplicationSource.valid_name?(origin) -> origin
        ApplicationSource.valid_name?(id) -> id
        true -> nil
      end

    case name do
      nil ->
        []

      safe_name ->
        source = CommandSource.with_bytes(:component, safe_name, bytes)
        [source: source] ++ span_opts(span, bytes)
    end
  end

  defp span_opts(%{start_byte: start_byte, end_byte: end_byte}, bytes)
       when is_integer(start_byte) and is_integer(end_byte) and start_byte >= 0 and
              end_byte >= start_byte and end_byte <= byte_size(bytes),
       do: [span: %{start_byte: start_byte, end_byte: end_byte}]

  defp span_opts(_span, _bytes), do: []

  @doc false
  @spec validate_entry(PtcRunner.Kernel.FrozenBundle.t(), binary()) ::
          :ok | {:error, CommandDiagnostic.t()}
  def validate_entry(workflow_bundle, entry) do
    if PreparedRun.entry_callable?(workflow_bundle, entry),
      do: :ok,
      else: {:error, diagnostic(:bundle, :entry_invalid)}
  end

  @doc """
  Rejects an entry that evaluates into a mission when the manifest declares none.

  `kernel-mission-model-context` answers `unknown_mission` for every name a
  manifest without missions can supply, so a run that reaches it cannot reach its
  first model request. Both facts are in the documents `validate` already parses:
  the compiled entry's transitive tool references, and whether the manifest's
  mission map is empty. Which mission the entry will *name* is not decidable here
  — it comes from runtime configuration — so nothing else is checked.

  The reference set is a may-call set, so an entry that reaches the capability
  only on a branch its input never takes is refused too. That is the deliberate
  trade: such a manifest carries a mission-evaluating library it never uses, the
  remedy is one declared mission, and the failure it replaces is a paid run
  ending in `execution/workflow_failed` with nothing naming the cause.
  """
  @spec validate_entry_missions(PtcRunner.Kernel.FrozenBundle.t(), binary(), map() | nil) ::
          :ok | {:error, CommandDiagnostic.t()}
  def validate_entry_missions(workflow_bundle, entry, missions) do
    if map_size(missions || %{}) == 0 and mission_context_entry?(workflow_bundle, entry),
      do: {:error, diagnostic(:bundle, :mission_undeclared)},
      else: :ok
  end

  defp mission_context_entry?(%{prelude: prelude}, entry) when is_binary(entry) do
    "kernel-mission-model-context" in Prelude.export_tool_refs(prelude, entry)
  rescue
    _exception -> false
  end

  defp mission_context_entry?(_bundle, _entry), do: false

  defp prepare_providers(request, workflow_bundle, mission_bundles, catalog) do
    request.package.providers
    |> provider_specs()
    |> Enum.reduce_while({:ok, []}, fn {destination, selection, index}, {:ok, prepared} ->
      name = selection["name"]
      occurrence = %{destination: destination, index: index}

      case InstallationCatalog.fetch(catalog, name) do
        {:ok, descriptor} ->
          prepare_provider(
            request,
            workflow_bundle,
            mission_bundles,
            descriptor,
            name,
            Map.get(selection, "config", %{}),
            occurrence,
            prepared
          )

        :error ->
          {:ok, subject} = CommandSubject.provider(name, :declaration, occurrence)

          {:halt,
           {:error, diagnostic(:provider_declaration, :provider_unknown, subject: subject)}}
      end
    end)
    |> reverse_success()
  end

  defp prepare_provider(
         request,
         workflow_bundle,
         mission_bundles,
         descriptor,
         name,
         config,
         occurrence,
         prepared
       ) do
    with :ok <- validate_placement(descriptor, name, occurrence),
         selection_context <-
           selection_context(
             request,
             workflow_bundle,
             mission_bundles,
             descriptor,
             name,
             occurrence
           ),
         {:ok, normalized} <-
           SelectionRules.explain(descriptor.selection_rules, config, request.package.limits) do
      declaration = %{
        name: name,
        destination: occurrence.destination,
        index: occurrence.index,
        descriptor: descriptor,
        config: normalized,
        validation_state:
          if(descriptor.selection_validation == :active,
            do: :active_required,
            else: :declarative
          ),
        selection_context: selection_context
      }

      {:cont, {:ok, [declaration | prepared]}}
    else
      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:halt, {:error, diagnostic}}

      {:error, reason} ->
        {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)

        {:halt,
         {:error,
          diagnostic(
            :provider_declaration,
            :selection_invalid,
            [subject: subject] ++ selection_invalid_message(reason)
          )}}
    end
  end

  defp validate_placement(descriptor, name, occurrence) do
    if occurrence.destination in descriptor.destinations do
      :ok
    else
      {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)
      {:error, diagnostic(:provider_declaration, :placement_denied, subject: subject)}
    end
  end

  defp selection_context(
         request,
         workflow_bundle,
         mission_bundles,
         descriptor,
         name,
         occurrence
       ) do
    %{
      display: ProviderDescriptor.display_projection(descriptor, name),
      application_content_digest: request.package.application_content_digest,
      bundle_hashes: %{
        workflow: workflow_bundle.hash,
        missions: mission_bundle_hashes(mission_bundles)
      },
      input_authority_class: request.input.authority,
      execution_scope_id: make_ref(),
      destination: occurrence.destination,
      index: occurrence.index,
      limits: request.package.limits
    }
  end

  defp derive_provider_plan(request, workflow_bundle, mission_bundles, declarations) do
    case ProviderPlan.derive(request, workflow_bundle, mission_bundles, declarations) do
      {:ok, derived} ->
        {:ok, derived}

      {:error, {:dependency_invalid, nil}} ->
        {:error, diagnostic(:provider_declaration, :dependency_invalid)}

      {:error, {:dependency_invalid, declaration}} ->
        {:ok, subject} = CommandSubject.provider(declaration.name, :declaration)
        {:error, diagnostic(:provider_declaration, :dependency_invalid, subject: subject)}

      {:error, {:data_policy_denied, declaration}} ->
        occurrence = %{destination: declaration.destination, index: declaration.index}
        {:ok, subject} = CommandSubject.provider(declaration.name, :selection, occurrence)
        {:error, diagnostic(:provider_declaration, :data_policy_denied, subject: subject)}
    end
  end

  defp add_post_selection_context(declarations, context) do
    Enum.map(declarations, fn declaration ->
      Map.update!(declaration, :selection_context, &Map.merge(&1, context))
    end)
  end

  defp prepared_declarations(declarations) do
    Enum.map(declarations, fn declaration ->
      %{
        name: declaration.name,
        destination: declaration.destination,
        index: declaration.index,
        config: declaration.config,
        validation_state: declaration.validation_state,
        selection_context: declaration.selection_context,
        provider_projection:
          ProviderDescriptor.public_projection(
            declaration.descriptor,
            declaration.name,
            declaration.config
          )
      }
    end)
  end

  defp provider_specs(providers) do
    for destination <- [:workflow, :mission],
        {selection, index} <- providers |> Map.fetch!(destination) |> Enum.with_index(),
        do: {destination, selection, index}
  end

  defp reverse_success({:ok, declarations}), do: {:ok, Enum.reverse(declarations)}
  defp reverse_success({:error, _diagnostic} = error), do: error

  @spec validation_result(PreparedRun.t()) ::
          {:ok, map()}
          | {:error, :invalid_prepared_run}
          | {:error, {:selection_unverifiable, binary(), CommandSubject.occurrence()}}
  @doc "Projects the closed validation-success result from one sealed preparation."
  def validation_result(%PreparedRun{} = prepared) do
    cond do
      not PreparedRun.valid?(prepared) or
          ProviderActivity.value(prepared.provider_activity) != false ->
        {:error, :invalid_prepared_run}

      declaration = first_active_declaration(prepared.provider_declarations) ->
        {:error,
         {:selection_unverifiable, declaration.name,
          %{destination: declaration.destination, index: declaration.index}}}

      true ->
        {:ok,
         %{
           "application_content_digest" =>
             "sha256:" <> prepared.request.package.application_content_digest,
           "effective_application_digest" => prepared.effective_application_digest,
           "workflow_bundle_hash" => prepared.workflow_bundle.hash,
           "mission_bundle_hashes" => mission_bundle_hashes(prepared.mission_bundles),
           "mission_grants" => mission_grants(prepared),
           "provider_activity" => false
         }}
    end
  end

  defp mission_grants(%PreparedRun{} = prepared) do
    providers = prepared.request.package.providers.mission

    Map.new(prepared.request.package.missions, fn {name, mission} ->
      provider_names =
        Enum.map(mission.provider_occurrences, fn index ->
          providers |> Enum.at(index) |> Map.fetch!("name")
        end)

      {name,
       MissionInventory.grant_summary(
         mission.data,
         Map.get(prepared.mission_bundles, name),
         provider_names
       )}
    end)
  end

  defp first_active_declaration(declarations) do
    declarations
    |> Enum.filter(&(&1.validation_state == :active_required))
    |> Enum.sort_by(fn declaration ->
      {declaration.name, destination_rank(declaration.destination), declaration.index}
    end)
    |> List.first()
  end

  defp destination_rank(:workflow), do: 0
  defp destination_rank(:mission), do: 1

  defp mission_bundle_hashes(bundles),
    do: Map.new(bundles, fn {name, bundle} -> {name, bundle && bundle.hash} end)

  defp diagnostic(phase, code, opts \\ []),
    do: CommandDiagnostic.new!(phase, code, opts)

  defp selection_invalid_message(reason) do
    case SelectionRulesDiagnostic.message(reason) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end
end
