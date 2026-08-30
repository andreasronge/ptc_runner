defmodule PtcRunner.Kernel.QueryValidation do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue

  @doc false
  @spec string(term(), pos_integer()) :: :ok | {:error, :invalid_query}
  def string(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 and
             byte_size(value) >= 1 and byte_size(value) <= max_bytes,
      do: if(String.valid?(value), do: :ok, else: {:error, :invalid_query})

  def string(_value, _max_bytes), do: {:error, :invalid_query}

  @doc false
  @spec tags(term(), pos_integer()) :: :ok | {:error, :invalid_query}
  def tags(tags, max_string_bytes)
      when is_map(tags) and map_size(tags) <= 16 and is_integer(max_string_bytes) and
             max_string_bytes > 0 do
    if Enum.all?(tags, fn {key, value} ->
         string(key, max_string_bytes) == :ok and JSONValue.value?(value)
       end),
       do: :ok,
       else: {:error, :invalid_query}
  end

  def tags(_tags, _max_string_bytes), do: {:error, :invalid_query}

  @doc false
  @spec timestamp(term()) :: :ok | {:error, :invalid_query}
  def timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :invalid_query}
    end
  end

  def timestamp(_timestamp), do: {:error, :invalid_query}
end
