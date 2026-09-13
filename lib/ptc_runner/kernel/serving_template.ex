defmodule PtcRunner.Kernel.ServingTemplate do
  @moduledoc """
  Compile-once, provider-free application template for transport-neutral hosting.

  `from_directory(manifest_path, installed_limits, opts \\\\ [])` returns
  `{:ok, template}` or `{:error, build_code}`. `installed_limits` is a complete
  valid `PtcRunner.Kernel.Limits` value. The only option is
  `:expected_application_content_digest`, a `sha256:<64 lowercase hex>` pin.
  Unknown or duplicate options, and malformed pins, fail before acquisition.
  The pin compares content only, never effective identity.

  Construction captures the directory closure once, compiles its workflow and
  mission bundles and object value contracts once, and assembles the complete
  runnable environment before validating effects. Exactly one callable workflow
  entry is required. Its declaration must be `read` or `write`. Declared read
  requires the complete grant resolved by `PtcRunner.Kernel.EntryEffect` to be
  read; declared write remains write even with unknown grant components.
  Manifest-owned event IDs and any selected providers are rejected.

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
  No providers, HTTP dependencies or artifact destinations are involved.

  ## Safe metadata

  `input_schema/1` and `output_schema/1` return exactly the normalized schemas
  retained by the compiled input and result validators, including root tagged
  unions of objects. `PtcRunner.Kernel.DeterministicJSON.encode/1` encodes them
  deterministically. `effect/1` returns the validated `:read` or `:write`.
  `application_content_digest/1`, `effective_application_digest/1`, and all
  values of `installation_config_digests/1` use qualified SHA-256. The latter
  map is empty for this provider-free surface. `limits/1` returns the resolved
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

  ## Ownership and close

  Templates are opaque, immutable, process-independent values concurrently
  shareable across processes. They retain no selected `ExecutionInput`,
  `ExecutionPolicy`, provider activity, sink, publication authority, run or trace
  identity, PID, reference, callback, or file handle. Acquisition closes its
  temporary document source on success and failure. Its resource-free placeholder
  input is discarded. No `PreparedRun` or one-shot owner is created.
  `close(template)` returns `:ok` and is an idempotent no-op: it releases no owned
  resource and does not invalidate other copies. Drop all copies to reclaim memory.

  ## Closed build codes

  Errors contain only one atom, with no paths, payloads or private reasons:
  `:invalid_options`, `:invalid_installed_limits`, `:invalid_application`,
  `:contracts_required`, `:entry_invalid`, `:manifest_identity_forbidden`,
  `:provider_runtime_required`, `:private_result_unservable`, `:application_content_digest_mismatch`,
  `:compilation_failed`, `:environment_invalid`, `:effect_declaration_required`,
  `:declared_read_effect_violation`, or `:internal_error`.
  Acquisition failures, including invalid contracts/declarations or document
  bounds, collapse to `:invalid_application`. Compiler failures collapse to
  `:compilation_failed`. Unexpected construction exceptions become `:internal_error`.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.DeclaredReadEffectValidator
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.EntryEffect
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.ServingCall
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [:package, :workflow, :missions, :effect, :effective_digest, :policy]
  defstruct @enforce_keys

  @typedoc "An immutable compiled application with no owned execution resources."
  @opaque t :: %__MODULE__{
            package: ApplicationPackage.t(),
            workflow: PtcRunner.Kernel.WorkflowEnvironment.t(),
            missions: map(),
            effect: :read | :write,
            effective_digest: binary(),
            policy: map()
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
          | :provider_runtime_required
          | :application_content_digest_mismatch
          | :compilation_failed
          | :environment_invalid
          | :effect_declaration_required
          | :declared_read_effect_violation
          | :internal_error

  @doc "Acquires and compiles one immutable provider-free directory template."
  @spec from_directory(binary(), Limits.t(), keyword()) :: {:ok, t()} | {:error, build_code()}
  def from_directory(path, installed_limits, opts \\ []) do
    with :ok <- options(opts),
         true <- Limits.valid?(installed_limits),
         {:ok, package} <- acquire(path, installed_limits),
         :ok <- package_rules(package, opts) do
      construct(package)
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

  @doc "Returns content identity, independent of selected input and effective hosting policy."
  @spec application_content_digest(t()) :: binary()
  def application_content_digest(%__MODULE__{package: package}),
    do: "sha256:" <> package.application_content_digest

  @doc "Returns the existing effective identity with frozen hosting policy."
  @spec effective_application_digest(t()) :: binary()
  def effective_application_digest(%__MODULE__{effective_digest: digest}), do: digest

  @doc "Returns selected installation configuration digests (empty without providers)."
  @spec installation_config_digests(t()) :: %{binary() => binary()}
  def installation_config_digests(%__MODULE__{}), do: %{}

  @doc "Returns effective limits resolved against installed ceilings."
  @spec limits(t()) :: Limits.t()
  def limits(%__MODULE__{package: package}), do: package.limits

  @doc "Returns frozen event, projection, inspection, publication and absolute-deadline rules."
  @spec policy(t()) :: map()
  def policy(%__MODULE__{policy: policy}), do: policy

  @doc "Reserves a validated complete JSON input without creating execution resources."
  @spec reserve(t(), term(), pid(), integer() | :infinity) ::
          {:ok, reservation()} | ServingOutcome.t()
  def reserve(template, input, admission, deadline \\ :infinity),
    do: ServingCall.reserve(template, input, admission, deadline)

  @doc "Activates after transport commitment and finishes publication in this calling worker."
  @spec activate(reservation()) ::
          ServingOutcome.t()
  def activate(reservation), do: ServingCall.activate(reservation)

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
         Keyword.keys(opts) in [[], [:expected_application_content_digest]] and
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
      package.providers.workflow != [] or package.providers.mission != [] ->
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

  defp construct(package) do
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
