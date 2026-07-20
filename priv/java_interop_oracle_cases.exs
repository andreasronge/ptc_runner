value = fn type, value -> %{status: :ok, type: type, value: value} end
error = fn class -> %{status: :error, type: :error, value: class} end

fixture = fn overload_id, oracle, subsets, receiver, arguments, expected, divergence_ids ->
  %{
    case_id: overload_id |> Atom.to_string() |> String.replace("_", "-"),
    overload_id: overload_id,
    oracle: oracle,
    subsets: subsets,
    invocation: %{receiver: receiver, arguments: arguments},
    expected: expected,
    divergence_ids: divergence_ids
  }
end

jvm = fn overload_id, receiver, arguments, expected, divergence_ids ->
  fixture.(overload_id, :jvm, [:implemented], receiver, arguments, expected, divergence_ids)
end

fast = fn overload_id, receiver, arguments, expected, divergence_ids ->
  fixture.(
    overload_id,
    :jvm,
    [:implemented, :fast],
    receiver,
    arguments,
    expected,
    divergence_ids
  )
end

ptc_only = fn overload_id, receiver, arguments, expected, divergence_ids ->
  fixture.(overload_id, :ptc_only, [:ptc_only], receiver, arguments, expected, divergence_ids)
end

string = fn text -> value.(:string, text) end
int = fn number -> value.(:int, number) end
long = fn number -> value.(:long, number) end
float = fn number -> value.(:float, number) end
double = fn number -> value.(:double, number) end
local_date = fn text -> value.(:local_date, text) end
instant = fn text -> value.(:instant, text) end
duration = fn text -> value.(:duration, text) end
date = fn milliseconds -> value.(:date, milliseconds) end

