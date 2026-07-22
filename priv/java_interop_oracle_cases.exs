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

string = fn text -> value.(:string, text) end

repeated_string = fn prefix, repeated, count, suffix ->
  value.(:string, %{
    "encoding" => "repeat",
    "prefix" => prefix,
    "repeated" => repeated,
    "count" => count,
    "suffix" => suffix
  })
end

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
    []
  ),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("11.760000")],
    value.(:double, "0x1.7851eb851eb85p3"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-direct-rounding"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("1.7976931348623157e308")],
    value.(:double, "0x1.fffffffffffffp1023"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-max-finite"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("0x1.fffffffffffff8p1023")],
    value.(:double, "Infinity"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-overflow-tie"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("0x0.00000000000008p-1022")],
    value.(:double, "0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-underflow-tie"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("0x0.0000000000001p-1022")],
    value.(:double, "0x0.0000000000001p-1022"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-subnormal"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.(" -0.0D ")],
    value.(:double, "-0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-signed-zero-whitespace-suffix"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("1e0000001")],
    value.(:double, "0x1.4p3"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-zero-padded-decimal-exponent"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("0x1p-0000001")],
    value.(:double, "0x1.0p-1"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-zero-padded-hex-negative-exponent"),
  jvm.(
    :double_parse_double_string,
    nil,
    [repeated_string.("0x0.", "0", 250_000, "1p1000004")],
    value.(:double, "0x1.0p0"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-large-exponent-cancellation"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("-Infinity")],
    value.(:double, "-Infinity"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-negative-infinity"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("+NaN")],
    value.(:double, "NaN"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-signed-nan"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.("not-a-double")],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-invalid"),
  jvm.(
    :double_parse_double_string,
    nil,
    [string.(nil)],
    error.("java.lang.NullPointerException"),
    []
  )
  |> Map.put(:case_id, "double-parse-double-string-null"),
  jvm.(:double_positive_infinity_field, nil, [], value.(:double, "Infinity"), []),
  jvm.(:double_negative_infinity_field, nil, [], value.(:double, "-Infinity"), []),
  jvm.(:double_nan_field, nil, [], value.(:double, "NaN"), []),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("1.5")],
    value.(:float, "0x1.8p0"),
    []
  ),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("11.760000")],
    value.(:float, "0x1.7851ecp3"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-direct-rounding"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("3.4028235e38f")],
    value.(:float, "0x1.fffffep127"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-max-finite"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("0x1.ffffffp127f")],
    value.(:float, "Infinity"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-overflow-tie"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("0x0.000001p-126f")],
    value.(:float, "0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-underflow-tie"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("1.4e-45")],
    value.(:float, "0x0.000002p-126"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-subnormal"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.(" -0.0F ")],
    value.(:float, "-0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-signed-zero-whitespace-suffix"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("1e0000001")],
    value.(:float, "0x1.4p3"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-zero-padded-decimal-exponent"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("0x1p-0000001")],
    value.(:float, "0x1.0p-1"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-zero-padded-hex-negative-exponent"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("+Infinity")],
    value.(:float, "Infinity"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-positive-infinity"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("-NaN")],
    value.(:float, "NaN"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-signed-nan"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.("")],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-invalid"),
  jvm.(
    :float_parse_float_string,
    nil,
    [string.(nil)],
    error.("java.lang.NullPointerException"),
    []
  )
  |> Map.put(:case_id, "float-parse-float-string-null"),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.("-42")],
    value.(:int, "-42"),
    []
  ),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.("-2147483648")],
    value.(:int, "-2147483648"),
    []
  )
  |> Map.put(:case_id, "integer-parse-int-string-min-value"),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.("2147483648")],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "integer-parse-int-string-overflow"),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.(nil)],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "integer-parse-int-string-null"),
  jvm.(
    :integer_parse_int_string,
    nil,
    [string.("١٢")],
    value.(:int, "12"),
    []
  )
  |> Map.put(:case_id, "integer-parse-int-string-unicode-digits"),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.("9223372036854775807")],
    value.(:long, "9223372036854775807"),
    []
  ),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.("-9223372036854775808")],
    value.(:long, "-9223372036854775808"),
    []
  )
  |> Map.put(:case_id, "long-parse-long-string-min-value"),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.("-9223372036854775809")],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "long-parse-long-string-underflow"),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.(nil)],
    error.("java.lang.NumberFormatException"),
    []
  )
  |> Map.put(:case_id, "long-parse-long-string-null"),
  jvm.(
    :long_parse_long_string,
    nil,
    [string.("１２")],
    value.(:long, "12"),
    []
  )
  |> Map.put(:case_id, "long-parse-long-string-unicode-digits"),
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
    ["DIV-40", "DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_index_of_string,
    string.("😀a"),
    [string.("a")],
    value.(:int, "2"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_index_of_string_from,
    string.("ababa"),
    [string.("ba"), int.(2)],
    value.(:int, "3"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_last_index_of_string,
    string.("😀a😀"),
    [string.("😀")],
    value.(:int, "3"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_starts_with_string,
    string.("alpha"),
    [string.("al")],
    value.(:boolean, "true"),
    ["DIV-40", "DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_ends_with_string,
    string.("alpha"),
    [string.("ha")],
    value.(:boolean, "true"),
    ["DIV-40", "DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_length_0,
    string.("😀a"),
    [],
    value.(:int, "3"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_substring_begin,
    string.("😀a"),
    [int.(2)],
    value.(:string, "a"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_substring_begin_end,
    string.("😀a"),
    [int.(0), int.(2)],
    value.(:string, "😀"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_trim_0,
    string.(<<0, 9, 31, 32>> <> "Ada" <> <<32, 0>>),
    [],
    value.(:string, "Ada"),
    ["DIV-41", "DIV-53"]
  ),
  jvm.(
    :string_trim_0,
    string.("\u00A0\u2003Ada\u2003\u00A0"),
    [],
    value.(:string, "\u00A0\u2003Ada\u2003\u00A0"),
    ["DIV-41", "DIV-53"]
  )
  |> Map.put(:case_id, "string-trim-preserves-unicode-whitespace"),
  jvm.(
    :local_date_parse_char_sequence,
    nil,
    [string.("2024-01-02")],
    value.(:local_date, "2024-01-02"),
    []
  ),
  jvm.(
    :local_date_parse_char_sequence,
    nil,
    [string.("+00000-01-01")],
    value.(:local_date, "0000-01-01"),
    []
  )
  |> Map.put(:case_id, "local-date-parse-positive-zero-extended-year"),
  jvm.(
    :local_date_parse_char_sequence,
    nil,
    [string.("not-a-date")],
    error.("java.time.format.DateTimeParseException"),
    []
  )
  |> Map.put(:case_id, "local-date-parse-invalid"),
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
    []
  ),
  jvm.(
    :local_date_minus_days_long,
    local_date.("2024-01-02"),
    [long.(2)],
    value.(:local_date, "2023-12-31"),
    []
  ),
  jvm.(
    :local_date_minus_days_long,
    local_date.("1970-01-01"),
    [long.(-9_223_372_036_854_775_808)],
    error.("java.time.DateTimeException"),
    []
  )
  |> Map.put(:case_id, "local-date-minus-days-long-min-at-epoch"),
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
    []
  ),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("+00000-01-01T00:00:00Z")],
    value.(:instant, "0000-01-01T00:00:00Z"),
    []
  )
  |> Map.put(:case_id, "instant-parse-positive-zero-extended-year"),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("1970-01-01T00:00:00.Z")],
    value.(:instant, "1970-01-01T00:00:00Z"),
    []
  )
  |> Map.put(:case_id, "instant-parse-empty-fraction"),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("1970-01-01T00:00:00+00")],
    error.("java.time.format.DateTimeParseException"),
    []
  )
  |> Map.put(:case_id, "instant-parse-hour-offset"),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("1970-01-01T00:00:00+0000")],
    error.("java.time.format.DateTimeParseException"),
    []
  )
  |> Map.put(:case_id, "instant-parse-compact-minute-offset"),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("1970-01-01T00:00:00+000000")],
    error.("java.time.format.DateTimeParseException"),
    []
  )
  |> Map.put(:case_id, "instant-parse-compact-second-offset"),
  jvm.(
    :instant_parse_char_sequence,
    nil,
    [string.("not-an-instant")],
    error.("java.time.format.DateTimeParseException"),
    []
  )
  |> Map.put(:case_id, "instant-parse-invalid"),
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
  jvm.(
    :instant_to_epoch_milli_0,
    instant.("1970-01-01T00:00:01Z"),
    [],
    value.(:long, "1000"),
    []
  ),
  jvm.(
    :duration_between_temporal,
    nil,
    [instant.("2024-01-01T00:00:00Z"), instant.("2024-01-01T00:00:01.500Z")],
    value.(:duration, "PT1.5S"),
    ["DIV-52"]
  ),
  jvm.(
    :duration_between_temporal,
    nil,
    [local_date.("2024-01-01"), local_date.("2024-01-02")],
    error.("java.time.temporal.UnsupportedTemporalTypeException"),
    ["DIV-52"]
  )
  |> Map.put(:case_id, "duration-between-local-date-boundary")
  |> Map.put(:ptc_expected, error.("java_type_error"))
  |> Map.put(:boundary_probe, true),
  jvm.(
    :duration_to_millis_0,
    duration.("PT36H"),
    [],
    value.(:long, "129600000"),
    []
  ),
  jvm.(
    :duration_to_millis_0,
    duration.("PT-0.000000001S"),
    [],
    value.(:long, "0"),
    []
  )
  |> Map.put(:case_id, "duration-to-millis-negative-submillisecond"),
  jvm.(
    :duration_to_millis_0,
    duration.("PT2562047788015215H30M7S"),
    [],
    error.("java.lang.ArithmeticException"),
    []
  )
  |> Map.put(:case_id, "duration-to-millis-overflow"),
  jvm.(:duration_to_days_0, duration.("PT36H"), [], value.(:long, "1"), []),
  jvm.(:date_new_0, nil, [], value.(:date, "<dynamic>"), [])
  |> Map.put(:normalizer, :type_only),
  jvm.(:date_new_long, nil, [long.(1)], value.(:date, "1"), []),
  jvm.(
    :date_new_string,
    nil,
    [string.("Thu Jan 01 00:00:01 GMT 1970")],
    value.(:date, "1000"),
    ["DIV-51"]
  ),
  jvm.(
    :date_new_string,
    nil,
    [string.(nil)],
    error.("java.lang.IllegalArgumentException"),
    ["DIV-51"]
  )
  |> Map.put(:case_id, "date-new-string-null"),
  jvm.(
    :date_new_string,
    nil,
    [string.("Wed, 8 Jan 2026 14:30 UTC")],
    value.(:date, "1767882600000"),
    ["DIV-51"]
  )
  |> Map.put(:case_id, "date-new-string-without-seconds"),
  jvm.(
    :date_new_string,
    nil,
    [string.("Thu Jan 01 00:00:01 1970")],
    value.(:date, "1000"),
    ["DIV-51"]
  )
  |> Map.put(:case_id, "date-new-string-without-zone"),
  jvm.(
    :date_new_string,
    nil,
    [string.("Nonsense Jan 01 1970")],
    error.("java.lang.IllegalArgumentException"),
    ["DIV-51"]
  )
  |> Map.put(:case_id, "date-new-string-invalid-weekday"),
  jvm.(
    :date_new_string,
    nil,
    [string.("Junk 01 1970")],
    error.("java.lang.IllegalArgumentException"),
    ["DIV-51"]
  )
  |> Map.put(:case_id, "date-new-string-invalid-month"),
  jvm.(:date_get_time_0, date.(1234), [], value.(:long, "1234"), []),
  jvm.(
    :date_before_date,
    date.(0),
    [date.(1)],
    value.(:boolean, "true"),
    []
  ),
  jvm.(
    :date_after_date,
    date.(1),
    [date.(0)],
    value.(:boolean, "true"),
    []
  ),
  jvm.(:math_abs_int, nil, [int.(-7)], value.(:int, "7"), []),
  jvm.(:math_abs_int, nil, [int.(-2_147_483_648)], value.(:int, "-2147483648"), [])
  |> Map.put(:case_id, "math-abs-int-min-value"),
  jvm.(:math_abs_long, nil, [long.(-9)], value.(:long, "9"), []),
  jvm.(
    :math_abs_long,
    nil,
    [long.(-9_223_372_036_854_775_808)],
    value.(:long, "-9223372036854775808"),
    []
  )
  |> Map.put(:case_id, "math-abs-long-min-value"),
  jvm.(:math_abs_float, nil, [float.(-1.5)], value.(:float, "0x1.8p0"), []),
  jvm.(:math_abs_float, nil, [float.(-0.0)], value.(:float, "0x0.0p0"), [])
  |> Map.put(:case_id, "math-abs-float-negative-zero"),
  jvm.(
    :math_abs_double,
    nil,
    [double.(-1.5)],
    value.(:double, "0x1.8p0"),
    []
  ),
  jvm.(:math_abs_double, nil, [double.("NaN")], value.(:double, "NaN"), [])
  |> Map.put(:case_id, "math-abs-double-nan"),
  jvm.(:math_ceil_double, nil, [double.(1.2)], value.(:double, "0x1.0p1"), []),
  jvm.(:math_ceil_double, nil, [double.(-0.3)], value.(:double, "-0x0.0p0"), [])
  |> Map.put(:case_id, "math-ceil-double-negative-zero"),
  jvm.(
    :math_floor_double,
    nil,
    [double.(-1.2)],
    value.(:double, "-0x1.0p1"),
    []
  ),
  jvm.(:math_floor_double, nil, [double.(0.3)], value.(:double, "0x0.0p0"), [])
  |> Map.put(:case_id, "math-floor-double-positive-zero"),
  jvm.(:math_max_int, nil, [int.(1), int.(2)], value.(:int, "2"), []),
  jvm.(
    :math_max_int,
    nil,
    [int.(-2_147_483_648), int.(2_147_483_647)],
    value.(:int, "2147483647"),
    []
  )
  |> Map.put(:case_id, "math-max-int-boundaries"),
  jvm.(
    :math_max_long,
    nil,
    [long.(8), long.(9)],
    value.(:long, "9"),
    []
  ),
  jvm.(
    :math_max_float,
    nil,
    [float.(-0.0), float.(0.0)],
    value.(:float, "0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "math-max-float-signed-zero"),
  jvm.(
    :math_max_float,
    nil,
    [float.(1.25), float.(2.5)],
    value.(:float, "0x1.4p1"),
    []
  ),
  jvm.(
    :math_max_double,
    nil,
    [double.(1.25), double.(2.5)],
    value.(:double, "0x1.4p1"),
    []
  ),
  jvm.(
    :math_max_double,
    nil,
    [double.("NaN"), double.(1.0)],
    value.(:double, "NaN"),
    []
  )
  |> Map.put(:case_id, "math-max-double-nan"),
  jvm.(:math_min_int, nil, [int.(1), int.(2)], value.(:int, "1"), []),
  jvm.(
    :math_min_long,
    nil,
    [long.(8), long.(9)],
    value.(:long, "8"),
    []
  ),
  jvm.(
    :math_min_float,
    nil,
    [float.(0.0), float.(-0.0)],
    value.(:float, "-0x0.0p0"),
    []
  )
  |> Map.put(:case_id, "math-min-float-signed-zero"),
  jvm.(
    :math_min_float,
    nil,
    [float.(1.25), float.(2.5)],
    value.(:float, "0x1.4p0"),
    []
  ),
  jvm.(
    :math_min_double,
    nil,
    [double.(1.25), double.(2.5)],
    value.(:double, "0x1.4p0"),
    []
  ),
  jvm.(
    :math_min_double,
    nil,
    [double.("NaN"), double.(1.0)],
    value.(:double, "NaN"),
    []
  )
  |> Map.put(:case_id, "math-min-double-nan"),
  fast.(:math_pow_double, nil, [double.(2.0), double.(3.0)], value.(:double, "0x1.0p3"), []),
  jvm.(
    :math_pow_double,
    nil,
    [double.(-2.0), double.(0.5)],
    value.(:double, "NaN"),
    []
  )
  |> Map.put(:case_id, "math-pow-double-negative-fractional"),
  jvm.(:math_round_float, nil, [float.(-1.5)], value.(:int, "-1"), []),
  jvm.(:math_round_float, nil, [float.("NaN")], value.(:int, "0"), [])
  |> Map.put(:case_id, "math-round-float-nan"),
  jvm.(
    :math_round_float,
    nil,
    [float.("Infinity")],
    value.(:int, "2147483647"),
    []
  )
  |> Map.put(:case_id, "math-round-float-positive-infinity"),
  jvm.(
    :math_round_double,
    nil,
    [double.(-1.5)],
    value.(:long, "-1"),
    []
  ),
  jvm.(
    :math_round_double,
    nil,
    [double.(4_503_599_627_370_497.0)],
    value.(:long, "4503599627370497"),
    []
  )
  |> Map.put(:case_id, "math-round-double-exact-integer-above-two-to-the-52"),
  jvm.(
    :math_round_double,
    nil,
    [double.("-Infinity")],
    value.(:long, "-9223372036854775808"),
    []
  )
  |> Map.put(:case_id, "math-round-double-negative-infinity"),
  fast.(:math_sqrt_double, nil, [double.(9.0)], value.(:double, "0x1.8p1"), []),
  jvm.(:math_sqrt_double, nil, [double.(-1.0)], value.(:double, "NaN"), [])
  |> Map.put(:case_id, "math-sqrt-double-negative"),
  jvm.(:math_sqrt_double, nil, [double.(-0.0)], value.(:double, "-0x0.0p0"), [])
  |> Map.put(:case_id, "math-sqrt-double-negative-zero")
]
