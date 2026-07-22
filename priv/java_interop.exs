%{
  version: 1,
  projection_policy: %{
    audit_reference_coverage: :all,
    interop_omitted_reference_ids: [],
    interop_omission_reason: "Every admitted Java reference has an interop presentation row."
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
      member: "trim",
      kind: :instance,
      class_id: :java_lang_string,
      spellings: [".trim"],
      overload_ids: [:string_trim_0],
      reference_id: :string_trim,
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
      member: "toEpochMilli",
      kind: :instance,
      class_id: :java_time_instant,
      spellings: [".toEpochMilli"],
      overload_ids: [:instant_to_epoch_milli_0],
      reference_id: :instant_to_epoch_milli,
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
      overload_ids: [:date_new_0, :date_new_long, :date_new_string],
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
      member: "before",
      kind: :instance,
      class_id: :java_util_date,
      spellings: [".before"],
      overload_ids: [:date_before_date],
      reference_id: :date_before,
      callable?: true
    },
    %{
      member: "after",
      kind: :instance,
      class_id: :java_util_date,
      spellings: [".after"],
      overload_ids: [:date_after_date],
      reference_id: :date_after,
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
      route: {:dispatch, :boolean_parse_boolean},
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
      route: {:dispatch, :double_parse_double},
      reference_id: :double_parse_double,
      descriptor: "(Ljava/lang/String;)D",
      overload_id: :double_parse_double_string,
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
      route: {:dispatch, :double_positive_infinity},
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
      route: {:dispatch, :double_negative_infinity},
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
      route: {:dispatch, :double_nan},
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
      route: {:dispatch, :float_parse_float},
      reference_id: :float_parse_float,
      descriptor: "(Ljava/lang/String;)F",
      overload_id: :float_parse_float_string,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception],
      receiver: nil,
      route: {:dispatch, :integer_parse_int},
      reference_id: :integer_parse_int,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :integer_parse_int_string,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:string],
      errors: [:number_format_exception],
      receiver: nil,
      route: {:dispatch, :long_parse_long},
      reference_id: :long_parse_long,
      descriptor: "(Ljava/lang/String;)J",
      overload_id: :long_parse_long_string,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [],
      receiver: nil,
      route: {:dispatch, :system_current_time_millis},
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
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_contains},
      reference_id: :string_contains,
      descriptor: "(Ljava/lang/CharSequence;)Z",
      overload_id: :string_contains_char_sequence,
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_index_of},
      reference_id: :string_index_of,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :string_index_of_string,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:string, :int],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_index_of},
      reference_id: :string_index_of,
      descriptor: "(Ljava/lang/String;I)I",
      overload_id: :string_index_of_string_from,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:string],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_last_index_of},
      reference_id: :string_last_index_of,
      descriptor: "(Ljava/lang/String;)I",
      overload_id: :string_last_index_of_string,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:string],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_starts_with},
      reference_id: :string_starts_with,
      descriptor: "(Ljava/lang/String;)Z",
      overload_id: :string_starts_with_string,
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :boolean,
      arity: 1,
      arguments: [:string],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_ends_with},
      reference_id: :string_ends_with,
      descriptor: "(Ljava/lang/String;)Z",
      overload_id: :string_ends_with_string,
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 0,
      arguments: [],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_length},
      reference_id: :string_length,
      descriptor: "()I",
      overload_id: :string_length_0,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 1,
      arguments: [:int],
      errors: [
        :invalid_java_string,
        :null_pointer_exception,
        :string_index_out_of_bounds_exception
      ],
      receiver: :string,
      route: {:dispatch, :string_substring},
      reference_id: :string_substring,
      descriptor: "(I)Ljava/lang/String;",
      overload_id: :string_substring_begin,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 2,
      arguments: [:int, :int],
      errors: [
        :invalid_java_string,
        :null_pointer_exception,
        :string_index_out_of_bounds_exception
      ],
      receiver: :string,
      route: {:dispatch, :string_substring},
      reference_id: :string_substring,
      descriptor: "(II)Ljava/lang/String;",
      overload_id: :string_substring_begin_end,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :string,
      arity: 0,
      arguments: [],
      errors: [:invalid_java_string, :null_pointer_exception],
      receiver: :string,
      route: {:dispatch, :string_trim},
      reference_id: :string_trim,
      descriptor: "()Ljava/lang/String;",
      overload_id: :string_trim_0,
      divergence_ids: ["DIV-41", "DIV-53"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :local_date,
      arity: 1,
      arguments: [:char_sequence],
      errors: [:date_time_parse_exception, :null_pointer_exception],
      receiver: nil,
      route: {:dispatch, :local_date_parse},
      reference_id: :local_date_parse,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;",
      overload_id: :local_date_parse_char_sequence,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [:null_pointer_exception],
      receiver: :local_date,
      route: {:dispatch, :local_date_to_epoch_day},
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
      errors: [:date_time_exception, :arithmetic_exception, :null_pointer_exception],
      receiver: :local_date,
      route: {:dispatch, :local_date_plus_days},
      reference_id: :local_date_plus_days,
      descriptor: "(J)Ljava/time/LocalDate;",
      overload_id: :local_date_plus_days_long,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :local_date,
      arity: 1,
      arguments: [:long],
      errors: [:date_time_exception, :arithmetic_exception, :null_pointer_exception],
      receiver: :local_date,
      route: {:dispatch, :local_date_minus_days},
      reference_id: :local_date_minus_days,
      descriptor: "(J)Ljava/time/LocalDate;",
      overload_id: :local_date_minus_days_long,
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
      route: {:dispatch, :local_date_is_before},
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
      route: {:dispatch, :local_date_is_after},
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
      route: {:dispatch, :instant_parse},
      reference_id: :instant_parse,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/Instant;",
      overload_id: :instant_parse_char_sequence,
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
      route: {:dispatch, :instant_is_before},
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
      route: {:dispatch, :instant_is_after},
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
      errors: [:arithmetic_exception, :null_pointer_exception],
      receiver: :instant,
      route: {:dispatch, :instant_to_epoch_milli},
      reference_id: :instant_to_epoch_milli,
      descriptor: "()J",
      overload_id: :instant_to_epoch_milli_0,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :duration,
      arity: 2,
      arguments: [:instant, :instant],
      errors: [:date_time_exception, :arithmetic_exception, :null_pointer_exception],
      receiver: nil,
      route: {:dispatch, :duration_between},
      reference_id: :duration_between,
      descriptor:
        "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;",
      overload_id: :duration_between_temporal,
      divergence_ids: ["DIV-52"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [:arithmetic_exception, :null_pointer_exception],
      receiver: :duration,
      route: {:dispatch, :duration_to_millis},
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
      errors: [:null_pointer_exception],
      receiver: :duration,
      route: {:dispatch, :duration_to_days},
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
      route: {:dispatch, :date_new},
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
      route: {:dispatch, :date_new},
      reference_id: :date_new,
      descriptor: "(J)V",
      overload_id: :date_new_long,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :date,
      arity: 1,
      arguments: [:string],
      errors: [:illegal_argument_exception],
      receiver: nil,
      route: {:dispatch, :date_new},
      reference_id: :date_new,
      descriptor: "(Ljava/lang/String;)V",
      overload_id: :date_new_string,
      divergence_ids: ["DIV-51"],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 0,
      arguments: [],
      errors: [:null_pointer_exception],
      receiver: :date,
      route: {:dispatch, :date_get_time},
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
      route: {:dispatch, :date_before},
      reference_id: :date_before,
      descriptor: "(Ljava/util/Date;)Z",
      overload_id: :date_before_date,
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
      route: {:dispatch, :date_after},
      reference_id: :date_after,
      descriptor: "(Ljava/util/Date;)Z",
      overload_id: :date_after_date,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 1,
      arguments: [:int],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_abs_int},
      reference_id: :math_abs,
      descriptor: "(I)I",
      overload_id: :math_abs_int,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:long],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_abs_long},
      reference_id: :math_abs,
      descriptor: "(J)J",
      overload_id: :math_abs_long,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 1,
      arguments: [:float],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_abs_float},
      reference_id: :math_abs,
      descriptor: "(F)F",
      overload_id: :math_abs_float,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_abs_double},
      reference_id: :math_abs,
      descriptor: "(D)D",
      overload_id: :math_abs_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_ceil_double},
      reference_id: :math_ceil,
      descriptor: "(D)D",
      overload_id: :math_ceil_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_floor_double},
      reference_id: :math_floor,
      descriptor: "(D)D",
      overload_id: :math_floor_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:int, :int],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_max_int},
      reference_id: :math_max,
      descriptor: "(II)I",
      overload_id: :math_max_int,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 2,
      arguments: [:long, :long],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_max_long},
      reference_id: :math_max,
      descriptor: "(JJ)J",
      overload_id: :math_max_long,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 2,
      arguments: [:float, :float],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_max_float},
      reference_id: :math_max,
      descriptor: "(FF)F",
      overload_id: :math_max_float,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_max_double},
      reference_id: :math_max,
      descriptor: "(DD)D",
      overload_id: :math_max_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :int,
      arity: 2,
      arguments: [:int, :int],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_min_int},
      reference_id: :math_min,
      descriptor: "(II)I",
      overload_id: :math_min_int,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 2,
      arguments: [:long, :long],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_min_long},
      reference_id: :math_min,
      descriptor: "(JJ)J",
      overload_id: :math_min_long,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :float,
      arity: 2,
      arguments: [:float, :float],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_min_float},
      reference_id: :math_min,
      descriptor: "(FF)F",
      overload_id: :math_min_float,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_min_double},
      reference_id: :math_min,
      descriptor: "(DD)D",
      overload_id: :math_min_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 2,
      arguments: [:double, :double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_pow_double},
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
      route: {:dispatch, :math_round_float},
      reference_id: :math_round,
      descriptor: "(F)I",
      overload_id: :math_round_float,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :long,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_round_double},
      reference_id: :math_round,
      descriptor: "(D)J",
      overload_id: :math_round_double,
      divergence_ids: [],
      classification: :exact,
      attestation: :jvm
    },
    %{
      return: :double,
      arity: 1,
      arguments: [:double],
      errors: [],
      receiver: nil,
      route: {:dispatch, :math_sqrt_double},
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
        %{source_name: :abs, reference_id: :math_abs},
        %{source_name: :ceil, reference_id: :math_ceil},
        %{source_name: :floor, reference_id: :math_floor},
        %{source_name: :max, reference_id: :math_max},
        %{source_name: :min, reference_id: :math_min},
        %{source_name: :pow, reference_id: :math_pow},
        %{source_name: :round, reference_id: :math_round},
        %{source_name: :sqrt, reference_id: :math_sqrt}
      ]
    },
    %{
      category: :interop,
      namespace: :System,
      class_id: :java_lang_system,
      members: [%{source_name: :currentTimeMillis, reference_id: :system_current_time_millis}]
    },
    %{
      category: :interop,
      namespace: :Boolean,
      class_id: :java_lang_boolean,
      members: [%{source_name: "parseBoolean", reference_id: :boolean_parse_boolean}]
    },
    %{
      category: :interop,
      namespace: :Double,
      class_id: :java_lang_double,
      members: [
        %{source_name: "parseDouble", reference_id: :double_parse_double},
        %{source_name: :POSITIVE_INFINITY, reference_id: :double_positive_infinity},
        %{source_name: :NEGATIVE_INFINITY, reference_id: :double_negative_infinity},
        %{source_name: :NaN, reference_id: :double_nan}
      ]
    },
    %{
      category: :interop,
      namespace: :Float,
      class_id: :java_lang_float,
      members: [%{source_name: "parseFloat", reference_id: :float_parse_float}]
    },
    %{
      category: :interop,
      namespace: :Integer,
      class_id: :java_lang_integer,
      members: [%{source_name: "parseInt", reference_id: :integer_parse_int}]
    },
    %{
      category: :interop,
      namespace: :Long,
      class_id: :java_lang_long,
      members: [%{source_name: "parseLong", reference_id: :long_parse_long}]
    },
    %{
      category: :interop,
      namespace: :LocalDate,
      class_id: :java_time_local_date,
      members: [%{source_name: :parse, reference_id: :local_date_parse}]
    },
    %{
      category: :interop,
      namespace: :"java.time.LocalDate",
      class_id: :java_time_local_date,
      members: [%{source_name: :parse, reference_id: :local_date_parse}]
    },
    %{
      category: :interop,
      namespace: :Instant,
      class_id: :java_time_instant,
      members: [%{source_name: :parse, reference_id: :instant_parse}]
    },
    %{
      category: :interop,
      namespace: :"java.time.Instant",
      class_id: :java_time_instant,
      members: [%{source_name: :parse, reference_id: :instant_parse}]
    },
    %{
      category: :interop,
      namespace: :Duration,
      class_id: :java_time_duration,
      members: [%{source_name: :between, reference_id: :duration_between}]
    },
    %{
      category: :interop,
      namespace: :"java.time.Duration",
      class_id: :java_time_duration,
      members: [%{source_name: :between, reference_id: :duration_between}]
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
        notes: "Uses the selected Java primitive overload, including int/long minimum overflow.",
        reference_id: :math_abs,
        jvm_descriptor_attestations: %{
          math_abs_int: "(I)I",
          math_abs_long: "(J)J",
          math_abs_float: "(F)F",
          math_abs_double: "(D)D"
        },
        admitted_overload_divergences: %{
          math_abs_int: [],
          math_abs_long: [],
          math_abs_float: [],
          math_abs_double: []
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
        notes: "Returns a Java double, preserving signed zero and non-finite values.",
        reference_id: :math_ceil,
        jvm_descriptor_attestations: %{math_ceil_double: "(D)D"},
        admitted_overload_divergences: %{math_ceil_double: []},
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
        notes: "Returns a Java double, preserving signed zero and non-finite values.",
        reference_id: :math_floor,
        jvm_descriptor_attestations: %{math_floor_double: "(D)D"},
        admitted_overload_divergences: %{math_floor_double: []},
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
          "Uses Java's two-argument primitive overloads, including NaN and signed-zero behavior.",
        reference_id: :math_max,
        jvm_descriptor_attestations: %{
          math_max_int: "(II)I",
          math_max_long: "(JJ)J",
          math_max_float: "(FF)F",
          math_max_double: "(DD)D"
        },
        admitted_overload_divergences: %{
          math_max_int: [],
          math_max_long: [],
          math_max_float: [],
          math_max_double: []
        },
        target_id: :java_math_audit_max
      },
      %{
        name: "min",
        status: :supported,
        description: "Returns the smaller of two values",
        notes:
          "Uses Java's two-argument primitive overloads, including NaN and signed-zero behavior.",
        reference_id: :math_min,
        jvm_descriptor_attestations: %{
          math_min_int: "(II)I",
          math_min_long: "(JJ)J",
          math_min_float: "(FF)F",
          math_min_double: "(DD)D"
        },
        admitted_overload_divergences: %{
          math_min_int: [],
          math_min_long: [],
          math_min_float: [],
          math_min_double: []
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
          "Uses Java float/double overloads, ties toward positive infinity, and Java NaN/infinity saturation.",
        reference_id: :math_round,
        jvm_descriptor_attestations: %{math_round_float: "(F)I", math_round_double: "(D)J"},
        admitted_overload_divergences: %{
          math_round_float: [],
          math_round_double: []
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
          "Matches Java parsing, including bounded NumberFormatException/NullPointerException failures, surrounding Java whitespace, hexadecimal syntax, and exact double rounding.",
        reference_id: :double_parse_double,
        jvm_descriptor_attestations: %{double_parse_double_string: "(Ljava/lang/String;)D"},
        admitted_overload_divergences: %{double_parse_double_string: []},
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
          "Matches Java parsing, including bounded NumberFormatException/NullPointerException failures, surrounding Java whitespace, hexadecimal syntax, and exact float rounding.",
        reference_id: :float_parse_float,
        jvm_descriptor_attestations: %{float_parse_float_string: "(Ljava/lang/String;)F"},
        admitted_overload_divergences: %{float_parse_float_string: []},
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
          "Matches Java decimal parsing and int range failures. BUG GAP-J15: radix overload is unsupported.",
        reference_id: :integer_parse_int,
        jvm_descriptor_attestations: %{integer_parse_int_string: "(Ljava/lang/String;)I"},
        admitted_overload_divergences: %{integer_parse_int_string: []},
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
          "Matches Java decimal parsing and long range failures. BUG GAP-J15: radix overload is unsupported.",
        reference_id: :long_parse_long,
        jvm_descriptor_attestations: %{long_parse_long_string: "(Ljava/lang/String;)J"},
        admitted_overload_divergences: %{long_parse_long_string: []},
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
          "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings. DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_contains,
        jvm_descriptor_attestations: %{
          string_contains_char_sequence: "(Ljava/lang/CharSequence;)Z"
        },
        admitted_overload_divergences: %{
          string_contains_char_sequence: ["DIV-40", "DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_contains
      },
      %{
        name: ".indexOf",
        status: :supported,
        description: "First substring index",
        notes:
          "BUG GAP-J05: integer character-code overloads are unsupported. Indexes use Java UTF-16 code units. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type). DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_index_of,
        jvm_descriptor_attestations: %{
          string_index_of_string: "(Ljava/lang/String;)I",
          string_index_of_string_from: "(Ljava/lang/String;I)I"
        },
        admitted_overload_divergences: %{
          string_index_of_string: ["DIV-41", "DIV-53"],
          string_index_of_string_from: ["DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_indexof
      },
      %{
        name: ".lastIndexOf",
        status: :supported,
        description: "Last substring index",
        notes:
          "BUG GAP-J05: substring/from-index and integer character-code overloads are unsupported. Indexes use Java UTF-16 code units. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type). DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_last_index_of,
        jvm_descriptor_attestations: %{string_last_index_of_string: "(Ljava/lang/String;)I"},
        admitted_overload_divergences: %{
          string_last_index_of_string: ["DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_lastindexof
      },
      %{
        name: ".length",
        status: :supported,
        description: "String length",
        notes:
          "Returns Java UTF-16 code-unit length. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type). DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_length,
        jvm_descriptor_attestations: %{string_length_0: "()I"},
        admitted_overload_divergences: %{string_length_0: ["DIV-41", "DIV-53"]},
        target_id: :java_lang_string_audit_length
      },
      %{
        name: ".substring",
        status: :supported,
        description: "Extract substring",
        notes:
          "Uses Java UTF-16 code-unit indexes. DIV-41: character-literal receivers behave as one-character strings. DIV-53: ranges containing an unpaired surrogate and inputs larger than 256,000 bytes produce invalid_java_string.",
        reference_id: :string_substring,
        jvm_descriptor_attestations: %{
          string_substring_begin: "(I)Ljava/lang/String;",
          string_substring_begin_end: "(II)Ljava/lang/String;"
        },
        admitted_overload_divergences: %{
          string_substring_begin: ["DIV-41", "DIV-53"],
          string_substring_begin_end: ["DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_substring
      },
      %{
        name: ".toLowerCase",
        status: :candidate,
        description: "Lowercase string",
        notes:
          "Deferred until a deterministic locale and pinned Unicode-data contract are selected.",
        reference_id: nil,
        target_id: :java_lang_string_audit_tolowercase
      },
      %{
        name: ".toUpperCase",
        status: :candidate,
        description: "Uppercase string",
        notes:
          "Deferred until a deterministic locale and pinned Unicode-data contract are selected.",
        reference_id: nil,
        target_id: :java_lang_string_audit_touppercase
      },
      %{
        name: ".startsWith",
        status: :supported,
        description: "Prefix test",
        notes:
          "BUG GAP-J05: prefix/offset overload is unsupported. DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings. DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_starts_with,
        jvm_descriptor_attestations: %{string_starts_with_string: "(Ljava/lang/String;)Z"},
        admitted_overload_divergences: %{
          string_starts_with_string: ["DIV-40", "DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_startswith
      },
      %{
        name: ".endsWith",
        status: :supported,
        description: "Suffix test",
        notes:
          "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings. DIV-53: the bounded UTF-16 view rejects String inputs larger than 256,000 bytes.",
        reference_id: :string_ends_with,
        jvm_descriptor_attestations: %{string_ends_with_string: "(Ljava/lang/String;)Z"},
        admitted_overload_divergences: %{
          string_ends_with_string: ["DIV-40", "DIV-41", "DIV-53"]
        },
        target_id: :java_lang_string_audit_endswith
      },
      %{
        name: ".trim",
        status: :supported,
        description: "Remove leading and trailing code units from U+0000 through U+0020",
        notes:
          "Uses Java String.trim semantics, which differ from clojure.string/trim. DIV-41: character-literal receivers behave as one-character strings. DIV-53: String inputs larger than 256,000 bytes produce invalid_java_string.",
        reference_id: :string_trim,
        jvm_descriptor_attestations: %{string_trim_0: "()Ljava/lang/String;"},
        admitted_overload_divergences: %{string_trim_0: ["DIV-41", "DIV-53"]},
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
        notes:
          "Potentially useful, but PTC-Lisp must define how a Java UTF-16 char, including an isolated surrogate, is represented.",
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
          "Also available as java.time.LocalDate/parse; parsing is class-specific and strict.",
        reference_id: :local_date_parse,
        jvm_descriptor_attestations: %{
          local_date_parse_char_sequence: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;"
        },
        admitted_overload_divergences: %{local_date_parse_char_sequence: []},
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
        notes: "Works for native LocalDate values only.",
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
        notes: "Works for native LocalDate values only.",
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
        notes: "Requested in issue #1019 for date arithmetic.",
        reference_id: :local_date_plus_days,
        jvm_descriptor_attestations: %{local_date_plus_days_long: "(J)Ljava/time/LocalDate;"},
        admitted_overload_divergences: %{local_date_plus_days_long: []},
        target_id: :java_time_local_date_audit_plusdays
      },
      %{
        name: ".minusDays",
        status: :supported,
        description: "Subtract days from a LocalDate",
        notes: "Requested in issue #1019 for date arithmetic.",
        reference_id: :local_date_minus_days,
        jvm_descriptor_attestations: %{local_date_minus_days_long: "(J)Ljava/time/LocalDate;"},
        admitted_overload_divergences: %{local_date_minus_days_long: []},
        target_id: :java_time_local_date_audit_minusdays
      }
    ],
    java_time_instant_audit: [
      %{
        name: "Instant/parse",
        status: :supported,
        description: "Parse ISO-8601 instant string",
        notes: "Also available as java.time.Instant/parse; parsing requires an offset.",
        reference_id: :instant_parse,
        jvm_descriptor_attestations: %{
          instant_parse_char_sequence: "(Ljava/lang/CharSequence;)Ljava/time/Instant;"
        },
        admitted_overload_divergences: %{instant_parse_char_sequence: []},
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
        notes: "Works for native Instant values only.",
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
        notes: "Works for native Instant values only.",
        reference_id: :instant_is_after,
        jvm_descriptor_attestations: %{instant_is_after_instant: "(Ljava/time/Instant;)Z"},
        admitted_overload_divergences: %{instant_is_after_instant: []},
        target_id: :java_time_instant_audit_isafter
      },
      %{
        name: ".getTime",
        upstream: [{"java.util.Date", :instance, "getTime"}],
        status: :not_relevant,
        description: "Method belongs to java.util.Date, not Instant",
        notes: "Removed from Instant when class-aware temporal dispatch landed.",
        reference_id: nil,
        target_id: :java_time_instant_audit_gettime
      },
      %{
        name: ".toEpochMilli",
        status: :supported,
        description: "Return Instant epoch millisecond",
        notes: "Raises a bounded arithmetic condition when the result exceeds Java long.",
        reference_id: :instant_to_epoch_milli,
        jvm_descriptor_attestations: %{instant_to_epoch_milli_0: "()J"},
        admitted_overload_divergences: %{instant_to_epoch_milli_0: []},
        target_id: :java_time_instant_audit_toepochmilli
      },
      %{
        name: "Instant/ofEpochMilli",
        status: :candidate,
        description: "Construct instant from epoch milliseconds",
        notes:
          "java.util.Date. accepts exact epoch milliseconds but returns a Date, not an Instant.",
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
          "Requested in issue #1019 for millisecond/day differences. DIV-52: the admitted profile accepts Instants only rather than every Temporal implementation.",
        reference_id: :duration_between,
        jvm_descriptor_attestations: %{
          duration_between_temporal:
            "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;"
        },
        admitted_overload_divergences: %{duration_between_temporal: ["DIV-52"]},
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
        description: "Construct a legacy Date value",
        notes:
          "Numeric input is exact epoch milliseconds. DIV-51: string input uses a deterministic bounded legacy English grammar, admits dates on or after 1582-10-15, and uses UTC when no zone is present.",
        reference_id: :date_new,
        jvm_descriptor_attestations: %{
          date_new_0: "()V",
          date_new_long: "(J)V",
          date_new_string: "(Ljava/lang/String;)V"
        },
        admitted_overload_divergences: %{
          date_new_0: [],
          date_new_long: [],
          date_new_string: ["DIV-51"]
        },
        target_id: :java_util_date_audit_java_util_date
      },
      %{
        name: ".getTime",
        upstream: [{"java.util.Date", :instance, "getTime"}],
        status: :supported,
        description: "Exact epoch timestamp in milliseconds",
        notes: "Works only on native java.util.Date values.",
        reference_id: :date_get_time,
        jvm_descriptor_attestations: %{date_get_time_0: "()J"},
        admitted_overload_divergences: %{date_get_time_0: []},
        target_id: :java_util_date_audit_gettime
      },
      %{
        name: ".isBefore",
        upstream: [
          {"java.time.LocalDate", :instance, "isBefore"},
          {"java.time.Instant", :instance, "isBefore"}
        ],
        status: :not_relevant,
        description: "Method belongs to java.time classes, not java.util.Date",
        notes: "Removed from Date when class-aware temporal dispatch landed.",
        reference_id: nil,
        target_id: :java_util_date_audit_isbefore
      },
      %{
        name: ".isAfter",
        upstream: [
          {"java.time.LocalDate", :instance, "isAfter"},
          {"java.time.Instant", :instance, "isAfter"}
        ],
        status: :not_relevant,
        description: "Method belongs to java.time classes, not java.util.Date",
        notes: "Removed from Date when class-aware temporal dispatch landed.",
        reference_id: nil,
        target_id: :java_util_date_audit_isafter
      },
      %{
        name: ".before",
        upstream: [{"java.util.Date", :instance, "before"}],
        status: :supported,
        description: "Date ordering predicate",
        notes: "Class-owned java.util.Date comparison.",
        reference_id: :date_before,
        jvm_descriptor_attestations: %{date_before_date: "(Ljava/util/Date;)Z"},
        admitted_overload_divergences: %{date_before_date: []},
        target_id: :java_util_date_audit_before
      },
      %{
        name: ".after",
        upstream: [{"java.util.Date", :instance, "after"}],
        status: :supported,
        description: "Date ordering predicate",
        notes: "Class-owned java.util.Date comparison.",
        reference_id: :date_after,
        jvm_descriptor_attestations: %{date_after_date: "(Ljava/util/Date;)Z"},
        admitted_overload_divergences: %{date_after_date: []},
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
      name: "Math/abs",
      description: "Return the absolute value using a selected Java primitive overload",
      kind: :static,
      signatures: ["(Math/abs x)"],
      notes: "Preserves int, long, float, or double identity and Java minimum-value overflow.",
      class: "java.lang.Math",
      reference_ids: [:math_abs]
    },
    %{
      name: "Math/ceil",
      description: "Return the smallest double value not less than the argument",
      kind: :static,
      signatures: ["(Math/ceil x)"],
      notes: "Returns a Java double and preserves signed zero and non-finite values.",
      class: "java.lang.Math",
      reference_ids: [:math_ceil]
    },
    %{
      name: "Math/floor",
      description: "Return the largest double value not greater than the argument",
      kind: :static,
      signatures: ["(Math/floor x)"],
      notes: "Returns a Java double and preserves signed zero and non-finite values.",
      class: "java.lang.Math",
      reference_ids: [:math_floor]
    },
    %{
      name: "Math/max",
      description: "Return the greater of two Java primitive values",
      kind: :static,
      signatures: ["(Math/max x y)"],
      notes: "Uses exact primitive overload selection plus Java NaN and signed-zero behavior.",
      class: "java.lang.Math",
      reference_ids: [:math_max]
    },
    %{
      name: "Math/min",
      description: "Return the smaller of two Java primitive values",
      kind: :static,
      signatures: ["(Math/min x y)"],
      notes: "Uses exact primitive overload selection plus Java NaN and signed-zero behavior.",
      class: "java.lang.Math",
      reference_ids: [:math_min]
    },
    %{
      name: "Math/pow",
      description: "Return the first argument raised to the power of the second",
      kind: :static,
      signatures: ["(Math/pow base exponent)"],
      notes: "Uses the Java double overload and its IEEE 754 special-case table.",
      class: "java.lang.Math",
      reference_ids: [:math_pow]
    },
    %{
      name: "Math/round",
      description: "Round a float to int or double to long with ties toward positive infinity",
      kind: :static,
      signatures: ["(Math/round x)"],
      notes: "NaN becomes zero and infinities saturate to the selected integer primitive range.",
      class: "java.lang.Math",
      reference_ids: [:math_round]
    },
    %{
      name: "Math/sqrt",
      description: "Return the positive double square root",
      kind: :static,
      signatures: ["(Math/sqrt x)"],
      notes: "Uses Java double semantics for negative, signed-zero, NaN, and infinite inputs.",
      class: "java.lang.Math",
      reference_ids: [:math_sqrt]
    },
    %{
      name: "java.util.Date.",
      description:
        "Construct a native legacy Date from current time, exact milliseconds, or legacy text",
      kind: :constructor,
      signatures: [
        "(java.util.Date.)",
        "(java.util.Date. epoch-milliseconds)",
        "(java.util.Date. legacy-date-string)"
      ],
      notes:
        "Integer input is always Java epoch milliseconds. ISO-8601 strings and raw host temporal structs are not Date constructor overloads.",
      class: "java.util.Date",
      reference_ids: [:date_new]
    },
    %{
      name: ".getTime",
      description: "Return exact epoch milliseconds from a legacy Date",
      kind: :method,
      signatures: ["(.getTime date)"],
      notes: "Owned only by java.util.Date.",
      class: "java.util.Date",
      reference_ids: [:date_get_time]
    },
    %{
      name: ".toEpochMilli",
      description: "Return epoch milliseconds from an Instant",
      kind: :method,
      signatures: ["(.toEpochMilli instant)"],
      notes: "Preserves nanoseconds natively and raises on Java long overflow.",
      class: "java.time.Instant",
      reference_ids: [:instant_to_epoch_milli]
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
      notes: "Java long coercion is applied to `n`.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_plus_days]
    },
    %{
      name: ".minusDays",
      description: "Subtract days from a LocalDate",
      kind: :method,
      signatures: ["(.minusDays local-date n)"],
      notes: "Java long coercion is applied to `n`.",
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
      notes: "Receiver-owned for LocalDate and Instant; mixed classes are rejected.",
      class: "java.time.LocalDate / java.time.Instant",
      reference_ids: [:local_date_is_before, :instant_is_before]
    },
    %{
      name: ".isAfter",
      description: "Returns true if receiver comes strictly after argument (same-type only)",
      kind: :method,
      signatures: ["(.isAfter a b)"],
      notes: "Receiver-owned for LocalDate and Instant; mixed classes are rejected.",
      class: "java.time.LocalDate / java.time.Instant",
      reference_ids: [:local_date_is_after, :instant_is_after]
    },
    %{
      name: ".before",
      description: "Returns true if a legacy Date precedes another",
      kind: :method,
      signatures: ["(.before date other-date)"],
      notes: "Owned only by java.util.Date.",
      class: "java.util.Date",
      reference_ids: [:date_before]
    },
    %{
      name: ".after",
      description: "Returns true if a legacy Date follows another",
      kind: :method,
      signatures: ["(.after date other-date)"],
      notes: "Owned only by java.util.Date.",
      class: "java.util.Date",
      reference_ids: [:date_after]
    },
    %{
      name: "LocalDate/parse",
      description: "Parse strict ISO-8601 text to a native LocalDate",
      kind: :static,
      signatures: [
        "(LocalDate/parse date-string)",
        "(java.time.LocalDate/parse date-string)"
      ],
      notes: "Date-time text is rejected; class identity is retained natively.",
      class: "java.time.LocalDate",
      reference_ids: [:local_date_parse]
    },
    %{
      name: "Instant/parse",
      description: "Parse strict ISO-8601 text to a native Instant",
      kind: :static,
      signatures: [
        "(Instant/parse iso-string)",
        "(java.time.Instant/parse iso-string)"
      ],
      notes: "An explicit UTC or numeric offset is required; nanoseconds are retained.",
      class: "java.time.Instant",
      reference_ids: [:instant_parse]
    },
    %{
      name: "Duration/between",
      description: "Return a native Duration between two Instants",
      kind: :static,
      signatures: [
        "(Duration/between start-instant end-instant)",
        "(java.time.Duration/between start-instant end-instant)"
      ],
      notes:
        "Requires native Instant values; LocalDate, Date, and raw host temporal structs are rejected.",
      class: "java.time.Duration",
      reference_ids: [:duration_between]
    },
    %{
      name: "System/currentTimeMillis",
      description: "Return current time in milliseconds since Unix epoch",
      kind: :static,
      signatures: ["(System/currentTimeMillis)"],
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
      signatures: ["Double/POSITIVE_INFINITY"],
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
        "Uses Java syntax, whitespace, range, rounding, and bounded NumberFormatException/NullPointerException semantics.",
      class: "java.lang.Double",
      reference_ids: [:double_parse_double]
    },
    %{
      name: "Double/NEGATIVE_INFINITY",
      description: "Negative infinity constant (##-Inf)",
      kind: :constant,
      signatures: ["Double/NEGATIVE_INFINITY"],
      notes: "",
      class: "java.lang.Double",
      reference_ids: [:double_negative_infinity]
    },
    %{
      name: "Double/NaN",
      description: "Not-a-Number constant (##NaN)",
      kind: :constant,
      signatures: ["Double/NaN"],
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
        "Uses Java syntax, whitespace, range, direct float rounding, and bounded NumberFormatException/NullPointerException semantics.",
      class: "java.lang.Float",
      reference_ids: [:float_parse_float]
    },
    %{
      name: "Integer/parseInt",
      description: "Parse string to integer",
      kind: :static,
      signatures: ["(Integer/parseInt s)"],
      notes:
        "Uses Java decimal syntax, int range checks, and bounded NumberFormatException semantics.",
      class: "java.lang.Integer",
      reference_ids: [:integer_parse_int]
    },
    %{
      name: "Long/parseLong",
      description: "Parse string to integer",
      kind: :static,
      signatures: ["(Long/parseLong s)"],
      notes:
        "Uses Java decimal syntax, long range checks, and bounded NumberFormatException semantics.",
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
      notes: "Returns Java UTF-16 code-unit indexes.",
      class: "java.lang.String",
      reference_ids: [:string_index_of]
    },
    %{
      name: ".lastIndexOf",
      description: "Index of last occurrence of substring, or -1 if not found",
      kind: :method,
      signatures: ["(.lastIndexOf s substr)"],
      notes: "Returns Java UTF-16 code-unit indexes.",
      class: "java.lang.String",
      reference_ids: [:string_last_index_of]
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
      description: "Return the UTF-16 code-unit length of a string",
      kind: :method,
      signatures: ["(.length s)"],
      notes: "Uses Java UTF-16 code units; ordinary PTC `count` remains grapheme-based.",
      class: "java.lang.String",
      reference_ids: [:string_length]
    },
    %{
      name: ".substring",
      description: "Extract a substring by UTF-16 code-unit index",
      kind: :method,
      signatures: ["(.substring s start)", "(.substring s start end)"],
      notes:
        "Uses Java UTF-16 code-unit indexes. A range containing an unpaired surrogate returns invalid_java_string because PTC strings require valid UTF-8.",
      class: "java.lang.String",
      reference_ids: [:string_substring]
    },
    %{
      name: ".trim",
      description: "Remove leading and trailing code units from U+0000 through U+0020",
      kind: :method,
      signatures: ["(.trim s)"],
      notes: "Uses Java String.trim semantics, not clojure.string/trim whitespace semantics.",
      class: "java.lang.String",
      reference_ids: [:string_trim]
    }
  ],
  function_entries: [
    %{
      name: "Math/abs",
      description: "Java primitive absolute value",
      binding: :normal,
      reference_ids: [:math_abs],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/abs x)"],
      since: nil,
      examples: [{"(Math/abs -7)", "7"}],
      notes: "Preserves the selected Java primitive kind and minimum-value overflow.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["abs"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/ceil",
      description: "Java double ceiling",
      binding: :normal,
      reference_ids: [:math_ceil],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/ceil x)"],
      since: nil,
      examples: [{"(Math/ceil 1.2)", "2.0"}],
      notes: "Returns a Java double rather than the integer returned by bare `ceil`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["ceil"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/floor",
      description: "Java double floor",
      binding: :normal,
      reference_ids: [:math_floor],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/floor x)"],
      since: nil,
      examples: [{"(Math/floor -1.2)", "-2.0"}],
      notes: "Returns a Java double rather than the integer returned by bare `floor`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["floor"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/max",
      description: "Java two-argument primitive maximum",
      binding: :normal,
      reference_ids: [:math_max],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/max x y)"],
      since: nil,
      examples: [{"(Math/max 1 2)", "2"}],
      notes: "Requires one admitted primitive overload; bare `max` remains variadic.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["max"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/min",
      description: "Java two-argument primitive minimum",
      binding: :normal,
      reference_ids: [:math_min],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/min x y)"],
      since: nil,
      examples: [{"(Math/min 1 2)", "1"}],
      notes: "Requires one admitted primitive overload; bare `min` remains variadic.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["min"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/pow",
      description: "Java double exponentiation",
      binding: :normal,
      reference_ids: [:math_pow],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/pow base exponent)"],
      since: nil,
      examples: [{"(Math/pow 2 3)", "8.0"}],
      notes: "Uses Java's IEEE 754 `double` special-case table.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["pow"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/round",
      description: "Java float/double rounding to int/long",
      binding: :normal,
      reference_ids: [:math_round],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/round x)"],
      since: nil,
      examples: [{"(Math/round -1.5)", "-1"}],
      notes: "Ties go toward positive infinity; NaN and infinities use Java saturation.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["round"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Math/sqrt",
      description: "Java double square root",
      binding: :normal,
      reference_ids: [:math_sqrt],
      category: :interop,
      dispatch: :java,
      signatures: ["(Math/sqrt x)"],
      since: nil,
      examples: [{"(Math/sqrt 25)", "5.0"}],
      notes: "Uses Java double signed-zero, NaN, and infinity behavior.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["sqrt"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".getTime",
      description: "Return exact epoch milliseconds from a legacy Date",
      binding: :normal,
      reference_ids: [:date_get_time],
      category: :interop,
      dispatch: :java,
      signatures: ["(.getTime date)"],
      since: nil,
      examples: [],
      notes: "Owned only by java.util.Date.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".toEpochMilli",
      description: "Return epoch milliseconds from an Instant",
      binding: :normal,
      reference_ids: [:instant_to_epoch_milli],
      category: :interop,
      dispatch: :java,
      signatures: ["(.toEpochMilli instant)"],
      since: nil,
      examples: [],
      notes: "Raises when the result exceeds Java long.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Instant/parse", ".getTime"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".toEpochDay",
      description: "Return LocalDate epoch-day integer",
      binding: :normal,
      reference_ids: [:local_date_to_epoch_day],
      category: :interop,
      dispatch: :java,
      signatures: ["(.toEpochDay local-date)"],
      since: nil,
      examples: [],
      notes: "Works on LocalDate values returned by `LocalDate/parse`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".plusDays", ".minusDays"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".plusDays",
      description: "Add days to a LocalDate",
      binding: :normal,
      reference_ids: [:local_date_plus_days],
      category: :interop,
      dispatch: :java,
      signatures: ["(.plusDays local-date n)"],
      since: nil,
      examples: [],
      notes:
        "Works on LocalDate values returned by `LocalDate/parse`; Java long coercion applies.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".minusDays", ".toEpochDay"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".minusDays",
      description: "Subtract days from a LocalDate",
      binding: :normal,
      reference_ids: [:local_date_minus_days],
      category: :interop,
      dispatch: :java,
      signatures: ["(.minusDays local-date n)"],
      since: nil,
      examples: [],
      notes:
        "Works on LocalDate values returned by `LocalDate/parse`; Java long coercion applies.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".plusDays", ".toEpochDay"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".toMillis",
      description: "Return duration length in milliseconds",
      binding: :normal,
      reference_ids: [:duration_to_millis],
      category: :interop,
      dispatch: :java,
      signatures: ["(.toMillis duration)"],
      since: nil,
      examples: [],
      notes: "Works on Duration values returned by `Duration/between`.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Duration/between", ".toDays"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".toDays",
      description: "Return duration length in whole days",
      binding: :normal,
      reference_ids: [:duration_to_days],
      category: :interop,
      dispatch: :java,
      signatures: ["(.toDays duration)"],
      since: nil,
      examples: [],
      notes:
        "Works on Duration values returned by `Duration/between`; partial days truncate toward zero.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Duration/between", ".toMillis"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".contains",
      description: "Returns true if string contains substring",
      binding: :normal,
      reference_ids: [:string_contains],
      category: :interop,
      dispatch: :java,
      signatures: ["(.contains s substr)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".indexOf",
      description: "Index of first occurrence starting from position",
      binding: :normal,
      reference_ids: [:string_index_of],
      category: :interop,
      dispatch: :java,
      signatures: ["(.indexOf s substr)", "(.indexOf s substr from)"],
      since: nil,
      examples: [],
      notes: "Returns Java UTF-16 code-unit indexes.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".lastIndexOf",
      description: "Index of last occurrence, or -1 if not found",
      binding: :normal,
      reference_ids: [:string_last_index_of],
      category: :interop,
      dispatch: :java,
      signatures: ["(.lastIndexOf s substr)"],
      since: nil,
      examples: [],
      notes: "Returns Java UTF-16 code-unit indexes.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".length",
      description: "Return the UTF-16 code-unit length of a string",
      binding: :normal,
      reference_ids: [:string_length],
      category: :interop,
      dispatch: :java,
      signatures: ["(.length s)"],
      since: nil,
      examples: [],
      notes: "Uses Java UTF-16 code units; ordinary PTC `count` remains grapheme-based.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["count"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".substring",
      description: "Extract a substring by UTF-16 code-unit index",
      binding: :normal,
      reference_ids: [:string_substring],
      category: :interop,
      dispatch: :java,
      signatures: ["(.substring s start)", "(.substring s start end)"],
      since: nil,
      examples: [],
      notes:
        "Uses Java UTF-16 code-unit indexes. A range containing an unpaired surrogate returns invalid_java_string because PTC strings require valid UTF-8.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".indexOf", ".length"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".trim",
      description: "Remove Java String.trim boundary code units",
      binding: :normal,
      reference_ids: [:string_trim],
      category: :interop,
      dispatch: :java,
      signatures: ["(.trim s)"],
      since: nil,
      examples: [{"(.trim \"  Ada  \")", "\"Ada\""}],
      notes:
        "Removes leading and trailing UTF-16 code units from U+0000 through U+0020; clojure.string/trim uses Character.isWhitespace instead.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["trim"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".startsWith",
      description: "Returns true if string starts with prefix",
      binding: :normal,
      reference_ids: [:string_starts_with],
      category: :interop,
      dispatch: :java,
      signatures: ["(.startsWith s prefix)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".endsWith",
      description: "Returns true if string ends with suffix",
      binding: :normal,
      reference_ids: [:string_ends_with],
      category: :interop,
      dispatch: :java,
      signatures: ["(.endsWith s suffix)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".isBefore",
      description: "Compare native LocalDate or Instant values within their owning class",
      binding: :normal,
      reference_ids: [:local_date_is_before, :instant_is_before],
      category: :interop,
      dispatch: :java,
      signatures: ["(.isBefore a b)"],
      since: nil,
      examples: [],
      notes: "Mixed Java classes and raw host temporal structs are rejected.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".isAfter"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".isAfter",
      description: "Compare native LocalDate or Instant values within their owning class",
      binding: :normal,
      reference_ids: [:local_date_is_after, :instant_is_after],
      category: :interop,
      dispatch: :java,
      signatures: ["(.isAfter a b)"],
      since: nil,
      examples: [],
      notes: "Mixed Java classes and raw host temporal structs are rejected.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".isBefore"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".before",
      description: "Return true when a legacy Date precedes another",
      binding: :normal,
      reference_ids: [:date_before],
      category: :interop,
      dispatch: :java,
      signatures: ["(.before date other-date)"],
      since: nil,
      examples: [],
      notes: "Owned only by java.util.Date.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".after", ".getTime"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: ".after",
      description: "Return true when a legacy Date follows another",
      binding: :normal,
      reference_ids: [:date_after],
      category: :interop,
      dispatch: :java,
      signatures: ["(.after date other-date)"],
      since: nil,
      examples: [],
      notes: "Owned only by java.util.Date.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [".before", ".getTime"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "System/currentTimeMillis",
      description: "Return current time in milliseconds since epoch",
      binding: :normal,
      reference_ids: [:system_current_time_millis],
      category: :interop,
      dispatch: :java,
      signatures: ["(System/currentTimeMillis)"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Duration/between",
      description: "Return a native Duration between two Instants",
      binding: :normal,
      reference_ids: [:duration_between],
      category: :interop,
      dispatch: :java,
      signatures: [
        "(Duration/between start-instant end-instant)",
        "(java.time.Duration/between start-instant end-instant)"
      ],
      since: nil,
      examples: [],
      notes: "Requires native Instant values; other temporal classes are rejected.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Instant/parse", ".toMillis", ".toDays"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Boolean/parseBoolean",
      description:
        "Java-compatible boolean string parser; returns true only for case-insensitive \"true\"",
      binding: :normal,
      reference_ids: [:boolean_parse_boolean],
      category: :interop,
      dispatch: :java,
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
      name: "Double/parseDouble",
      description: "Java-compatible double parser",
      binding: :normal,
      reference_ids: [:double_parse_double],
      category: :interop,
      dispatch: :java,
      signatures: ["(Double/parseDouble s)"],
      since: nil,
      examples: [
        {"(Double/parseDouble \"1.5\")", "1.5"},
        {"(Double/parseDouble \"0x1.8p0\")", "1.5"}
      ],
      notes:
        "Matches Java syntax, whitespace, range, rounding, and bounded NumberFormatException/NullPointerException semantics.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["parse-double"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Double/POSITIVE_INFINITY",
      description: "Java positive-infinity double field",
      binding: :normal,
      reference_ids: [:double_positive_infinity],
      category: :interop,
      dispatch: :java,
      signatures: ["Double/POSITIVE_INFINITY"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Double/NEGATIVE_INFINITY",
      description: "Java negative-infinity double field",
      binding: :normal,
      reference_ids: [:double_negative_infinity],
      category: :interop,
      dispatch: :java,
      signatures: ["Double/NEGATIVE_INFINITY"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Double/NaN",
      description: "Java not-a-number double field",
      binding: :normal,
      reference_ids: [:double_nan],
      category: :interop,
      dispatch: :java,
      signatures: ["Double/NaN"],
      since: nil,
      examples: [],
      notes: nil,
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Float/parseFloat",
      description: "Java-compatible float parser",
      binding: :normal,
      reference_ids: [:float_parse_float],
      category: :interop,
      dispatch: :java,
      signatures: ["(Float/parseFloat s)"],
      since: nil,
      examples: [{"(Float/parseFloat \"1.5\")", "1.5"}],
      notes:
        "Matches Java syntax, whitespace, range, direct float rounding, and bounded NumberFormatException/NullPointerException semantics.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["parse-double"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Integer/parseInt",
      description: "Java-compatible decimal int parser",
      binding: :normal,
      reference_ids: [:integer_parse_int],
      category: :interop,
      dispatch: :java,
      signatures: ["(Integer/parseInt s)"],
      since: nil,
      examples: [{"(Integer/parseInt \"42\")", "42"}],
      notes:
        "Matches Java decimal syntax, int range, and bounded NumberFormatException semantics.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["parse-long"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Long/parseLong",
      description: "Java-compatible decimal long parser",
      binding: :normal,
      reference_ids: [:long_parse_long],
      category: :interop,
      dispatch: :java,
      signatures: ["(Long/parseLong s)"],
      since: nil,
      examples: [{"(Long/parseLong \"42\")", "42"}],
      notes:
        "Matches Java decimal syntax, long range, and bounded NumberFormatException semantics.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["parse-long"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "java.util.Date.",
      description: "Construct a native legacy Date with exact Java millisecond identity",
      binding: :normal,
      reference_ids: [:date_new],
      category: :interop,
      dispatch: :java,
      signatures: [
        "(java.util.Date.)",
        "(java.util.Date. epoch-milliseconds)",
        "(java.util.Date. legacy-date-string)"
      ],
      since: nil,
      examples: [],
      notes: "Numeric input is always milliseconds; raw host temporal structs are not promoted.",
      section: "Interop",
      ptc_extension?: false,
      see_also: [],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "LocalDate/parse",
      description: "Parse strict ISO-8601 local-date text to a native LocalDate",
      binding: :normal,
      reference_ids: [:local_date_parse],
      category: :interop,
      dispatch: :java,
      signatures: [
        "(LocalDate/parse date-str)",
        "(java.time.LocalDate/parse date-str)"
      ],
      since: nil,
      examples: [],
      notes: "Date-time strings are rejected; the bare `parse` alias was removed.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["Instant/parse", ".toEpochDay", ".plusDays", ".minusDays"],
      clojure_var: nil,
      divergences: nil
    },
    %{
      name: "Instant/parse",
      description: "Parse strict ISO-8601 instant text to a native Instant",
      binding: :normal,
      reference_ids: [:instant_parse],
      category: :interop,
      dispatch: :java,
      signatures: [
        "(Instant/parse iso-string)",
        "(java.time.Instant/parse iso-string)"
      ],
      since: nil,
      examples: [],
      notes: "An explicit UTC or numeric offset is required; nanoseconds are retained.",
      section: "Interop",
      ptc_extension?: false,
      see_also: ["LocalDate/parse", ".toEpochMilli", "Duration/between"],
      clojure_var: nil,
      divergences: nil
    }
  ]
}
