%{
  java_lang_boolean_audit: [
    %{
      name: "Boolean/parseBoolean",
      status: :supported,
      description: "Parse string to boolean",
      notes:
        "Fixed GAP-J02: matches java.lang.Boolean.parseBoolean; nil/null and every string other than case-insensitive \"true\" return false, while non-string, non-nil inputs raise."
    },
    %{
      name: "Boolean/valueOf",
      status: :candidate,
      description: "Return Boolean value for a string or boolean",
      notes: "Common LLM spelling; parse-boolean covers string parsing but not Java's object API."
    },
    %{
      name: "Boolean/TRUE",
      status: :candidate,
      description: "Boolean true constant",
      notes: "Low-cost compatibility constant if models emit Java constants."
    },
    %{
      name: "Boolean/FALSE",
      status: :candidate,
      description: "Boolean false constant",
      notes: "Low-cost compatibility constant if models emit Java constants."
    },
    %{
      name: "booleanValue",
      status: :not_relevant,
      description: "Unbox a Boolean object",
      notes: "PTC-Lisp has primitive booleans, not boxed Java Boolean objects."
    }
  ],
  java_lang_double_audit: [
    %{
      name: "Double/parseDouble",
      status: :supported,
      description: "Parse string to double",
      notes:
        "BUG GAP-J01: currently aliases parse-double, returns nil on invalid input, and rejects surrounding whitespace that Java accepts."
    },
    %{
      name: "Double/POSITIVE_INFINITY",
      status: :supported,
      description: "Positive infinity constant",
      notes: ""
    },
    %{
      name: "Double/NEGATIVE_INFINITY",
      status: :supported,
      description: "Negative infinity constant",
      notes: ""
    },
    %{name: "Double/NaN", status: :supported, description: "NaN constant", notes: ""},
    %{
      name: "Double/isNaN",
      status: :candidate,
      description: "Return true if value is NaN",
      notes: "Common guard around parsed floating data."
    },
    %{
      name: "Double/isInfinite",
      status: :candidate,
      description: "Return true if value is infinite",
      notes: "Common guard around parsed floating data."
    },
    %{
      name: "Double/valueOf",
      status: :candidate,
      description: "Parse or box a double value",
      notes: "parse-double covers string parsing; boxing is not relevant."
    },
    %{
      name: "doubleValue",
      status: :not_relevant,
      description: "Unbox a Double object",
      notes: "PTC-Lisp has one numeric value model, not boxed Java numbers."
    }
  ],
  java_lang_float_audit: [
    %{
      name: "Float/parseFloat",
      status: :supported,
      description: "Parse string to float",
      notes:
        "BUG GAP-J01: currently aliases parse-double, returns nil on invalid input, and rejects surrounding whitespace that Java accepts. PTC-Lisp uses one floating type."
    },
    %{
      name: "Float/isNaN",
      status: :candidate,
      description: "Return true if value is NaN",
      notes: "Common guard around parsed floating data."
    },
    %{
      name: "Float/isInfinite",
      status: :candidate,
      description: "Return true if value is infinite",
      notes: "Common guard around parsed floating data."
    },
    %{
      name: "Float/valueOf",
      status: :candidate,
      description: "Parse or box a float value",
      notes: "parse-double covers string parsing; boxing is not relevant."
    },
    %{
      name: "floatValue",
      status: :not_relevant,
      description: "Unbox a Float object",
      notes: "PTC-Lisp has one floating type, not boxed Java numbers."
    }
  ],
  java_lang_integer_audit: [
    %{
      name: "Integer/parseInt",
      status: :supported,
      description: "Parse string to integer",
      notes:
        "BUG GAP-J01: currently aliases parse-long, returns nil on invalid input, and accepts values outside Java int range; Java raises NumberFormatException. BUG GAP-J15: radix overload is unsupported."
    },
    %{
      name: "Integer/valueOf",
      status: :candidate,
      description: "Parse or box an integer value",
      notes: "parse-long covers string parsing; boxing is not relevant."
    },
    %{
      name: "Integer/toString",
      status: :candidate,
      description: "Convert integer to string",
      notes: "str covers the common PTC-Lisp need."
    },
    %{
      name: "Integer/MAX_VALUE",
      status: :not_relevant,
      description: "Maximum Java int constant",
      notes: "BEAM integers are arbitrary precision; Java int bounds are misleading."
    },
    %{
      name: "Integer/MIN_VALUE",
      status: :not_relevant,
      description: "Minimum Java int constant",
      notes: "BEAM integers are arbitrary precision; Java int bounds are misleading."
    }
  ],
  java_lang_long_audit: [
    %{
      name: "Long/parseLong",
      status: :supported,
      description: "Parse string to integer",
      notes:
        "BUG GAP-J01: currently aliases parse-long, returns nil on invalid input, and accepts values outside Java long range; Java raises NumberFormatException. BUG GAP-J15: radix overload is unsupported."
    },
    %{
      name: "Long/valueOf",
      status: :candidate,
      description: "Parse or box a long value",
      notes: "parse-long covers string parsing; boxing is not relevant."
    },
    %{
      name: "Long/toString",
      status: :candidate,
      description: "Convert long to string",
      notes: "str covers the common PTC-Lisp need."
    },
    %{
      name: "Long/MAX_VALUE",
      status: :not_relevant,
      description: "Maximum Java long constant",
      notes: "BEAM integers are arbitrary precision; Java long bounds are misleading."
    },
    %{
      name: "Long/MIN_VALUE",
      status: :not_relevant,
      description: "Minimum Java long constant",
      notes: "BEAM integers are arbitrary precision; Java long bounds are misleading."
    }
  ],
  java_lang_string_audit: [
    %{
      name: ".contains",
      status: :supported,
      description: "Substring containment",
      notes:
        "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings"
    },
    %{
      name: ".indexOf",
      status: :supported,
      description: "First substring index",
      notes:
        "BUG GAP-J05: integer character-code overloads are unsupported. BUG GAP-J09: non-BMP offsets are grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".lastIndexOf",
      status: :supported,
      description: "Last substring index",
      notes:
        "BUG GAP-J05: substring/from-index and integer character-code overloads are unsupported. BUG GAP-J09: non-BMP offsets are grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".length",
      status: :supported,
      description: "String length",
      notes:
        "BUG GAP-J09: non-BMP length is grapheme-based instead of Java UTF-16 code-unit based. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".substring",
      status: :supported,
      description: "Extract substring",
      notes:
        "BUG GAP-J09: non-BMP indexes are grapheme-based instead of Java UTF-16 code-unit based. BUG GAP-J14: finite numeric indexes such as floats are rejected instead of coerced. DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".toLowerCase",
      status: :supported,
      description: "Lowercase string",
      notes:
        "DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".toUpperCase",
      status: :supported,
      description: "Uppercase string",
      notes:
        "DIV-41: character-literal receivers behave as one-character strings (PTC-Lisp has no Character type)"
    },
    %{
      name: ".startsWith",
      status: :supported,
      description: "Prefix test",
      notes:
        "BUG GAP-J05: prefix/offset overload is unsupported. DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings"
    },
    %{
      name: ".endsWith",
      status: :supported,
      description: "Suffix test",
      notes:
        "DIV-40: character literals are accepted as arguments (PTC-Lisp has no Character type). DIV-41: character-literal receivers behave as one-character strings"
    },
    %{
      name: ".trim",
      status: :candidate,
      description: "Trim leading and trailing whitespace",
      notes: "Common LLM spelling; clojure.string/trim is not currently implemented."
    },
    %{
      name: ".isEmpty",
      status: :candidate,
      description: "Return true for empty string",
      notes: "empty? covers the common PTC-Lisp need."
    },
    %{
      name: ".equalsIgnoreCase",
      status: :candidate,
      description: "Case-insensitive string equality",
      notes: "Common Java idiom in generated code."
    },
    %{
      name: ".charAt",
      status: :candidate,
      description: "Return character at index",
      notes: "Potentially useful, but PTC-Lisp must define grapheme semantics."
    },
    %{
      name: ".getBytes",
      status: :not_relevant,
      description: "Encode string to bytes",
      notes: "Byte arrays and charsets are outside the sandbox data model."
    },
    %{
      name: ".intern",
      status: :not_relevant,
      description: "Intern a Java string",
      notes: "JVM string pool operation; not meaningful on BEAM."
    }
  ],
  java_lang_system_audit: [
    %{
      name: "System/currentTimeMillis",
      status: :supported,
      description: "Current Unix time in milliseconds",
      notes: ""
    },
    %{
      name: "System/nanoTime",
      status: :candidate,
      description: "Monotonic time source",
      notes: "Potential benchmark/timing helper; not wall-clock time."
    },
    %{
      name: "System/getenv",
      status: :not_relevant,
      description: "Read process environment variables",
      notes: "Host environment access is intentionally not exposed."
    },
    %{
      name: "System/getProperty",
      status: :not_relevant,
      description: "Read JVM system properties",
      notes: "JVM property access is not meaningful and would leak host details."
    },
    %{
      name: "System/exit",
      status: :not_relevant,
      description: "Terminate the JVM",
      notes: "Process termination is forbidden in the sandbox."
    }
  ],
  java_time_local_date_audit: [
    %{
      name: "LocalDate/parse",
      status: :supported,
      description: "Parse ISO-8601 date string",
      notes:
        "Also available as java.time.LocalDate/parse and parse. BUG GAP-J06: date-time strings are accepted instead of rejected."
    },
    %{
      name: "LocalDate/now",
      status: :candidate,
      description: "Current date",
      notes: "Useful, but currentTimeMillis plus parse/Date constructors cover many cases."
    },
    %{
      name: ".isBefore",
      status: :supported,
      description: "Date ordering predicate",
      notes: "Works for same-type Date or DateTime values."
    },
    %{
      name: ".isAfter",
      status: :supported,
      description: "Date ordering predicate",
      notes: "Works for same-type Date or DateTime values."
    },
    %{
      name: "LocalDate/of",
      status: :candidate,
      description: "Construct date from year/month/day",
      notes: "Useful Java idiom; vector/map construction plus parse is the current workaround."
    },
    %{
      name: ".format",
      status: :candidate,
      description: "Format date with a formatter",
      notes: "Date formatting API would need a bounded formatter surface."
    },
    %{
      name: ".toEpochDay",
      status: :supported,
      description: "Return LocalDate epoch-day integer",
      notes: "Requested in issue #1019 for day differences and date sorting."
    },
    %{
      name: ".plusDays",
      status: :supported,
      description: "Add days to a LocalDate",
      notes:
        "Requested in issue #1019 for date arithmetic. BUG GAP-J12: floating and NaN day counts are rejected instead of following Clojure Java interop coercion."
    },
    %{
      name: ".minusDays",
      status: :supported,
      description: "Subtract days from a LocalDate",
      notes:
        "Requested in issue #1019 for date arithmetic. BUG GAP-J12: floating and NaN day counts are rejected instead of following Clojure Java interop coercion."
    }
  ],
  java_time_instant_audit: [
    %{
      name: "Instant/parse",
      status: :supported,
      description: "Parse ISO-8601 instant string",
      notes:
        "Also available as java.time.Instant/parse and parse. BUG GAP-J06: date-only and no-zone date-time strings are accepted instead of rejected."
    },
    %{
      name: "Instant/now",
      status: :candidate,
      description: "Current instant",
      notes: "System/currentTimeMillis plus java.util.Date. covers many cases."
    },
    %{
      name: ".isBefore",
      status: :supported,
      description: "Instant ordering predicate",
      notes: "Works for same-type Date or DateTime values."
    },
    %{
      name: ".isAfter",
      status: :supported,
      description: "Instant ordering predicate",
      notes: "Works for same-type Date or DateTime values."
    },
    %{
      name: ".getTime",
      status: :supported,
      description: "Unix timestamp in milliseconds",
      notes:
        "BUG GAP-J04: Java Instant has toEpochMilli, not getTime; current behavior is a PTC convenience."
    },
    %{
      name: ".toEpochMilli",
      status: :candidate,
      description: "Return Instant epoch millisecond",
      notes: "BUG GAP-J18: Java Instant.toEpochMilli is unsupported while .getTime is exposed."
    },
    %{
      name: "Instant/ofEpochMilli",
      status: :candidate,
      description: "Construct instant from epoch milliseconds",
      notes: "java.util.Date. already accepts seconds or milliseconds."
    }
  ],
  java_time_duration_audit: [
    %{
      name: "Duration/between",
      status: :supported,
      description: "Duration between two instants",
      notes:
        "Requested in issue #1019 for millisecond/day differences. BUG GAP-J19: java.util.Date inputs are accepted instead of rejected."
    },
    %{
      name: ".toMillis",
      status: :supported,
      description: "Return duration length in milliseconds",
      notes: "Requested in issue #1019 for instant differences."
    },
    %{
      name: ".toDays",
      status: :supported,
      description: "Return duration length in whole days",
      notes: "Requested in issue #1019 for bucket/day calculations."
    },
    %{
      name: "Duration/ofMillis",
      status: :candidate,
      description: "Construct duration from milliseconds",
      notes: "Useful companion for bounded Duration support."
    },
    %{
      name: "Duration/parse",
      status: :candidate,
      description: "Parse ISO-8601 duration string",
      notes: "Useful but lower-priority than between/toMillis/toDays."
    }
  ],
  java_time_period_audit: [
    %{
      name: "Period/between",
      status: :candidate,
      description: "Period between two dates",
      notes:
        "Deferred for issue #1019; `Period.getDays` is a component value, not total days. Use `.toEpochDay` subtraction for LocalDate day differences."
    },
    %{
      name: ".getDays",
      status: :candidate,
      description: "Return day component of a Period",
      notes:
        "Deferred for issue #1019 because this is the day component, not total days; easy to misuse for analytics."
    },
    %{
      name: "Period/ofDays",
      status: :candidate,
      description: "Construct period from days",
      notes: "Useful companion for bounded Period support."
    },
    %{
      name: "Period/parse",
      status: :candidate,
      description: "Parse ISO-8601 period string",
      notes: "Useful but lower-priority than between/getDays."
    }
  ],
  java_util_date_audit: [
    %{
      name: "java.util.Date.",
      status: :supported,
      description: "Construct DateTime value",
      notes:
        "BUG GAP-J03: numeric constructor currently treats milliseconds as seconds. BUG GAP-J06: ISO date strings are accepted by PTC-Lisp but rejected by the Java oracle. BUG GAP-J11: Java-accepted legacy date strings are rejected."
    },
    %{
      name: ".getTime",
      status: :supported,
      description: "Unix timestamp in milliseconds",
      notes: "Works on DateTime values."
    },
    %{
      name: ".isBefore",
      status: :supported,
      description: "Date ordering predicate",
      notes:
        "BUG GAP-J20: java.util.Date uses .before, not .isBefore; current behavior exposes a non-Java alias."
    },
    %{
      name: ".isAfter",
      status: :supported,
      description: "Date ordering predicate",
      notes:
        "BUG GAP-J20: java.util.Date uses .after, not .isAfter; current behavior exposes a non-Java alias."
    },
    %{
      name: ".before",
      status: :candidate,
      description: "Date ordering predicate",
      notes: ".isBefore covers the current PTC-Lisp spelling."
    },
    %{
      name: ".after",
      status: :candidate,
      description: "Date ordering predicate",
      notes: ".isAfter covers the current PTC-Lisp spelling."
    },
    %{
      name: ".setTime",
      status: :not_relevant,
      description: "Mutate Date timestamp",
      notes: "Mutable Java object operations are outside the sandbox model."
    }
  ]
}
