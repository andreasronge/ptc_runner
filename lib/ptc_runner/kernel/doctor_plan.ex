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
  # settled from what the connect operation returned.
  #
  # The closed result contract has no failing provider row in any mode, so this
  # module cannot express one. A check that fails must fail the whole command
  # with its catalogued diagnostic instead.

  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun

  @operations [:local, :selection, :credentials, :authorization, :connectivity]
  @modes [:default, :connect]

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
  @type settled :: {:pass | :warn | :skipped, atom()}
  @type row ::
          %{name: binary(), outcome: settled()}
          | %{name: binary(), alias: binary(), operation: operation(), outcome: settled()}
          | %{name: binary(), alias: binary(), operation: :local, outcome: :audited_local}
          | %{name: binary(), alias: binary(), operation: operation(), outcome: :pending}
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
         true <- bound_to_catalog?(prepared, catalog),
         {:ok, runtime} <- environment_row("runtime", environment, :runtime, runtime_codes()),
         {:ok, viewer} <- environment_row("viewer", environment, :viewer, viewer_codes()),
         {:ok, aliases} <- aliases(catalog, prepared) do
      {:ok,
       [runtime, application_row(prepared), viewer] ++
         provider_rows(catalog, aliases, prepared, mode)}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def new(_catalog, _prepared, _environment, _mode), do: {:error, :invalid_doctor_plan}

  # Every outcome the contract has a code for. Projection validates against this
  # rather than trusting its producers, so the rule that no provider row can
  # express a failure holds at the boundary that renders them.
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
  Settles every pending row as available.

  Callers use this only after the shared phase-7 step reported `:ok`, which
  verifies every applicable audited-local occurrence. A partial result cannot
  reach here: that step reports the first failure instead of returning.
  """
  @spec settle_pending(t()) :: {:ok, t()} | {:error, :invalid_doctor_plan}
  def settle_pending(rows) when is_list(rows) do
    rows
    |> pending()
    |> Enum.reduce_while({:ok, rows}, fn row, {:ok, rows} ->
      case settle(rows, row.name, {:pass, :available}) do
        {:ok, settled} -> {:cont, {:ok, settled}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def settle_pending(_rows), do: {:error, :invalid_doctor_plan}

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
  terms as `settle_pending/1` — a plan carries no seal of its own. What is
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

  defp pending(rows), do: Enum.filter(rows, &match?(%{outcome: :audited_local}, &1))

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
