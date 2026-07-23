defmodule PtcRunner.Lisp.Java.Lang.String do
  @moduledoc """
  Bounded UTF-16 semantics for the admitted `java.lang.String` methods.

  PTC strings remain UTF-8 binaries. Java indexes are measured over a temporary
  big-endian UTF-16 code-unit view capped at 256,000 input bytes. A substring
  that cuts a surrogate pair is rejected because it cannot be represented as a
  valid PTC UTF-8 string.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive

  @max_input_bytes 256_000

  @spec validate_input(term()) :: :ok | {:error, :invalid_utf8 | :too_large}
  def validate_input(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_input_bytes -> {:error, :too_large}
      not Elixir.String.valid?(value) -> {:error, :invalid_utf8}
      true -> :ok
    end
  end

  def validate_input(_value), do: :ok

  @spec contains([term()]) :: {:ok, boolean()} | {:error, Condition.t()}
  def contains([_receiver, nil]), do: null_argument("String.contains argument is null")

  def contains([receiver, substring]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, substring_view} <- view(substring) do
      {:ok, first_index(receiver_view, substring_view, 0) != -1}
    end
  end

  @spec index_of([term()]) :: {:ok, Primitive.t()} | {:error, Condition.t()}
  def index_of([_receiver, nil]), do: null_argument("String.indexOf argument is null")

  def index_of([receiver, substring]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, substring_view} <- view(substring) do
      receiver_view
      |> first_index(substring_view, 0)
      |> int_result()
    end
  end

  def index_of([_receiver, nil, _from_index]),
    do: null_argument("String.indexOf argument is null")

  def index_of([receiver, substring, from_index]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, substring_view} <- view(substring) do
      receiver_view
      |> first_index(substring_view, from_index)
      |> int_result()
    end
  end

  @spec last_index_of([term()]) :: {:ok, Primitive.t()} | {:error, Condition.t()}
  def last_index_of([_receiver, nil]),
    do: null_argument("String.lastIndexOf argument is null")

  def last_index_of([receiver, substring]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, substring_view} <- view(substring) do
      receiver_view
      |> last_index(substring_view)
      |> int_result()
    end
  end

  @spec starts_with([term()]) :: {:ok, boolean()} | {:error, Condition.t()}
  def starts_with([_receiver, nil]), do: null_argument("String.startsWith argument is null")

  def starts_with([receiver, prefix]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, prefix_view} <- view(prefix) do
      {:ok, starts_with_view?(receiver_view, prefix_view)}
    end
  end

  @spec ends_with([term()]) :: {:ok, boolean()} | {:error, Condition.t()}
  def ends_with([_receiver, nil]), do: null_argument("String.endsWith argument is null")

  def ends_with([receiver, suffix]) do
    with {:ok, receiver_view} <- view(receiver),
         {:ok, suffix_view} <- view(suffix) do
      {:ok, ends_with_view?(receiver_view, suffix_view)}
    end
  end

  @spec length([term()]) :: {:ok, Primitive.t()} | {:error, Condition.t()}
  def length([receiver]) do
    with {:ok, receiver_view} <- view(receiver) do
      receiver_view |> code_unit_length() |> int_result()
    end
  end

  @spec substring([term()]) :: {:ok, binary()} | {:error, Condition.t()}
  def substring([receiver, begin_index]) do
    with {:ok, receiver_view} <- view(receiver) do
      substring_view(receiver_view, begin_index, code_unit_length(receiver_view))
    end
  end

  def substring([receiver, begin_index, end_index]) do
    with {:ok, receiver_view} <- view(receiver) do
      substring_view(receiver_view, begin_index, end_index)
    end
  end

  @spec trim([term()]) :: {:ok, binary()} | {:error, Condition.t()}
  def trim([receiver]) do
    with {:ok, _receiver_view} <- view(receiver) do
      {:ok, receiver |> trim_java_leading() |> trim_java_trailing()}
    end
  end

  defp view(value) do
    case validate_input(value) do
      :ok ->
        case :unicode.characters_to_binary(value, :utf8, {:utf16, :big}) do
          binary when is_binary(binary) -> {:ok, binary}
          _invalid -> invalid_string(:invalid_utf8, "Java String input is not valid UTF-8")
        end

      {:error, reason} ->
        invalid_string(
          reason,
          "Java String input cannot be represented by the bounded UTF-16 view"
        )
    end
  end

  defp first_index(receiver, "", from_index) do
    from_index |> max(0) |> min(code_unit_length(receiver))
  end

  defp first_index(receiver, substring, from_index) do
    receiver_length = code_unit_length(receiver)
    substring_length = code_unit_length(substring)
    start_index = max(from_index, 0)

    if start_index > receiver_length - substring_length do
      -1
    else
      prefix_table = build_prefix_table(substring, substring_length)

      find_first_match(
        receiver,
        substring,
        prefix_table,
        start_index,
        0,
        receiver_length,
        substring_length
      )
    end
  end

  defp last_index(receiver, ""), do: code_unit_length(receiver)

  defp last_index(receiver, substring) do
    receiver_length = code_unit_length(receiver)
    substring_length = code_unit_length(substring)

    if substring_length > receiver_length do
      -1
    else
      prefix_table = build_prefix_table(substring, substring_length)

      find_last_match(
        receiver,
        substring,
        prefix_table,
        0,
        0,
        receiver_length,
        substring_length,
        -1
      )
    end
  end

  defp build_prefix_table(pattern, pattern_length) do
    table = :atomics.new(pattern_length, signed: false)
    build_prefix_table(pattern, table, 1, 0, pattern_length)
  end

  defp build_prefix_table(_pattern, table, index, _matched, pattern_length)
       when index >= pattern_length,
       do: table

  defp build_prefix_table(pattern, table, index, matched, pattern_length) do
    cond do
      code_unit_at(pattern, index) == code_unit_at(pattern, matched) ->
        next_matched = matched + 1

        build_prefix_table(
          pattern,
          put_prefix(table, index, next_matched),
          index + 1,
          next_matched,
          pattern_length
        )

      matched > 0 ->
        build_prefix_table(
          pattern,
          table,
          index,
          prefix_at(table, matched - 1),
          pattern_length
        )

      true ->
        build_prefix_table(pattern, table, index + 1, 0, pattern_length)
    end
  end

  defp find_first_match(
         _receiver,
         _pattern,
         _table,
         receiver_index,
         _matched,
         receiver_length,
         _pattern_length
       )
       when receiver_index >= receiver_length,
       do: -1

  defp find_first_match(
         receiver,
         pattern,
         table,
         receiver_index,
         matched,
         receiver_length,
         pattern_length
       ) do
    if code_unit_at(receiver, receiver_index) == code_unit_at(pattern, matched) do
      next_matched = matched + 1

      if next_matched == pattern_length do
        receiver_index - pattern_length + 1
      else
        find_first_match(
          receiver,
          pattern,
          table,
          receiver_index + 1,
          next_matched,
          receiver_length,
          pattern_length
        )
      end
    else
      if matched > 0 do
        find_first_match(
          receiver,
          pattern,
          table,
          receiver_index,
          prefix_at(table, matched - 1),
          receiver_length,
          pattern_length
        )
      else
        find_first_match(
          receiver,
          pattern,
          table,
          receiver_index + 1,
          0,
          receiver_length,
          pattern_length
        )
      end
    end
  end

  defp find_last_match(
         _receiver,
         _pattern,
         _table,
         receiver_index,
         _matched,
         receiver_length,
         _pattern_length,
         last
       )
       when receiver_index >= receiver_length,
       do: last

  defp find_last_match(
         receiver,
         pattern,
         table,
         receiver_index,
         matched,
         receiver_length,
         pattern_length,
         last
       ) do
    if code_unit_at(receiver, receiver_index) == code_unit_at(pattern, matched) do
      next_matched = matched + 1

      if next_matched == pattern_length do
        find_last_match(
          receiver,
          pattern,
          table,
          receiver_index + 1,
          prefix_at(table, pattern_length - 1),
          receiver_length,
          pattern_length,
          receiver_index - pattern_length + 1
        )
      else
        find_last_match(
          receiver,
          pattern,
          table,
          receiver_index + 1,
          next_matched,
          receiver_length,
          pattern_length,
          last
        )
      end
    else
      if matched > 0 do
        find_last_match(
          receiver,
          pattern,
          table,
          receiver_index,
          prefix_at(table, matched - 1),
          receiver_length,
          pattern_length,
          last
        )
      else
        find_last_match(
          receiver,
          pattern,
          table,
          receiver_index + 1,
          0,
          receiver_length,
          pattern_length,
          last
        )
      end
    end
  end

  defp code_unit_at(view, index) do
    offset = index * 2
    :binary.at(view, offset) * 256 + :binary.at(view, offset + 1)
  end

  defp put_prefix(table, index, value) do
    :ok = :atomics.put(table, index + 1, value)
    table
  end

  defp prefix_at(table, index), do: :atomics.get(table, index + 1)

  defp substring_view(receiver, begin_index, end_index) do
    length = code_unit_length(receiver)

    if begin_index < 0 or end_index > length or begin_index > end_index do
      domain_error(
        :string_index_out_of_bounds_exception,
        "String substring indexes are outside the UTF-16 code-unit range"
      )
    else
      utf16 = binary_part(receiver, begin_index * 2, (end_index - begin_index) * 2)

      case :unicode.characters_to_binary(utf16, {:utf16, :big}, :utf8) do
        binary when is_binary(binary) ->
          {:ok, binary}

        _unpaired ->
          invalid_string(:unpaired_surrogate, "String substring contains an unpaired surrogate")
      end
    end
  end

  defp starts_with_view?(receiver, prefix) when byte_size(prefix) > byte_size(receiver), do: false

  defp starts_with_view?(receiver, prefix),
    do: binary_part(receiver, 0, byte_size(prefix)) == prefix

  defp ends_with_view?(receiver, suffix) when byte_size(suffix) > byte_size(receiver), do: false

  defp ends_with_view?(receiver, suffix) do
    binary_part(receiver, byte_size(receiver) - byte_size(suffix), byte_size(suffix)) == suffix
  end

  defp code_unit_length(view), do: div(byte_size(view), 2)
  defp int_result(value), do: Primitive.new(:int, value)

  defp trim_java_leading(<<codepoint, rest::binary>>) when codepoint <= 0x20,
    do: trim_java_leading(rest)

  defp trim_java_leading(value), do: value

  defp trim_java_trailing(value) do
    trailing_bytes = trailing_java_whitespace_bytes(value, 0)
    binary_part(value, 0, byte_size(value) - trailing_bytes)
  end

  defp trailing_java_whitespace_bytes(<<>>, trailing_bytes), do: trailing_bytes

  defp trailing_java_whitespace_bytes(<<codepoint, rest::binary>>, trailing_bytes) do
    next_trailing_bytes = if codepoint <= 0x20, do: trailing_bytes + 1, else: 0
    trailing_java_whitespace_bytes(rest, next_trailing_bytes)
  end

  defp null_argument(message), do: domain_error(:null_pointer_exception, message)

  defp domain_error(exception, message) do
    {:error, Condition.new(:java_domain_error, nil, nil, message, %{java_exception: exception})}
  end

  defp invalid_string(reason, message) do
    {:error,
     Condition.new(:invalid_java_string, nil, nil, message, %{
       java_exception: :invalid_java_string,
       reason: reason
     })}
  end
end
