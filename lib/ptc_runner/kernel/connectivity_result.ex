defmodule PtcRunner.Kernel.ConnectivityResult do
  @moduledoc false

  # Sealed internal success value of the `:connect` execution operation.
  #
  # One entry per selected occurrence, in declaration order. Occurrences are
  # never collapsed by alias here: an alias may be selected once per
  # destination, and each occurrence carries its own selection and destination,
  # so which occurrence was reached is part of the answer. Collapsing belongs to
  # the doctor plan that renders one group per alias, and it can only collapse
  # correctly if this value kept them apart.
  #
  # Declaration order is the canonical *reporting* order and says nothing about
  # execution order. This is a success projection: on failure no result exists
  # at all, so there is no partial evidence whose sequence could be read. The
  # operation acquires its targets through the shared dependency-order barrier
  # and probes in a separately pinned order, then builds these entries in
  # manifest order afterwards. A reader may rely on the output being stable and
  # matching the manifest; a reader may not infer what ran first, and a failure
  # names the occurrence that actually failed rather than the earliest declared
  # one.
  #
  # The value is bound to the exact preparation and catalog it answers for, not
  # merely shaped like a plausible answer. Alias names are not identity: two
  # catalogs can install the same alias over different sealed descriptors, so a
  # result checked only for occurrence identity could report reachability for
  # declarations it never touched. Construction therefore requires the trio,
  # verifies that every entry's mode is the one its sealed descriptor declares,
  # and seals the pair of attestations into the value. A consumer re-checks the
  # binding with `bound_to?/3` rather than trusting the entries it holds.
  #
  # The outcome and mode vocabularies are closed and validated here rather than
  # trusted from the producer, on the same terms as the doctor plan's settled
  # outcomes: a value that cannot express an unknown result cannot smuggle one
  # into a rendered row.
  #
  # `provider_activity` is cumulative attempted-work evidence from the active
  # prefix, acquisition targets, and probes. It is sealed beside the entries so
  # doctor cannot replace a no-op success with the lifecycle marker. Construction
  # also rejects `false` when the sealed declarations or reached entries prove
  # work happened; `true` remains admissible for command-owned application
  # startup, which these fields cannot independently derive.

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun

  @destinations [:workflow, :mission]
  @modes [:none, :probe, :acquisition]
  @outcomes [:skipped, :reachable]
  @entry_keys [:name, :destination, :index, :mode, :outcome]
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @max_entries 128

  @enforce_keys [:prepared_attestation, :catalog_attestation, :entries, :provider_activity]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type outcome :: :skipped | :reachable
  @type entry :: %{
          name: binary(),
          destination: :workflow | :mission,
          index: non_neg_integer(),
          mode: :none | :probe | :acquisition,
          outcome: outcome()
        }
  @type t :: %__MODULE__{
          prepared_attestation: binary(),
          catalog_attestation: binary(),
          entries: [entry()],
          provider_activity: boolean(),
          attestation: binary() | nil
        }

  @spec new(PreparedRun.t(), InstallationCatalog.t(), [entry()], boolean()) ::
          {:ok, t()} | {:error, :invalid_connectivity_result}
  @doc false
  def new(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, entries, provider_activity)
      when is_list(entries) and length(entries) <= @max_entries and is_boolean(provider_activity) do
    if bound_pair?(prepared, catalog) and entries_valid?(entries) and
         answers_for?(entries, prepared, catalog) and
         activity_consistent?(provider_activity, entries, prepared, catalog) do
      result = %__MODULE__{
        prepared_attestation: prepared.attestation,
        catalog_attestation: catalog.attestation,
        entries: entries,
        provider_activity: provider_activity
      }

      {:ok, %{result | attestation: Attestation.attest(__MODULE__, payload(result))}}
    else
      {:error, :invalid_connectivity_result}
    end
  end

  def new(_prepared, _catalog, _entries, _provider_activity),
    do: {:error, :invalid_connectivity_result}

  @spec valid?(term()) :: boolean()
  @doc false
  def valid?(%__MODULE__{attestation: attestation} = result),
    do:
      Enum.sort(Map.keys(result)) == @field_keys and is_binary(result.prepared_attestation) and
        is_binary(result.catalog_attestation) and is_boolean(result.provider_activity) and
        entries_valid?(result.entries) and activity_covers_entries?(result) and
        Attestation.valid?(__MODULE__, payload(result), attestation)

  def valid?(_result), do: false

  @doc """
  Checks that a result answers for exactly this preparation against this
  catalog.

  Occurrence identity alone is not enough: the same alias sequence can name
  different sealed descriptors in another catalog, so a consumer that settled
  rows from an unbound result would be reporting reachability for declarations
  nothing reached. The mode of every entry is re-derived from the catalog here
  for the same reason.
  """
  @spec bound_to?(term(), term(), term()) :: boolean()
  def bound_to?(
        %__MODULE__{} = result,
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog
      ) do
    valid?(result) and bound_pair?(prepared, catalog) and
      result.prepared_attestation == prepared.attestation and
      result.catalog_attestation == catalog.attestation and
      answers_for?(result.entries, prepared, catalog) and
      activity_consistent?(result.provider_activity, result.entries, prepared, catalog)
  end

  def bound_to?(_result, _prepared, _catalog), do: false

  @spec entries(t()) :: [entry()]
  @doc false
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec provider_activity(t()) :: boolean()
  @doc false
  def provider_activity(%__MODULE__{provider_activity: provider_activity}), do: provider_activity

  # The preparation's lifecycle state is its caller's business — it is consumed
  # while the operation runs and closed afterwards — but its seal is not. A
  # caller-authored `%PreparedRun{}` that kept a stale attestation while its
  # declarations were edited would otherwise get those declarations attested
  # here, so the seal is recomputed rather than read.
  defp bound_pair?(prepared, catalog) do
    PreparedRun.sealed?(prepared) and InstallationCatalog.valid?(catalog) and
      prepared.catalog_attestation == catalog.attestation
  end

  defp payload(result),
    do:
      {result.prepared_attestation, result.catalog_attestation, result.entries,
       result.provider_activity}

  defp entries_valid?(entries) when is_list(entries) and length(entries) <= @max_entries,
    do: Enum.all?(entries, &valid_entry?/1)

  defp entries_valid?(_entries), do: false

  defp activity_covers_entries?(%{provider_activity: true}), do: true

  defp activity_covers_entries?(%{provider_activity: false, entries: entries}),
    do: Enum.all?(entries, &(&1.mode == :none))

  defp activity_consistent?(true, _entries, _prepared, _catalog), do: true

  defp activity_consistent?(false, entries, prepared, catalog) do
    activity_covers_entries?(%{provider_activity: false, entries: entries}) and
      Enum.all?(prepared.provider_declarations, fn declaration ->
        descriptor = Map.fetch!(catalog.descriptors, declaration.name)

        declaration.validation_state != :active_required and
          descriptor.local_preflight != :unverified
      end)
  end

  defp valid_entry?(%{} = entry) when not is_struct(entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(@entry_keys) and
      is_binary(entry.name) and entry.name =~ @name and
      entry.destination in @destinations and
      is_integer(entry.index) and entry.index >= 0 and
      entry.mode in @modes and entry.outcome in @outcomes
  end

  defp valid_entry?(_entry), do: false

  # One entry per selected occurrence, in declaration order, each reporting the
  # mode its own sealed descriptor declares.
  defp answers_for?(entries, prepared, catalog) do
    declarations = prepared.provider_declarations

    length(entries) == length(declarations) and
      Enum.zip(entries, declarations) |> Enum.all?(&answers_for_declaration?(&1, catalog))
  end

  defp answers_for_declaration?({entry, declaration}, catalog) do
    case catalog.descriptors[declaration.name] do
      %{connectivity_mode: mode} ->
        entry.name == declaration.name and entry.destination == declaration.destination and
          entry.index == declaration.index and entry.mode == mode and
          outcome_matches_mode?(entry.outcome, mode)

      _missing ->
        false
    end
  end

  # A declaration asking for no connectivity can only be skipped, and one that
  # asks for connectivity can only be reported as reached. Neither may borrow
  # the other's outcome, so a skipped occurrence can never render as a passing
  # connectivity row.
  defp outcome_matches_mode?(:skipped, :none), do: true
  defp outcome_matches_mode?(:reachable, mode) when mode in [:probe, :acquisition], do: true
  defp outcome_matches_mode?(_outcome, _mode), do: false
end
