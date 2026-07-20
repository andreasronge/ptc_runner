%{
  overloads: %{
    boolean_parse_boolean_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: []
    },
    date_get_time_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    date_is_after_alias_date: %{
      attestation: :ptc_only,
      descriptor: nil,
      divergence_ids: ["GAP-J20"]
    },
    date_is_before_alias_date: %{
      attestation: :ptc_only,
      descriptor: nil,
      divergence_ids: ["GAP-J20"]
    },
    date_new_0: %{attestation: :jvm, descriptor: "()V", divergence_ids: []},
    date_new_long: %{attestation: :jvm, descriptor: "(J)V", divergence_ids: ["GAP-J03"]},
    date_new_ptc_temporal: %{attestation: :ptc_only, descriptor: nil, divergence_ids: ["GAP-J21"]},
    date_new_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)V",
      divergence_ids: ["GAP-J06", "GAP-J11"]
    },
    double_nan_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    double_negative_infinity_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    double_parse_double_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)D",
      divergence_ids: ["GAP-J01"]
    },
    double_positive_infinity_field: %{attestation: :jvm, descriptor: "D", divergence_ids: []},
    duration_between_temporal: %{
      attestation: :jvm,
      descriptor:
        "(Ljava/time/temporal/Temporal;Ljava/time/temporal/Temporal;)Ljava/time/Duration;",
      divergence_ids: ["GAP-J19"]
    },
    duration_to_days_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    duration_to_millis_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    float_parse_float_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)F",
      divergence_ids: ["GAP-J01"]
    },
    instant_get_time_alias_0: %{
      attestation: :ptc_only,
      descriptor: nil,
      divergence_ids: ["GAP-J04"]
    },
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
      divergence_ids: ["GAP-J06"]
    },
    integer_parse_int_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: ["GAP-J01"]
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
      divergence_ids: ["GAP-J12"]
    },
    local_date_parse_char_sequence: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;",
      divergence_ids: ["GAP-J06"]
    },
    local_date_plus_days_long: %{
      attestation: :jvm,
      descriptor: "(J)Ljava/time/LocalDate;",
      divergence_ids: ["GAP-J12"]
    },
    local_date_to_epoch_day_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []},
    long_parse_long_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)J",
      divergence_ids: ["GAP-J01"]
    },
    math_abs_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: ["DIV-45"]},
    math_abs_float: %{attestation: :jvm, descriptor: "(F)F", divergence_ids: ["DIV-45"]},
    math_abs_int: %{attestation: :jvm, descriptor: "(I)I", divergence_ids: ["DIV-45"]},
    math_abs_long: %{attestation: :jvm, descriptor: "(J)J", divergence_ids: ["DIV-45"]},
    math_ceil_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: ["DIV-42"]},
    math_floor_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: ["DIV-42"]},
    math_max_double: %{
      attestation: :jvm,
      descriptor: "(DD)D",
      divergence_ids: ["DIV-44", "DIV-45"]
    },
    math_max_float: %{
      attestation: :jvm,
      descriptor: "(FF)F",
      divergence_ids: ["DIV-44", "DIV-45"]
    },
    math_max_int: %{attestation: :jvm, descriptor: "(II)I", divergence_ids: ["DIV-44", "DIV-45"]},
    math_max_long: %{attestation: :jvm, descriptor: "(JJ)J", divergence_ids: ["DIV-44", "DIV-45"]},
    math_min_double: %{
      attestation: :jvm,
      descriptor: "(DD)D",
      divergence_ids: ["DIV-44", "DIV-45"]
    },
    math_min_float: %{
      attestation: :jvm,
      descriptor: "(FF)F",
      divergence_ids: ["DIV-44", "DIV-45"]
    },
    math_min_int: %{attestation: :jvm, descriptor: "(II)I", divergence_ids: ["DIV-44", "DIV-45"]},
    math_min_long: %{attestation: :jvm, descriptor: "(JJ)J", divergence_ids: ["DIV-44", "DIV-45"]},
    math_pow_double: %{attestation: :jvm, descriptor: "(DD)D", divergence_ids: []},
    math_round_double: %{
      attestation: :jvm,
      descriptor: "(D)J",
      divergence_ids: ["DIV-43", "DIV-45"]
    },
    math_round_float: %{
      attestation: :jvm,
      descriptor: "(F)I",
      divergence_ids: ["DIV-43", "DIV-45"]
    },
    math_sqrt_double: %{attestation: :jvm, descriptor: "(D)D", divergence_ids: []},
    string_contains_char_sequence: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/CharSequence;)Z",
      divergence_ids: ["DIV-40", "DIV-41"]
    },
    string_ends_with_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: ["DIV-40", "DIV-41"]
    },
    string_index_of_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_index_of_string_from: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;I)I",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_last_index_of_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)I",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_length_0: %{
      attestation: :jvm,
      descriptor: "()I",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_starts_with_string: %{
      attestation: :jvm,
      descriptor: "(Ljava/lang/String;)Z",
      divergence_ids: ["DIV-40", "DIV-41"]
    },
    string_substring_begin: %{
      attestation: :jvm,
      descriptor: "(I)Ljava/lang/String;",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_substring_begin_end: %{
      attestation: :jvm,
      descriptor: "(II)Ljava/lang/String;",
      divergence_ids: ["GAP-J09", "DIV-41"]
    },
    string_to_lower_case_0: %{
      attestation: :jvm,
      descriptor: "()Ljava/lang/String;",
      divergence_ids: ["DIV-41"]
    },
    string_to_upper_case_0: %{
      attestation: :jvm,
      descriptor: "()Ljava/lang/String;",
      divergence_ids: ["DIV-41"]
    },
    system_current_time_millis_0: %{attestation: :jvm, descriptor: "()J", divergence_ids: []}
  }
}
