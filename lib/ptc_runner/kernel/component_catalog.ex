defmodule PtcRunner.Kernel.ComponentCatalog do
  @moduledoc """
  Immutable attested source-bearing projection of one compiled environment.

  In frozen dependency order each entry binds a component ID to its direct
  dependencies, declared namespaces, qualified `sha256:<64-hex>` source hash,
  and exact effective source bytes. The catalog is built from the same
  `%PtcRunner.Kernel.Component{}` values passed to the bundle compiler and is
  validated against the resulting `%PtcRunner.Kernel.FrozenBundle{}` before
  attestation, so source cannot be paired with a different compiled graph.

  This projection is setup memory for the selected workflow or mission
  environment. It is not prelude metadata, is not copied into result stamps,
  canonical traces, telemetry, or host logs, and is absent from direct
  `PtcRunner.Lisp.run/2` unless a Kernel evaluation threads the selected
  environment's catalog into the evaluation context.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.SourceIntern

  @enforce_keys [:entries]
  defstruct [:entries, attestation: nil]
  @field_keys Enum.sort([:__struct__, :entries, :attestation])

  @type entry :: %{
          id: binary(),
          dependencies: [binary()],
          namespaces: [binary()],
          source_hash: binary(),
          source: binary()
        }

  @type t :: %__MODULE__{entries: [entry()], attestation: binary() | nil}

  @doc "Returns the attested empty catalog."
  @spec empty() :: t()
  def empty, do: seal(%__MODULE__{entries: []})

  @doc "Returns true when `catalog` has no entries."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Builds an attested catalog from compiled `components` and their `bundle`.

  Source binaries are interned through `intern` so identical bytes stay one
  BEAM binary across catalogs. A nil bundle is valid only for an empty
  component list.
  """
  @spec build([Component.t()], FrozenBundle.t() | nil, SourceIntern.t()) ::
          {:ok, SourceIntern.t(), t()} | {:error, atom()}
  def build(components, bundle, intern \\ SourceIntern.new())

  def build([], nil, %SourceIntern{} = intern), do: {:ok, intern, empty()}

  def build(components, %FrozenBundle{} = bundle, %SourceIntern{} = intern)
      when is_list(components) do
    with true <- FrozenBundle.valid?(bundle),
         true <- same_ids?(components, bundle),
         {:ok, intern, entries} <- project_entries(components, bundle, intern),
         true <- matches_bundle?(entries, bundle) do
      {:ok, intern, seal(%__MODULE__{entries: entries})}
    else
      false -> {:error, :catalog_bundle_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def build(_components, _bundle, _intern), do: {:error, :catalog_bundle_mismatch}

  @doc """
  Accepts a catalog for environment assembly against `bundle`.

  An omitted or empty catalog is allowed even when a bundle is present, so
  inspection remains opt-in at construction. A non-empty catalog must be
  attested and match the bundle's frozen graph and source hashes.
  """
  @spec bind(t() | nil, FrozenBundle.t() | nil) :: {:ok, t()} | {:error, atom()}
  def bind(nil, _bundle), do: {:ok, empty()}
  def bind(%__MODULE__{} = catalog, _bundle) when catalog.entries == [], do: {:ok, empty()}

  def bind(%__MODULE__{} = catalog, %FrozenBundle{} = bundle) do
    if valid?(catalog) and matches_bundle?(catalog.entries, bundle),
      do: {:ok, catalog},
      else: {:error, :catalog_bundle_mismatch}
  end

  def bind(_catalog, _bundle), do: {:error, :catalog_bundle_mismatch}

  @doc "Component IDs in frozen dependency order."
  @spec ids(t()) :: [binary()]
  def ids(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1.id)

  @doc "Looks up one catalog entry by exact component ID."
  @spec fetch(t(), binary()) :: {:ok, entry()} | :error
  def fetch(%__MODULE__{entries: entries}, id) when is_binary(id) do
    case Enum.find(entries, &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = catalog),
    do: Attestation.valid_struct?(__MODULE__, catalog, @field_keys, fn -> payload(catalog) end)

  def valid?(_catalog), do: false

  defp project_entries(components, bundle, intern) do
    by_id = Map.new(components, &{&1.id, &1})

    Enum.reduce_while(bundle.components, {:ok, intern, []}, fn frozen, {:ok, intern, acc} ->
      case Map.fetch(by_id, frozen.id) do
        {:ok, %Component{source: source, dependencies: dependencies}} ->
          project_entry(frozen, source, dependencies, intern, acc)

        :error ->
          {:halt, {:error, :catalog_bundle_mismatch}}
      end
    end)
    |> case do
      {:ok, intern, acc} -> {:ok, intern, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp project_entry(frozen, source, dependencies, intern, acc) do
    if dependencies == frozen.dependencies do
      intern_entry(frozen, source, intern, acc)
    else
      {:halt, {:error, :catalog_bundle_mismatch}}
    end
  end

  defp intern_entry(frozen, source, intern, acc) do
    case SourceIntern.intern(intern, source) do
      {:ok, interned, intern} ->
        {:cont, {:ok, intern, [catalog_entry(frozen, interned) | acc]}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp catalog_entry(frozen, interned) do
    %{
      id: frozen.id,
      dependencies: frozen.dependencies,
      namespaces: frozen.namespaces,
      source_hash: ComponentOverride.hash(interned),
      source: interned
    }
  end

  defp same_ids?(components, bundle) do
    Enum.all?(components, &match?(%Component{}, &1)) and
      Enum.map(components, & &1.id) |> Enum.sort() == Enum.sort(bundle.component_ids) and
      length(components) == length(Enum.uniq(Enum.map(components, & &1.id)))
  end

  defp matches_bundle?(entries, bundle) do
    bundle.component_ids == Enum.map(entries, & &1.id) and
      Enum.zip(entries, bundle.components)
      |> Enum.all?(fn {entry, frozen} ->
        entry.id == frozen.id and
          entry.dependencies == frozen.dependencies and
          entry.namespaces == frozen.namespaces and
          bare_hash(entry.source_hash) == frozen.source_hash and
          ComponentOverride.hash(entry.source) == entry.source_hash
      end)
  end

  defp bare_hash("sha256:" <> hex) when byte_size(hex) == 64, do: hex
  defp bare_hash(_hash), do: nil

  defp seal(%__MODULE__{} = catalog),
    do: %{catalog | attestation: Attestation.attest(__MODULE__, payload(catalog))}

  defp payload(catalog), do: catalog.entries
end
