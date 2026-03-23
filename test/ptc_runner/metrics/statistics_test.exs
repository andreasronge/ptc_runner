defmodule PtcRunner.Metrics.StatisticsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Metrics.Statistics

  doctest PtcRunner.Metrics.Statistics

  describe "wilson_interval/3" do
    test "7/10 at 95% confidence" do
      {lower, upper} = Statistics.wilson_interval(7, 10)
      assert_in_delta lower, 0.40, 0.02
      assert_in_delta upper, 0.89, 0.02
    end

    test "0/10 lower bound is 0.0" do
      {lower, _upper} = Statistics.wilson_interval(0, 10)
      assert lower == 0.0
    end

    test "0/10 upper bound is positive" do
      {_lower, upper} = Statistics.wilson_interval(0, 10)
      assert upper > 0.0
      assert_in_delta upper, 0.28, 0.05
    end

    test "10/10 upper bound is 1.0" do
      {_lower, upper} = Statistics.wilson_interval(10, 10)
      assert upper == 1.0
    end

    test "10/10 lower bound is high" do
      {lower, _upper} = Statistics.wilson_interval(10, 10)
      assert_in_delta lower, 0.72, 0.05
    end

    test "50/100 at 95% confidence" do
      {lower, upper} = Statistics.wilson_interval(50, 100)
      assert_in_delta lower, 0.40, 0.02
      assert_in_delta upper, 0.60, 0.02
    end

    test "bounds are always in [0, 1]" do
      for {s, n} <- [{0, 1}, {1, 1}, {3, 5}, {0, 100}, {100, 100}] do
        {lower, upper} = Statistics.wilson_interval(s, n)
        assert lower >= 0.0, "lower bound #{lower} < 0 for #{s}/#{n}"
        assert upper <= 1.0, "upper bound #{upper} > 1 for #{s}/#{n}"
        assert lower <= upper, "lower #{lower} > upper #{upper} for #{s}/#{n}"
      end
    end
  end

  describe "fisher_exact_p/4" do
    test "identical distributions return p = 1.0" do
      assert Statistics.fisher_exact_p(5, 5, 5, 5) == 1.0
    end

    test "clear difference yields small p-value" do
      p = Statistics.fisher_exact_p(9, 1, 5, 5)
      assert p < 0.15
      assert p > 0.0
    end

    test "very clear difference yields very small p-value" do
      p = Statistics.fisher_exact_p(10, 0, 0, 10)
      assert p < 0.001
    end

    test "swapping groups gives same p-value" do
      p1 = Statistics.fisher_exact_p(9, 1, 5, 5)
      p2 = Statistics.fisher_exact_p(5, 5, 9, 1)
      assert_in_delta p1, p2, 1.0e-10
    end

    test "p-value is in [0, 1]" do
      for {a, b, c, d} <- [{3, 7, 5, 5}, {0, 10, 10, 0}, {8, 2, 6, 4}] do
        p = Statistics.fisher_exact_p(a, b, c, d)
        assert p >= 0.0 and p <= 1.0, "p=#{p} out of range for #{a},#{b},#{c},#{d}"
      end
    end
  end

  describe "sample_size_for_two_proportions/4" do
    test "~400 per group for 10pp difference around 50%" do
      n = Statistics.sample_size_for_two_proportions(0.5, 0.6)
      assert n > 300
      assert n < 500
    end

    test "larger sample needed for smaller difference" do
      n_10pp = Statistics.sample_size_for_two_proportions(0.5, 0.6)
      n_5pp = Statistics.sample_size_for_two_proportions(0.5, 0.55)
      assert n_5pp > n_10pp
    end

    test "small differences need very large samples" do
      n = Statistics.sample_size_for_two_proportions(0.5, 0.55)
      assert n > 1000
    end

    test "raises when p1 == p2" do
      assert_raise ArgumentError, fn ->
        Statistics.sample_size_for_two_proportions(0.5, 0.5)
      end
    end

    test "returns positive integer" do
      n = Statistics.sample_size_for_two_proportions(0.3, 0.5)
      assert is_integer(n)
      assert n > 0
    end
  end
end
