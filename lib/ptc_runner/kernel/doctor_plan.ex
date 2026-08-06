defmodule PtcRunner.Kernel.DoctorPlan do
  @moduledoc false

  # Deterministic default-doctor plan.
  #
  # Every row comes from sealed declarations and the two supplied environment
  # facts. Nothing here activates a provider, resolves a credential, acquires a
  # resource, or opens a connection, so the plan is identical whether or not the
  # command later executes an audited-local check.
  #
  # The closed result contract has no failing provider row in any mode, so this
  # module cannot express one. A check that fails must fail the whole command
  # with its catalogued diagnostic instead.

  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun

  @operations [:local, :selection, :credentials, :authorization, :connectivity]

  @type operation :: :local | :selection | :credentials | :authorization | :connectivity
  @type settled :: {:pass | :warn | :skipped, atom()}
  @type row ::
          %{name: binary(), outcome: settled()}
          | %{name: binary(), alias: binary(), operation: operation(), outcome: settled()}
          | %{name: binary(), alias: binary(), operation: :local, outcome: :audited_local}
  @type environment :: %{
          runtime: :supported | :unsupported,
          viewer: :available | :unavailable
        }
  @type t :: [row()]

  @doc """
  Derives the ordered default-doctor rows.

  `prepared` is `nil` when no application was requested. Its presence decides
  both the alias set — installed aliases without one, selected aliases with one
  — and whether a selection row applies at all. A prepared run must be bound to
  this exact catalog, on the same terms as
  `PtcRunner.Kernel.ProviderExecution.bound_to_prepared?/2`.
  """
  @spec new(InstallationCatalog.t(), PreparedRun.t() | nil, environment()) ::
          {:ok, t()} | {:error, :invalid_doctor_plan}
  def new(%InstallationCatalog{} = catalog, prepared, environment) do
    with true <- InstallationCatalog.valid?(catalog),
         true <- is_nil(prepared) or PreparedRun.valid?(prepared),
         true <- bound_to_catalog?(prepared, catalog),
         {:ok, runtime} <- environment_row("runtime", environment, :runtime, runtime_codes()),
         {:ok, viewer} <- environment_row("viewer", environment, :viewer, viewer_codes()),
         {:ok, aliases} <- aliases(catalog, prepared) do
      {:ok,
       [runtime, application_row(prepared), viewer] ++ provider_rows(catalog, aliases, prepared)}
    else
      _invalid -> {:error, :invalid_doctor_plan}
    end
  end

  def new(_catalog, _prepared, _environment), do: {:error, :invalid_doctor_plan}

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

  @doc "Returns the rows an audited-local phase-7 check must settle, in order."
  @spec pending(t()) :: [row()]
  def pending(rows) when is_list(rows),
    do: Enum.filter(rows, &match?(%{outcome: :audited_local}, &1))

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

  defp provider_rows(catalog, aliases, prepared) do
    Enum.flat_map(aliases, fn name ->
      descriptor = Map.fetch!(catalog.descriptors, name)

      Enum.flat_map(@operations, fn operation ->
        case outcome(operation, descriptor, prepared) do
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
  defp outcome(:local, _descriptor, nil), do: {:skipped, :application_required}
  defp outcome(:local, %{local_preflight: :none}, _prepared), do: {:pass, :available}
  defp outcome(:local, %{local_preflight: :audited_local}, _prepared), do: :audited_local

  defp outcome(:local, %{local_preflight: :unverified}, _prepared),
    do: {:skipped, :active_check_required}

  # A selection only exists once an application named one, so this row is absent
  # rather than skipped when no application was requested.
  defp outcome(:selection, _descriptor, nil), do: nil

  defp outcome(:selection, %{selection_validation: :declarative}, _prepared),
    do: {:pass, :declarative}

  defp outcome(:selection, %{selection_validation: :active}, _prepared),
    do: {:skipped, :active_check_required}

  # The remaining operations are active work by definition. They appear only
  # when the declaration says they apply, and default doctor always defers them.
  defp outcome(:credentials, %{credential_names: []}, _prepared), do: nil
  defp outcome(:credentials, _descriptor, _prepared), do: {:skipped, :requires_connect}

  defp outcome(:authorization, %{authorization_mode: :oauth}, _prepared),
    do: {:skipped, :requires_connect}

  defp outcome(:authorization, _descriptor, _prepared), do: nil

  defp outcome(:connectivity, %{connectivity_mode: :none}, _prepared), do: nil
  defp outcome(:connectivity, _descriptor, _prepared), do: {:skipped, :requires_connect}
end
