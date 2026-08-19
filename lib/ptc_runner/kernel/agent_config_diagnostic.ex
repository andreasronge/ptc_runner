defmodule PtcRunner.Kernel.AgentConfigDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern

  # The shipped agent library rejects an out-of-range or mistyped bounded option
  # before it spends a provider request. The Kernel authors the command sentence
  # from a closed payload: an int64 value, or a type tag. Caller-controlled
  # non-integer content never enters the message.
  @options [
    {"max_turns", 1, 128},
    {"max_program_chars", 1, 1_000_000},
    {"max_observation_chars", 1, 65_536},
    {"max_transcript_chars", 1, 1_000_000}
  ]

  @types [:string, :float, :bool, :map, :vector, nil, :other]
  @type_names %{
    "string" => :string,
    "float" => :float,
    "bool" => :bool,
    "map" => :map,
    "vector" => :vector,
    "nil" => nil,
    "other" => :other
  }
  @type_phrases %{
    string: "a string",
    float: "a float",
    bool: "a bool",
    map: "a map",
    vector: "a vector",
    nil: "nil",
    other: "an unsupported value"
  }

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @int64_max_digits 20
  @int64_pattern "(?:0|-?[1-9][0-9]{0,18})"
  @range_separator "–"

  @doc false
  @spec options() :: [{binary(), pos_integer(), pos_integer()}]
  def options, do: @options

  @doc false
  @spec types() :: [atom()]
  def types, do: @types

  @doc false
  @spec integer_message(term(), term(), term(), term()) :: {:ok, binary()} | :error
  def integer_message(option, minimum, maximum, value)
      when is_binary(option) and is_integer(minimum) and is_integer(maximum) and
             is_integer(value) and value >= @int64_min and value <= @int64_max do
    if accepted_range?(option, minimum, maximum) and out_of_range?(value, minimum, maximum) do
      {:ok, integer_text(option, minimum, maximum, value)}
    else
      :error
    end
  end

  def integer_message(_option, _minimum, _maximum, _value), do: :error

  @doc false
  @spec type_message(term(), term(), term(), term()) :: {:ok, binary()} | :error
  def type_message(option, minimum, maximum, type)
      when is_binary(option) and is_integer(minimum) and is_integer(maximum) do
    with true <- accepted_range?(option, minimum, maximum),
         {:ok, type} <- type_tag(type) do
      {:ok, type_text(option, minimum, maximum, type)}
    else
      _invalid -> :error
    end
  end

  def type_message(_option, _minimum, _maximum, _type), do: :error

  @doc false
  @spec retain_details(term()) :: {:ok, map()} | :error
  def retain_details(%{option: option, min: minimum, max: maximum, value: value} = details)
      when map_size(details) == 4 do
    case integer_message(option, minimum, maximum, value) do
      {:ok, _message} ->
        {:ok, %{option: option, min: minimum, max: maximum, value: value}}

      :error ->
        :error
    end
  end

  def retain_details(%{option: option, min: minimum, max: maximum, type: type} = details)
      when map_size(details) == 4 do
    case type_message(option, minimum, maximum, type) do
      {:ok, _message} ->
        {:ok, %{option: option, min: minimum, max: maximum, type: type}}

      :error ->
        :error
    end
  end

  def retain_details(_details), do: :error

  @doc false
  @spec message(map()) :: {:ok, binary()} | :error
  def message(%{option: option, min: minimum, max: maximum, value: value} = details)
      when map_size(details) == 4,
      do: integer_message(option, minimum, maximum, value)

  def message(%{option: option, min: minimum, max: maximum, type: type} = details)
      when map_size(details) == 4,
      do: type_message(option, minimum, maximum, type)

  def message(_details), do: :error

  @doc false
  @spec valid_error?(term(), term()) :: boolean()
  def valid_error?(message, details) when is_binary(message) do
    case retain_details(details) do
      {:ok, retained} -> message(retained) == {:ok, message}
      :error -> false
    end
  end

  def valid_error?(_message, _details), do: false

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    Enum.any?(integer_examples(), fn {option, minimum, maximum, value} ->
      integer_message(option, minimum, maximum, value) == {:ok, message}
    end) or
      Enum.any?(type_examples(), fn {option, minimum, maximum, type} ->
        type_message(option, minimum, maximum, type) == {:ok, message}
      end) or
      integer_pattern_match?(message)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{"oneOf" => [%{"const" => fallback} | schema_branches()]}
  end

  @doc false
  @spec type_tag(term()) :: {:ok, atom()} | :error
  def type_tag(type) when type in @types, do: {:ok, type}

  def type_tag(name) when is_binary(name), do: Map.fetch(@type_names, name)

  def type_tag(_type), do: :error

  defp accepted_range?(option, minimum, maximum) do
    Enum.any?(@options, fn
      {^option, ^minimum, ^maximum} -> true
      _other -> false
    end)
  end

  defp out_of_range?(value, minimum, maximum), do: value < minimum or value > maximum

  defp integer_text(option, minimum, maximum, value),
    do:
      "#{option} #{value} is outside the supported range #{minimum}#{@range_separator}#{maximum} for agent.core/run; lower it"

  defp type_text(option, minimum, maximum, type),
    do:
      "#{option} must be an integer in #{minimum}#{@range_separator}#{maximum} for agent.core/run; received #{@type_phrases[type]}"

  defp integer_examples do
    Enum.flat_map(@options, fn {option, minimum, maximum} ->
      [
        {option, minimum, maximum, 0},
        {option, minimum, maximum, maximum + 1}
      ]
    end)
  end

  defp type_examples do
    Enum.flat_map(@options, fn {option, minimum, maximum} ->
      Enum.map(@types, &{option, minimum, maximum, &1})
    end)
  end

  defp schema_branches do
    Enum.map(@options, &integer_branch/1) ++ Enum.map(type_examples(), &type_branch/1)
  end

  defp integer_branch({option, minimum, maximum}) do
    prefix = "#{option} "
    suffix = integer_suffix(minimum, maximum)

    escaped =
      DiagnosticPattern.escape(prefix) <> @int64_pattern <> DiagnosticPattern.escape(suffix)

    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => byte_size(prefix) + @int64_max_digits + byte_size(suffix),
      "pattern" => DiagnosticPattern.exact(escaped)
    }
  end

  defp type_branch({option, minimum, maximum, type}) do
    {:ok, message} = type_message(option, minimum, maximum, type)
    %{"const" => message}
  end

  defp integer_suffix(minimum, maximum),
    do:
      " is outside the supported range #{minimum}#{@range_separator}#{maximum} for agent.core/run; lower it"

  defp integer_pattern_match?(message) do
    Enum.any?(@options, fn {option, minimum, maximum} ->
      prefix = "#{option} "
      suffix = integer_suffix(minimum, maximum)
      prefix_len = String.length(prefix)
      suffix_len = String.length(suffix)

      case String.split_at(message, prefix_len) do
        {^prefix, rest} ->
          case String.split_at(rest, String.length(rest) - suffix_len) do
            {digits, ^suffix} -> int64_digits?(digits)
            _other -> false
          end

        _other ->
          false
      end
    end)
  end

  defp int64_digits?("0"), do: true

  defp int64_digits?("-9223372036854775808"), do: true

  defp int64_digits?("-" <> digits), do: int64_digits?(digits) and digits != "0"

  defp int64_digits?(digits) when is_binary(digits) and byte_size(digits) in 1..19 do
    case Integer.parse(digits) do
      {value, ""} when value > 0 -> value <= @int64_max
      _other -> false
    end
  end

  defp int64_digits?(_digits), do: false
end
