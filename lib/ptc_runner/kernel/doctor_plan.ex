defmodule PtcRunner.Kernel.DoctorPlan do
  @moduledoc false

  # Deterministic doctor plan, in either mode.
  #
  # Every row comes from sealed declarations and the two supplied environment
  # facts. Nothing here activates a provider, resolves a credential, acquires a
  # resource, or opens a connection, so the plan is identical whether or not the
  # command later executes anything.
  #
  # The mode decides only which rows arrive unsettled. Default doctor performs
  # no provider activity, so every active row is settled inertly as
  # `requires_connect` or `active_check_required`, and the one step it does run
  # — the audited-local phase-7 check — leaves its rows pending.
  # `doctor --connect` runs all of them, so each becomes pending instead and is
  # settled from what the connect operation returned. Default doctor instead
  # settles every audited-local row from its complete finding set.
  #
  # A failed connect operation can be projected only when its closed diagnostic
  # identifies one canonical row in the exact plan. Every other pending row is
  # reported as unverified: the fail-fast operation retains no per-step success
  # transcript, so a diagnostic cannot prove whether those checks ran.

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun

  @operations [:local, :selection, :credentials, :authorization, :connectivity]
  @modes [:default, :connect]

  @failure_codes_by_operation DiagnosticCatalog.doctor_failure_codes_by_operation()
  @application_failure_codes DiagnosticCatalog.doctor_application_rows()
                             |> Enum.map(& &1.code)

  # Every code a connect plan cannot hold: the two that say default doctor
  # declined the work rather than doing it, and the two an application-less plan
  # reports, which connect has no form for. Together with the `:audited_local`
  # marker they are all of what `new/4` can construct and `:connect` cannot, so
  # refusing them lets the connect settlement recognise any plan derived under
  # the other mode.
  @deferred [
    {:skipped, :requires_connect},
    {:skipped, :active_check_required},
    {:skipped, :application_required},
    {:skipped, :not_requested}
  ]

  @type mode :: :default | :connect
  @type operation :: :local | :selection | :credentials | :authorization | :connectivity
  @type settled :: {:pass | :warn | :skipped | :fail, atom()}
  @type row ::
          %{name: binary(), outcome: settled(), plan_binding: binary()}
          | %{
              name: binary(),
              alias: binary(),
              operation: operation(),
              outcome: settled(),
              plan_binding: binary()
            }
          | %{
              name: binary(),
              alias: binary(),
              operation: :local,
              outcome: :audited_local,
              plan_binding: binary()
            }
          | %{
              name: binary(),
              alias: binary(),
              operation: operation(),
              outcome: :pending,
              plan_binding: binary()
            }
  @type environment :: %{
          runtime: :supported | :unsupported,
          viewer: :available | :unavailable
        }
  @type t :: [row()]

  @doc """
  Derives the ordered doctor rows for one mode.

  `prepared` is `nil` when no application was requested. Its presence decides
  both the alias set — installed aliases without one, selected aliases with one
  — and whether a selection row applies at all. A prepared run must be bound to
  this exact catalog, on the same terms as
  `PtcRunner.Kernel.ProviderExecution.bound_to_prepared?/2`.

  Connect requires one: the closed contract admits a connect success only when
  the application row is `pass/valid`, so a connect plan without an application
  could not be projected at all.

  Neither mode takes a default, because the two produce different unsettled
  rows from the same declarations and a caller that did not say which it wanted
  would get one of them by accident.
  """
  @spec new(InstallationCatalog.t(), PreparedRun.t() | nil, environment(), mode()) ::
          {:ok, t()} | {:error, :invalid_doctor_plan}
  def new(%InstallationCatalog{} = catalog, prepared, environment, mode) when mode in @modes do
    with true <- InstallationCatalog.valid?(catalog),
         true <- is_nil(prepared) or PreparedRun.valid?(prepared),
         true <- mode == :default or not is_nil(prepared),
         true <- bound_to_catalog?(prepared, catalog) do
      derive_plan(catalog, prepared, environment, mode)
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def new(_catalog, _prepared, _environment, _mode), do: {:error, :invalid_doctor_plan}

  @doc "Derives a closed failed plan when application preparation did not complete."
  @spec application_failure(
          InstallationCatalog.t(),
          CommandDiagnostic.t(),
          environment(),
          mode()
        ) :: {:ok, t()} | {:error, :invalid_doctor_plan}
  def application_failure(
        %InstallationCatalog{} = catalog,
        %CommandDiagnostic{phase: :application, code: code} = diagnostic,
        environment,
        mode
      )
      when code in @application_failure_codes and mode in @modes do
    with true <- InstallationCatalog.valid?(catalog),
         true <- CommandDiagnostic.valid?(diagnostic),
         {:ok, rows} <- derive_plan(catalog, nil, environment, :default) do
      binding =
        Attestation.attest(__MODULE__, {catalog.attestation, diagnostic, environment, mode})

      {:ok,
       Enum.map(rows, fn
         %{name: "application"} = row ->
           %{row | outcome: {:fail, code}, plan_binding: binding}

         %{operation: _operation} = row ->
           %{row | outcome: {:skipped, :not_verified_due_to_failure}, plan_binding: binding}

         row ->
           %{row | plan_binding: binding}
       end)}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def application_failure(_catalog, _diagnostic, _environment, _mode),
    do: {:error, :invalid_doctor_plan}

  # Every outcome the contract has a code for. Projection validates against this
  # rather than trusting its producers, including provider failures retained by
  # doctor rather than raised as a bare command error.
  @permitted [
    {:pass, :supported},
    {:warn, :unsupported},
    {:pass, :valid},
    {:skipped, :not_requested},
    {:pass, :available},
    {:warn, :optional_unavailable},
    {:skipped, :application_required},
    {:skipped, :active_check_required},
    {:pass, :declarative},
    {:skipped, :requires_connect}
  ]

  @doc "Projects settled rows into the closed public check list."
  @spec checks(t()) :: {:ok, [map()]} | {:error, :invalid_doctor_plan}
  def checks(rows) when is_list(rows) do
    if Enum.all?(rows, &permitted?/1) do
      {:ok, Enum.map(rows, &check/1)}
    else
      {:error, :invalid_doctor_plan}
    end
  end

  def checks(_rows), do: {:error, :invalid_doctor_plan}

  @doc "Projects installed or selected workflow LLM aliases for doctor output."
  @spec model_aliases(InstallationCatalog.t(), PreparedRun.t() | nil) ::
          {:ok, [map()]} | {:error, :invalid_doctor_plan}
  def model_aliases(%InstallationCatalog{} = catalog, prepared) do
    with true <- InstallationCatalog.valid?(catalog),
         true <- is_nil(prepared) or PreparedRun.sealed?(prepared),
         true <- bound_to_catalog?(prepared, catalog) do
      selected =
        if prepared,
          do: Map.new(prepared.provider_declarations, &{&1.name, &1.config}),
          else: %{}

      aliases =
        catalog.descriptors
        |> Enum.filter(fn {_name, descriptor} -> descriptor.workflow_llm? end)
        |> Enum.map(fn {name, descriptor} ->
          config = Map.get(selected, name)

          %{
            "alias" => name,
            "source" => Atom.to_string(descriptor.source),
            "installation_revision" => descriptor.installation_revision,
            "default" => if(config, do: Map.get(config, "default", false), else: nil),
            "selected" => not is_nil(config)
          }
        end)
        |> Enum.sort_by(& &1["alias"])

      {:ok, aliases}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def model_aliases(_catalog, _prepared), do: {:error, :invalid_doctor_plan}

  @doc "Settles one pending row with an outcome the closed contract allows."
  @spec settle(t(), binary(), settled()) :: {:ok, t()} | {:error, :invalid_doctor_plan}
  def settle(rows, name, {status, code} = outcome)
      when is_list(rows) and is_binary(name) and is_atom(status) and is_atom(code) do
    if outcome in local_codes() and Enum.any?(rows, &pending_named?(&1, name)) do
      {:ok,
       Enum.map(rows, fn row ->
         if pending_named?(row, name), do: %{row | outcome: outcome}, else: row
       end)}
    else
      {:error, :invalid_doctor_plan}
    end
  end

  def settle(_rows, _name, _outcome), do: {:error, :invalid_doctor_plan}

  @doc """
  Settles a default plan from doctor's complete audited-local finding set.

  The plan is reconstructed from the same catalog, preparation, and
  environment before any row is changed. Each failing diagnostic must identify
  a selected local occurrence; aliases without a finding pass. When an alias is
  selected more than once, any failed occurrence fails its single collapsed
  row, using the first finding in declaration order as its code.
  """
  @spec settle_local(
          t(),
          [CommandDiagnostic.t()],
          PreparedRun.t() | nil,
          InstallationCatalog.t(),
          environment()
        ) :: {:ok, t()} | {:error, :invalid_doctor_plan}
  def settle_local(rows, findings, prepared, %InstallationCatalog{} = catalog, environment)
      when is_list(rows) and is_list(findings) do
    with true <- InstallationCatalog.valid?(catalog),
         true <- is_nil(prepared) or PreparedRun.inactive_valid?(prepared),
         true <- bound_to_catalog?(prepared, catalog),
         {:ok, canonical} <- derive_plan(catalog, prepared, environment, :default),
         true <- rows == canonical,
         true <- Enum.all?(findings, &CommandDiagnostic.valid?/1),
         {:ok, failures} <- local_failures(findings, prepared, catalog) do
      {:ok, Enum.map(rows, &settle_local_row(&1, failures))}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def settle_local(_rows, _findings, _prepared, _catalog, _environment),
    do: {:error, :invalid_doctor_plan}

  @doc """
  Settles a connect-mode plan from the connect operation's sealed result.

  There is one settlement step in this mode, because there is one operation.
  `PtcRunner.Kernel.RunCoordinator.connect/3` fails closed on the first
  audited-local check, active selection validator, unverified check, credential
  resolution, or connectivity attempt that does not succeed, so a result
  existing at all is what settles every row but the connectivity ones.

  Those are settled from the entries themselves rather than from the same
  success, because the plan reports one row per alias while the operation
  answers per occurrence: an alias passes only when every occurrence of it was
  reached. `ConnectivityResult.bound_to?/3` is checked first, since alias names
  are not identity — a result from another catalog installing the same aliases
  would otherwise settle rows for declarations nothing touched.

  An authorization row is never settled. Its own contract has no settling path
  in V1: the row demands `pass/available` while standalone OAuth execution is
  disabled, and `PtcRunner.Kernel.ProviderExecution` refuses a selected OAuth
  occurrence before any provider work. Reaching one here means an operation
  reported success for a selection that cannot succeed, so this fails closed
  rather than claiming an authorization nothing performed.

  The rows are trusted to have come from `new/4` with the same trio, on the same
  terms as `settle_local/5` — a plan carries no seal of its own. What is
  checked is that its provider aliases are the preparation's selected ones and
  that its pending connectivity rows are exactly the aliases the result reports
  reached, so a plan derived from another application or another set of
  connectivity modes is refused rather than settled.
  """
  @spec settle_connect(t(), ConnectivityResult.t(), PreparedRun.t(), InstallationCatalog.t()) ::
          {:ok, t()} | {:error, :invalid_doctor_plan}
  def settle_connect(rows, result, prepared, catalog) when is_list(rows) do
    with true <- ConnectivityResult.bound_to?(result, prepared, catalog),
         true <- plan_aliases(rows) == MapSet.new(prepared.provider_declarations, & &1.name),
         {:ok, pending_connectivity} <- pending_connectivity_aliases(rows),
         true <- pending_connectivity == reached_aliases(ConnectivityResult.entries(result)) do
      settle_connect_rows(rows)
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def settle_connect(_rows, _result, _prepared, _catalog), do: {:error, :invalid_doctor_plan}

  @doc """
  Settles one attributable connect failure against its canonical plan.

  The supplied rows must be byte-for-byte equal to a connect plan reconstructed
  from the same catalog, preparation, and environment. This prevents alias
  names from standing in for the sealed identities they happen to name.

  Only the row identified by the diagnostic becomes a failure. Other pending
  rows become `skipped/not_verified_due_to_failure`, except that an
  `authentication_rejected` credential failure passes the same alias's
  connectivity row because the provider response is retained reachability
  evidence.
  """
  @spec settle_failure(
          t(),
          CommandDiagnostic.t(),
          PreparedRun.t(),
          InstallationCatalog.t(),
          environment()
        ) :: {:ok, t()} | {:error, :invalid_doctor_plan}
  def settle_failure(
        rows,
        %CommandDiagnostic{} = diagnostic,
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        environment
      )
      when is_list(rows) do
    with true <- CommandDiagnostic.valid?(diagnostic),
         true <- InstallationCatalog.valid?(catalog),
         true <- PreparedRun.sealed?(prepared),
         true <- bound_to_catalog?(prepared, catalog),
         {:ok, canonical} <- derive_plan(catalog, prepared, environment, :connect),
         true <- rows == canonical,
         {:ok, target} <- failure_target(diagnostic, prepared, catalog),
         1 <- Enum.count(rows, &pending_target?(&1, target)) do
      {:ok, Enum.map(rows, &settle_failure_row(&1, target, diagnostic.code))}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def settle_failure(_rows, _diagnostic, _prepared, _catalog, _environment),
    do: {:error, :invalid_doctor_plan}

  # The aliases the result reports as reached, and only those. An occurrence a
  # `:none` declaration skipped contributes nothing, and an alias holding both a
  # reached and a skipped occurrence is reported as neither, so it can never
  # cover a connectivity row. A validated result cannot mix them today — the
  # outcome must match the mode its sealed descriptor declares — but a settled
  # row must not depend on that holding elsewhere.
  defp reached_aliases(entries) do
    {reached, skipped} =
      Enum.reduce(entries, {MapSet.new(), MapSet.new()}, fn entry, {reached, skipped} ->
        case entry.outcome do
          :reachable -> {MapSet.put(reached, entry.name), skipped}
          _other -> {reached, MapSet.put(skipped, entry.name)}
        end
      end)

    MapSet.difference(reached, skipped)
  end

  defp plan_aliases(rows), do: for(%{alias: name} <- rows, into: MapSet.new(), do: name)

  # A connect plan leaves every connectivity row pending, because only the
  # operation's own result can settle one. A settled connectivity row here is a
  # plan from the other mode, and settling around it would project a connect
  # success whose connectivity rows still said `requires_connect`.
  defp pending_connectivity_aliases(rows) do
    Enum.reduce_while(rows, {:ok, MapSet.new()}, fn
      %{operation: :connectivity, alias: name, outcome: :pending}, {:ok, names} ->
        {:cont, {:ok, MapSet.put(names, name)}}

      %{operation: :connectivity}, _accumulated ->
        {:halt, :error}

      _row, accumulated ->
        {:cont, accumulated}
    end)
  end

  defp settle_connect_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, settled} ->
      case settle_connect_row(row) do
        {:ok, row} -> {:cont, {:ok, [row | settled]}}
        :error -> {:halt, {:error, :invalid_doctor_plan}}
      end
    end)
    |> case do
      {:ok, settled} -> {:ok, Enum.reverse(settled)}
      {:error, _reason} = error -> error
    end
  end

  defp settle_connect_row(%{outcome: :pending, operation: :authorization}), do: :error

  defp settle_connect_row(%{outcome: :pending} = row),
    do: {:ok, %{row | outcome: {:pass, :available}}}

  # Refusing the codes themselves is what makes the mode check total rather than
  # partial. The connectivity guard above catches a deferred connectivity row,
  # but a deferred credentials or authorization row has no connectivity row to
  # be caught by, and an application-less plan has neither; either would
  # otherwise settle into a check list that fails only at the closed result
  # contract, as an internal error rather than as this refusal.
  defp settle_connect_row(%{outcome: outcome}) when outcome in @deferred, do: :error

  defp settle_connect_row(%{outcome: {status, code}} = row)
       when is_atom(status) and is_atom(code),
       do: {:ok, row}

  # `:audited_local` reaches here only from a default-mode plan, whose rows this
  # step has no evidence for: the audited-local check it names ran under a
  # different settlement.
  defp settle_connect_row(_row), do: :error

  defp failure_target(
         %CommandDiagnostic{
           phase: phase,
           code: code,
           subject: %CommandSubject{
             name: name,
             operation: subject_operation,
             occurrence: occurrence
           }
         },
         prepared,
         catalog
       )
       when phase in [:local_preflight, :active_preflight, :provider_acquisition] do
    with true <- selected_occurrence?(prepared, name, occurrence),
         {:ok, report_operation} <- report_operation(subject_operation, name, catalog),
         true <- code in Map.get(@failure_codes_by_operation, report_operation, []) do
      {:ok, {name, report_operation}}
    else
      _invalid -> :error
    end
  end

  defp failure_target(_diagnostic, _prepared, _catalog), do: :error

  defp report_operation(:acquisition, name, catalog) do
    case Map.fetch(catalog.descriptors, name) do
      {:ok, %{connectivity_mode: :acquisition}} -> {:ok, :connectivity}
      _other -> :error
    end
  end

  defp report_operation(operation, _name, _catalog) when operation in @operations,
    do: {:ok, operation}

  defp report_operation(_operation, _name, _catalog), do: :error

  defp selected_occurrence?(prepared, name, nil),
    do: Enum.any?(prepared.provider_declarations, &(&1.name == name))

  defp selected_occurrence?(prepared, name, occurrence) do
    Enum.any?(prepared.provider_declarations, fn declaration ->
      declaration.name == name and declaration.destination == occurrence.destination and
        declaration.index == occurrence.index
    end)
  end

  defp pending_target?(
         %{alias: name, operation: operation, outcome: :pending},
         {name, operation}
       ),
       do: true

  defp pending_target?(_row, _target), do: false

  defp settle_failure_row(row, target, code) do
    cond do
      pending_target?(row, target) -> %{row | outcome: {:fail, code}}
      reached_authentication_target?(row, target, code) -> %{row | outcome: {:pass, :available}}
      row.outcome == :pending -> %{row | outcome: {:skipped, :not_verified_due_to_failure}}
      true -> row
    end
  end

  defp reached_authentication_target?(
         %{alias: name, operation: :connectivity, outcome: :pending},
         {name, :credentials},
         :authentication_rejected
       ),
       do: true

  defp reached_authentication_target?(_row, _target, _code), do: false

  defp local_failures(findings, prepared, catalog) do
    Enum.reduce_while(findings, {:ok, %{}}, fn diagnostic, {:ok, failures} ->
      case failure_target(diagnostic, prepared, catalog) do
        {:ok, {name, :local}} ->
          {:cont, {:ok, Map.put_new(failures, name, diagnostic.code)}}

        _invalid ->
          {:halt, {:error, :invalid_doctor_plan}}
      end
    end)
  end

  defp settle_local_row(%{alias: name, outcome: :audited_local} = row, failures) do
    case Map.fetch(failures, name) do
      {:ok, code} -> %{row | outcome: {:fail, code}}
      :error -> %{row | outcome: {:pass, :available}}
    end
  end

  defp settle_local_row(row, _failures), do: row

  defp derive_plan(catalog, prepared, environment, mode) do
    with {:ok, runtime} <- environment_row("runtime", environment, :runtime, runtime_codes()),
         {:ok, viewer} <- environment_row("viewer", environment, :viewer, viewer_codes()),
         {:ok, aliases} <- aliases(catalog, prepared) do
      binding =
        Attestation.attest(
          __MODULE__,
          {catalog.attestation, prepared && prepared.attestation, environment, mode}
        )

      {:ok,
       [runtime, application_row(prepared), viewer]
       |> Kernel.++(provider_rows(catalog, aliases, prepared, mode))
       |> Enum.map(&Map.put(&1, :plan_binding, binding))}
    end
  end

  defp permitted?(%{operation: operation, outcome: {:fail, code}}),
    do: code in Map.get(@failure_codes_by_operation, operation, [])

  defp permitted?(%{name: "application", outcome: {:fail, code}}),
    do: code in @application_failure_codes

  defp permitted?(%{outcome: {:skipped, :not_verified_due_to_failure}}), do: true
  defp permitted?(%{outcome: outcome}), do: outcome in @permitted
  defp permitted?(_row), do: false

  defp pending_named?(%{name: name, outcome: :audited_local}, name), do: true
  defp pending_named?(_row, _name), do: false

  # Alias names are not identity. Two catalogs can install the same aliases over
  # different sealed descriptors, and every row below is read from the
  # descriptor rather than the name, so a preparation from another catalog would
  # be reported against declarations it was never validated against.
  defp bound_to_catalog?(nil, _catalog), do: true

  defp bound_to_catalog?(prepared, catalog),
    do: prepared.catalog_attestation == catalog.attestation

  defp check(%{name: name, outcome: {status, code}}),
    do: %{"name" => name, "status" => Atom.to_string(status), "code" => Atom.to_string(code)}

  defp environment_row(name, environment, key, codes) do
    with fact when not is_nil(fact) <- environment_fact(environment, key),
         {:ok, outcome} <- Map.fetch(codes, fact) do
      {:ok, %{name: name, outcome: outcome}}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  defp environment_fact(environment, key) when is_map(environment) and not is_struct(environment),
    do: Map.get(environment, key)

  defp environment_fact(_environment, _key), do: nil

  defp runtime_codes,
    do: %{supported: {:pass, :supported}, unsupported: {:warn, :unsupported}}

  defp viewer_codes,
    do: %{available: {:pass, :available}, unavailable: {:warn, :optional_unavailable}}

  # `local` is the only operation an audited-local check settles, so the closed
  # set it may be settled with lives beside the rows that declare it pending.
  defp local_codes, do: [{:pass, :available}, {:skipped, :active_check_required}]

  defp application_row(nil), do: %{name: "application", outcome: {:skipped, :not_requested}}
  defp application_row(_prepared), do: %{name: "application", outcome: {:pass, :valid}}

  # Without an application there is no selection to check against, so the plan
  # reports the installed surface. With one it reports exactly the occurrences
  # the run would use, collapsed to one group per alias.
  defp aliases(catalog, nil), do: {:ok, InstallationCatalog.names(catalog)}

  defp aliases(catalog, prepared) do
    names =
      prepared.provider_declarations
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.all?(names, &Map.has_key?(catalog.descriptors, &1)),
      do: {:ok, names},
      else: {:error, :invalid_doctor_plan}
  end

  defp provider_rows(catalog, aliases, prepared, mode) do
    Enum.flat_map(aliases, fn name ->
      descriptor = Map.fetch!(catalog.descriptors, name)

      Enum.flat_map(@operations, fn operation ->
        case outcome(operation, descriptor, prepared, mode) do
          nil -> []
          outcome -> [provider_row(name, operation, outcome)]
        end
      end)
    end)
  end

  defp provider_row(name, operation, outcome) do
    %{
      name: "provider/#{name}/#{operation}",
      alias: name,
      operation: operation,
      outcome: outcome
    }
  end

  # Every group starts with `local`, which is what makes an alias visible at all.
  # Neither local mode reaches this without an application, and connect requires
  # one, so the `nil` clause belongs to default doctor's installed surface alone.
  defp outcome(:local, _descriptor, nil, _mode), do: {:skipped, :application_required}
  defp outcome(:local, %{local_preflight: :none}, _prepared, _mode), do: {:pass, :available}

  # Both local modes are pending under connect, which runs the audited-local
  # step in phase 7 and the unverified one after the phase-8 marker. Under
  # default doctor only the first runs, and the second says so.
  defp outcome(:local, %{local_preflight: :audited_local}, _prepared, :default),
    do: :audited_local

  defp outcome(:local, %{local_preflight: :unverified}, _prepared, :default),
    do: {:skipped, :active_check_required}

  defp outcome(:local, %{local_preflight: mode}, _prepared, :connect)
       when mode in [:audited_local, :unverified],
       do: :pending

  # A selection only exists once an application named one, so this row is absent
  # rather than skipped when no application was requested.
  defp outcome(:selection, _descriptor, nil, _mode), do: nil

  defp outcome(:selection, %{selection_validation: :declarative}, _prepared, _mode),
    do: {:pass, :declarative}

  defp outcome(:selection, %{selection_validation: :active}, _prepared, :default),
    do: {:skipped, :active_check_required}

  defp outcome(:selection, %{selection_validation: :active}, _prepared, :connect), do: :pending

  # The remaining operations require connect mode, but the credentials row can
  # finish through local lookup without attempting provider work. They appear
  # only when the declaration says they apply. Default doctor defers all of
  # them; connect settles each from what its operation returned, except
  # authorization, which has no settling path in V1 at all.
  defp outcome(:credentials, %{credential_names: []}, _prepared, _mode), do: nil
  defp outcome(:credentials, _descriptor, _prepared, :default), do: {:skipped, :requires_connect}
  defp outcome(:credentials, _descriptor, _prepared, :connect), do: :pending

  defp outcome(:authorization, %{authorization_mode: :oauth}, _prepared, :default),
    do: {:skipped, :requires_connect}

  defp outcome(:authorization, %{authorization_mode: :oauth}, _prepared, :connect), do: :pending
  defp outcome(:authorization, _descriptor, _prepared, _mode), do: nil

  defp outcome(:connectivity, %{connectivity_mode: :none}, _prepared, _mode), do: nil
  defp outcome(:connectivity, _descriptor, _prepared, :default), do: {:skipped, :requires_connect}
  defp outcome(:connectivity, _descriptor, _prepared, :connect), do: :pending
end
