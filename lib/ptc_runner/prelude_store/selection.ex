defmodule PtcRunner.PreludeStore.Selection do
  @moduledoc false

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore

  @type resolved :: {Prelude.t() | nil, [map()]}

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

    candidates =
      prelude_refs
      |> List.wrap()
      |> Enum.map(&read_candidate!(store, &1))

    candidates
    |> Enum.map(&candidate_selection/1)
    |> Bundle.compile()
    |> case do
      {:ok, prelude} ->
        {prelude, Enum.map(candidates, &candidate_ref/1)}

      {:error, error} ->
        raise ArgumentError, "failed to compile selected preludes: #{error.message}"
    end
  end

  def resolve!(store, _prelude_refs, _opts) do
    raise ArgumentError,
          ":prelude_store must be a %PtcRunner.PreludeStore{}, got: #{inspect(store)}"
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

  defp candidate_selection(%PreludeCandidate{} = candidate) do
    %{
      id: candidate.id,
      version: candidate.version,
      checksum: PreludeCandidate.checksum(candidate),
      source: candidate.source,
      origin: PreludeCandidate.public_origin(candidate.origin)
    }
  end

  defp candidate_ref(%PreludeCandidate{} = candidate) do
    %{
      id: candidate.id,
      version: candidate.version,
      checksum: PreludeCandidate.checksum(candidate),
      origin: PreludeCandidate.public_origin(candidate.origin)
    }
  end
end
