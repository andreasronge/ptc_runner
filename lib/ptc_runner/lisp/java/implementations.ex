defmodule PtcRunner.Lisp.Java.Implementations do
  @moduledoc false

  @handlers %{
    boolean_parse_boolean: {PtcRunner.Lisp.Java.Lang.Boolean, :parse_boolean},
    double_nan: {PtcRunner.Lisp.Java.Lang.Double, :nan},
    double_negative_infinity: {PtcRunner.Lisp.Java.Lang.Double, :negative_infinity},
    double_parse_double: {PtcRunner.Lisp.Java.Lang.Double, :parse_double},
    double_positive_infinity: {PtcRunner.Lisp.Java.Lang.Double, :positive_infinity},
    date_after: {PtcRunner.Lisp.Java.Util.Date, :after?},
    date_before: {PtcRunner.Lisp.Java.Util.Date, :before?},
    date_get_time: {PtcRunner.Lisp.Java.Util.Date, :get_time},
    date_new: {PtcRunner.Lisp.Java.Util.Date, :construct},
    duration_between: {PtcRunner.Lisp.Java.Time.Duration, :between},
    duration_to_days: {PtcRunner.Lisp.Java.Time.Duration, :to_days},
    duration_to_millis: {PtcRunner.Lisp.Java.Time.Duration, :to_millis},
    float_parse_float: {PtcRunner.Lisp.Java.Lang.Float, :parse_float},
    integer_parse_int: {PtcRunner.Lisp.Java.Lang.Integer, :parse_int},
    instant_is_after: {PtcRunner.Lisp.Java.Time.Instant, :after?},
    instant_is_before: {PtcRunner.Lisp.Java.Time.Instant, :before?},
    instant_parse: {PtcRunner.Lisp.Java.Time.Instant, :parse},
    instant_to_epoch_milli: {PtcRunner.Lisp.Java.Time.Instant, :to_epoch_milli},
    local_date_is_after: {PtcRunner.Lisp.Java.Time.LocalDate, :after?},
    local_date_is_before: {PtcRunner.Lisp.Java.Time.LocalDate, :before?},
    local_date_minus_days: {PtcRunner.Lisp.Java.Time.LocalDate, :minus_days},
    local_date_parse: {PtcRunner.Lisp.Java.Time.LocalDate, :parse},
    local_date_plus_days: {PtcRunner.Lisp.Java.Time.LocalDate, :plus_days},
    local_date_to_epoch_day: {PtcRunner.Lisp.Java.Time.LocalDate, :to_epoch_day},
    long_parse_long: {PtcRunner.Lisp.Java.Lang.Long, :parse_long},
    math_abs_double: {PtcRunner.Lisp.Java.Lang.Math, :abs_double},
    math_abs_float: {PtcRunner.Lisp.Java.Lang.Math, :abs_float},
    math_abs_int: {PtcRunner.Lisp.Java.Lang.Math, :abs_int},
    math_abs_long: {PtcRunner.Lisp.Java.Lang.Math, :abs_long},
    math_ceil_double: {PtcRunner.Lisp.Java.Lang.Math, :ceil_double},
    math_floor_double: {PtcRunner.Lisp.Java.Lang.Math, :floor_double},
    math_max_double: {PtcRunner.Lisp.Java.Lang.Math, :max_double},
    math_max_float: {PtcRunner.Lisp.Java.Lang.Math, :max_float},
    math_max_int: {PtcRunner.Lisp.Java.Lang.Math, :max_int},
    math_max_long: {PtcRunner.Lisp.Java.Lang.Math, :max_long},
    math_min_double: {PtcRunner.Lisp.Java.Lang.Math, :min_double},
    math_min_float: {PtcRunner.Lisp.Java.Lang.Math, :min_float},
    math_min_int: {PtcRunner.Lisp.Java.Lang.Math, :min_int},
    math_min_long: {PtcRunner.Lisp.Java.Lang.Math, :min_long},
    math_pow_double: {PtcRunner.Lisp.Java.Lang.Math, :pow_double},
    math_round_double: {PtcRunner.Lisp.Java.Lang.Math, :round_double},
    math_round_float: {PtcRunner.Lisp.Java.Lang.Math, :round_float},
    math_sqrt_double: {PtcRunner.Lisp.Java.Lang.Math, :sqrt_double},
    system_current_time_millis: {PtcRunner.Lisp.Java.Lang.System, :current_time_millis}
  }

  @spec keys() :: %{atom() => true}
  def keys, do: Map.new(@handlers, fn {key, _handler} -> {key, true} end)

  @spec fetch(atom()) :: {:ok, {module(), atom()}} | :error
  def fetch(key), do: Map.fetch(@handlers, key)
end
