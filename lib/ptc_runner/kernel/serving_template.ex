defmodule PtcRunner.Kernel.ServingTemplate do
  @moduledoc """
  Compile-once application template for transport-neutral hosting.

  `from_directory(manifest_path, installed_limits, opts \\\\ [])` returns
  `{:ok, template}` or `{:error, build_code}`. `installed_limits` is a complete
  valid `PtcRunner.Kernel.Limits` value. Options are
  `providers: %InstallationCatalog{}` for provider-bearing packages and
  `:expected_application_content_digest`, a `sha256:<64 lowercase hex>` pin.
  Unknown or duplicate options, and malformed pins, fail before acquisition.
  The pin compares content only, never effective identity.

  Construction captures the directory closure once, compiles its workflow and
  mission bundles and object value contracts once, and validates declared effects.
  Provider-free construction also assembles the complete runnable environment.
  Exactly one callable workflow
  entry is required. Its declaration must be `read` or `write`. Declared read
  requires the complete grant resolved by `PtcRunner.Kernel.EntryEffect` to be
  read; declared write remains write even with unknown grant components.
  Manifest-owned event IDs are rejected. Selected providers require the explicit
  `:providers` catalog, valid and bound to the supplied installed limits; otherwise
  construction refuses with `:provider_runtime_required` or
  `:invalid_installation_catalog`. Provider-free packages ignore this option.

  The required manifest input declaration is shape-validated, but its referenced
  file is never opened and its value is never contract-validated. Ordinary
  command acquisition still requires and validates selected input. Per-call
  input is supplied to `reserve/4`; this constructor never dispatches execution.

  ## Calls

  `reserve(template, json_object, admission_pid, deadline \\\\ :infinity)` returns
  `{:ok, reservation}` or a `ServingOutcome`. Input is a complete
  JSON object, validated before admission. `deadline` is an absolute monotonic
  millisecond integer. Invalid deadlines return `:internal_error`; expired
  deadlines return `:cancelled`. No input/policy seal, identity, activity,
  authority, sink or execution owner is created by a reservation.

  After the transport commits its response, the same reserving worker calls
  `activate(reservation)` and receives one closed ServingOutcome. Activation
  is single-use, creates fresh one-shot resources, and performs sealed outcome
  opening and artifact-free publication in that worker. Capacity remains held
  through publication and authority cleanup. Caller death cancels execution;
  death during publication fences admission because cleanup is uncertain.
  Deadlines remain active through publication, which cannot publish a successful
  outcome after expiry. Cleanup uncertainty outranks cancellation and fences
  admission. See ServingOutcome for exhaustive codes, metadata and precedence.

  `close(reservation)` returns `:ok` or `{:error, :run_admission_unavailable}`.
  Call it if response commitment fails: unused capacity is released without
  dispatch. Closed/expired/foreign/reused reservations cannot activate; closed
  reservations return `:admission_unavailable` (expired ones `:cancelled`).
  Active cancellation requests stop execution and does not undo possible writes.
  `call(template, json_object, admission_pid, deadline \\\\ :infinity)` reserves
  and activates immediately; use it when no transport commitment is needed.
  The host starts RunAdmission under its supervisor and bounds inbound workers.
  Provider-bearing templates must first be bound with `with_provider_runtime/2`.

  ## Safe metadata

  `input_schema/1` and `output_schema/1` return exactly the normalized schemas
  retained by the compiled input and result validators, including root tagged
  unions of objects. `PtcRunner.Kernel.DeterministicJSON.encode/1` encodes them
  deterministically. `effect/1` returns the validated `:read` or `:write`.
  `application_content_digest/1`, `effective_application_digest/1`, and all
  values of `installation_config_digests/1` use qualified SHA-256. The latter
  map contains the real selected installation identities, and is empty without
  providers. `limits/1` returns the resolved
  effective limits; `policy/1` returns the frozen non-owning hosting rules.

  ## Limits and deadlines

  Manifest-narrowable limits are resolved against the supplied installed ceilings
  by the ordinary manifest loader; installed-only limits remain unchanged.
  Bundle compilation shares one absolute monotonic deadline of five seconds
  and the ordinary aggregate 4,000,000-byte compiled-artifact bound.
  Acquisition is capped at 512 documents and 8 MiB of captured bytes; content
  framing is independently capped at 8 MiB. Normalized contracts are capped
  at 64 KiB each. The bounded compiler also enforces its standard component,
  dependency, source-byte and worker-heap limits.
  The frozen call rule is one absolute monotonic millisecond deadline, computed
  at reservation as the minimum of the caller deadline and reservation time plus
  `limits.run_duration_ms`. Admission, activation, execution and publication
  share that deadline; it is never reset at activation. No absolute timestamp is
  stored in the template.

  Private event policy is rejected with `:private_result_unservable`; event
  policy for accepted templates and input authority are
  normal, result projection is JSON, inspection capture is disabled, and
  publication is artifact-free. None of these choices is a per-call override.
  The private refusal is the decided contract rather than an unimplemented
  destination: serving authorizes no artifact destination at all, so a private
  policy has no private result to place, and possessing a serving template must
  not become an implicit override of it. Serve such an application by setting its
  manifest policy to normal and pinning the application content digest that
  change produces.

  ## Ownership and close

  Templates are opaque, immutable values concurrently shareable across processes.
  Provider-bearing construction retains the sealed catalog, frozen policy and
  complete inert preparation metadata, including selection scope references.
  Its temporary ProviderActivity is closed before construction returns. No
  selected input, acquired capability, sink or execution owner is retained.
  Provider-bearing templates cache bundles without assembled environments;
  actual capabilities are required by environment validation, so assembly occurs
  when a borrowed run is built. The coordinator validates declared effects
  during construction. Catalog implementations remain internal, excluded from
  inspection and the safe metadata API. Acquisition closes its temporary
  document source on success and failure and discards its placeholder input.
  `prepare_call/2` seals a real RunRequest from cached bundles and complete
  metadata without recompilation or provider callbacks. ProviderRuntime owns
  acquisition; ServingCall borrows it with the reservation's unchanged deadline.
  `close(template)` returns `:ok` and is an idempotent no-op: it releases no owned
  resource and does not invalidate other copies. Drop all copies to reclaim memory.

  ## Closed build codes

  Errors contain only one atom, with no paths, payloads or private reasons:
  `:invalid_options`, `:invalid_installed_limits`, `:invalid_application`,
  `:contracts_required`, `:entry_invalid`, `:manifest_identity_forbidden`,
  `:provider_runtime_required`, `:invalid_installation_catalog`,
  `:private_result_unservable`, `:application_content_digest_mismatch`,
  `:compilation_failed`, `:environment_invalid`, `:effect_declaration_required`,
  `:declared_read_effect_violation`, or `:internal_error`.
  Acquisition failures, including invalid contracts/declarations or document
  bounds, collapse to `:invalid_application`. Compiler failures collapse to
  `:compilation_failed`. Assembled-environment failures (including missing required
  capabilities) become `:environment_invalid`. Effective-identity failures and
  unexpected construction exceptions, throws or exits become `:internal_error`.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.DeclaredReadEffectValidator
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.EntryEffect
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.ProviderRuntime
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ServingCall
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingRequest
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [:package, :workflow, :missions, :effect, :effective_digest, :policy]
  @derive {Inspect, only: [:effect, :effective_digest, :policy]}
  defstruct @enforce_keys ++
              [retained: nil, installation_digests: %{}, provider_runtime: nil, warm_runtime: nil]

  @typedoc "An immutable compiled application with no owned execution resources."
  @opaque t :: %__MODULE__{
            package: ApplicationPackage.t(),
            workflow:
              PtcRunner.Kernel.WorkflowEnvironment.t()
              | %{bundle: PtcRunner.Kernel.FrozenBundle.t()},
            missions: map(),
            effect: :read | :write,
            effective_digest: binary(),
            policy: map(),
            retained: map() | nil,
            installation_digests: map(),
            provider_runtime: pid() | nil,
            warm_runtime: pid() | nil
          }
  @typedoc "Single-use capacity reservation owned by its calling worker."
  @type reservation :: ServingCall.reservation()

  @typedoc "Closed construction failures containing no private detail."
  @type build_code ::
          :invalid_options
          | :invalid_installed_limits
          | :invalid_application
          | :contracts_required
          | :entry_invalid
          | :manifest_identity_forbidden
          | :private_result_unservable
          | :invalid_installation_catalog
          | :provider_runtime_required
          | :application_content_digest_mismatch
          | :compilation_failed
          | :environment_invalid
          | :effect_declaration_required
          | :declared_read_effect_violation
          | :internal_error

  @doc "Acquires and compiles one immutable directory template without selected input."
  @spec from_directory(binary(), Limits.t(), keyword()) :: {:ok, t()} | {:error, build_code()}
  def from_directory(path, installed_limits, opts \\ []) do
    with :ok <- options(opts),
         true <- Limits.valid?(installed_limits),
         {:ok, package} <- acquire(path, installed_limits),
         :ok <- package_rules(package, opts) do
      construct(package, opts)
    else
      false -> {:error, :invalid_installed_limits}
      {:error, _code} = error -> error
    end
  rescue
    _exception -> {:error, :internal_error}
  catch
    _kind, _reason -> {:error, :internal_error}
  end

  @doc "Returns the compiled normalized object input schema."
  @spec input_schema(t()) :: map()
  def input_schema(%__MODULE__{package: package}), do: package.contracts.input.schema

  @doc "Returns the compiled normalized object result schema."
  @spec output_schema(t()) :: map()
  def output_schema(%__MODULE__{package: package}), do: package.contracts.result.schema

  @doc "Returns the validated declaration, widened by the complete grant for read entries."
  @spec effect(t()) :: :read | :write
  def effect(%__MODULE__{effect: effect}), do: effect

  @doc "Returns an invalid-result outcome preserving the call's dispatch metadata."
  @spec invalid_result(t(), ServingOutcome.t()) :: ServingOutcome.t()
  def invalid_result(%__MODULE__{} = template, outcome) do
    ServingOutcome.new(
      :invalid_result,
      ServingOutcome.metadata(outcome).dispatched,
      template.effect
    )
  end

  @doc "Returns content identity, independent of selected input and effective hosting policy."
  @spec application_content_digest(t()) :: binary()
  def application_content_digest(%__MODULE__{package: package}),
    do: "sha256:" <> package.application_content_digest

  @doc "Returns the existing effective identity with frozen hosting policy."
  @spec effective_application_digest(t()) :: binary()
  def effective_application_digest(%__MODULE__{effective_digest: digest}), do: digest

  @doc "Returns selected installation configuration digests (empty without providers)."
  @spec installation_config_digests(t()) :: %{binary() => binary()}
  def installation_config_digests(%__MODULE__{installation_digests: digests}), do: digests

  @doc "Returns effective limits resolved against installed ceilings."
  @spec limits(t()) :: Limits.t()
  def limits(%__MODULE__{package: package}), do: package.limits

  @doc "Returns frozen event, projection, inspection, publication and absolute-deadline rules."
  @spec policy(t()) :: map()
  def policy(%__MODULE__{policy: policy}), do: policy

  @doc "Binds a provider-bearing template to its ready, exact warm runtime."
  @spec with_provider_runtime(t(), pid()) :: {:ok, t()} | {:error, :provider_runtime_mismatch}
  def with_provider_runtime(%__MODULE__{} = template, runtime) do
    if ProviderRuntime.matches_template?(runtime, template),
      do: {:ok, %{template | provider_runtime: runtime}},
      else: {:error, :provider_runtime_mismatch}
  end

  def with_provider_runtime(_, _), do: {:error, :provider_runtime_mismatch}

  @doc "Reserves a validated complete JSON input without creating execution resources."
  @spec reserve(t(), term(), pid(), integer() | :infinity) ::
          {:ok, reservation()} | ServingOutcome.t()
  def reserve(template, input, admission, deadline \\ :infinity),
    do: ServingCall.reserve(template, input, admission, deadline)

  @doc "Activates after transport commitment and finishes publication in this calling worker."
  @spec activate(reservation()) ::
          ServingOutcome.t()
  def activate(reservation), do: ServingCall.activate(reservation)

  @doc false
  @spec activate(reservation(), map()) :: ServingOutcome.t()
  def activate(reservation, hooks) when is_map(hooks),
    do: ServingCall.activate(reservation, hooks)

  @doc """
  Activates a reserved transport call and retains admission through terminal publication and audit.

  `close_outcome` may replace the execution outcome with a bounded wire-safe
  outcome. Admission then atomically freezes cancellation, deadline and cleanup
  state before `publish` performs the transport's one terminal publication.
  `publish` returns `:ok` when publication or a positively observed disconnect
  is clean. Its failure becomes `:publication_failed` only when the frozen
  outcome is lower precedence; cancellation and uncertain cleanup remain
  authoritative. `audit` receives that final outcome and must durably finish
  before capacity is released. Audit or admission-release failure closes as
  uncertain cleanup and fences new admission.
  """
  @spec activate_transport(
          reservation(),
          (ServingOutcome.t() -> ServingOutcome.t()),
          (ServingOutcome.t() -> :ok | {:error, term()}),
          (ServingOutcome.t() -> :ok | {:error, term()})
        ) :: ServingOutcome.t()
  def activate_transport(reservation, close_outcome, publish, audit)
      when is_function(close_outcome, 1) and is_function(publish, 1) and is_function(audit, 1) do
    ServingCall.activate(reservation, %{
      close_outcome: close_outcome,
      before_release: publish,
      before_release_audit: audit
    })
  end

  @doc "Requests cancellation of a transport-owned reservation after client disconnect."
  @spec cancel_external(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def cancel_external(reservation), do: ServingCall.cancel_external(reservation)

  @doc "Reserves and activates immediately for transports that need no commitment handshake."
  @spec call(t(), term(), pid(), integer() | :infinity) :: ServingOutcome.t()
  def call(template, input, admission, deadline \\ :infinity) do
    case reserve(template, input, admission, deadline) do
      {:ok, reservation} -> activate(reservation)
      outcome -> outcome
    end
  end

  @doc "Closes a resource-free template; an idempotent no-op that leaves copies usable."
  @spec close(t() | reservation()) ::
          :ok | {:error, :run_admission_unavailable}
  def close(%__MODULE__{}), do: :ok
  def close(reservation), do: ServingCall.close(reservation)

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:providers, :expected_application_content_digest] == [] and
         length(opts) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
         (not Keyword.has_key?(opts, :expected_application_content_digest) or
            InstallationConfigDigest.valid_digest?(opts[:expected_application_content_digest])),
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp acquire(path, limits) do
    case ApplicationPackage.acquire_directory(path, installed_limits: limits, omit_input: true) do
      {:ok, package, _discarded_input} -> {:ok, package}
      {:error, _reason} -> {:error, :invalid_application}
    end
  end

  defp package_rules(package, opts) do
    cond do
      provider_bearing?(package) and not Keyword.has_key?(opts, :providers) ->
        {:error, :provider_runtime_required}

      package.events.policy == :private ->
        {:error, :private_result_unservable}

      package.events.run_id != nil or package.events.trace_id != nil ->
        {:error, :manifest_identity_forbidden}

      not match?(%ValueContract{}, package.contracts.input) or
          not match?(%ValueContract{}, package.contracts.result) ->
        {:error, :contracts_required}

      Keyword.has_key?(opts, :expected_application_content_digest) and
          opts[:expected_application_content_digest] !=
            "sha256:" <> package.application_content_digest ->
        {:error, :application_content_digest_mismatch}

      true ->
        :ok
    end
  end

  defp construct(package, opts) do
    if provider_bearing?(package),
      do: construct_retained(package, opts[:providers]),
      else: construct_free(package)
  end

  defp provider_bearing?(package),
    do: package.providers.workflow != [] or package.providers.mission != []

  defp construct_free(package) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with {:ok, bundle} <- compile(package.workflow_components, deadline),
         {:ok, bundles} <- compile_missions(package, bundle, deadline),
         :ok <- entry_valid(bundle, package),
         {:ok, workflow, missions} <- assemble(package, bundle, bundles),
         {:ok, effect} <- validate_effect(workflow, missions, package.entry),
         policy = %{
           input_authority_class: :normal,
           inspection_capture: false,
           result_projection: :json,
           effective_event_policy: package.events.policy,
           publication: :artifact_free,
           deadline: :absolute_from_reservation
         },
         {:ok, identity} <-
           EffectiveApplication.build_package(
             package,
             bundle,
             bundles,
             %{workflow: [], mission: []},
             policy
           ) do
      {:ok,
       %__MODULE__{
         package: package,
         workflow: workflow,
         missions: missions,
         effect: effect,
         effective_digest: identity.digest,
         policy: policy
       }}
    else
      {:error, :invalid_effective_application} -> {:error, :internal_error}
      {:error, _code} = error -> error
    end
  end

  @doc "Seals a per-call run from cached bundles and the complete prepared metadata."
  @spec prepare_call(t(), RunRequest.t()) :: {:ok, PreparedRun.t()} | {:error, term()}
  def prepare_call(%__MODULE__{} = template, %RunRequest{} = request) do
    if RunRequest.valid?(request) and request.package == template.package and
         request.input.authority == :normal and request.policy.result_projection == :json and
         not request.policy.inspection_capture and request.policy.event_policy == :normal do
      with {:ok, retained} <- retained_metadata(template, request) do
        seal_call(template, request, retained)
      end
    else
      {:error, :invalid_run_request}
    end
  end

  def prepare_call(_template, _request), do: {:error, :invalid_run_request}

  defp seal_call(template, request, retained) do
    ProviderActivity.start_owned(fn activity ->
      PreparedRun.new(
        request,
        template.workflow.bundle,
        Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
        "(#{template.package.entry} data/input)",
        activity,
        retained.catalog,
        retained.metadata
      )
    end)
  end

  @doc false
  @spec with_warm_runtime(t(), pid()) :: t()
  def with_warm_runtime(%__MODULE__{} = template, runtime) when is_pid(runtime),
    do: %{template | warm_runtime: runtime}

  @doc false
  @spec runtime_context(term()) :: map() | nil
  def runtime_context(%__MODULE__{} = template) do
    %{
      required?: not is_nil(template.retained),
      runtime: template.provider_runtime,
      warm_runtime: template.warm_runtime,
      identity: {template.effective_digest, template.installation_digests}
    }
  end

  def runtime_context(_), do: nil

  @doc false
  @spec provider_plan(term()) :: {:ok, map()} | {:error, :provider_runtime_required}
  def provider_plan(%__MODULE__{retained: nil}), do: {:error, :provider_runtime_required}

  def provider_plan(%__MODULE__{retained: %{reader: reader, attestation: attestation}} = template) do
    if Attestation.valid?(
         __MODULE__,
         {template.package, template.installation_digests, template.effective_digest, reader},
         attestation
       ) do
      {:ok,
       Map.merge(reader.(), %{
         workflow_bundle: template.workflow.bundle,
         mission_bundles:
           Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
         entry_source: "(#{template.package.entry} data/input)"
       })}
    else
      {:error, :provider_runtime_required}
    end
  end

  def provider_plan(_template), do: {:error, :provider_runtime_required}

  defp retain(package, digests, effective_digest, state) do
    reader = fn -> state end

    %{
      reader: reader,
      attestation: Attestation.attest(__MODULE__, {package, digests, effective_digest, reader})
    }
  end

  defp retained_metadata(%__MODULE__{retained: retained} = template, _request)
       when not is_nil(retained),
       do: provider_plan(template)

  defp retained_metadata(template, request) do
    with {:ok, catalog} <-
           InstallationCatalog.new(%{}, installed_limits: template.package.installed_limits),
         {:ok, metadata} <-
           ProviderPlan.derive(
             request,
             template.workflow.bundle,
             Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
             []
           ) do
      {:ok,
       %{
         catalog: catalog,
         metadata:
           Map.merge(metadata, %{provider_declarations: [], installation_config_digests: %{}})
       }}
    end
  end

  defp construct_retained(package, catalog) do
    if InstallationCatalog.valid?(catalog) and
         catalog.installed_limits == package.installed_limits do
      with {:ok, policy} <-
             ExecutionPolicy.new(event_policy: package.events.policy, result_projection: :json),
           {:ok, request} <- ServingRequest.new(package, policy),
           {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
        try do
          metadata =
            Map.take(prepared, [
              :provider_declarations,
              :installation_config_digests,
              :effective_data_class,
              :effective_flow,
              :effective_event_policy,
              :effective_application_projection,
              :effective_application_digest,
              :post_selection_context
            ])

          entry = Enum.find(prepared.workflow_bundle.prelude.exports, &(&1.ref == package.entry))

          if entry.declared_effect in [:read, :write] do
            {:ok,
             %__MODULE__{
               package: package,
               workflow: %{bundle: prepared.workflow_bundle},
               missions:
                 Map.new(prepared.mission_bundles, fn {name, bundle} ->
                   {name, %{bundle: bundle}}
                 end),
               effect: entry.declared_effect,
               effective_digest: prepared.effective_application_digest,
               policy: %{
                 input_authority_class: :normal,
                 inspection_capture: false,
                 result_projection: :json,
                 effective_event_policy: :normal,
                 publication: :artifact_free,
                 deadline: :absolute_from_reservation
               },
               installation_digests: prepared.installation_config_digests,
               retained:
                 retain(
                   package,
                   prepared.installation_config_digests,
                   prepared.effective_application_digest,
                   %{catalog: catalog, metadata: metadata, request: request}
                 )
             }}
          else
            {:error, :effect_declaration_required}
          end
        after
          PreparedRun.close(prepared)
        end
      else
        {:error, %CommandDiagnostic{} = diagnostic} ->
          {:error, preparation_build_code(diagnostic)}

        {:error, :private_result_unservable} = error ->
          error

        _invalid ->
          {:error, :internal_error}
      end
    else
      {:error, :invalid_installation_catalog}
    end
  end

  defp preparation_build_code(%CommandDiagnostic{code: :declared_read_effect_invalid}),
    do: :declared_read_effect_violation

  defp preparation_build_code(%CommandDiagnostic{code: code})
       when code in [:entry_invalid, :mission_undeclared], do: :entry_invalid

  defp preparation_build_code(%CommandDiagnostic{code: :mission_capability_ungranted}),
    do: :environment_invalid

  defp preparation_build_code(%CommandDiagnostic{phase: :bundle}), do: :compilation_failed

  defp preparation_build_code(%CommandDiagnostic{phase: :provider_declaration}),
    do: :invalid_application

  defp preparation_build_code(_diagnostic), do: :internal_error

  defp compile(components, deadline) do
    case BundleCompiler.compile(components, deadline) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} -> {:error, :compilation_failed}
    end
  end

  defp compile_missions(package, bundle, deadline) do
    case BundleCompiler.compile_named(
           package.missions,
           deadline,
           :erlang.external_size(bundle),
           4_000_000,
           [{package.workflow_components, bundle}]
         ) do
      {:ok, bundles} -> {:ok, bundles}
      {:error, _reason} -> {:error, :compilation_failed}
    end
  end

  defp entry_valid(bundle, package) do
    with :ok <- RunCoordinator.validate_entry(bundle, package.entry),
         :ok <- RunCoordinator.validate_entry_missions(bundle, package.entry, package.missions) do
      :ok
    else
      {:error, _reason} -> {:error, :entry_invalid}
    end
  end

  defp assemble(package, bundle, bundles) do
    case RunBuilder.assemble_environments(package, bundle, bundles, %{
           workflow: %{capabilities: []},
           mission: %{by_occurrence: %{}}
         }) do
      {:ok, workflow, missions} -> {:ok, workflow, missions}
      {:error, _reason} -> {:error, :environment_invalid}
    end
  end

  defp validate_effect(workflow, missions, entry_ref) do
    entry = Enum.find(workflow.bundle.prelude.exports, &(&1.ref == entry_ref))
    resolved = EntryEffect.resolve(%{workflow: workflow, missions: missions}, entry)

    validation =
      DeclaredReadEffectValidator.validate_assembled(
        workflow,
        missions,
        resolved.capability_effects
      )

    cond do
      entry.declared_effect not in [:read, :write] ->
        {:error, :effect_declaration_required}

      validation != :ok or
          (entry.declared_effect == :read and resolved.effect != :read) ->
        {:error, :declared_read_effect_violation}

      true ->
        {:ok, entry.declared_effect}
    end
  end
end