[
  fast.(:boolean_parse_boolean_string, nil, [string.("TrUe")], value.(:boolean, "true"), []),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("1.5")],
    value.(:double, "0x1.8p0"),
    ["GAP-J01"]
  ),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("not-a-double")],
    error.("java.lang.NumberFormatException"),
    ["GAP-J01"]
  )
  |> Map.put(:case_id, "double-parse-double-string-invalid"),
  jvm.(:double_positive_infinity_field, nil, [], value.(:double, "Infinity"), []),
  jvm.(:double_negative_infinity_field, nil, [], value.(:double, "-Infinity"), []),
  jvm.(:double_nan_field, nil, [], value.(:double, "NaN"), []),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("1.5")],
    value.(:float, "0x1.8p0"),
    ["GAP-J01"]
  ),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.("-42")],
    value.(:int, "-42"),
    ["GAP-J01"]
  ),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.("9223372036854775807")],
    value.(:long, "9223372036854775807"),
    ["GAP-J01"]
  ),
  jvm.(
    :system_current_time_millis_0,
    nil,
    [],
    value.(:long, "<non-negative>"),
    []
  )
  |> Map.put(:normalizer, :non_negative),
  jvm.(
    :string_contains_char_sequence,
    string.("alpha-beta"),
    [string.("beta")],
    value.(:boolean, "true"),
    ["DIV-40", "DIV-41"]
  ),
  jvm.(
    :string_index_of_string,
    string.("😀a"),
    [string.("a")],
    value.(:int, "2"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :string_index_of_string_from,
    string.("ababa"),
    [string.("ba"), int.(2)],
    value.(:int, "3"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :string_last_index_of_string,
    string.("😀a😀"),
    [string.("😀")],
    value.(:int, "3"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :string_to_lower_case_0,
    string.("ABC"),
    [],
    value.(:string, "abc"),
    ["DIV-41"]
  ),
  jvm.(
    :string_to_upper_case_0,
    string.("abc"),
    [],
    value.(:string, "ABC"),
    ["DIV-41"]
  ),
  jvm.(
    :string_starts_with_string,
    string.("alpha"),
    [string.("al")],
    value.(:boolean, "true"),
    ["DIV-40", "DIV-41"]
  ),
  jvm.(
    :string_ends_with_string,
    string.("alpha"),
    [string.("ha")],
    value.(:boolean, "true"),
    ["DIV-40", "DIV-41"]
  ),
  jvm.(
    :string_length_0,
    string.("😀a"),
    [],
    value.(:int, "3"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :string_substring_begin,
    string.("😀a"),
    [int.(2)],
    value.(:string, "a"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :string_substring_begin_end,
    string.("😀a"),
    [int.(0), int.(2)],
    value.(:string, "😀"),
    ["GAP-J09", "DIV-41"]
  ),
  jvm.(
    :local_date_parse_char_sequence,
    nil,
    [string.("2024-01-02")],
    value.(:local_date, "2024-01-02"),
    ["GAP-J06"]
  ),
  jvm.(
    :local_date_to_epoch_day_0,
    local_date.("1970-01-02"),
    [],
    value.(:long, "1"),
    []
  ),
  jvm.(
    :local_date_plus_days_long,
    local_date.("2024-01-02"),
    [long.(2)],
    value.(:local_date, "2024-01-04"),
    ["GAP-J12"]
  ),
  jvm.(
    :local_date_minus_days_long,
    local_date.("2024-01-02"),
    [long.(2)],
    value.(:local_date, "2023-12-31"),
    ["GAP-J12"]
  ),
  jvm.(
    :local_date_is_before_chrono_local_date,
    local_date.("2024-01-01"),
    [local_date.("2024-01-02")],
    value.(:boolean, "true"),
    []
  ),
  jvm.(
    :local_date_is_after_chrono_local_date,
    local_date.("2024-01-02"),
    [local_date.("2024-01-01")],
    value.(:boolean, "true"),
    []
  ),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("2024-01-02T03:04:05.006Z")],
    value.(:instant, "2024-01-02T03:04:05.006Z"),
    ["GAP-J06"]
  ),
  jvm.(
    :instant_is_before_instant,
    instant.("2024-01-01T00:00:00Z"),
    [instant.("2024-01-02T00:00:00Z")],
    value.(:boolean, "true"),
    []
  ),
  jvm.(
    :instant_is_after_instant,
    instant.("2024-01-02T00:00:00Z"),
    [instant.("2024-01-01T00:00:00Z")],
    value.(:boolean, "true"),
    []
  ),
  ptc_only.(
    :instant_get_time_alias_0,
    instant.("1970-01-01T00:00:01Z"),
    [],
    value.(:long, "1000"),
    ["GAP-J04"]
  ),
  jvm.(
    :duration_between_temporal,
    nil,
    [instant.("2024-01-01T00:00:00Z"), instant.("2024-01-01T00:00:01.500Z")],
    value.(:duration, "PT1.5S"),
    ["GAP-J19"]
  ),
  jvm.(
    :duration_to_millis_0,
    duration.("PT36H"),
    [],
    value.(:long, "129600000"),
    []
  ),
  jvm.(:duration_to_days_0, duration.("PT36H"), [], value.(:long, "1"), []),
  jvm.(:date_new_0, nil, [], value.(:date, "<dynamic>"), [])
  |> Map.put(:normalizer, :type_only),
  jvm.(:date_new_long, nil, [long.(1)], value.(:date, "1"), ["GAP-J03"]),
  jvm.(
    :date_new_string,
    nil,
    [string.("Thu Jan 01 00:00:01 GMT 1970")],
    value.(:date, "1000"),
    ["GAP-J06", "GAP-J11"]
  ),
  ptc_only.(
    :date_new_ptc_temporal,
    nil,
    [local_date.("1970-01-02")],
    value.(:date, "86400000"),
    ["GAP-J21"]
  ),
  jvm.(:date_get_time_0, date.(1234), [], value.(:long, "1234"), []),
  ptc_only.(
    :date_is_before_alias_date,
    date.(0),
    [date.(1)],
    value.(:boolean, "true"),
    ["GAP-J20"]
  ),
  ptc_only.(
    :date_is_after_alias_date,
    date.(1),
    [date.(0)],
    value.(:boolean, "true"),
    ["GAP-J20"]
  ),
  jvm.(:math_abs_int, nil, [int.(-7)], value.(:int, "7"), ["DIV-45"]),
  jvm.(:math_abs_long, nil, [long.(-9)], value.(:long, "9"), ["DIV-45"]),
  jvm.(:math_abs_float, nil, [float.(-1.5)], value.(:float, "0x1.8p0"), ["DIV-45"]),
  jvm.(
    :math_abs_double,
    nil,
    [double.(-1.5)],
    value.(:double, "0x1.8p0"),
    ["DIV-45"]
  ),
  jvm.(:math_ceil_double, nil, [double.(1.2)], value.(:double, "0x1.0p1"), ["DIV-42"]),
  jvm.(
    :math_floor_double,
    nil,
    [double.(-1.2)],
    value.(:double, "-0x1.0p1"),
    ["DIV-42"]
  ),
  jvm.(:math_max_int, nil, [int.(1), int.(2)], value.(:int, "2"), ["DIV-44", "DIV-45"]),
  jvm.(
    :math_max_long,
    nil,
    [long.(8), long.(9)],
    value.(:long, "9"),
    ["DIV-44", "DIV-45"]
  ),
  jvm.(
    :math_max_float,
    nil,
    [float.(1.25), float.(2.5)],
    value.(:float, "0x1.4p1"),
    ["DIV-44", "DIV-45"]
  ),
  jvm.(
    :math_max_double,
    nil,
    [double.(1.25), double.(2.5)],
    value.(:double, "0x1.4p1"),
    ["DIV-44", "DIV-45"]
  ),
  jvm.(:math_min_int, nil, [int.(1), int.(2)], value.(:int, "1"), ["DIV-44", "DIV-45"]),
  jvm.(
    :math_min_long,
    nil,
    [long.(8), long.(9)],
    value.(:long, "8"),
    ["DIV-44", "DIV-45"]
  ),
  jvm.(
    :math_min_float,
    nil,
    [float.(1.25), float.(2.5)],
    value.(:float, "0x1.4p0"),
    ["DIV-44", "DIV-45"]
  ),
  jvm.(
    :math_min_double,
    nil,
    [double.(1.25), double.(2.5)],
    value.(:double, "0x1.4p0"),
    ["DIV-44", "DIV-45"]
  ),
  fast.(:math_pow_double, nil, [double.(2.0), double.(3.0)], value.(:double, "0x1.0p3"), []),
  jvm.(:math_round_float, nil, [float.(-1.5)], value.(:int, "-1"), ["DIV-43", "DIV-45"]),
  jvm.(
    :math_round_double,
    nil,
    [double.(-1.5)],
    value.(:long, "-1"),
    ["DIV-43", "DIV-45"]
  ),
  fast.(:math_sqrt_double, nil, [double.(9.0)], value.(:double, "0x1.8p1"), [])
]
