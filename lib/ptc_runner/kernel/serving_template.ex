defmodule PtcRunner.Kernel.ServingTemplate do
  @moduledoc """
  Compile-once application template for transport-neutral hosting.

  `from_directory(manifest_path, installed_limits, opts \\\\ [])` returns
  `{:ok, template}` or `{:error, build_code}`. `installed_limits` is a complete
  valid `PtcRunner.Kernel.Limits` value. Options are
  `providers: %InstallationCatalog{}` for provider-bearing packages and
  `:expected_application_content_digest`, a `sha256:<64 lowercase hex>` pin,
  and `:inspection_capture` for an operator-configured gateway artifact root.
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
  Selected OAuth MCP installations and workflow MCP catalog selections refuse
  with `:provider_runtime_unsupported` before credential capture or acquisition.

  The required manifest input declaration is shape-validated, but its referenced
  file is never opened and its value is never contract-validated. Ordinary
  command acquisition still requires and validates selected input. Per-call
  input is supplied to `reserve/4`; this constructor never dispatches execution.

  ## Calls

  `reserve(template, json_object, admission_pid, deadline \\\\ :infinity)` returns
  `{:ok, reservation}` or a `ServingOutcome`. Input is a complete
  JSON object, validated before admission. `deadline` is an absolute monotonic
  millisecond integer. Invalid deadlines return `:internal_error`; expired
  deadlines return `:cancelled`. A reservation fixes a fresh command run
  reference but creates no input/policy seal, activity, authority, sink or
  execution owner.

  After the transport commits its response, the same reserving worker calls
  `activate(reservation)` and receives one closed ServingOutcome. Activation
  is single-use, creates fresh one-shot resources, and performs sealed outcome
  opening and publication in that worker. Capacity remains held
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
  Warm provider-bearing templates must first be bound with `with_provider_runtime/2`.
  Templates selecting only normal trace snapshots instead bind host-owned services
  with `with_cold_services/2`; activation acquires and cleans up a fresh capture
  for each run. Mixed snapshot/live selections and private snapshot sources are
  refused with `:provider_runtime_unsupported` before acquisition.

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
  normal and result projection is JSON. Ordinary template calls capture no
  inspection data and publish no artifacts. A gateway operator may configure
  normal trace and inspection destinations for all tools; the gateway reserves
  them before execution. Possessing a serving template or an endpoint grants
  no private-result override. Serve such an application by setting its manifest
  policy to normal and pinning the application content digest that change produces.

  ## Ownership and close

  Templates are opaque, immutable values concurrently shareable across processes.
  Provider-bearing construction retains the sealed catalog, frozen policy and
  complete inert preparation metadata, including selection scope references.
  Its temporary ProviderActivity is closed before construction returns. No
  selected input, acquired capability, sink or execution owner is retained.
  Provider-bearing templates cache bundles without assembled environments;
  actual capabilities are required by environment validation, so assembly occurs
  when a borrowed run is built. The coordinator validates declared effects
  during construction, including the complete grant resolved from inert provider
  declarations before acquisition. Catalog implementations remain internal,
  excluded from
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
  `:provider_runtime_required`, `:provider_runtime_unsupported`, `:invalid_installation_catalog`,
  `:private_result_unservable`, `:application_content_digest_mismatch`,
  `:compilation_failed`, `:environment_invalid`, `:effect_declaration_required`,
  `:declared_read_effect_violation`, or `:internal_error`.
  Acquisition failures, including invalid contracts/declarations or document
  bounds, collapse to `:invalid_application`. Compiler failures collapse to
  `:compilation_failed`. Assembled-environment failures (including missing required
  capabilities) become `:environment_invalid`. Effective-identity failures and
  unexpected construction exceptions, throws or exits become `:internal_error`.
  """

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRuntime
  alias PtcRunner.Kernel.ServingCall
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingPlan

  @opaque t :: ServingPlan.t()
  @type reservation :: ServingCall.reservation()
  @type build_code :: ServingPlan.build_code()

  @doc "Acquires and compiles one immutable directory template without selected input."
  @spec from_directory(binary(), Limits.t(), keyword()) ::
          {:ok, t()} | {:error, build_code()}
  def from_directory(path, installed_limits, opts \\ []),
    do: ServingPlan.from_directory(path, installed_limits, opts)

  @doc "Returns the compiled normalized object input schema."
  @spec input_schema(t()) :: map()
  defdelegate input_schema(template), to: ServingPlan
  @doc "Returns the compiled normalized object result schema."
  @spec output_schema(t()) :: map()
  defdelegate output_schema(template), to: ServingPlan
  @doc "Returns the validated declaration, widened by the complete grant for read entries."
  @spec effect(t()) :: :read | :write
  defdelegate effect(template), to: ServingPlan
  @doc "Returns an invalid-result outcome preserving the call's dispatch metadata."
  @spec invalid_result(t(), ServingOutcome.t()) :: ServingOutcome.t()
  defdelegate invalid_result(template, outcome), to: ServingPlan
  @doc "Returns content identity, independent of selected input and effective hosting policy."
  @spec application_content_digest(t()) :: binary()
  defdelegate application_content_digest(template), to: ServingPlan
  @doc "Returns the existing effective identity with frozen hosting policy."
  @spec effective_application_digest(t()) :: binary()
  defdelegate effective_application_digest(template), to: ServingPlan
  @doc "Returns selected installation configuration digests (empty without providers)."
  @spec installation_config_digests(t()) :: %{binary() => binary()}
  defdelegate installation_config_digests(template), to: ServingPlan
  @doc "Returns effective limits resolved against installed ceilings."
  @spec limits(t()) :: Limits.t()
  defdelegate limits(template), to: ServingPlan
  @doc "Returns frozen event, projection, inspection, publication and absolute-deadline rules."
  @spec policy(t()) :: map()
  defdelegate policy(template), to: ServingPlan
  @doc false
  defdelegate prepare_call(template, request), to: ServingPlan
  @doc false
  defdelegate with_warm_runtime(template, runtime), to: ServingPlan
  @doc false
  defdelegate cold?(template), to: ServingPlan
  @doc false
  defdelegate with_cold_services(template, services), to: ServingPlan
  @doc false
  defdelegate runtime_context(template), to: ServingPlan
  @doc false
  defdelegate provider_plan(template), to: ServingPlan
  @doc false
  defdelegate credential_names(template), to: ServingPlan

  @doc "Binds a provider-bearing template to its ready, exact warm runtime."
  @spec with_provider_runtime(t(), pid()) :: {:ok, t()} | {:error, :provider_runtime_mismatch}
  def with_provider_runtime(%ServingPlan{} = template, runtime) do
    if ProviderRuntime.matches_template?(runtime, template),
      do: {:ok, %{template | provider_runtime: runtime}},
      else: {:error, :provider_runtime_mismatch}
  end

  def with_provider_runtime(_, _), do: {:error, :provider_runtime_mismatch}

  @doc "Reserves a validated complete JSON input without creating execution resources."
  @spec reserve(t(), term(), pid(), integer() | :infinity) ::
          {:ok, reservation()} | ServingOutcome.t()
  def reserve(template, input, admission, deadline \\ :infinity),
    do: ServingCall.reserve(template, input, admission, deadline, nil)

  @doc false
  def reserve_gateway(template, input, admission, artifacts),
    do: ServingCall.reserve(template, input, admission, :infinity, artifacts)

  @doc false
  def reservation_run_ref(reservation), do: ServingCall.run_ref(reservation)

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
  def close(%ServingPlan{}), do: :ok
  def close(reservation), do: ServingCall.close(reservation)
end
