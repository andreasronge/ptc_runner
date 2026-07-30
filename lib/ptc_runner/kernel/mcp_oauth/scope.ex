defmodule PtcRunner.Kernel.MCPOAuth.Scope do
  @moduledoc """
  Shared strict parser for every OAuth scope-bearing boundary.

  Scope members are case-sensitive ASCII `scope-token` values. Parsed sets are
  duplicate-free, bounded to 64 members, and serialize deterministically by
  original byte order sorting.
  """

  @max_count 64
  @max_member_bytes 256
  @max_serialized_bytes 8_192

  @type scope_set :: MapSet.t(binary())

  @spec parse_list(term(), keyword()) ::
          {:ok, scope_set()} | {:error, :invalid_scope}
  def parse_list(values, opts \\ [])

  def parse_list(values, opts) when is_list(values) and is_list(opts) do
    allow_empty? = Keyword.get(opts, :allow_empty, false)

    with true <- Keyword.keys(opts) -- [:allow_empty] == [],
         true <- is_boolean(allow_empty?),
         true <- length(values) <= @max_count,
         true <- allow_empty? or values != [],
         true <- Enum.all?(values, &valid_token?/1),
         true <- values == Enum.uniq(values),
         set = MapSet.new(values),
         {:ok, serialized} <- serialize(set),
         true <- byte_size(serialized) <= @max_serialized_bytes do
      {:ok, set}
    else
      _invalid -> {:error, :invalid_scope}
    end
  end

  def parse_list(_values, _opts), do: {:error, :invalid_scope}

  @spec parse_string(term()) :: {:ok, scope_set()} | {:error, :invalid_scope}
  def parse_string(value) when is_binary(value) do
    with true <- byte_size(value) in 1..@max_serialized_bytes,
         values = :binary.split(value, " ", [:global]),
         true <- length(values) <= @max_count,
         true <- Enum.all?(values, &valid_token?/1),
         true <- values == Enum.uniq(values) do
      {:ok, MapSet.new(values)}
    else
      _invalid -> {:error, :invalid_scope}
    end
  end

  def parse_string(_value), do: {:error, :invalid_scope}

  @spec serialize(scope_set()) :: {:ok, binary()} | {:error, :invalid_scope}
  def serialize(%MapSet{} = scopes) do
    values = scopes |> MapSet.to_list() |> Enum.sort()

    if length(values) <= @max_count and Enum.all?(values, &valid_token?/1) do
      encoded = Enum.join(values, " ")

      if byte_size(encoded) <= @max_serialized_bytes,
        do: {:ok, encoded},
        else: {:error, :invalid_scope}
    else
      {:error, :invalid_scope}
    end
  end

  def serialize(_scopes), do: {:error, :invalid_scope}

  @spec subset?(scope_set(), scope_set()) :: boolean()
  def subset?(%MapSet{} = left, %MapSet{} = right), do: MapSet.subset?(left, right)

  @spec valid_token?(term()) :: boolean()
  def valid_token?(value)
      when is_binary(value) and byte_size(value) in 1..@max_member_bytes do
    for(<<byte <- value>>, do: byte)
    |> Enum.all?(fn byte -> byte == 0x21 or byte in 0x23..0x5B or byte in 0x5D..0x7E end)
  end

  def valid_token?(_value), do: false
end
