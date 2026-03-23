defmodule PtcRunner.Metrics.Statistics do
  @moduledoc """
  Statistical comparison functions for benchmark results.

  Pure math — no external dependencies.
  """

  @doc """
  Wilson score confidence interval for a proportion.

  Returns `{lower, upper}` bounds. Uses z=1.96 for 95% confidence (default).

  ## Examples

      iex> {lower, upper} = PtcRunner.Metrics.Statistics.wilson_interval(7, 10)
      iex> is_float(lower) and is_float(upper)
      true
  """
  @spec wilson_interval(non_neg_integer(), pos_integer(), float()) :: {float(), float()}
  def wilson_interval(successes, total, confidence \\ 0.95)

  def wilson_interval(0, total, confidence) when total > 0 do
    z = z_score(confidence)
    upper = 1.0 - :math.pow(1.0 - confidence, 1.0 / total)
    # Use Wilson formula for lower bound (which is 0.0 for 0 successes)
    denominator = 1.0 + z * z / total

    upper_wilson =
      (z * z / (2.0 * total) + z * :math.sqrt(z * z / (4.0 * total * total))) / denominator

    {0.0, min(max(upper, upper_wilson), 1.0)}
  end

  def wilson_interval(successes, total, confidence) when successes == total and total > 0 do
    {_lower, upper} = wilson_interval(0, total, confidence)
    {Float.round(1.0 - upper, 10), 1.0}
  end

  def wilson_interval(successes, total, confidence)
      when total > 0 and successes >= 0 and successes <= total do
    z = z_score(confidence)
    p_hat = successes / total
    z2 = z * z
    denominator = 1.0 + z2 / total
    centre = p_hat + z2 / (2.0 * total)
    margin = z * :math.sqrt(p_hat * (1.0 - p_hat) / total + z2 / (4.0 * total * total))

    lower = max((centre - margin) / denominator, 0.0)
    upper = min((centre + margin) / denominator, 1.0)

    {lower, upper}
  end

  @doc """
  Fisher exact test p-value for 2x2 contingency table (two-tailed).

  Compares pass/fail counts between two variants.
  Uses log-factorials to avoid overflow.

  ## Examples

      iex> p = PtcRunner.Metrics.Statistics.fisher_exact_p(5, 5, 5, 5)
      iex> p == 1.0
      true
  """
  @spec fisher_exact_p(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          float()
  def fisher_exact_p(pass_a, fail_a, pass_b, fail_b) do
    n_a = pass_a + fail_a
    n_b = pass_b + fail_b
    total_pass = pass_a + pass_b
    total_fail = fail_a + fail_b
    n = n_a + n_b

    marginals = %{n_a: n_a, n_b: n_b, total_pass: total_pass, total_fail: total_fail, n: n}

    observed_prob = table_probability({pass_a, fail_a, pass_b, fail_b}, marginals)

    # Enumerate all possible tables with the same marginals
    min_a = max(0, total_pass - n_b)
    max_a = min(n_a, total_pass)

    p_value =
      Enum.reduce(min_a..max_a, 0.0, fn a, acc ->
        b = n_a - a
        c = total_pass - a
        d = total_fail - b

        if b >= 0 and c >= 0 and d >= 0 do
          prob = table_probability({a, b, c, d}, marginals)

          if prob <= observed_prob + 1.0e-10 do
            acc + prob
          else
            acc
          end
        else
          acc
        end
      end)

    min(p_value, 1.0)
  end

  @doc """
  Sample size per group for comparing two proportions.

  Uses the standard formula for desired power and significance level.
  Returns the number of observations needed per group.

  ## Examples

      iex> n = PtcRunner.Metrics.Statistics.sample_size_for_two_proportions(0.5, 0.6)
      iex> is_integer(n) and n > 0
      true
  """
  @spec sample_size_for_two_proportions(float(), float(), float(), float()) :: pos_integer()
  def sample_size_for_two_proportions(p1, p2, power \\ 0.8, alpha \\ 0.05)

  def sample_size_for_two_proportions(p1, p2, _power, _alpha) when p1 == p2 do
    raise ArgumentError, "p1 and p2 must differ (got both #{p1})"
  end

  def sample_size_for_two_proportions(p1, p2, power, alpha) do
    z_alpha = z_from_alpha(alpha / 2.0)
    z_beta = z_from_power(power)
    p_bar = (p1 + p2) / 2.0

    numerator =
      z_alpha * :math.sqrt(2.0 * p_bar * (1.0 - p_bar)) +
        z_beta * :math.sqrt(p1 * (1.0 - p1) + p2 * (1.0 - p2))

    n = :math.pow(numerator / (p1 - p2), 2)
    ceil(n)
  end

  # Private helpers

  defp log_factorial(0), do: 0.0
  defp log_factorial(1), do: 0.0

  defp log_factorial(n) when n >= 2 do
    Enum.reduce(2..n, 0.0, fn i, acc -> acc + :math.log(i) end)
  end

  defp table_probability({a, b, c, d}, %{n_a: n_a, n_b: n_b, total_pass: tp, total_fail: tf, n: n}) do
    log_p =
      log_factorial(n_a) + log_factorial(n_b) + log_factorial(tp) + log_factorial(tf) -
        log_factorial(n) - log_factorial(a) - log_factorial(b) - log_factorial(c) -
        log_factorial(d)

    :math.exp(log_p)
  end

  defp z_score(0.90), do: 1.645
  defp z_score(0.95), do: 1.96
  defp z_score(0.99), do: 2.576

  defp z_score(confidence) do
    raise ArgumentError,
          "unsupported confidence level #{confidence}, use 0.90, 0.95, or 0.99"
  end

  defp z_from_alpha(alpha) do
    # Common two-tailed z-values from alpha/2
    cond do
      abs(alpha - 0.025) < 1.0e-10 -> 1.96
      abs(alpha - 0.005) < 1.0e-10 -> 2.576
      abs(alpha - 0.05) < 1.0e-10 -> 1.645
      true -> approximate_z(1.0 - alpha)
    end
  end

  defp z_from_power(power) do
    cond do
      abs(power - 0.8) < 1.0e-10 -> 0.8416
      abs(power - 0.9) < 1.0e-10 -> 1.2816
      abs(power - 0.95) < 1.0e-10 -> 1.6449
      true -> approximate_z(power)
    end
  end

  # Rational approximation of the inverse normal CDF (Abramowitz and Stegun)
  defp approximate_z(p) when p > 0.5 and p < 1.0 do
    t = :math.sqrt(-2.0 * :math.log(1.0 - p))

    c0 = 2.515517
    c1 = 0.802853
    c2 = 0.010328
    d1 = 1.432788
    d2 = 0.189269
    d3 = 0.001308

    t - (c0 + c1 * t + c2 * t * t) / (1.0 + d1 * t + d2 * t * t + d3 * t * t * t)
  end
end
