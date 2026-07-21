%{
  overloads: %{
    boolean_parse_boolean_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: []
    },
    date_get_time_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    date_after_date: %{
      attestation: :jvm,
      descriptor: "(Ljava/util/Date;)Z",
      divergence_ids: []
    },
    date_before_date: %{
      attestation: :jvm,
      descriptor: "(Ljava/util/Date;)Z",
      divergence_ids: []
    },
    date_new_0: %{attestation: :jvm, descriptor: "()V", divergence_ids: []},
    date_new_long: %{attestation: :jvm, descriptor: "(J)V", divergence_ids: []},
    date_new_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)V",
      divergence_ids: ["DIV-51"]
    },
    double_nan_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    double_negative_infinity_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    double_parse_double_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)D",
      divergence_ids: []
    },
    double_positive_infinity_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    duration_between_temporal: %{
      attestation: :jvm,
      descriptor:
        "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;",
      divergence_ids: ["DIV-52"]
    },
    duration_to_days_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    duration_to_millis_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    float_parse_float_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)F",
      divergence_ids: []
    },
    instant_to_epoch_milli_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    instant_is_after_instant: %{
      attestation: :jvm,
      descriptor: "(Ljava/time/Instant;)Z",
      divergence_ids: []
    },
    instant_is_before_instant: %{
      attestation: :jvm,
      descriptor: "(Ljava/time/Instant;)Z",
      divergence_ids: []
    },
    instant_parse_char_sequence: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/Instant;",
      divergence_ids: []
    },
    integer_parse_int_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: []
    },
    local_date_is_after_chrono_local_date: %{
      attestation: :jvm,
      descriptor: "(Ljava/time/chrono/ChronoLocalDate;)Z",
      divergence_ids: []
    },
    local_date_is_before_chrono_local_date: %{
      attestation: :jvm,
      descriptor: "(Ljava/time/chrono/ChronoLocalDate;)Z",
      divergence_ids: []
    },
    local_date_minus_days_long: %{
      attestation: :jvm,
      descriptor: "(J)Ljava/time/LocalDate;",
      divergence_ids: []
    },
    local_date_parse_char_sequence: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;",
      divergence_ids: []
    },
    local_date_plus_days_long: %{
      attestation: :jvm,
      descriptor: "(J)Ljava/time/LocalDate;",
      divergence_ids: []
    },
    local_date_to_epoch_day_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    long_parse_long_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)J",
      divergence_ids: []
    },
    math_abs_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: []},
    math_abs_float: %{attestation: :jvm, descriptor: "(F)F", divergence_ids: []},
    math_abs_int: %{attestation: :jvm, descriptor: "(I)I", divergence_ids: []},
    math_abs_long: %{attestation: :jvm, descriptor: "(J)J", divergence_ids: []},
    math_ceil_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: []},
    math_floor_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: []},
    math_max_double: %{
      attestation: :jvm,
      descriptor: "(DD)D",
      divergence_ids: []
    },
    math_max_float: %{
      attestation: :jvm,
      descriptor: "(FF)F",
      divergence_ids: []
    },
    math_max_int: %{attestation: :jvm, descriptor: "(II)I", divergence_ids: []},
    math_max_long: %{attestation: :jvm, descriptor: "(JJ)J", divergence_ids: []},
    math_min_double: %{
      attestation: :jvm,
      descriptor: "(DD)D",
      divergence_ids: []
    },
    math_min_float: %{
      attestation: :jvm,
      descriptor: "(FF)F",
      divergence_ids: []
    },
    math_min_int: %{attestation: :jvm, descriptor: "(II)I", divergence_ids: []},
    math_min_long: %{attestation: :jvm, descriptor: "(JJ)J", divergence_ids: []},
    math_pow_double: %{attestation: :jvm, descriptor: "(DD)D", divergence_ids: []},
    math_round_double: %{
      attestation: :jvm,
      descriptor: "(D)J",
      divergence_ids: []
    },
    math_round_float: %{
      attestation: :jvm,
      descriptor: "(F)I",
      divergence_ids: []
    },
    math_sqrt_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: []},
    string_contains_char_sequence: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/CharSequence;)Z",
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"]
    },
    string_ends_with_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"]
    },
    string_index_of_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    string_index_of_string_from: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;I)I",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    string_last_index_of_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    string_length_0: %{
      attestation: :jvm,
      descriptor: "()I",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    string_starts_with_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: ["DIV-40", "DIV-41", "DIV-53"]
    },
    string_substring_begin: %{
      attestation: :jvm,
      descriptor: "(I)Ljava/lang/String;",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    string_substring_begin_end: %{
      attestation: :jvm,
      descriptor: "(II)Ljava/lang/String;",
      divergence_ids: ["DIV-41", "DIV-53"]
    },
    system_current_time_millis_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []}
  }
}
