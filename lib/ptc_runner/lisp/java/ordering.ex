defmodule PtcRunner.Lisp.Java.Ordering do
  @moduledoc false

  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate

  @type comparison :: :lt | :eq | :gt

  @spec compare(term(), term()) :: {:ok, comparison()} | {:error, :invalid_java_value} | :not_java
  def compare(%LocalDate{epoch_day: left} = a, %LocalDate{epoch_day: right} = b),
    do: compare_valid(a, b, LocalDate, left, right)

  def compare(%Instant{} = left, %Instant{} = right) do
    if Instant.valid?(left) and Instant.valid?(right),
      do: {:ok, Instant.compare(left, right)},
      else: {:error, :invalid_java_value}
  end

  def compare(
        %Duration{seconds: left_seconds, nano: left_nano} = a,
        %Duration{
          seconds: right_seconds,
          nano: right_nano
        } = b
      ),
      do: compare_valid(a, b, Duration, {left_seconds, left_nano}, {right_seconds, right_nano})

  def compare(%JavaDate{epoch_millis: left} = a, %JavaDate{epoch_millis: right} = b),
    do: compare_valid(a, b, JavaDate, left, right)

  def compare(%{__struct__: module}, %{__struct__: module})
      when module in [LocalDate, Instant, Duration, JavaDate],
      do: {:error, :invalid_java_value}

  def compare(%{__struct__: module} = value, other)
      when module in [LocalDate, Instant, Duration, JavaDate],
      do: validate_mixed(value, module, other)

  def compare(other, %{__struct__: module} = value)
      when module in [LocalDate, Instant, Duration, JavaDate],
      do: validate_mixed(value, module, other)

  def compare(_left, _right), do: :not_java

  defp compare_valid(left, right, module, left_key, right_key) do
    if module.valid?(left) and module.valid?(right),
      do: {:ok, compare_keys(left_key, right_key)},
      else: {:error, :invalid_java_value}
  end

  defp validate_mixed(value, module, other) do
    if module.valid?(value) and valid_known_java_value?(other),
      do: :not_java,
      else: {:error, :invalid_java_value}
  end

  defp valid_known_java_value?(%{__struct__: module} = value)
       when module in [LocalDate, Instant, Duration, JavaDate],
       do: module.valid?(value)

  defp valid_known_java_value?(_value), do: true

  defp compare_keys(left, right) when left < right, do: :lt
  defp compare_keys(left, right) when left > right, do: :gt
  defp compare_keys(_left, _right), do: :eq
end
