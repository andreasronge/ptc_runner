%{
  version: 1,
  projection_policy: %{
    audit_reference_coverage: :all,
    interop_omitted_reference_ids: [
      :math_abs,
      :math_ceil,
      :math_floor,
      :math_max,
      :math_min,
      :math_pow,
      :math_round,
      :math_sqrt
    ],
    interop_omission_reason:
      "Math members use the ordinary function reference plus the generated Java Math audit instead of duplicate Java interop rows."
  },
  references: [
    %{
      member: "parseBoolean",
      kind: :static,
      class_id: :java_lang_boolean,
      spellings: ["Boolean/parseBoolean"],
      overload_ids: [:boolean_parse_boolean_string],
      reference_id: :boolean_parse_boolean,
      callable?: true
    },
    %{
      member: "parseDouble",
      kind: :static,
      class_id: :java_lang_double,
      spellings: ["Double/parseDouble"],
      overload_ids: [:double_parse_double_string],
      reference_id: :double_parse_double,
      callable?: true
    },
    %{
      member: "POSITIVE_INFINITY",
      kind: :field,
      class_id: :java_lang_double,
      spellings: ["Double/POSITIVE_INFINITY"],
      overload_ids: [:double_positive_infinity_field],
      reference_id: :double_positive_infinity,
      callable?: false
    },
    %{
      member: "NEGATIVE_INFINITY",
      kind: :field,
      class_id: :java_lang_double,
      spellings: ["Double/NEGATIVE_INFINITY"],
      overload_ids: [:double_negative_infinity_field],
      reference_id: :double_negative_infinity,
      callable?: false
    },
    %{
      member: "NaN",
      kind: :field,
      class_id: :java_lang_double,
      spellings: ["Double/NaN"],
      overload_ids: [:double_nan_field],
      reference_id: :double_nan,
      callable?: false
    },
    %{
      member: "parseFloat",
      kind: :static,
      class_id: :java_lang_float,
      spellings: ["Float/parseFloat"],
      overload_ids: [:float_parse_float_string],
      reference_id: :float_parse_float,
      callable?: true
    },
    %{
      member: "parseInt",
      kind: :static,
      class_id: :java_lang_integer,
      spellings: ["Integer/parseInt"],
      overload_ids: [:integer_parse_int_string],
      reference_id: :integer_parse_int,
      callable?: true
    },
    %{
      member: "parseLong",
      kind: :static,
      class_id: :java_lang_long,
      spellings: ["Long/parseLong"],
      overload_ids: [:long_parse_long_string],
      reference_id: :long_parse_long,
      callable?: true
    },
    %{
      member: "currentTimeMillis",
      kind: :static,
      class_id: :java_lang_system,
      spellings: ["System/currentTimeMillis"],
      overload_ids: [:system_current_time_millis_0],
      reference_id: :system_current_time_millis,
      callable?: true
    },
    %{
      member: "contains",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".contains"],
      overload_ids: [:string_contains_char_sequence],
      reference_id: :string_contains,
      callable?: true
    },
    %{
      member: "indexOf",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".indexOf"],
      overload_ids: [:string_index_of_string, :string_index_of_string_from],
      reference_id: :string_index_of,
      callable?: true
    },
    %{
      member: "lastIndexOf",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".lastIndexOf"],
      overload_ids: [:string_last_index_of_string],
      reference_id: :string_last_index_of,
      callable?: true
    },
    %{
      member: "toLowerCase",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".toLowerCase"],
      overload_ids: [:string_to_lower_case_0],
      reference_id: :string_to_lower_case,
      callable?: true
    },
    %{
      member: "toUpperCase",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".toUpperCase"],
      overload_ids: [:string_to_upper_case_0],
      reference_id: :string_to_upper_case,
      callable?: true
    },
    %{
      member: "startsWith",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".startsWith"],
      overload_ids: [:string_starts_with_string],
      reference_id: :string_starts_with,
      callable?: true
    },
    %{
      member: "endsWith",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".endsWith"],
      overload_ids: [:string_ends_with_string],
      reference_id: :string_ends_with,
      callable?: true
    },
    %{
      member: "length",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".length"],
      overload_ids: [:string_length_0],
      reference_id: :string_length,
      callable?: true
    },
    %{
      member: "substring",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".substring"],
      overload_ids: [:string_substring_begin, :string_substring_begin_end],
      reference_id: :string_substring,
      callable?: true
    },
    %{
      member: "parse",
      kind: :static,
      class_id: :java_time_local_date,
      spellings: ["LocalDate/parse", "java.time.LocalDate/parse"],
      overload_ids: [:local_date_parse_char_sequence],
      reference_id: :local_date_parse,
      callable?: true
    },
    %{
      member: "toEpochDay",
      kind: :instance,
      class_id: :java_time_local_date,
      spellings: [".toEpochDay"],
      overload_ids: [:local_date_to_epoch_day_0],
      reference_id: :local_date_to_epoch_day,
      callable?: true
    },
    %{
      member: "plusDays",
      kind: :instance,
      class_id: :java_time_local_date,
      spellings: [".plusDays"],
      overload_ids: [:local_date_plus_days_long],
      reference_id: :local_date_plus_days,
      callable?: true
    },
    %{
      member: "minusDays",
      kind: :instance,
      class_id: :java_time_local_date,
      spellings: [".minusDays"],
      overload_ids: [:local_date_minus_days_long],
      reference_id: :local_date_minus_days,
      callable?: true
    },
    %{
      member: "isBefore",
      kind: :instance,
      class_id: :java_time_local_date,
      spellings: [".isBefore"],
      overload_ids: [:local_date_is_before_chrono_local_date],
      reference_id: :local_date_is_before,
      callable?: true
    },
    %{
      member: "isAfter",
      kind: :instance,
      class_id: :java_time_local_date,
      spellings: [".isAfter"],
      overload_ids: [:local_date_is_after_chrono_local_date],
      reference_id: :local_date_is_after,
      callable?: true
    },
    %{
      member: "parse",
      kind: :static,
      class_id: :java_time_instant,
      spellings: ["Instant/parse", "java.time.Instant/parse"],
      overload_ids: [:instant_parse_char_sequence],
      reference_id: :instant_parse,
      callable?: true
    },
    %{
      member: "isBefore",
      kind: :instance,
      class_id: :java_time_instant,
      spellings: [".isBefore"],
      overload_ids: [:instant_is_before_instant],
      reference_id: :instant_is_before,
      callable?: true
    },
    %{
      member: "isAfter",
      kind: :instance,
      class_id: :java_time_instant,
      spellings: [".isAfter"],
      overload_ids: [:instant_is_after_instant],
      reference_id: :instant_is_after,
      callable?: true
    },
    %{
      member: "getTime",
      kind: :instance,
      class_id: :java_time_instant,
      spellings: [".getTime"],
      overload_ids: [:instant_get_time_alias_0],
      reference_id: :instant_get_time_alias,
      callable?: true
    },
    %{
      member: "between",
      kind: :static,
      class_id: :java_time_duration,
      spellings: ["Duration/between", "java.time.Duration/between"],
      overload_ids: [:duration_between_temporal],
      reference_id: :duration_between,
      callable?: true
    },
    %{
      member: "toMillis",
      kind: :instance,
      class_id: :java_time_duration,
      spellings: [".toMillis"],
      overload_ids: [:duration_to_millis_0],
      reference_id: :duration_to_millis,
      callable?: true
    },
    %{
      member: "toDays",
      kind: :instance,
      class_id: :java_time_duration,
      spellings: [".toDays"],
      overload_ids: [:duration_to_days_0],
      reference_id: :duration_to_days,
      callable?: true
    },
    %{
      member: "<init>",
      kind: :constructor,
      class_id: :java_util_date,
      spellings: ["java.util.Date."],
      overload_ids: [:date_new_0, :date_new_long, :date_new_string, :date_new_ptc_temporal],
      reference_id: :date_new,
      callable?: true
    },
    %{
      member: "getTime",
      kind: :instance,
      class_id: :java_util_date,
      spellings: [".getTime"],
      overload_ids: [:date_get_time_0],
      reference_id: :date_get_time,
      callable?: true
    },
    %{
      member: "isBefore",
      kind: :instance,
      class_id: :java_util_date,
      spellings: [".isBefore"],
      overload_ids: [:date_is_before_alias_date],
      reference_id: :date_is_before_alias,
      callable?: true
    },
    %{
      member: "isAfter",
      kind: :instance,
      class_id: :java_util_date,
      spellings: [".isAfter"],
      overload_ids: [:date_is_after_alias_date],
      reference_id: :date_is_after_alias,
      callable?: true
    },
    %{
      member: "abs",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/abs"],
      overload_ids: [:math_abs_int, :math_abs_long, :math_abs_float, :math_abs_double],
      reference_id: :math_abs,
      callable?: true
    },
    %{
      member: "ceil",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/ceil"],
      overload_ids: [:math_ceil_double],
      reference_id: :math_ceil,
      callable?: true
    },
    %{
      member: "floor",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/floor"],
      overload_ids: [:math_floor_double],
      reference_id: :math_floor,
      callable?: true
    },
    %{
      member: "max",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/max"],
      overload_ids: [:math_max_int, :math_max_long, :math_max_float, :math_max_double],
      reference_id: :math_max,
      callable?: true
    },
    %{
      member: "min",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/min"],
      overload_ids: [:math_min_int, :math_min_long, :math_min_float, :math_min_double],
      reference_id: :math_min,
      callable?: true
    },
    %{
      member: "pow",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/pow"],
      overload_ids: [:math_pow_double],
      reference_id: :math_pow,
      callable?: true
    },
    %{
      member: "round",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/round"],
      overload_ids: [:math_round_float, :math_round_double],
      reference_id: :math_round,
      callable?: true
    },
    %{
      member: "sqrt",
      kind: :static,
      class_id: :java_lang_math,
      spellings: ["Math/sqrt"],
      overload_ids: [:math_sqrt_double],
      reference_id: :math_sqrt,
      callable?: true
    }
  ],
  classes: [
    %{
      name: "java.lang.Boolean",
      class_id: :java_lang_boolean,
      spellings: ["Boolean"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.Double",
      class_id: :java_lang_double,
      spellings: ["Double"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.Float",
      class_id: :java_lang_float,
      spellings: ["Float"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.Integer",
      class_id: :java_lang_integer,
      spellings: ["Integer"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.Long",
      class_id: :java_lang_long,
      spellings: ["Long"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.Math",
      class_id: :java_lang_math,
      spellings: ["Math"],
      receiver_profile: nil
    },
    %{
      name: "java.lang.String",
      class_id: :java_lang_string,
      spellings: [],
      receiver_profile: :string
    },
    %{
      name: "java.lang.System",
      class_id: :java_lang_system,
      spellings: ["System"],
      receiver_profile: nil
    },
    %{
      name: "java.time.LocalDate",
      class_id: :java_time_local_date,
      spellings: ["LocalDate", "java.time.LocalDate"],
      receiver_profile: :local_date
    },
    %{
      name: "java.time.Instant",
      class_id: :java_time_instant,
      spellings: ["Instant", "java.time.Instant"],
      receiver_profile: :instant
    },
    %{
      name: "java.time.Duration",
      class_id: :java_time_duration,
      spellings: ["Duration", "java.time.Duration"],
      receiver_profile: :duration
    },
    %{
      name: "java.time.Period",
      class_id: :java_time_period,
      spellings: [],
      receiver_profile: nil
    },
    %{
      name: "java.util.Date",
      class_id: :java_util_date,
      spellings: ["java.util.Date."],
      receiver_profile: :date
    }
  ],
  overloads: [
    %{
      return: :boolean,
      arity: 1,
      arguments: [:string],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :"Boolean/parseBoolean"},
      reference_id: :boolean_parse_boolean,
      descriptor: "(Ljava/lang/String;)Z",
      overload_id: :boolean_parse_boolean_string,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :"parse-double"},
      reference_id: :double_parse_double,
      descriptor: "(Ljava/lang/String;)D",
      overload_id: :double_parse_double_string,
      divergence_ids: ["GAP-J01"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :POSITIVE_INFINITY},
      reference_id: :double_positive_infinity,
      descriptor: "D",
      overload_id: :double_positive_infinity_field,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :NEGATIVE_INFINITY},
      reference_id: :double_negative_infinity,
      descriptor: "D",
      overload_id: :double_negative_infinity_field,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :NaN},
      reference_id: :double_nan,
      descriptor: "D",
      overload_id: :double_nan_field,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :"parse-double"},
      reference_id: :float_parse_float,
      descriptor: "(Ljava/lang/String;)F",
      overload_id: :float_parse_float_string,
      divergence_ids: ["GAP-J01"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception],
      receiver: nil,
      route: {:legacy_env, :"parse-long"},
      reference_id: :integer_parse_int,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :integer_parse_int_string,
      divergence_ids: ["GAP-J01"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception],
      receiver: nil,
      route: {:legacy_env, :"parse-long"},
      reference_id: :long_parse_long,
      descriptor: "(Ljava/lang/String;)J",
      overload_id: :long_parse_long_string,
      divergence_ids: ["GAP-J01"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :currentTimeMillis},
      reference_id: :system_current_time_millis,
      descriptor: "()J",
      overload_id: :system_current_time_millis_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:char_sequence],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".contains"},
      reference_id: :string_contains,
      descriptor: "(Ljava/lang/CharSequence;)Z",
      overload_id: :string_contains_char_sequence,
      divergence_ids: ["DIV-40", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".indexOf"},
      reference_id: :string_index_of,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :string_index_of_string,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:string, :int],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".indexOf"},
      reference_id: :string_index_of,
      descriptor: "(Ljava/lang/String;I)I",
      overload_id: :string_index_of_string_from,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".lastIndexOf"},
      reference_id: :string_last_index_of,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :string_last_index_of_string,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :string,
      route: {:legacy_env, :".toLowerCase"},
      reference_id: :string_to_lower_case,
      descriptor: "()Ljava/lang/String;",
      overload_id: :string_to_lower_case_0,
      divergence_ids: ["DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :string,
      route: {:legacy_env, :".toUpperCase"},
      reference_id: :string_to_upper_case,
      descriptor: "()Ljava/lang/String;",
      overload_id: :string_to_upper_case_0,
      divergence_ids: ["DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:string],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".startsWith"},
      reference_id: :string_starts_with,
      descriptor: "(Ljava/lang/String;)Z",
      overload_id: :string_starts_with_string,
      divergence_ids: ["DIV-40", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:string],
      errors: [:null_pointer_exception],
      receiver: :string,
      route: {:legacy_env, :".endsWith"},
      reference_id: :string_ends_with,
      descriptor: "(Ljava/lang/String;)Z",
      overload_id: :string_ends_with_string,
      divergence_ids: ["DIV-40", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :string,
      route: {:legacy_env, :".length"},
      reference_id: :string_length,
      descriptor: "()I",
      overload_id: :string_length_0,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 1,
      arguments: [:int],
      errors: [:string_index_out_of_bounds_exception],
      receiver: :string,
      route: {:legacy_env, :".substring"},
      reference_id: :string_substring,
      descriptor: "(I)Ljava/lang/String;",
      overload_id: :string_substring_begin,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 2,
      arguments: [:int, :int],
      errors: [:string_index_out_of_bounds_exception],
      receiver: :string,
      route: {:legacy_env, :".substring"},
      reference_id: :string_substring,
      descriptor: "(II)Ljava/lang/String;",
      overload_id: :string_substring_begin_end,
      divergence_ids: ["GAP-J09", "DIV-41"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :local_date,
      arity: 1,
      arguments: [:char_sequence],
      errors: [:date_time_parse_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :parse},
      reference_id: :local_date_parse,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;",
      overload_id: :local_date_parse_char_sequence,
      divergence_ids: ["GAP-J06"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :local_date,
      route: {:legacy_env, :".toEpochDay"},
      reference_id: :local_date_to_epoch_day,
      descriptor: "()J",
      overload_id: :local_date_to_epoch_day_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :local_date,
      arity: 1,
      arguments: [:long],
      errors: [:date_time_exception, :arithmetic_exception],
      receiver: :local_date,
      route: {:legacy_env, :".plusDays"},
      reference_id: :local_date_plus_days,
      descriptor: "(J)Ljava/time/LocalDate;",
      overload_id: :local_date_plus_days_long,
      divergence_ids: ["GAP-J12"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :local_date,
      arity: 1,
      arguments: [:long],
      errors: [:date_time_exception, :arithmetic_exception],
      receiver: :local_date,
      route: {:legacy_env, :".minusDays"},
      reference_id: :local_date_minus_days,
      descriptor: "(J)Ljava/time/LocalDate;",
      overload_id: :local_date_minus_days_long,
      divergence_ids: ["GAP-J12"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:local_date],
      errors: [:null_pointer_exception],
      receiver: :local_date,
      route: {:legacy_env, :".isBefore"},
      reference_id: :local_date_is_before,
      descriptor: "(Ljava/time/chrono/ChronoLocalDate;)Z",
      overload_id: :local_date_is_before_chrono_local_date,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:local_date],
      errors: [:null_pointer_exception],
      receiver: :local_date,
      route: {:legacy_env, :".isAfter"},
      reference_id: :local_date_is_after,
      descriptor: "(Ljava/time/chrono/ChronoLocalDate;)Z",
      overload_id: :local_date_is_after_chrono_local_date,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :instant,
      arity: 1,
      arguments: [:char_sequence],
      errors: [:date_time_parse_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :parse},
      reference_id: :instant_parse,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/Instant;",
      overload_id: :instant_parse_char_sequence,
      divergence_ids: ["GAP-J06"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:instant],
      errors: [:null_pointer_exception],
      receiver: :instant,
      route: {:legacy_env, :".isBefore"},
      reference_id: :instant_is_before,
      descriptor: "(Ljava/time/Instant;)Z",
      overload_id: :instant_is_before_instant,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:instant],
      errors: [:null_pointer_exception],
      receiver: :instant,
      route: {:legacy_env, :".isAfter"},
      reference_id: :instant_is_after,
      descriptor: "(Ljava/time/Instant;)Z",
      overload_id: :instant_is_after_instant,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :instant,
      route: {:legacy_env, :".getTime"},
      reference_id: :instant_get_time_alias,
      descriptor: nil,
      overload_id: :instant_get_time_alias_0,
      divergence_ids: ["GAP-J04"],
      classification: :intentional_ptc_alias,
      attestation: :ptc_only
    },
    %{
      return: :duration,
      arity: 2,
      arguments: [:temporal, :temporal],
      errors: [:date_time_exception, :arithmetic_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :"Duration/between"},
      reference_id: :duration_between,
      descriptor:
        "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;",
      overload_id: :duration_between_temporal,
      divergence_ids: ["GAP-J19"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :duration,
      route: {:legacy_env, :".toMillis"},
      reference_id: :duration_to_millis,
      descriptor: "()J",
      overload_id: :duration_to_millis_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :duration,
      route: {:legacy_env, :".toDays"},
      reference_id: :duration_to_days,
      descriptor: "()J",
      overload_id: :duration_to_days_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :date,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :"java.util.Date."},
      reference_id: :date_new,
      descriptor: "()V",
      overload_id: :date_new_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :date,
      arity: 1,
      arguments: [:long],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :"java.util.Date."},
      reference_id: :date_new,
      descriptor: "(J)V",
      overload_id: :date_new_long,
      divergence_ids: ["GAP-J03"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :date,
      arity: 1,
      arguments: [:string],
      errors: [:illegal_argument_exception, :null_pointer_exception],
      receiver: nil,
      route: {:legacy_env, :"java.util.Date."},
      reference_id: :date_new,
      descriptor: "(Ljava/lang/String;)V",
      overload_id: :date_new_string,
      divergence_ids: ["GAP-J06", "GAP-J11"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :date,
      arity: 1,
      arguments: [:ptc_temporal],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :"java.util.Date."},
      reference_id: :date_new,
      descriptor: nil,
      overload_id: :date_new_ptc_temporal,
      divergence_ids: ["GAP-J21"],
      classification: :ptc_extension,
      attestation: :ptc_only
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: :date,
      route: {:legacy_env, :".getTime"},
      reference_id: :date_get_time,
      descriptor: "()J",
      overload_id: :date_get_time_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:date],
      errors: [:null_pointer_exception],
      receiver: :date,
      route: {:legacy_env, :".isBefore"},
      reference_id: :date_is_before_alias,
      descriptor: nil,
      overload_id: :date_is_before_alias_date,
      divergence_ids: ["GAP-J20"],
      classification: :intentional_ptc_alias,
      attestation: :ptc_only
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:date],
      errors: [:null_pointer_exception],
      receiver: :date,
      route: {:legacy_env, :".isAfter"},
      reference_id: :date_is_after_alias,
      descriptor: nil,
      overload_id: :date_is_after_alias_date,
      divergence_ids: ["GAP-J20"],
      classification: :intentional_ptc_alias,
      attestation: :ptc_only
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:int],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :abs},
      reference_id: :math_abs,
      descriptor: "(I)I",
      overload_id: :math_abs_int,
      divergence_ids: ["DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:long],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :abs},
      reference_id: :math_abs,
      descriptor: "(J)J",
      overload_id: :math_abs_long,
      divergence_ids: ["DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 1,
      arguments: [:float],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :abs},
      reference_id: :math_abs,
      descriptor: "(F)F",
      overload_id: :math_abs_float,
      divergence_ids: ["DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :abs},
      reference_id: :math_abs,
      descriptor: "(D)D",
      overload_id: :math_abs_double,
      divergence_ids: ["DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :ceil},
      reference_id: :math_ceil,
      descriptor: "(D)D",
      overload_id: :math_ceil_double,
      divergence_ids: ["DIV-42"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :floor},
      reference_id: :math_floor,
      descriptor: "(D)D",
      overload_id: :math_floor_double,
      divergence_ids: ["DIV-42"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:int, :int],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :max},
      reference_id: :math_max,
      descriptor: "(II)I",
      overload_id: :math_max_int,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 2,
      arguments: [:long, :long],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :max},
      reference_id: :math_max,
      descriptor: "(JJ)J",
      overload_id: :math_max_long,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 2,
      arguments: [:float, :float],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :max},
      reference_id: :math_max,
      descriptor: "(FF)F",
      overload_id: :math_max_float,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :max},
      reference_id: :math_max,
      descriptor: "(DD)D",
      overload_id: :math_max_double,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:int, :int],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :min},
      reference_id: :math_min,
      descriptor: "(II)I",
      overload_id: :math_min_int,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 2,
      arguments: [:long, :long],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :min},
      reference_id: :math_min,
      descriptor: "(JJ)J",
      overload_id: :math_min_long,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 2,
      arguments: [:float, :float],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :min},
      reference_id: :math_min,
      descriptor: "(FF)F",
      overload_id: :math_min_float,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :min},
      reference_id: :math_min,
      descriptor: "(DD)D",
      overload_id: :math_min_double,
      divergence_ids: ["DIV-44", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :pow},
      reference_id: :math_pow,
      descriptor: "(DD)D",
      overload_id: :math_pow_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:float],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :round},
      reference_id: :math_round,
      descriptor: "(F)I",
      overload_id: :math_round_float,
      divergence_ids: ["DIV-43", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :round},
      reference_id: :math_round,
      descriptor: "(D)J",
      overload_id: :math_round_double,
      divergence_ids: ["DIV-43", "DIV-45"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:legacy_env, :sqrt},
      reference_id: :math_sqrt,
      descriptor: "(D)D",
      overload_id: :math_sqrt_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    }
  ],
  namespaces: [
    %{
      category: :math,
      namespace: :Math,
      class_id: :java_lang_math,
      members: [
        %{
          source_name: :abs,
          reference_id: :math_abs,
          classification: :admitted,
          legacy_binding: :abs
        },
        %{
          source_name: :"bit-and",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-and"
        },
        %{
          source_name: :"bit-and-not",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-and-not"
        },
        %{
          source_name: :"bit-clear",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-clear"
        },
        %{
          source_name: :"bit-flip",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-flip"
        },
        %{
          source_name: :"bit-not",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-not"
        },
        %{
          source_name: :"bit-or",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-or"
        },
        %{
          source_name: :"bit-set",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-set"
        },
        %{
          source_name: :"bit-shift-left",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-shift-left"
        },
        %{
          source_name: :"bit-shift-right",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-shift-right"
        },
        %{
          source_name: :"bit-test",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-test"
        },
        %{
          source_name: :"bit-xor",
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :"bit-xor"
        },
        %{
          source_name: :ceil,
          reference_id: :math_ceil,
          classification: :admitted,
          legacy_binding: :ceil
        },
        %{
          source_name: :double,
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :double
        },
        %{
          source_name: :float,
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :float
        },
        %{
          source_name: :floor,
          reference_id: :math_floor,
          classification: :admitted,
          legacy_binding: :floor
        },
        %{
          source_name: :int,
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :int
        },
        %{
          source_name: :max,
          reference_id: :math_max,
          classification: :admitted,
          legacy_binding: :max
        },
        %{
          source_name: :min,
          reference_id: :math_min,
          classification: :admitted,
          legacy_binding: :min
        },
        %{
          source_name: :pow,
          reference_id: :math_pow,
          classification: :admitted,
          legacy_binding: :pow
        },
        %{
          source_name: :quot,
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :quot
        },
        %{
          source_name: :round,
          reference_id: :math_round,
          classification: :admitted,
          legacy_binding: :round
        },
        %{
          source_name: :sqrt,
          reference_id: :math_sqrt,
          classification: :admitted,
          legacy_binding: :sqrt
        },
        %{
          source_name: :trunc,
          reference_id: nil,
          classification: :incorrect_non_java_alias,
          legacy_binding: :trunc
        }
      ]
    },
    %{
      category: :interop,
      namespace: :System,
      class_id: :java_lang_system,
      members: [
        %{
          source_name: :currentTimeMillis,
          reference_id: :system_current_time_millis,
          classification: :admitted,
          legacy_binding: :currentTimeMillis
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Boolean,
      class_id: :java_lang_boolean,
      members: [
        %{
          source_name: "parseBoolean",
          reference_id: :boolean_parse_boolean,
          classification: :admitted,
          legacy_binding: :"Boolean/parseBoolean"
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Double,
      class_id: :java_lang_double,
      members: [
        %{
          source_name: "parseDouble",
          reference_id: :double_parse_double,
          classification: :admitted,
          legacy_binding: :"parse-double"
        },
        %{
          source_name: :POSITIVE_INFINITY,
          reference_id: :double_positive_infinity,
          classification: :admitted,
          legacy_binding: :POSITIVE_INFINITY
        },
        %{
          source_name: :NEGATIVE_INFINITY,
          reference_id: :double_negative_infinity,
          classification: :admitted,
          legacy_binding: :NEGATIVE_INFINITY
        },
        %{
          source_name: :NaN,
          reference_id: :double_nan,
          classification: :admitted,
          legacy_binding: :NaN
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Float,
      class_id: :java_lang_float,
      members: [
        %{
          source_name: "parseFloat",
          reference_id: :float_parse_float,
          classification: :admitted,
          legacy_binding: :"parse-double"
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Integer,
      class_id: :java_lang_integer,
      members: [
        %{
          source_name: "parseInt",
          reference_id: :integer_parse_int,
          classification: :admitted,
          legacy_binding: :"parse-long"
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Long,
      class_id: :java_lang_long,
      members: [
        %{
          source_name: "parseLong",
          reference_id: :long_parse_long,
          classification: :admitted,
          legacy_binding: :"parse-long"
        }
      ]
    },
    %{
      category: :interop,
      namespace: :LocalDate,
      class_id: :java_time_local_date,
      members: [
        %{
          source_name: :parse,
          reference_id: :local_date_parse,
          classification: :admitted,
          legacy_binding: :parse
        }
      ]
    },
    %{
      category: :interop,
      namespace: :"java.time.LocalDate",
      class_id: :java_time_local_date,
      members: [
        %{
          source_name: :parse,
          reference_id: :local_date_parse,
          classification: :admitted,
          legacy_binding: :parse
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Instant,
      class_id: :java_time_instant,
      members: [
        %{
          source_name: :parse,
          reference_id: :instant_parse,
          classification: :admitted,
          legacy_binding: :parse
        }
      ]
    },
    %{
      category: :interop,
      namespace: :"java.time.Instant",
      class_id: :java_time_instant,
      members: [
        %{
          source_name: :parse,
          reference_id: :instant_parse,
          classification: :admitted,
          legacy_binding: :parse
        }
      ]
    },
    %{
      category: :interop,
      namespace: :Duration,
      class_id: :java_time_duration,
      legacy_lookup: :qualified_table,
      members: [
        %{
          source_name: :between,
          reference_id: :duration_between,
          classification: :admitted,
          legacy_binding: :"Duration/between"
        }
      ]
    },
    %{
      category: :interop,
      namespace: :"java.time.Duration",
      class_id: :java_time_duration,
      members: [
        %{
          source_name: :between,
          reference_id: :duration_between,
          classification: :admitted,
          legacy_binding: :"Duration/between"
        }
      ]
    }
  ],
  audit_specs: [
    %{
      scope: "Java standard",
      path: "docs/conformance/java-math-audit.md",
      description: "Comparison of `java.lang.Math` methods against PTC-Lisp builtins.",
      title: "Java Math Audit for PTC-Lisp",
      key: :java_math_audit,
      target: "curated Java standard methods",
      class_id: :java_lang_math,
      namespace: "java.lang.Math",
      conformance_prefix: "Math/",
      default_kind: :static,
      namespace_label: "`Math/`, `java.lang.Math`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-boolean-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.Boolean`.",
      title: "Java Boolean Audit for PTC-Lisp",
      key: :java_lang_boolean_audit,
      target: "curated Java standard methods/constants",
      class_id: :java_lang_boolean,
      namespace: "java.lang.Boolean",
      default_kind: :static,
      namespace_label: "`Boolean/`, `java.lang.Boolean`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-double-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.Double`.",
      title: "Java Double Audit for PTC-Lisp",
      key: :java_lang_double_audit,
      target: "curated Java standard methods/constants",
      class_id: :java_lang_double,
      namespace: "java.lang.Double",
      default_kind: :static,
      namespace_label: "`Double/`, `java.lang.Double`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-float-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.Float`.",
      title: "Java Float Audit for PTC-Lisp",
      key: :java_lang_float_audit,
      target: "curated Java standard methods",
      class_id: :java_lang_float,
      namespace: "java.lang.Float",
      default_kind: :static,
      namespace_label: "`Float/`, `java.lang.Float`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-integer-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.Integer`.",
      title: "Java Integer Audit for PTC-Lisp",
      key: :java_lang_integer_audit,
      target: "curated Java standard methods/constants",
      class_id: :java_lang_integer,
      namespace: "java.lang.Integer",
      default_kind: :static,
      namespace_label: "`Integer/`, `java.lang.Integer`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-long-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.Long`.",
      title: "Java Long Audit for PTC-Lisp",
      key: :java_lang_long_audit,
      target: "curated Java standard methods/constants",
      class_id: :java_lang_long,
      namespace: "java.lang.Long",
      default_kind: :static,
      namespace_label: "`Long/`, `java.lang.Long`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-string-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.String` methods.",
      title: "Java String Audit for PTC-Lisp",
      key: :java_lang_string_audit,
      target: "curated Java standard methods",
      class_id: :java_lang_string,
      namespace: "java.lang.String",
      default_kind: :instance,
      namespace_label: "`java.lang.String` dot methods"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-lang-system-audit.md",
      description: "Curated LLM-compatibility target for `java.lang.System`.",
      title: "Java System Audit for PTC-Lisp",
      key: :java_lang_system_audit,
      target: "curated Java standard methods",
      class_id: :java_lang_system,
      namespace: "java.lang.System",
      default_kind: :static,
      namespace_label: "`System/`, `java.lang.System`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-time-local-date-audit.md",
      description: "Curated LLM-compatibility target for `java.time.LocalDate`.",
      title: "Java LocalDate Audit for PTC-Lisp",
      key: :java_time_local_date_audit,
      target: "curated Java standard methods",
      class_id: :java_time_local_date,
      namespace: "java.time.LocalDate",
      default_kind: :static,
      namespace_label: "`LocalDate/`, `java.time.LocalDate/`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-time-instant-audit.md",
      description: "Curated LLM-compatibility target for `java.time.Instant`.",
      title: "Java Instant Audit for PTC-Lisp",
      key: :java_time_instant_audit,
      target: "curated Java standard methods",
      class_id: :java_time_instant,
      namespace: "java.time.Instant",
      default_kind: :static,
      namespace_label: "`Instant/`, `java.time.Instant/`"
    },
    %{
      scope: "Java standard candidate",
      path: "docs/conformance/java-time-duration-audit.md",
      description: "Curated LLM-compatibility target for `java.time.Duration`.",
      title: "Java Duration Audit for PTC-Lisp",
      key: :java_time_duration_audit,
      target: "curated Java standard methods",
      class_id: :java_time_duration,
      namespace: "java.time.Duration",
      default_kind: :static,
      namespace_label: "`Duration/`, `java.time.Duration`"
    },
    %{
      scope: "Java standard candidate",
      path: "docs/conformance/java-time-period-audit.md",
      description: "Curated LLM-compatibility target for `java.time.Period`.",
      title: "Java Period Audit for PTC-Lisp",
      key: :java_time_period_audit,
      target: "curated Java standard methods",
      class_id: :java_time_period,
      namespace: "java.time.Period",
      default_kind: :static,
      namespace_label: "`Period/`, `java.time.Period`"
    },
    %{
      scope: "Java standard",
      path: "docs/conformance/java-util-date-audit.md",
      description: "Curated LLM-compatibility target for `java.util.Date`.",
      title: "Java Date Audit for PTC-Lisp",
      key: :java_util_date_audit,
      target: "curated Java standard methods/constructors",
      class_id: :java_util_date,
      namespace: "java.util.Date",
      default_kind: :instance,
      namespace_label: "`java.util.Date.`"
    }
  ],
  audits: %{
    java_math_audit: [
      %{
        name: "abs",
        status: :supported,
        description: "Returns the absolute value",
        notes:
          "DIV-45: uses PTC-Lisp arbitrary-precision integers, so abs returns the mathematically correct positive value and accepts BigInt input rather than reproducing Java long-overflow/overload artifacts",
        reference_id: :math_abs,
        jvm_descriptor_attestations: %{
          math_abs_int: "(I)I",
          math_abs_long: "(J)J",
          math_abs_float: "(F)F",
          math_abs_double: "(D)D"
        },
        admitted_overload_divergences: %{
          math_abs_int: ["DIV-45"],
          math_abs_long: ["DIV-45"],
          math_abs_float: ["DIV-45"],
          math_abs_double: ["DIV-45"]
        },
        target_id: :java_math_audit_abs
      },
      %{
        name: "acos",
        status: :candidate,
        description: "Returns the arc cosine of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_acos
      },
      %{
        name: "addExact",
        status: :not_relevant,
        description: "Returns sum, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_addexact
      },
      %{
        name: "asin",
        status: :candidate,
        description: "Returns the arc sine of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_asin
      },
      %{
        name: "atan",
        status: :candidate,
        description: "Returns the arc tangent of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_atan
      },
      %{
        name: "atan2",
        status: :candidate,
        description: "Returns angle theta from (x,y) to polar (r,theta)",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_atan2
      },
      %{
        name: "cbrt",
        status: :candidate,
        description: "Returns the cube root of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_cbrt
      },
      %{
        name: "ceil",
        status: :supported,
        description: "Returns the smallest integer >= argument",
        notes:
          "DIV-42: integer-returning PTC-Lisp extension, so finite results render as integers rather than Java's double shape",
        reference_id: :math_ceil,
        jvm_descriptor_attestations: %{math_ceil_double: "(D)D"},
        admitted_overload_divergences: %{math_ceil_double: ["DIV-42"]},
        target_id: :java_math_audit_ceil
      },
      %{
        name: "copySign",
        status: :not_relevant,
        description: "Returns first arg with sign of second arg",
        notes: "low-level IEEE 754 manipulation",
        reference_id: nil,
        target_id: :java_math_audit_copysign
      },
      %{
        name: "cos",
        status: :candidate,
        description: "Returns the trigonometric cosine of an angle",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_cos
      },
      %{
        name: "cosh",
        status: :candidate,
        description: "Returns the hyperbolic cosine of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_cosh
      },
      %{
        name: "decrementExact",
        status: :not_relevant,
        description: "Returns argument decremented by one, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_decrementexact
      },
      %{
        name: "exp",
        status: :candidate,
        description: "Returns Euler's number e raised to the power of a",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_exp
      },
      %{
        name: "expm1",
        status: :not_relevant,
        description: "Returns e^x - 1",
        notes: "specialized numerical precision, low demand",
        reference_id: nil,
        target_id: :java_math_audit_expm1
      },
      %{
        name: "floor",
        status: :supported,
        description: "Returns the largest integer <= argument",
        notes:
          "DIV-42: integer-returning PTC-Lisp extension, so finite results render as integers rather than Java's double shape",
        reference_id: :math_floor,
        jvm_descriptor_attestations: %{math_floor_double: "(D)D"},
        admitted_overload_divergences: %{math_floor_double: ["DIV-42"]},
        target_id: :java_math_audit_floor
      },
      %{
        name: "floorDiv",
        status: :not_relevant,
        description: "Returns floor of integer division",
        notes: "Java integer division semantics; use quot + floor",
        reference_id: nil,
        target_id: :java_math_audit_floordiv
      },
      %{
        name: "floorMod",
        status: :not_relevant,
        description: "Returns floor modulus of arguments",
        notes: "Java integer semantics; use mod",
        reference_id: nil,
        target_id: :java_math_audit_floormod
      },
      %{
        name: "fma",
        status: :not_relevant,
        description: "Fused multiply-add",
        notes: "specialized numerical precision",
        reference_id: nil,
        target_id: :java_math_audit_fma
      },
      %{
        name: "getExponent",
        status: :not_relevant,
        description: "Returns unbiased exponent of a float/double",
        notes: "low-level IEEE 754 inspection",
        reference_id: nil,
        target_id: :java_math_audit_getexponent
      },
      %{
        name: "hypot",
        status: :candidate,
        description: "Returns sqrt(x^2 + y^2) without intermediate overflow",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_hypot
      },
      %{
        name: "IEEEremainder",
        status: :not_relevant,
        description: "Returns IEEE 754 remainder",
        notes: "low-level IEEE 754 semantics; use rem/mod",
        reference_id: nil,
        target_id: :java_math_audit_ieeeremainder
      },
      %{
        name: "incrementExact",
        status: :not_relevant,
        description: "Returns argument incremented by one, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_incrementexact
      },
      %{
        name: "log",
        status: :candidate,
        description: "Returns the natural logarithm (base e) of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_log
      },
      %{
        name: "log10",
        status: :candidate,
        description: "Returns the base 10 logarithm of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_log10
      },
      %{
        name: "log1p",
        status: :not_relevant,
        description: "Returns ln(1 + x)",
        notes: "specialized numerical precision, low demand",
        reference_id: nil,
        target_id: :java_math_audit_log1p
      },
      %{
        name: "max",
        status: :supported,
        description: "Returns the greater of two values",
        notes:
          "DIV-44: max is the Clojure-named variadic helper (Math/max is an alias), not Java's two-argument primitive. DIV-45: mixed numeric and total-ordering comparisons are accepted via PTC-Lisp's generic value model rather than Java's primitive overloads",
        reference_id: :math_max,
        jvm_descriptor_attestations: %{
          math_max_int: "(II)I",
          math_max_long: "(JJ)J",
          math_max_float: "(FF)F",
          math_max_double: "(DD)D"
        },
        admitted_overload_divergences: %{
          math_max_int: ["DIV-44", "DIV-45"],
          math_max_long: ["DIV-44", "DIV-45"],
          math_max_float: ["DIV-44", "DIV-45"],
          math_max_double: ["DIV-44", "DIV-45"]
        },
        target_id: :java_math_audit_max
      },
      %{
        name: "min",
        status: :supported,
        description: "Returns the smaller of two values",
        notes:
          "DIV-44: min is the Clojure-named variadic helper (Math/min is an alias), not Java's two-argument primitive. DIV-45: mixed numeric and total-ordering comparisons are accepted via PTC-Lisp's generic value model rather than Java's primitive overloads",
        reference_id: :math_min,
        jvm_descriptor_attestations: %{
          math_min_int: "(II)I",
          math_min_long: "(JJ)J",
          math_min_float: "(FF)F",
          math_min_double: "(DD)D"
        },
        admitted_overload_divergences: %{
          math_min_int: ["DIV-44", "DIV-45"],
          math_min_long: ["DIV-44", "DIV-45"],
          math_min_float: ["DIV-44", "DIV-45"],
          math_min_double: ["DIV-44", "DIV-45"]
        },
        target_id: :java_math_audit_min
      },
      %{
        name: "multiplyExact",
        status: :not_relevant,
        description: "Returns product, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_multiplyexact
      },
      %{
        name: "multiplyHigh",
        status: :not_relevant,
        description: "Returns high 64 bits of 128-bit product",
        notes: "low-level 64-bit arithmetic",
        reference_id: nil,
        target_id: :java_math_audit_multiplyhigh
      },
      %{
        name: "negateExact",
        status: :not_relevant,
        description: "Returns negation, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_negateexact
      },
      %{
        name: "nextAfter",
        status: :not_relevant,
        description: "Returns adjacent floating-point value",
        notes: "low-level IEEE 754 manipulation",
        reference_id: nil,
        target_id: :java_math_audit_nextafter
      },
      %{
        name: "nextDown",
        status: :not_relevant,
        description: "Returns adjacent floating-point value towards negative infinity",
        notes: "low-level IEEE 754 manipulation",
        reference_id: nil,
        target_id: :java_math_audit_nextdown
      },
      %{
        name: "nextUp",
        status: :not_relevant,
        description: "Returns adjacent floating-point value towards positive infinity",
        notes: "low-level IEEE 754 manipulation",
        reference_id: nil,
        target_id: :java_math_audit_nextup
      },
      %{
        name: "pow",
        status: :supported,
        description: "Returns the value of a raised to the power of b",
        notes:
          "Follows java.lang.Math.pow's IEEE 754 special-case table, returning :nan / :infinity / :negative_infinity as recoverable signal values instead of raising (e.g. (pow -1 0.5) => NaN, (pow 0 -1) => Inf)",
        reference_id: :math_pow,
        jvm_descriptor_attestations: %{math_pow_double: "(DD)D"},
        admitted_overload_divergences: %{math_pow_double: []},
        target_id: :java_math_audit_pow
      },
      %{
        name: "random",
        status: :candidate,
        description: "Returns a pseudorandom double between 0.0 and 1.0",
        notes: "pure (non-deterministic but side-effect free)",
        reference_id: nil,
        target_id: :java_math_audit_random
      },
      %{
        name: "rint",
        status: :not_relevant,
        description: "Returns closest double to argument that is a mathematical integer",
        notes: "use round instead",
        reference_id: nil,
        target_id: :java_math_audit_rint
      },
      %{
        name: "round",
        status: :supported,
        description: "Returns the closest long/int to the argument",
        notes:
          "DIV-43: round-half-away-from-zero, integer result, and special values (NaN/infinity) are preserved rather than Java's floor(x+0.5) and long saturation. DIV-45: integer and BigInt arguments are accepted (returned unchanged) via PTC-Lisp's value model rather than Java's float/double-only overloads",
        reference_id: :math_round,
        jvm_descriptor_attestations: %{math_round_float: "(F)I", math_round_double: "(D)J"},
        admitted_overload_divergences: %{
          math_round_float: ["DIV-43", "DIV-45"],
          math_round_double: ["DIV-43", "DIV-45"]
        },
        target_id: :java_math_audit_round
      },
      %{
        name: "scalb",
        status: :not_relevant,
        description: "Returns d × 2^scaleFactor",
        notes: "low-level IEEE 754 manipulation",
        reference_id: nil,
        target_id: :java_math_audit_scalb
      },
      %{
        name: "signum",
        status: :candidate,
        description: "Returns the signum function of the argument",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_signum
      },
      %{
        name: "sin",
        status: :candidate,
        description: "Returns the trigonometric sine of an angle",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_sin
      },
      %{
        name: "sinh",
        status: :candidate,
        description: "Returns the hyperbolic sine of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_sinh
      },
      %{
        name: "sqrt",
        status: :supported,
        description: "Returns the positive square root of a value",
        notes: "",
        reference_id: :math_sqrt,
        jvm_descriptor_attestations: %{math_sqrt_double: "(D)D"},
        admitted_overload_divergences: %{math_sqrt_double: []},
        target_id: :java_math_audit_sqrt
      },
      %{
        name: "subtractExact",
        status: :not_relevant,
        description: "Returns difference, throwing on overflow",
        notes: "Java overflow semantics not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_subtractexact
      },
      %{
        name: "tan",
        status: :candidate,
        description: "Returns the trigonometric tangent of an angle",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_tan
      },
      %{
        name: "tanh",
        status: :candidate,
        description: "Returns the hyperbolic tangent of a value",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_tanh
      },
      %{
        name: "toDegrees",
        status: :candidate,
        description: "Converts an angle from radians to degrees",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_todegrees
      },
      %{
        name: "toIntExact",
        status: :not_relevant,
        description: "Returns long narrowed to int, throwing on overflow",
        notes: "Java type narrowing not applicable on BEAM",
        reference_id: nil,
        target_id: :java_math_audit_tointexact
      },
      %{
        name: "toRadians",
        status: :candidate,
        description: "Converts an angle from degrees to radians",
        notes: "pure math",
        reference_id: nil,
        target_id: :java_math_audit_toradians
      },
      %{
        name: "ulp",
        status: :not_relevant,
        description: "Returns size of an ulp of the argument",
        notes: "low-level IEEE 754 inspection",
        reference_id: nil,
        target_id: :java_math_audit_ulp
      }
    ],
    java_lang_boolean_audit: [
      %{
        name: "Boolean/parseBoolean",
        status: :supported,
        description: "Parse string to boolean",
        notes:
          "Fixed GAP-J02: matches java.lang.Boolean.parseBoolean; nil/null and every string other than case-insensitive \"true\" return false, while non-string, non-nil inputs raise.",
        reference_id: :boolean_parse_boolean,
        jvm_descriptor_attestations: %{boolean_parse_boolean_string: "(Ljava/lang/String;)Z"},
        admitted_overload_divergences: %{boolean_parse_boolean_string: []},
        target_id: :java_lang_boolean_audit_boolean_parseboolean
      },
      %{
        name: "Boolean/valueOf",
        status: :candidate,
        description: "Return Boolean value for a string or boolean",
        notes:
          "Common LLM spelling; parse-boolean covers string parsing but not Java's object API.",
        reference_id: nil,
        target_id: :java_lang_boolean_audit_boolean_valueof
      },
      %{
        name: "Boolean/TRUE",
        status: :candidate,
        description: "Boolean true constant",
        notes: "Low-cost compatibility constant if models emit Java constants.",
        reference_id: nil,
        target_id: :java_lang_boolean_audit_boolean_true
      },
      %{
        name: "Boolean/FALSE",
        status: :candidate,
        description: "Boolean false constant",
        notes: "Low-cost compatibility constant if models emit Java constants.",
        reference_id: nil,
        target_id: :java_lang_boolean_audit_boolean_false
      },
      %{
        name: "booleanValue",
        upstream: [{"java.lang.Boolean", :instance, "booleanValue"}],
        status: :not_relevant,
        description: "Unbox a Boolean object",
        notes: "PTC-Lisp has primitive booleans, not boxed Java Boolean objects.",
        reference_id: nil,
        target_id: :java_lang_boolean_audit_booleanvalue
      }
    ],
    java_lang_double_audit: [
      %{
        name: "Double/parseDouble",
        status: :supported,
        description: "Parse string to double",
        notes:
          "BUG GAP-J01: currently aliases parse-double, returns nil on invalid input, and rejects surrounding whitespace that Java accepts.",
        reference_id: :double_parse_double,
        jvm_descriptor_attestations: %{double_parse_double_string: "(Ljava/lang/String;)D"},
        admitted_overload_divergences: %{double_parse_double_string: ["GAP-J01"]},
        target_id: :java_lang_double_audit_double_parsedouble
      },
      %{
        name: "Double/POSITIVE_INFINITY",
        status: :supported,
        description: "Positive infinity constant",
        notes: "",
        reference_id: :double_positive_infinity,
        jvm_descriptor_attestations: %{double_positive_infinity_field: "D"},
        admitted_overload_divergences: %{double_positive_infinity_field: []},
        target_id: :java_lang_double_audit_double_positive_infinity
      },
      %{
        name: "Double/NEGATIVE_INFINITY",
        status: :supported,
        description: "Negative infinity constant",
        notes: "",
        reference_id: :double_negative_infinity,
        jvm_descriptor_attestations: %{double_negative_infinity_field: "D"},
        admitted_overload_divergences: %{double_negative_infinity_field: []},
        target_id: :java_lang_double_audit_double_negative_infinity
      },
      %{
        name: "Double/NaN",
        status: :supported,
        description: "NaN constant",
        notes: "",
        reference_id: :double_nan,
        jvm_descriptor_attestations: %{double_nan_field: "D"},
        admitted_overload_divergences: %{double_nan_field: []},
        target_id: :java_lang_double_audit_double_nan
      },
      %{
        name: "Double/isNaN",
        status: :candidate,
        description: "Return true if value is NaN",
        notes: "Common guard around parsed floating data.",
        reference_id: nil,
        target_id: :java_lang_double_audit_double_isnan
      },
      %{
        name: "Double/isInfinite",
        status: :candidate,
        description: "Return true if value is infinite",
        notes: "Common guard around parsed floating data.",
        reference_id: nil,
        target_id: :java_lang_double_audit_double_isinfinite
      },
      %{
        name: "Double/valueOf",
        status: :candidate,
        description: "Parse or box a double value",
        notes: "parse-double covers string parsing; boxing is not relevant.",
        reference_id: nil,
        target_id: :java_lang_double_audit_double_valueof
      },
      %{
        name: "doubleValue",
        upstream: [{"java.lang.Double", :instance, "doubleValue"}],
        status: :not_relevant,
        description: "Unbox a Double object",
        notes: "PTC-Lisp has one numeric value model, not boxed Java numbers.",
        reference_id: nil,
        target_id: :java_lang_double_audit_doublevalue
      }
    ],
    java_lang_float_audit: [
      %{
        name: "Float/parseFloat",
        status: :supported,
        description: "Parse string to float",
        notes:
          "BUG GAP-J01: currently aliases parse-double, returns nil on invalid input, and rejects surrounding whitespace that Java accepts. PTC-Lisp uses one floating type.",
        reference_id: :float_parse_float,
        jvm_descriptor_attestations: %{float_parse_float_string: "(Ljava/lang/String;)F"},
        admitted_overload_divergences: %{float_parse_float_string: ["GAP-J01"]},
        target_id: :java_lang_float_audit_float_parsefloat
      },
      %{
        name: "Float/isNaN",
        status: :candidate,
        description: "Return true if value is NaN",
        notes: "Common guard around parsed floating data.",
        reference_id: nil,
        target_id: :java_lang_float_audit_float_isnan
      },
      %{
        name: "Float/isInfinite",
        status: :candidate,
        description: "Return true if value is infinite",
        notes: "Common guard around parsed floating data.",
        reference_id: nil,
        target_id: :java_lang_float_audit_float_isinfinite
      },
      %{
        name: "Float/valueOf",
        status: :candidate,
        description: "Parse or box a float value",
        notes: "parse-double covers string parsing; boxing is not relevant.",
        reference_id: nil,
        target_id: :java_lang_float_audit_float_valueof
      },
      %{
        name: "floatValue",
        upstream: [{"java.lang.Float", :instance, "floatValue"}],
        status: :not_relevant,
        description: "Unbox a Float object",
        notes: "PTC-Lisp has one floating type, not boxed Java numbers.",
        reference_id: nil,
        target_id: :java_lang_float_audit_floatvalue
      }
    ],
    java_lang_integer_audit: [
      %{
        name: "Integer/parseInt",
        status: :supported,
        description: "Parse string to integer",
        notes:
          "BUG GAP-J01: currently aliases parse-long, returns nil on invalid input, and accepts values outside Java int range; Java raises NumberFormatException. BUG GAP-J15: radix overload is unsupported.",
        reference_id: :integer_parse_int,
        jvm_descriptor_attestations: %{integer_parse_int_string: "(Ljava/lang/String;)I"},
        admitted_overload_divergences: %{integer_parse_int_string: ["GAP-J01"]},
        target_id: :java_lang_integer_audit_integer_parseint
      },
      %{
        name: "Integer/valueOf",
        status: :candidate,
        description: "Parse or box an integer value",
        notes: "parse-long covers string parsing; boxing is not relevant.",
        reference_id: nil,
        target_id: :java_lang_integer_audit_integer_valueof
      },
      %{
        name: "Integer/toString",
        status: :candidate,
        description: "Convert integer to string",
        notes: "str covers the common PTC-Lisp need.",
        reference_id: nil,
        target_id: :java_lang_integer_audit_integer_tostring
      },
      %{
        name: "Integer/MAX_VALUE",
        status: :not_relevant,
        description: "Maximum Java int constant",
        notes: "BEAM integers are arbitrary precision; Java int bounds are misleading.",
        reference_id: nil,
        target_id: :java_lang_integer_audit_integer_max_value
      },
      %{
        name: "Integer/MIN_VALUE",
        status: :not_relevant,
        description: "Minimum Java int constant",
        notes: "BEAM integers are arbitrary precision; Java int bounds are misleading.",
        reference_id: nil,
        target_id: :java_lang_integer_audit_integer_min_value
      }
    ],
    java_lang_long_audit: [
      %{
        name: "Long/parseLong",
        status: :supported,
        description: "Parse string to integer",
        notes:
          "BUG GAP-J01: currently aliases parse-long, returns nil on invalid input, and accepts values outside Java long range; Java raises NumberFormatException. BUG GAP-J15: radix overload is unsupported.",
        reference_id: :long_parse_long,
        jvm_descriptor_attestations: %{long_parse_long_string: "(Ljava/lang/String;)J"},
        admitted_overload_divergences: %{long_parse_long_string: ["GAP-J01"]},
        target_id: :java_lang_long_audit_long_parselong
      },
      %{
        name: "Long/valueOf",
        status: :candidate,
        description: "Parse or box a long value",
        notes: "parse-long covers string parsing; boxing is not relevant.",
        reference_id: nil,
        target_id: :java_lang_long_audit_long_valueof
      },
      %{
        name: "Long/toString",
        status: :candidate,
        description: "Convert long to string",
        notes: "str covers the common PTC-Lisp need.",
        reference_id: nil,
        target_id: :java_lang_long_audit_long_tostring
      },
      %{
        name: "Long/MAX_VALUE",
        status: :not_relevant,
        description: "Maximum Java long constant",
        notes: "BEAM integers are arbitrary precision; Java long bounds are misleading.",
        reference_id: nil,
        target_id: :java_lang_long_audit_long_max_value
      },
      %{
        name: "Long/MIN_VALUE",
        status: :not_relevant,
        description: "Minimum Java long constant",
        notes: "BEAM integers are arbitrary precision; Java long bounds are misleading.",
        reference_id: nil,
        target_id: :java_lang_long_audit_long_min_value
      }
    ],
    java_lang_string_audit: [
      %{
        name: ".contains",
        status: :supported,
        description: "Substring containment",
        notes:
          "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings",
        reference_id: :string_contains,
        jvm_descriptor_attestations: %{
          string_contains_char_sequence: "(Ljava/lang/CharSequence;)Z"
        },
        admitted_overload_divergences: %{string_contains_char_sequence: ["DIV-40", "DIV-41"]},
        target_id: :java_lang_string_audit_contains
      },
      %{
        name: ".indexOf",
        status: :supported,
        description: "First substring index",
        notes:
          "BUG GAP-J05: integer character-code overloads are unsupported. BUG GAP-J09: non-BMP offsets are grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_index_of,
        jvm_descriptor_attestations: %{
          string_index_of_string: "(Ljava/lang/String;)I",
          string_index_of_string_from: "(Ljava/lang/String;I)I"
        },
        admitted_overload_divergences: %{
          string_index_of_string: ["GAP-J09", "DIV-41"],
          string_index_of_string_from: ["GAP-J09", "DIV-41"]
        },
        target_id: :java_lang_string_audit_indexof
      },
      %{
        name: ".lastIndexOf",
        status: :supported,
        description: "Last substring index",
        notes:
          "BUG GAP-J05: substring/from-index and integer character-code overloads are unsupported. BUG GAP-J09: non-BMP offsets are grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_last_index_of,
        jvm_descriptor_attestations: %{string_last_index_of_string: "(Ljava/lang/String;)I"},
        admitted_overload_divergences: %{string_last_index_of_string: ["GAP-J09", "DIV-41"]},
        target_id: :java_lang_string_audit_lastindexof
      },
      %{
        name: ".length",
        status: :supported,
        description: "String length",
        notes:
          "BUG GAP-J09: non-BMP length is grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_length,
        jvm_descriptor_attestations: %{string_length_0: "()I"},
        admitted_overload_divergences: %{string_length_0: ["GAP-J09", "DIV-41"]},
        target_id: :java_lang_string_audit_length
      },
      %{
        name: ".substring",
        status: :supported,
        description: "Extract substring",
        notes:
          "BUG GAP-J09: non-BMP indexes are grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_substring,
        jvm_descriptor_attestations: %{
          string_substring_begin: "(I)Ljava/lang/String;",
          string_substring_begin_end: "(II)Ljava/lang/String;"
        },
        admitted_overload_divergences: %{
          string_substring_begin: ["GAP-J09", "DIV-41"],
          string_substring_begin_end: ["GAP-J09", "DIV-41"]
        },
        target_id: :java_lang_string_audit_substring
      },
      %{
        name: ".toLowerCase",
        status: :supported,
        description: "Lowercase string",
        notes:
          "DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_to_lower_case,
        jvm_descriptor_attestations: %{string_to_lower_case_0: "()Ljava/lang/String;"},
        admitted_overload_divergences: %{string_to_lower_case_0: ["DIV-41"]},
        target_id: :java_lang_string_audit_tolowercase
      },
      %{
        name: ".toUpperCase",
        status: :supported,
        description: "Uppercase string",
        notes:
          "DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)",
        reference_id: :string_to_upper_case,
        jvm_descriptor_attestations: %{string_to_upper_case_0: "()Ljava/lang/String;"},
        admitted_overload_divergences: %{string_to_upper_case_0: ["DIV-41"]},
        target_id: :java_lang_string_audit_touppercase
      },
      %{
        name: ".startsWith",
        status: :supported,
        description: "Prefix test",
        notes:
          "BUG GAP-J05: prefix/offset overload is unsupported. DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings",
        reference_id: :string_starts_with,
        jvm_descriptor_attestations: %{string_starts_with_string: "(Ljava/lang/String;)Z"},
        admitted_overload_divergences: %{string_starts_with_string: ["DIV-40", "DIV-41"]},
        target_id: :java_lang_string_audit_startswith
      },
      %{
        name: ".endsWith",
        status: :supported,
        description: "Suffix test",
        notes:
          "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings",
        reference_id: :string_ends_with,
        jvm_descriptor_attestations: %{string_ends_with_string: "(Ljava/lang/String;)Z"},
        admitted_overload_divergences: %{string_ends_with_string: ["DIV-40", "DIV-41"]},
        target_id: :java_lang_string_audit_endswith
      },
      %{
        name: ".trim",
        status: :candidate,
        description: "Trim leading and trailing whitespace",
        notes: "Common LLM spelling; clojure.string/trim is not currently implemented.",
        reference_id: nil,
        target_id: :java_lang_string_audit_trim
      },
      %{
        name: ".isEmpty",
        status: :candidate,
        description: "Return true for empty string",
        notes: "empty? covers the common PTC-Lisp need.",
        reference_id: nil,
        target_id: :java_lang_string_audit_isempty
      },
      %{
        name: ".equalsIgnoreCase",
        status: :candidate,
        description: "Case-insensitive string equality",
        notes: "Common Java idiom in generated code.",
        reference_id: nil,
        target_id: :java_lang_string_audit_equalsignorecase
      },
      %{
        name: ".charAt",
        status: :candidate,
        description: "Return character at index",
        notes: "Potentially useful, but PTC-Lisp must define grapheme semantics.",
        reference_id: nil,
        target_id: :java_lang_string_audit_charat
      },
      %{
        name: ".getBytes",
        status: :not_relevant,
        description: "Encode string to bytes",
        notes: "Byte arrays and charsets are outside the sandbox data model.",
        reference_id: nil,
        target_id: :java_lang_string_audit_getbytes
      },
      %{
        name: ".intern",
        status: :not_relevant,
        description: "Intern a Java string",
        notes: "JVM string pool operation; not meaningful on BEAM.",
        reference_id: nil,
        target_id: :java_lang_string_audit_intern
      }
    ],
    java_lang_system_audit: [
      %{
        name: "System/currentTimeMillis",
        status: :supported,
        description: "Current Unix time in milliseconds",
        notes: "",
        reference_id: :system_current_time_millis,
        jvm_descriptor_attestations: %{system_current_time_millis_0: "()J"},
        admitted_overload_divergences: %{system_current_time_millis_0: []},
        target_id: :java_lang_system_audit_system_currenttimemillis
      },
      %{
        name: "System/nanoTime",
        status: :candidate,
        description: "Monotonic time source",
        notes: "Potential benchmark/timing helper; not wall-clock time.",
        reference_id: nil,
        target_id: :java_lang_system_audit_system_nanotime
      },
      %{
        name: "System/getenv",
        status: :not_relevant,
        description: "Read process environment variables",
        notes: "Host environment access is intentionally not exposed.",
        reference_id: nil,
        target_id: :java_lang_system_audit_system_getenv
      },
      %{
        name: "System/getProperty",
        status: :not_relevant,
        description: "Read JVM system properties",
        notes: "JVM property access is not meaningful and would leak host details.",
        reference_id: nil,
        target_id: :java_lang_system_audit_system_getproperty
      },
      %{
        name: "System/exit",
        status: :not_relevant,
        description: "Terminate the JVM",
        notes: "Process termination is forbidden in the sandbox.",
        reference_id: nil,
        target_id: :java_lang_system_audit_system_exit
      }
    ],
    java_time_local_date_audit: [
      %{
        name: "LocalDate/parse",
        status: :supported,
        description: "Parse ISO-8601 date string",
        notes:
          "Also available as java.time.LocalDate/parse and parse. BUG GAP-J06: date-time strings are accepted instead of rejected.",
        reference_id: :local_date_parse,
        jvm_descriptor_attestations: %{
          local_date_parse_char_sequence: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;"
        },
        admitted_overload_divergences: %{local_date_parse_char_sequence: ["GAP-J06"]},
        target_id: :java_time_local_date_audit_localdate_parse
      },
      %{
        name: "LocalDate/now",
        status: :candidate,
        description: "Current date",
        notes: "Useful, but currentTimeMillis plus parse/Date constructors cover many cases.",
        reference_id: nil,
        target_id: :java_time_local_date_audit_localdate_now
      },
      %{
        name: ".isBefore",
        upstream: [{"java.time.LocalDate", :instance, "isBefore"}],
        status: :supported,
        description: "Date ordering predicate",
        notes: "Works for same-type Date or DateTime values.",
        reference_id: :local_date_is_before,
        jvm_descriptor_attestations: %{
          local_date_is_before_chrono_local_date: "(Ljava/time/chrono/ChronoLocalDate;)Z"
        },
        admitted_overload_divergences: %{local_date_is_before_chrono_local_date: []},
        target_id: :java_time_local_date_audit_isbefore
      },
      %{
        name: ".isAfter",
        upstream: [{"java.time.LocalDate", :instance, "isAfter"}],
        status: :supported,
        description: "Date ordering predicate",
        notes: "Works for same-type Date or DateTime values.",
        reference_id: :local_date_is_after,
        jvm_descriptor_attestations: %{
          local_date_is_after_chrono_local_date: "(Ljava/time/chrono/ChronoLocalDate;)Z"
        },
        admitted_overload_divergences: %{local_date_is_after_chrono_local_date: []},
        target_id: :java_time_local_date_audit_isafter
      },
      %{
        name: "LocalDate/of",
        status: :candidate,
        description: "Construct date from year/month/day",
        notes: "Useful Java idiom; vector/map construction plus parse is the current workaround.",
        reference_id: nil,
        target_id: :java_time_local_date_audit_localdate_of
      },
      %{
        name: ".format",
        status: :candidate,
        description: "Format date with a formatter",
        notes: "Date formatting API would need a bounded formatter surface.",
        reference_id: nil,
        target_id: :java_time_local_date_audit_format
      },
      %{
        name: ".toEpochDay",
        status: :supported,
        description: "Return LocalDate epoch-day integer",
        notes: "Requested in issue #1019 for day differences and date sorting.",
        reference_id: :local_date_to_epoch_day,
        jvm_descriptor_attestations: %{local_date_to_epoch_day_0: "()J"},
        admitted_overload_divergences: %{local_date_to_epoch_day_0: []},
        target_id: :java_time_local_date_audit_toepochday
      },
      %{
        name: ".plusDays",
        status: :supported,
        description: "Add days to a LocalDate",
        notes:
          "Requested in issue #1019 for date arithmetic. BUG GAP-J12: floating and NaN day counts are rejected instead of following Clojure Java interop coercion.",
        reference_id: :local_date_plus_days,
        jvm_descriptor_attestations: %{local_date_plus_days_long: "(J)Ljava/time/LocalDate;"},
        admitted_overload_divergences: %{local_date_plus_days_long: ["GAP-J12"]},
        target_id: :java_time_local_date_audit_plusdays
      },
      %{
        name: ".minusDays",
        status: :supported,
        description: "Subtract days from a LocalDate",
        notes:
          "Requested in issue #1019 for date arithmetic. BUG GAP-J12: floating and NaN day counts are rejected instead of following Clojure Java interop coercion.",
        reference_id: :local_date_minus_days,
        jvm_descriptor_attestations: %{local_date_minus_days_long: "(J)Ljava/time/LocalDate;"},
        admitted_overload_divergences: %{local_date_minus_days_long: ["GAP-J12"]},
        target_id: :java_time_local_date_audit_minusdays
      }
    ],
    java_time_instant_audit: [
      %{
        name: "Instant/parse",
        status: :supported,
        description: "Parse ISO-8601 instant string",
        notes:
          "Also available as java.time.Instant/parse and parse. BUG GAP-J06: date-only and no-zone date-time strings are accepted instead of rejected.",
        reference_id: :instant_parse,
        jvm_descriptor_attestations: %{
          instant_parse_char_sequence: "(Ljava/lang/CharSequence;)Ljava/time/Instant;"
        },
        admitted_overload_divergences: %{instant_parse_char_sequence: ["GAP-J06"]},
        target_id: :java_time_instant_audit_instant_parse
      },
      %{
        name: "Instant/now",
        status: :candidate,
        description: "Current instant",
        notes: "System/currentTimeMillis plus java.util.Date. covers many cases.",
        reference_id: nil,
        target_id: :java_time_instant_audit_instant_now
      },
      %{
        name: ".isBefore",
        upstream: [{"java.time.Instant", :instance, "isBefore"}],
        status: :supported,
        description: "Instant ordering predicate",
        notes: "Works for same-type Date or DateTime values.",
        reference_id: :instant_is_before,
        jvm_descriptor_attestations: %{instant_is_before_instant: "(Ljava/time/Instant;)Z"},
        admitted_overload_divergences: %{instant_is_before_instant: []},
        target_id: :java_time_instant_audit_isbefore
      },
      %{
        name: ".isAfter",
        upstream: [{"java.time.Instant", :instance, "isAfter"}],
        status: :supported,
        description: "Instant ordering predicate",
        notes: "Works for same-type Date or DateTime values.",
        reference_id: :instant_is_after,
        jvm_descriptor_attestations: %{instant_is_after_instant: "(Ljava/time/Instant;)Z"},
        admitted_overload_divergences: %{instant_is_after_instant: []},
        target_id: :java_time_instant_audit_isafter
      },
      %{
        name: ".getTime",
        upstream: [{"java.util.Date", :instance, "getTime"}],
        status: :supported,
        description: "Unix timestamp in milliseconds",
        notes:
          "BUG GAP-J04: Java Instant has toEpochMilli, not getTime; current behavior is a PTC convenience.",
        reference_id: :instant_get_time_alias,
        jvm_descriptor_attestations: %{},
        admitted_overload_divergences: %{instant_get_time_alias_0: ["GAP-J04"]},
        target_id: :java_time_instant_audit_gettime
      },
      %{
        name: ".toEpochMilli",
        status: :candidate,
        description: "Return Instant epoch millisecond",
        notes: "BUG GAP-J18: Java Instant.toEpochMilli is unsupported while .getTime is exposed.",
        reference_id: nil,
        target_id: :java_time_instant_audit_toepochmilli
      },
      %{
        name: "Instant/ofEpochMilli",
        status: :candidate,
        description: "Construct instant from epoch milliseconds",
        notes: "java.util.Date. already accepts seconds or milliseconds.",
        reference_id: nil,
        target_id: :java_time_instant_audit_instant_ofepochmilli
      }
    ],
    java_time_duration_audit: [
      %{
        name: "Duration/between",
        status: :supported,
        description: "Duration between two instants",
        notes:
          "Requested in issue #1019 for millisecond/day differences. BUG GAP-J19: java.util.Date inputs are accepted instead of rejected.",
        reference_id: :duration_between,
        jvm_descriptor_attestations: %{
          duration_between_temporal:
            "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;"
        },
        admitted_overload_divergences: %{duration_between_temporal: ["GAP-J19"]},
        target_id: :java_time_duration_audit_duration_between
      },
      %{
        name: ".toMillis",
        status: :supported,
        description: "Return duration length in milliseconds",
        notes: "Requested in issue #1019 for instant differences.",
        reference_id: :duration_to_millis,
        jvm_descriptor_attestations: %{duration_to_millis_0: "()J"},
        admitted_overload_divergences: %{duration_to_millis_0: []},
        target_id: :java_time_duration_audit_tomillis
      },
      %{
        name: ".toDays",
        status: :supported,
        description: "Return duration length in whole days",
        notes: "Requested in issue #1019 for bucket/day calculations.",
        reference_id: :duration_to_days,
        jvm_descriptor_attestations: %{duration_to_days_0: "()J"},
        admitted_overload_divergences: %{duration_to_days_0: []},
        target_id: :java_time_duration_audit_todays
      },
      %{
        name: "Duration/ofMillis",
        status: :candidate,
        description: "Construct duration from milliseconds",
        notes: "Useful companion for bounded Duration support.",
        reference_id: nil,
        target_id: :java_time_duration_audit_duration_ofmillis
      },
      %{
        name: "Duration/parse",
        status: :candidate,
        description: "Parse ISO-8601 duration string",
        notes: "Useful but lower-priority than between/toMillis/toDays.",
        reference_id: nil,
        target_id: :java_time_duration_audit_duration_parse
      }
    ],
    java_time_period_audit: [
      %{
        name: "Period/between",
        status: :candidate,
        description: "Period between two dates",
        notes:
          "Deferred for issue #1019; `Period.getDays` is a component value, not total days. Use `.toEpochDay` subtraction for LocalDate day differences.",
        reference_id: nil,
        target_id: :java_time_period_audit_period_between
      },
      %{
        name: ".getDays",
        status: :candidate,
        description: "Return day component of a Period",
        notes:
          "Deferred for issue #1019 because this is the day component, not total days; easy to misuse for analytics.",
        reference_id: nil,
        target_id: :java_time_period_audit_getdays
      },
      %{
        name: "Period/ofDays",
        status: :candidate,
        description: "Construct period from days",
        notes: "Useful companion for bounded Period support.",
        reference_id: nil,
        target_id: :java_time_period_audit_period_ofdays
      },
      %{
        name: "Period/parse",
        status: :candidate,
        description: "Parse ISO-8601 period string",
        notes: "Useful but lower-priority than between/getDays.",
        reference_id: nil,
        target_id: :java_time_period_audit_period_parse
      }
    ],
    java_util_date_audit: [
      %{
        name: "java.util.Date.",
        status: :supported,
        description: "Construct DateTime value",
        notes:
          "BUG GAP-J03: numeric constructor currently treats milliseconds as seconds. BUG GAP-J06: ISO date strings are accepted by PTC-Lisp but rejected by the Java oracle. BUG GAP-J11: Java-accepted legacy date strings are rejected. EXTENSION GAP-J21: existing PTC temporal values are accepted directly.",
        reference_id: :date_new,
        jvm_descriptor_attestations: %{
          date_new_0: "()V",
          date_new_long: "(J)V",
          date_new_string: "(Ljava/lang/String;)V"
        },
        admitted_overload_divergences: %{
          date_new_0: [],
          date_new_long: ["GAP-J03"],
          date_new_string: ["GAP-J06", "GAP-J11"],
          date_new_ptc_temporal: ["GAP-J21"]
        },
        target_id: :java_util_date_audit_java_util_date
      },
      %{
        name: ".getTime",
        upstream: [{"java.util.Date", :instance, "getTime"}],
        status: :supported,
        description: "Unix timestamp in milliseconds",
        notes: "Works on DateTime values.",
        reference_id: :date_get_time,
        jvm_descriptor_attestations: %{date_get_time_0: "()J"},
        admitted_overload_divergences: %{date_get_time_0: []},
        target_id: :java_util_date_audit_gettime
      },
      %{
        name: ".isBefore",
        upstream: [{"java.util.Date", :instance, "before"}],
        status: :supported,
        description: "Date ordering predicate",
        notes:
          "BUG GAP-J20: java.util.Date uses .before, not .isBefore; current behavior exposes a non-Java alias.",
        reference_id: :date_is_before_alias,
        jvm_descriptor_attestations: %{},
        admitted_overload_divergences: %{date_is_before_alias_date: ["GAP-J20"]},
        target_id: :java_util_date_audit_isbefore
      },
      %{
        name: ".isAfter",
        upstream: [{"java.util.Date", :instance, "after"}],
        status: :supported,
        description: "Date ordering predicate",
        notes:
          "BUG GAP-J20: java.util.Date uses .after, not .isAfter; current behavior exposes a non-Java alias.",
        reference_id: :date_is_after_alias,
        jvm_descriptor_attestations: %{},
        admitted_overload_divergences: %{date_is_after_alias_date: ["GAP-J20"]},
        target_id: :java_util_date_audit_isafter
      },
      %{
        name: ".before",
        upstream: [{"java.util.Date", :instance, "before"}],
        status: :candidate,
        description: "Date ordering predicate",
        notes: ".isBefore covers the current PTC-Lisp spelling.",
        reference_id: nil,
        target_id: :java_util_date_audit_before
      },
      %{
        name: ".after",
        upstream: [{"java.util.Date", :instance, "after"}],
        status: :candidate,
        description: "Date ordering predicate",
        notes: ".isAfter covers the current PTC-Lisp spelling.",
        reference_id: nil,
        target_id: :java_util_date_audit_after
      },
      %{
        name: ".setTime",
        status: :not_relevant,
        description: "Mutate Date timestamp",
        notes: "Mutable Java object operations are outside the sandbox model.",
        reference_id: nil,
        target_id: :java_util_date_audit_settime
      }
    ]
  },
  interop_entries: [
    %{
      name: "java.util.Date.",
      description:
        "Construct current UTC time, from a timestamp / ISO-8601 / RFC-2822 string, or pass through an existing temporal value",
      kind: :constructor,
      signatures: [
        "(java.util.Date.)",
        "(java.util.Date. timestamp-or-string)",
        "(java.util.Date. datetime-or-date)"
      ],
      notes:
        "Returns Elixir DateTime. Accepts integer (seconds or ms auto-detected), ISO-8601 (with or without offset — offsetless is treated as UTC), RFC 2822, or an existing DateTime/NaiveDateTime/Date (Date and NaiveDateTime upgrade to UTC; DateTime returns as-is). Time alone is not accepted (no date component).",
      class: "java.util.Date",
      reference_ids: [:date_new]
    },
    %{
      name: ".getTime",
      description: "Return Unix timestamp in milliseconds from DateTime",
      kind: :method,
      signatures: ["(.getTime date)"],
      notes:
        "PTC compatibility alias for java.time.Instant; Java Instant declares `.toEpochMilli`, not `.getTime` (GAP-J04).",
      class: "java.util.Date / java.time.Instant",
      reference_ids: [:date_get_time, :instant_get_time_alias]
    },
    %{
      name: ".toEpochDay",
      description: "Return LocalDate epoch-day integer",
      kind: :method,
      signatures: ["(.toEpochDay local-date)"],
      notes: "Works on LocalDate values returned by `LocalDate/parse`.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_to_epoch_day]
    },
    %{
      name: ".plusDays",
      description: "Add days to a LocalDate",
      kind: :method,
      signatures: ["(.plusDays local-date n)"],
      notes: "`n` must be an integer.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_plus_days]
    },
    %{
      name: ".minusDays",
      description: "Subtract days from a LocalDate",
      kind: :method,
      signatures: ["(.minusDays local-date n)"],
      notes: "`n` must be an integer.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_minus_days]
    },
    %{
      name: ".toMillis",
      description: "Return duration length in milliseconds",
      kind: :method,
      signatures: ["(.toMillis duration)"],
      notes: "Works on Duration values returned by `Duration/between`.",
      class: "java.time.Duration",
      reference_ids: [:duration_to_millis]
    },
    %{
      name: ".toDays",
      description: "Return duration length in whole days",
      kind: :method,
      signatures: ["(.toDays duration)"],
      notes: "Partial days truncate toward zero.",
      class: "java.time.Duration",
      reference_ids: [:duration_to_days]
    },
    %{
      name: ".isBefore",
      description: "Returns true if receiver comes strictly before argument (same-type only)",
      kind: :method,
      signatures: ["(.isBefore a b)"],
      notes:
        "Works on both LocalDate and DateTime. Mixed types raise an error. PTC compatibility alias for java.util.Date; Java Date declares `.before`, not `.isBefore` (GAP-J20).",
      class: "java.time.LocalDate / java.time.Instant / java.util.Date",
      reference_ids: [:local_date_is_before, :instant_is_before, :date_is_before_alias]
    },
    %{
      name: ".isAfter",
      description: "Returns true if receiver comes strictly after argument (same-type only)",
      kind: :method,
      signatures: ["(.isAfter a b)"],
      notes:
        "Works on both LocalDate and DateTime. Mixed types raise an error. PTC compatibility alias for java.util.Date; Java Date declares `.after`, not `.isAfter` (GAP-J20).",
      class: "java.time.LocalDate / java.time.Instant / java.util.Date",
      reference_ids: [:local_date_is_after, :instant_is_after, :date_is_after_alias]
    },
    %{
      name: "LocalDate/parse",
      description: "Parse an ISO-8601 date string (YYYY-MM-DD) to a Date",
      kind: :static,
      signatures: [
        "(LocalDate/parse date-string)",
        "(java.time.LocalDate/parse date-string)",
        "(parse date-string)"
      ],
      notes:
        "Returns an Elixir Date for `YYYY-MM-DD`. If the string carries a time component (`...T...`) it returns a DateTime instead (see `Instant/parse`) — a divergence from Java's strict `LocalDate.parse`. Also available as the bare `parse` builtin.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_parse]
    },
    %{
      name: "Instant/parse",
      description: "Parse an ISO-8601 instant/date-time string to a DateTime",
      kind: :static,
      signatures: [
        "(Instant/parse iso-string)",
        "(java.time.Instant/parse iso-string)",
        "(parse iso-string)"
      ],
      notes:
        "Returns an Elixir DateTime. Accepts an offset (`Z`, `+02:00`, …); an offsetless `...T...` string is treated as UTC. `.isBefore` / `.isAfter` / `.getTime` work on the result. A bare `YYYY-MM-DD` string returns a Date instead (see `LocalDate/parse`). Also available as the bare `parse` builtin.",
      class: "java.time.Instant",
      reference_ids: [:instant_parse]
    },
    %{
      name: "Duration/between",
      description: "Return a Duration between two DateTime instants",
      kind: :static,
      signatures: [
        "(Duration/between start-instant end-instant)",
        "(java.time.Duration/between start-instant end-instant)"
      ],
      notes:
        "Requires DateTime values, such as results from `Instant/parse`; LocalDate values are intentionally rejected.",
      class: "java.time.Duration",
      reference_ids: [:duration_between]
    },
    %{
      name: "System/currentTimeMillis",
      description: "Return current time in milliseconds since Unix epoch",
      kind: :static,
      signatures: ["(System/currentTimeMillis)", "(currentTimeMillis)"],
      notes: "",
      class: "java.lang.System",
      reference_ids: [:system_current_time_millis]
    },
    %{
      name: "Boolean/parseBoolean",
      description: "Parse \"true\"/\"false\" to boolean",
      kind: :static,
      signatures: ["(Boolean/parseBoolean s)"],
      notes:
        "Matches java.lang.Boolean.parseBoolean: nil/null and every string other than case-insensitive \"true\" return false; non-string, non-nil inputs raise.",
      class: "java.lang.Boolean",
      reference_ids: [:boolean_parse_boolean]
    },
    %{
      name: "Double/POSITIVE_INFINITY",
      description: "Positive infinity constant (##Inf)",
      kind: :constant,
      signatures: ["Double/POSITIVE_INFINITY", "POSITIVE_INFINITY"],
      notes: "",
      class: "java.lang.Double",
      reference_ids: [:double_positive_infinity]
    },
    %{
      name: "Double/parseDouble",
      description: "Parse string to double",
      kind: :static,
      signatures: ["(Double/parseDouble s)"],
      notes:
        "Compatibility alias for `(parse-double s)`. Invalid or non-string input returns nil instead of throwing.",
      class: "java.lang.Double",
      reference_ids: [:double_parse_double]
    },
    %{
      name: "Double/NEGATIVE_INFINITY",
      description: "Negative infinity constant (##-Inf)",
      kind: :constant,
      signatures: ["Double/NEGATIVE_INFINITY", "NEGATIVE_INFINITY"],
      notes: "",
      class: "java.lang.Double",
      reference_ids: [:double_negative_infinity]
    },
    %{
      name: "Double/NaN",
      description: "Not-a-Number constant (##NaN)",
      kind: :constant,
      signatures: ["Double/NaN", "NaN"],
      notes: "",
      class: "java.lang.Double",
      reference_ids: [:double_nan]
    },
    %{
      name: "Float/parseFloat",
      description: "Parse string to float",
      kind: :static,
      signatures: ["(Float/parseFloat s)"],
      notes:
        "Compatibility alias for `(parse-double s)`; PTC-Lisp uses one floating type. Invalid or non-string input returns nil instead of throwing.",
      class: "java.lang.Float",
      reference_ids: [:float_parse_float]
    },
    %{
      name: "Integer/parseInt",
      description: "Parse string to integer",
      kind: :static,
      signatures: ["(Integer/parseInt s)"],
      notes:
        "Compatibility alias for `(parse-long s)`. Invalid or non-string input returns nil instead of throwing.",
      class: "java.lang.Integer",
      reference_ids: [:integer_parse_int]
    },
    %{
      name: "Long/parseLong",
      description: "Parse string to integer",
      kind: :static,
      signatures: ["(Long/parseLong s)"],
      notes:
        "Compatibility alias for `(parse-long s)`. Invalid or non-string input returns nil instead of throwing.",
      class: "java.lang.Long",
      reference_ids: [:long_parse_long]
    },
    %{
      name: ".contains",
      description: "Returns true if string contains substring",
      kind: :method,
      signatures: ["(.contains s substr)"],
      notes: "",
      class: "java.lang.String",
      reference_ids: [:string_contains]
    },
    %{
      name: ".indexOf",
      description: "Index of first occurrence of substring, or -1 if not found",
      kind: :method,
      signatures: ["(.indexOf s substr)", "(.indexOf s substr from-index)"],
      notes: "Uses grapheme indices (not byte offsets).",
      class: "java.lang.String",
      reference_ids: [:string_index_of]
    },
    %{
      name: ".lastIndexOf",
      description: "Index of last occurrence of substring, or -1 if not found",
      kind: :method,
      signatures: ["(.lastIndexOf s substr)"],
      notes: "Uses grapheme indices (not byte offsets).",
      class: "java.lang.String",
      reference_ids: [:string_last_index_of]
    },
    %{
      name: ".toLowerCase",
      description: "Convert string to lower case",
      kind: :method,
      signatures: ["(.toLowerCase s)"],
      notes: "",
      class: "java.lang.String",
      reference_ids: [:string_to_lower_case]
    },
    %{
      name: ".toUpperCase",
      description: "Convert string to upper case",
      kind: :method,
      signatures: ["(.toUpperCase s)"],
      notes: "",
      class: "java.lang.String",
      reference_ids: [:string_to_upper_case]
    },
    %{
      name: ".startsWith",
      description: "Returns true if string starts with prefix",
      kind: :method,
      signatures: ["(.startsWith s prefix)"],
      notes: "",
      class: "java.lang.String",
      reference_ids: [:string_starts_with]
    },
    %{
      name: ".endsWith",
      description: "Returns true if string ends with suffix",
      kind: :method,
      signatures: ["(.endsWith s suffix)"],
      notes: "",
      class: "java.lang.String",
      reference_ids: [:string_ends_with]
    },
    %{
      name: ".length",
      description: "Return the grapheme count of a string",
      kind: :method,
      signatures: ["(.length s)"],
      notes:
        "Returns grapheme count (not byte length), matching `count` and `.indexOf` index semantics.",
      class: "java.lang.String",
      reference_ids: [:string_length]
    },
    %{
      name: ".substring",
      description: "Extract a substring by grapheme index",
      kind: :method,
      signatures: ["(.substring s start)", "(.substring s start end)"],
      notes:
        "Indices are grapheme-based (not byte offsets). Two-arg form returns graphemes in [start, end). Raises on out-of-range indices (matches Java's StringIndexOutOfBoundsException) — note that (.substring s -1) raises rather than silently returning the last grapheme, which matters when chaining .indexOf.",
      class: "java.lang.String",
      reference_ids: [:string_substring]
    }
  ],
  function_entries: [
    %{
      name: ".getTime",
      description: "Return Unix timestamp in milliseconds (**DateTime only**)",
      binding: :normal,
      reference_ids: [:instant_get_time_alias, :date_get_time],
      category: :interop,
      dispatch: :env,
      signatures: ["(.getTime date)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".getTime",
      divergences: nil
    },
    %{
      name: ".toEpochDay",
      description: "Return LocalDate epoch-day integer",
      binding: :normal,
      reference_ids: [:local_date_to_epoch_day],
      category: :interop,
      dispatch: :env,
      signatures: ["(.toEpochDay local-date)"],
      since: nil,
      examples: [],
      notes: "Works on LocalDate values returned by `LocalDate/parse`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".plusDays", ".minusDays"],
      clojure_var: ".toEpochDay",
      divergences: nil
    },
    %{
      name: ".plusDays",
      description: "Add days to a LocalDate",
      binding: :normal,
      reference_ids: [:local_date_plus_days],
      category: :interop,
      dispatch: :env,
      signatures: ["(.plusDays local-date n)"],
      since: nil,
      examples: [],
      notes: "Works on LocalDate values returned by `LocalDate/parse`; `n` must be an integer.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".minusDays", ".toEpochDay"],
      clojure_var: ".plusDays",
      divergences: nil
    },
    %{
      name: ".minusDays",
      description: "Subtract days from a LocalDate",
      binding: :normal,
      reference_ids: [:local_date_minus_days],
      category: :interop,
      dispatch: :env,
      signatures: ["(.minusDays local-date n)"],
      since: nil,
      examples: [],
      notes: "Works on LocalDate values returned by `LocalDate/parse`; `n` must be an integer.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".plusDays", ".toEpochDay"],
      clojure_var: ".minusDays",
      divergences: nil
    },
    %{
      name: ".toMillis",
      description: "Return duration length in milliseconds",
      binding: :normal,
      reference_ids: [:duration_to_millis],
      category: :interop,
      dispatch: :env,
      signatures: ["(.toMillis duration)"],
      since: nil,
      examples: [],
      notes: "Works on Duration values returned by `Duration/between`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Duration/between", ".toDays"],
      clojure_var: ".toMillis",
      divergences: nil
    },
    %{
      name: ".toDays",
      description: "Return duration length in whole days",
      binding: :normal,
      reference_ids: [:duration_to_days],
      category: :interop,
      dispatch: :env,
      signatures: ["(.toDays duration)"],
      since: nil,
      examples: [],
      notes:
        "Works on Duration values returned by `Duration/between`; partial days truncate toward zero.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Duration/between", ".toMillis"],
      clojure_var: ".toDays",
      divergences: nil
    },
    %{
      name: ".contains",
      description: "Returns true if string contains substring",
      binding: :normal,
      reference_ids: [:string_contains],
      category: :interop,
      dispatch: :env,
      signatures: ["(.contains s substr)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".contains",
      divergences: nil
    },
    %{
      name: ".indexOf",
      description: "Index of first occurrence starting from position",
      binding: :multi_arity,
      reference_ids: [:string_index_of],
      category: :interop,
      dispatch: :env,
      signatures: ["(.indexOf s substr)", "(.indexOf s substr from)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".indexOf",
      divergences: nil
    },
    %{
      name: ".lastIndexOf",
      description: "Index of last occurrence, or -1 if not found",
      binding: :normal,
      reference_ids: [:string_last_index_of],
      category: :interop,
      dispatch: :env,
      signatures: ["(.lastIndexOf s substr)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".lastIndexOf",
      divergences: nil
    },
    %{
      name: ".toLowerCase",
      description: "Convert string to lower case",
      binding: :normal,
      reference_ids: [:string_to_lower_case],
      category: :interop,
      dispatch: :env,
      signatures: ["(.toLowerCase s)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".toLowerCase",
      divergences: nil
    },
    %{
      name: ".length",
      description: "Return the grapheme count of a string",
      binding: :normal,
      reference_ids: [:string_length],
      category: :interop,
      dispatch: :env,
      signatures: ["(.length s)"],
      since: nil,
      examples: [],
      notes:
        "Returns grapheme count (not byte length), matching `count` on a string and `.indexOf` index semantics.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["count"],
      clojure_var: ".length",
      divergences: nil
    },
    %{
      name: ".substring",
      description: "Extract a substring by grapheme index",
      binding: :multi_arity,
      reference_ids: [:string_substring],
      category: :interop,
      dispatch: :env,
      signatures: ["(.substring s start)", "(.substring s start end)"],
      since: nil,
      examples: [],
      notes:
        "Indices are grapheme-based (not byte offsets). Two-arg form returns graphemes in [start, end). Raises on out-of-range indices (matches Java's StringIndexOutOfBoundsException): start < 0, start > length, end > length, or start > end. Notably, (.substring s -1) raises rather than silently returning the last grapheme — important when chaining .indexOf, which returns -1 on miss.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".indexOf", ".length"],
      clojure_var: ".substring",
      divergences: nil
    },
    %{
      name: ".toUpperCase",
      description: "Convert string to upper case",
      binding: :normal,
      reference_ids: [:string_to_upper_case],
      category: :interop,
      dispatch: :env,
      signatures: ["(.toUpperCase s)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".toUpperCase",
      divergences: nil
    },
    %{
      name: ".startsWith",
      description: "Returns true if string starts with prefix",
      binding: :normal,
      reference_ids: [:string_starts_with],
      category: :interop,
      dispatch: :env,
      signatures: ["(.startsWith s prefix)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".startsWith",
      divergences: nil
    },
    %{
      name: ".endsWith",
      description: "Returns true if string ends with suffix",
      binding: :normal,
      reference_ids: [:string_ends_with],
      category: :interop,
      dispatch: :env,
      signatures: ["(.endsWith s suffix)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: ".endsWith",
      divergences: nil
    },
    %{
      name: ".isBefore",
      description: "Returns true if date/datetime comes strictly before another (same-type only)",
      binding: :normal,
      reference_ids: [:local_date_is_before, :instant_is_before, :date_is_before_alias],
      category: :interop,
      dispatch: :env,
      signatures: ["(.isBefore a b)"],
      since: nil,
      examples: [],
      notes: "Works on both LocalDate and DateTime. Mixed types raise an error.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".isAfter"],
      clojure_var: ".isBefore",
      divergences: nil
    },
    %{
      name: ".isAfter",
      description: "Returns true if date/datetime comes strictly after another (same-type only)",
      binding: :normal,
      reference_ids: [:local_date_is_after, :instant_is_after, :date_is_after_alias],
      category: :interop,
      dispatch: :env,
      signatures: ["(.isAfter a b)"],
      since: nil,
      examples: [],
      notes: "Works on both LocalDate and DateTime. Mixed types raise an error.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".isBefore"],
      clojure_var: ".isAfter",
      divergences: nil
    },
    %{
      name: "NEGATIVE_INFINITY",
      description: "Negative infinity constant (Double/NEGATIVE_INFINITY)",
      binding: :constant,
      reference_ids: [:double_negative_infinity],
      category: :interop,
      dispatch: :env,
      signatures: ["NEGATIVE_INFINITY"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: "NEGATIVE_INFINITY",
      divergences: nil
    },
    %{
      name: "NaN",
      description: "Not-a-Number constant (Double/NaN)",
      binding: :constant,
      reference_ids: [:double_nan],
      category: :interop,
      dispatch: :env,
      signatures: ["NaN"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: "NaN",
      divergences: nil
    },
    %{
      name: "POSITIVE_INFINITY",
      description: "Positive infinity constant (Double/POSITIVE_INFINITY)",
      binding: :constant,
      reference_ids: [:double_positive_infinity],
      category: :interop,
      dispatch: :env,
      signatures: ["POSITIVE_INFINITY"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: "POSITIVE_INFINITY",
      divergences: nil
    },
    %{
      name: "currentTimeMillis",
      description: "Return current time in milliseconds since epoch",
      binding: :normal,
      reference_ids: [:system_current_time_millis],
      category: :interop,
      dispatch: :env,
      signatures: ["(System/currentTimeMillis)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: "currentTimeMillis",
      divergences: nil
    },
    %{
      name: "Duration/between",
      description: "Return a Duration between two DateTime instants",
      binding: :normal,
      reference_ids: [:duration_between],
      category: :interop,
      dispatch: :env,
      signatures: [
        "(Duration/between start-instant end-instant)",
        "(java.time.Duration/between start-instant end-instant)"
      ],
      since: nil,
      examples: [],
      notes:
        "Requires DateTime values, such as results from `Instant/parse`; LocalDate values are intentionally rejected.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Instant/parse", ".toMillis", ".toDays"],
      clojure_var: "Duration/between",
      divergences: nil
    },
    %{
      name: "Boolean/parseBoolean",
      description:
        "Java-compatible boolean string parser; returns true only for case-insensitive \"true\"",
      binding: :normal,
      reference_ids: [:boolean_parse_boolean],
      category: :interop,
      dispatch: :env,
      signatures: ["(Boolean/parseBoolean s)"],
      since: nil,
      examples: [
        {"(Boolean/parseBoolean \"true\")", "true"},
        {"(Boolean/parseBoolean \"TRUE\")", "true"},
        {"(Boolean/parseBoolean \"x\")", "false"}
      ],
      notes:
        "Matches java.lang.Boolean.parseBoolean: nil/null and every string other than case-insensitive \"true\" return false; non-string, non-nil inputs raise.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["parse-boolean"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "java.util.Date.",
      description:
        "Construct DateTime: no-arg returns current UTC, integer is Unix seconds/ms, string is ISO-8601 (offset optional, treated as UTC if absent) or RFC-2822, existing DateTime/NaiveDateTime/Date passes through",
      binding: :multi_arity,
      reference_ids: [:date_new],
      category: :interop,
      dispatch: :env,
      signatures: [
        "(java.util.Date.)",
        "(java.util.Date. millis-or-string)",
        "(java.util.Date. datetime-or-date)"
      ],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: "java.util.Date.",
      divergences: nil
    },
    %{
      name: "parse",
      description:
        "Parse an ISO-8601 temporal string: `YYYY-MM-DD` → Date, a string with a time component (`...T...`) → DateTime (offsetless treated as UTC)",
      binding: :normal,
      reference_ids: [:local_date_parse, :instant_parse],
      category: :interop,
      dispatch: :env,
      signatures: [
        "(parse iso-string)",
        "(LocalDate/parse date-str)",
        "(java.time.LocalDate/parse date-str)",
        "(java.time.Instant/parse iso-string)",
        "(Instant/parse iso-string)"
      ],
      since: nil,
      examples: [],
      notes:
        "Reachable as the bare `parse` builtin or via the `LocalDate/` and `Instant/` namespaces — all three dispatch on the string shape. `.isBefore`/`.isAfter`/`.getTime` work on both Date and DateTime results.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".isBefore", ".isAfter", ".getTime", "java.util.Date."],
      clojure_var: "parse",
      divergences:
        "Unlike Java's LocalDate.parse, accepts strings with a time component and returns a DateTime instead of raising — more useful for LLM timestamp comparisons. See docs/java-interop.md."
    }
  ]
}
