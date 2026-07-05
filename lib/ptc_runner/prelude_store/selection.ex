defmodule PtcRunner.PreludeStore.Selection do
  @moduledoc false

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore

  @type resolved :: {Prelude.t() | nil, [map()]}

  # Resolves prelude selections into ONE frozen bundle. Each requested
  # candidate's recorded dependency pins (`prelude_deps` metadata, written by
  # `PreludeStore.write/4`) are expanded transitively: attaching `audit`
  # auto-pulls `base@pinned`. Components order deps before dependents
  # (user selection order among independents), the pin graph feeds the
  # aggregate compile as `namespace_deps:`, and conflicts fail closed
  # (docs/plans/prelude-deps.md §3).
  @spec resolve!(PreludeStore.t() | nil, term(), keyword()) :: resolved()
  def resolve!(_store, nil, _opts), do: {nil, []}
  def resolve!(_store, [], _opts), do: {nil, []}

  def resolve!(nil, prelude_refs, _opts) do
    raise ArgumentError,
          ":prelude_store is required when :preludes is supplied, got preludes: " <>
            inspect(prelude_refs, limit: 5)
  end

  def resolve!(%PreludeStore{} = store, prelude_refs, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :prelude) or Keyword.has_key?(opts, :runtime_prelude) do
      raise ArgumentError, ":runtime_prelude/:prelude and :preludes are mutually exclusive"
    end

    store
    |> resolve_closure!(prelude_refs)
    |> compile_closure!([])
  end

  def resolve!(store, _prelude_refs, _opts) do
    raise ArgumentError,
          ":prelude_store must be a %PtcRunner.PreludeStore{}, got: #{inspect(store)}"
  end

  @doc false
  @spec resolve_with_prefix!(PreludeStore.t() | nil, term(), [map()], keyword()) :: resolved()
  def resolve_with_prefix!(store, prelude_refs, prefixes, opts)
      when is_list(prefixes) and is_list(opts) do
    cond do
      prelude_refs in [nil, []] ->
        compile_prefixes!(prefixes, [])

      Keyword.has_key?(opts, :prelude) or Keyword.has_key?(opts, :runtime_prelude) ->
        raise ArgumentError, ":runtime_prelude/:prelude and :preludes are mutually exclusive"

      true ->
        store
        |> resolve_closure!(prelude_refs)
        |> compile_closure!(prefixes)
    end
  end

  def resolve_with_prefix!(store, prelude_refs, _prefixes, opts) do
    resolve!(store, prelude_refs, opts)
  end

  defp resolve_closure!(nil, prelude_refs) do
    raise ArgumentError,
          ":prelude_store is required when :preludes is supplied, got preludes: " <>
            inspect(prelude_refs, limit: 5)
  end

  defp resolve_closure!(%PreludeStore{} = store, prelude_refs) do
    requested =
      prelude_refs
      |> List.wrap()
      |> Enum.map(&read_candidate!(store, &1))

    expand_dep_closure!(store, requested)
  end

  defp compile_closure!(closure, prefixes) do
    namespace_deps = closure_namespace_deps(closure)
    selections = prefixes ++ Enum.map(closure, &candidate_selection(&1.candidate))

    case Bundle.compile_precompiled(selections, namespace_deps: namespace_deps) do
      {:ok, prelude} ->
        {prelude, Enum.map(closure, &candidate_ref/1)}

      {:error, error} ->
        raise ArgumentError, "failed to compile selected preludes: #{error.message}"
    end
  end

  defp read_candidate!(store, ref) do
    case PreludeStore.read(store, ref) do
      {:ok, candidate} ->
        candidate

      {:error, error} ->
        raise ArgumentError,
              "failed to resolve prelude #{inspect(ref, limit: 5)}: " <>
                "#{Map.get(error, :message, inspect(error))}"
    end
  end

  # ============================================================
  # Transitive pin closure
  # ============================================================

  # Post-order DFS: each candidate's pinned deps join the closure before the
  # candidate itself, memoized by id. Two paths reaching the same id must
  # agree on version+checksum (identical pins deduplicate to one component;
  # a mismatch is a session-level conflict and fails closed). Pins are
  # acyclic by construction — a dep must exist before its dependent can pin
  # it — so `path` is defense in depth against a corrupted store, not an
  # expected error.
  defp expand_dep_closure!(store, requested) do
    {order, entries} =
      Enum.reduce(requested, {[], %{}}, fn candidate, {order, entries} ->
        visit(store, candidate, nil, order, entries, [])
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(entries, &1))
  end

  # `path` is a plain list (not MapSet) to avoid dialyzer opaque-type
  # friction; pin chains are short so linear membership is fine.
  defp visit(store, %PreludeCandidate{} = candidate, requirer, order, entries, path) do
    if candidate.id in path do
      raise ArgumentError,
            "prelude dependency cycle involving `#{candidate.id}` " <>
              "(store pins are expected to be acyclic)"
    end

    case Map.get(entries, candidate.id) do
      %{candidate: existing} = entry ->
        ensure_same_version!(existing, candidate, entry, requirer)
        {order, Map.put(entries, candidate.id, add_requirer(entry, requirer))}

      nil ->
        path = [candidate.id | path]

        {order, entries} =
          candidate
          |> PreludeCandidate.dep_pins()
          |> Enum.reduce({order, entries}, fn pin, {o, e} ->
            dep = read_pinned!(store, pin, candidate)
            visit(store, dep, candidate.id, o, e, path)
          end)

        entry = %{candidate: candidate, required_by: requirer_list(requirer)}
        {[candidate.id | order], Map.put(entries, candidate.id, entry)}
    end
  end

  defp read_pinned!(store, pin, %PreludeCandidate{} = dependent) do
    case PreludeStore.read(store, %{id: pin.id, version: pin.version, checksum: pin.checksum}) do
      {:ok, candidate} ->
        candidate

      {:error, error} ->
        raise ArgumentError,
              "failed to resolve dependency `#{pin.id}@#{pin.version}` pinned by " <>
                "`#{dependent.id}@#{dependent.version}`: " <>
                Map.get(error, :message, inspect(error))
    end
  end

  defp ensure_same_version!(existing, candidate, entry, requirer) do
    same? =
      existing.version == candidate.version and
        PreludeCandidate.checksum(existing) == PreludeCandidate.checksum(candidate)

    unless same? do
      requirers =
        (entry.required_by ++ requirer_list(requirer))
        |> Enum.uniq()
        |> case do
          [] -> "the session selection"
          ids -> Enum.map_join(ids, ", ", &"`#{&1}`")
        end

      raise ArgumentError,
            "conflicting versions of prelude `#{existing.id}`: the session needs both " <>
              "@#{existing.version} and @#{candidate.version} (required by #{requirers}); " <>
              "align the pins or the selection"
    end
  end

  defp requirer_list(nil), do: []
  defp requirer_list(requirer), do: [requirer]

  defp add_requirer(entry, nil), do: entry

  defp add_requirer(entry, requirer),
    do: %{entry | required_by: Enum.uniq(entry.required_by ++ [requirer])}

  defp closure_namespace_deps(closure) do
    closure
    |> Enum.flat_map(fn %{candidate: candidate} ->
      case PreludeCandidate.dep_pins(candidate) do
        [] -> []
        pins -> [{candidate.id, Enum.map(pins, & &1.id)}]
      end
    end)
    |> Map.new()
  end

  defp candidate_selection(%PreludeCandidate{} = candidate) do
    %{
      id: candidate.id,
      version: candidate.version,
      checksum: PreludeCandidate.checksum(candidate),
      source: candidate.source,
      prelude: candidate.compiled,
      origin: PreludeCandidate.public_origin(candidate.origin)
    }
  end

  # `required_by` marks auto-pulled deps ([] = user-selected) so sessions can
  # see exactly what got attached and why.
  defp candidate_ref(%{candidate: candidate, required_by: required_by}) do
    %{
      id: candidate.id,
      version: candidate.version,
      checksum: PreludeCandidate.checksum(candidate),
      namespaces: candidate.compiled.namespaces,
      form_graph: candidate.compiled.form_graph,
      origin: PreludeCandidate.public_origin(candidate.origin),
      required_by: Enum.sort(required_by)
    }
  end

  defp compile_prefixes!([], resolved), do: {nil, resolved}

  defp compile_prefixes!(prefixes, resolved) do
    case Bundle.compile_precompiled(prefixes) do
      {:ok, prelude} ->
        {prelude, resolved}

      {:error, error} ->
        raise ArgumentError, "failed to compile prefixed preludes: #{error.message}"
    end
  end
end
