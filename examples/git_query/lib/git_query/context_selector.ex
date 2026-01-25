defmodule GitQuery.ContextSelector do
  @moduledoc """
  Selects and transforms context data passed between pipeline steps.

  Supports three modes:
  - `:all` - Pass all accumulated results (keyed by step ID)
  - `:declared` - Pass only what each step declares it needs
  - `:summary` - Like :declared but summarizes large data
  """

  @doc """
  Select context based on mode and declared dependencies.

  ## Parameters

  - `results` - Map of step_id => result data
  - `needs` - List of dependencies: `{step_id, key}` or `key`
  - `mode` - Context mode: `:all`, `:declared`, or `:summary`

  ## Examples

      iex> results = %{1 => %{contributor: "alice", count: 15}}
      iex> GitQuery.ContextSelector.select(results, [{1, :contributor}], :declared)
      %{contributor: "alice"}

      iex> results = %{1 => %{name: "alice"}, 2 => %{commits: [1, 2, 3]}}
      iex> GitQuery.ContextSelector.select(results, [], :all)
      %{1 => %{name: "alice"}, 2 => %{commits: [1, 2, 3]}}
  """
  @spec select(map(), list(), atom()) :: map()
  def select(results, _needs, :all) do
    # Preserve step structure to avoid key collisions
    results
  end

  def select(results, needs, :declared) do
    needs
    |> Enum.map(fn
      {step_id, key} -> {key, get_in(results, [step_id, key])}
      key -> {key, find_key_in_results(results, key)}
    end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def select(results, needs, :summary) do
    results
    |> select(needs, :declared)
    |> Enum.map(fn {k, v} -> {k, maybe_summarize(v)} end)
    |> Map.new()
  end

  @doc """
  Summarize large data to reduce context bloat.

  - Lists with >10 items get summarized to count + sample
  - Strings with >2000 bytes get truncated with preview
  - Maps with >20 keys get summarized to key list

  ## Examples

      iex> GitQuery.ContextSelector.maybe_summarize([1, 2, 3])
      [1, 2, 3]

      iex> list = Enum.to_list(1..15)
      iex> result = GitQuery.ContextSelector.maybe_summarize(list)
      iex> result.type
      :list
      iex> result.count
      15
  """
  @spec maybe_summarize(any()) :: any()
  def maybe_summarize(data) when is_list(data) and length(data) > 10 do
    first = List.first(data)

    keys =
      if is_map(first) and not is_struct(first) do
        Map.keys(first)
      else
        nil
      end

    %{
      type: :list,
      count: length(data),
      sample: Enum.take(data, 3),
      keys: keys
    }
  end

  def maybe_summarize(data) when is_binary(data) and byte_size(data) > 2000 do
    %{
      type: :string,
      length: byte_size(data),
      preview: String.slice(data, 0, 500) <> "..."
    }
  end

  def maybe_summarize(data) when is_map(data) and not is_struct(data) and map_size(data) > 20 do
    %{
      type: :map,
      size: map_size(data),
      keys: Map.keys(data)
    }
  end

  def maybe_summarize(data), do: data

  # Fallback: search all results for a key (use step-prefixed needs to avoid this)
  defp find_key_in_results(results, key) do
    Enum.find_value(results, fn {_step_id, data} ->
      if is_map(data), do: Map.get(data, key)
    end)
  end
end
