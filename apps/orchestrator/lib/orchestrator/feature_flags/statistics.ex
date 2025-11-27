defmodule Orchestrator.FeatureFlags.Statistics do
  require Logger
  alias Decimal, as: D

  def wilson_score_interval(successes, total, confidence_level \\ 95) do
    p = D.div(D.new(successes), D.new(total))
    n = D.new(total)
    z = confidence_z_score(confidence_level)
    z_squared = D.mult(z, z)
    denominator = D.add(D.new(1), D.div(z_squared, n))
    center_numerator = D.add(p, D.div(z_squared, D.mult(D.new(2), n)))
    center = D.div(center_numerator, denominator)
    p_complement = D.sub(D.new(1), p)
    variance_1 = D.div(D.mult(p, p_complement), n)
    variance_2 = D.div(z_squared, D.mult(D.new(4), D.mult(n, n)))
    variance = D.add(variance_1, variance_2)
    margin_numerator = D.mult(z, decimal_sqrt(variance))
    margin = D.div(margin_numerator, denominator)
    lower = D.sub(center, margin)
    upper = D.add(center, margin)
    {D.max(lower, D.new(0)), D.min(upper, D.new(1))}
  end

  def chi_square_test(successes_a, total_a, successes_b, total_b) do
    a = D.new(successes_a)
    b = D.new(successes_b)
    c = D.sub(D.new(total_a), a)
    d = D.sub(D.new(total_b), b)
    n = D.add(D.add(a, b), D.add(c, d))
    row1_total = D.add(a, c)
    row2_total = D.add(b, d)
    col1_total = D.add(a, b)
    col2_total = D.add(c, d)
    expected_a = D.div(D.mult(row1_total, col1_total), n)
    expected_b = D.div(D.mult(row2_total, col1_total), n)
    expected_c = D.div(D.mult(row1_total, col2_total), n)
    expected_d = D.div(D.mult(row2_total, col2_total), n)

    min_expected =
      [expected_a, expected_b, expected_c, expected_d]
      |> Enum.map(&D.to_float/1)
      |> Enum.min()

    if min_expected < 5 do
      Logger.warning(
        "Chi-square test: minimum expected frequency < 5 (#{min_expected}), results may be unreliable"
      )
    end

    ad = D.mult(a, d)
    bc = D.mult(b, c)
    diff = D.abs(D.sub(ad, bc))
    corrected_diff = D.sub(diff, D.div(n, D.new(2)))
    corrected_diff = D.max(corrected_diff, D.new(0))
    numerator = D.mult(n, D.mult(corrected_diff, corrected_diff))

    denominator =
      D.mult(
        D.mult(D.add(a, b), D.add(c, d)),
        D.mult(D.add(a, c), D.add(b, d))
      )

    chi_square = D.div(numerator, denominator)
    p_value = chi_square_p_value(D.to_float(chi_square), 1)

    %{
      chi_square: chi_square,
      p_value: D.from_float(p_value),
      is_significant: p_value < 0.05,
      degrees_of_freedom: 1,
      yates_correction_applied: true
    }
  end

  def two_sample_t_test(values_a, values_b) when is_list(values_a) and is_list(values_b) do
    n_a = length(values_a)
    n_b = length(values_b)
    mean_a = mean(values_a)
    mean_b = mean(values_b)
    var_a = variance(values_a, mean_a)
    var_b = variance(values_b, mean_b)
    std_a = :math.sqrt(var_a)
    std_b = :math.sqrt(var_b)
    standard_error = :math.sqrt(var_a / n_a + var_b / n_b)
    t_statistic = (mean_a - mean_b) / standard_error
    numerator = :math.pow(var_a / n_a + var_b / n_b, 2)

    denominator =
      :math.pow(var_a / n_a, 2) / (n_a - 1) +
        :math.pow(var_b / n_b, 2) / (n_b - 1)

    df = numerator / denominator
    p_value = t_distribution_p_value(abs(t_statistic), df) * 2
    pooled_std = :math.sqrt((var_a + var_b) / 2)
    cohens_d = (mean_a - mean_b) / pooled_std

    %{
      t_statistic: D.from_float(t_statistic),
      p_value: D.from_float(p_value),
      is_significant: p_value < 0.05,
      degrees_of_freedom: D.from_float(df),
      mean_a: D.from_float(mean_a),
      mean_b: D.from_float(mean_b),
      std_a: D.from_float(std_a),
      std_b: D.from_float(std_b),
      effect_size: D.from_float(cohens_d)
    }
  end

  def bayesian_probability(successes_a, total_a, successes_b, total_b, num_samples \\ 100_000) do
    alpha_a = successes_a + 1
    beta_a = total_a - successes_a + 1
    alpha_b = successes_b + 1
    beta_b = total_b - successes_b + 1

    wins_a =
      1..num_samples
      |> Enum.reduce(0, fn _, acc ->
        sample_a = sample_beta(alpha_a, beta_a)
        sample_b = sample_beta(alpha_b, beta_b)
        if sample_a > sample_b, do: acc + 1, else: acc
      end)

    probability = wins_a / num_samples
    D.from_float(probability)
  end

  def relative_improvement(baseline_rate, variation_rate) do
    baseline = D.new(baseline_rate)
    variation = D.new(variation_rate)

    if D.equal?(baseline, D.new(0)) do
      D.new(0)
    else
      improvement = D.div(D.sub(variation, baseline), baseline)
      D.mult(improvement, D.new(100))
    end
  end

  def minimum_detectable_effect(
        baseline_rate,
        sample_size_per_variation,
        alpha \\ 0.05,
        power \\ 0.80
      ) do
    p = baseline_rate
    n = sample_size_per_variation
    z_alpha = confidence_z_score((1 - alpha) * 100)
    z_beta = confidence_z_score(power * 100)
    variance_term = 2 * p * (1 - p) / n
    mde = (z_alpha + z_beta) * :math.sqrt(variance_term)
    D.from_float(mde)
  end

  def required_sample_size(baseline_rate, mde, alpha \\ 0.05, power \\ 0.80) do
    p = baseline_rate
    z_alpha = confidence_z_score((1 - alpha) * 100)
    z_beta = confidence_z_score(power * 100)
    numerator = 2 * p * (1 - p) * :math.pow(z_alpha + z_beta, 2)
    denominator = :math.pow(mde, 2)
    n = numerator / denominator
    ceil(n)
  end

  defp confidence_z_score(confidence_level) do
    case confidence_level do
      90 ->
        1.645

      95 ->
        1.96

      99 ->
        2.576

      99.9 ->
        3.291

      _ ->
        p = confidence_level / 100
        normal_quantile((1 + p) / 2)
    end
  end

  defp chi_square_p_value(chi_square, df) do
    if df == 1 do
      2 * (1 - normal_cdf(:math.sqrt(chi_square)))
    else
      1 - incomplete_gamma(df / 2, chi_square / 2)
    end
  end

  defp t_distribution_p_value(t, df) do
    if df > 30 do
      1 - normal_cdf(t)
    else
      x = df / (df + t * t)
      0.5 * incomplete_beta(x, df / 2, 0.5)
    end
  end

  defp normal_cdf(x) do
    0.5 * (1 + :math.erf(x / :math.sqrt(2)))
  end

  defp normal_quantile(p) do
    if p <= 0.5 do
      -rational_approximation(:math.sqrt(-2 * :math.log(p)))
    else
      rational_approximation(:math.sqrt(-2 * :math.log(1 - p)))
    end
  end

  defp rational_approximation(t) do
    c0 = 2.515517
    c1 = 0.802853
    c2 = 0.010328
    d1 = 1.432788
    d2 = 0.189269
    d3 = 0.001308
    numerator = c0 + c1 * t + c2 * t * t
    denominator = 1 + d1 * t + d2 * t * t + d3 * t * t * t
    t - numerator / denominator
  end

  defp incomplete_gamma(a, x) do
    gamma_series(a, x, 0, 1.0, a, 1.0e-10, 100)
  end

  defp gamma_series(a, x, sum, term, index, epsilon, max_iter) when max_iter > 0 do
    if abs(term) < epsilon do
      sum * :math.exp(-x + a * :math.log(x) - log_gamma(a))
    else
      new_term = term * x / index
      gamma_series(a, x, sum + new_term, new_term, index + 1, epsilon, max_iter - 1)
    end
  end

  defp gamma_series(a, x, sum, _term, _index, _epsilon, 0) do
    sum * :math.exp(-x + a * :math.log(x) - log_gamma(a))
  end

  defp incomplete_beta(x, a, b) do
    _ = a
    _ = b
    if x == 0, do: 0.0, else: if(x == 1, do: 1.0, else: 0.5)
  end

  defp log_gamma(x) do
    (x - 0.5) * :math.log(x) - x + 0.5 * :math.log(2 * :math.pi()) + 1 / (12 * x)
  end

  defp sample_beta(alpha, beta) do
    x = sample_gamma(alpha)
    y = sample_gamma(beta)
    x / (x + y)
  end

  defp sample_gamma(shape) when shape < 1 do
    e = :math.exp(1)
    b = (shape + e) / e
    gamma_rejection_sample(shape, b)
  end

  defp sample_gamma(shape) do
    d = shape - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)
    gamma_marsaglia_sample(d, c)
  end

  defp gamma_rejection_sample(shape, b) do
    u = :rand.uniform()
    p = b * u

    if p <= 1 do
      x = :math.pow(p, 1 / shape)
      u2 = :rand.uniform()

      if u2 <= :math.exp(-x) do
        x
      else
        gamma_rejection_sample(shape, b)
      end
    else
      x = -:math.log((b - p) / shape)
      u2 = :rand.uniform()

      if u2 <= :math.pow(x, shape - 1) do
        x
      else
        gamma_rejection_sample(shape, b)
      end
    end
  end

  defp gamma_marsaglia_sample(d, c) do
    v = normal_sample()
    v_cubed = v * v * v
    v1 = 1 + c * v

    if v1 > 0 do
      u = :rand.uniform()
      v_squared = v * v

      if u < 1 - 0.0331 * v_squared * v_squared do
        _ = v_cubed
        d * v1 * v1 * v1
      else
        if :math.log(u) < 0.5 * v_squared + d * (1 - v1 + :math.log(v1)) do
          d * v1 * v1 * v1
        else
          gamma_marsaglia_sample(d, c)
        end
      end
    else
      gamma_marsaglia_sample(d, c)
    end
  end

  defp normal_sample do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2 * :math.log(u1)) * :math.cos(2 * :math.pi() * u2)
  end

  defp mean(values) do
    Enum.sum(values) / length(values)
  end

  defp variance(values, mean) do
    n = length(values)

    sum_squared_diffs =
      values
      |> Enum.map(fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()

    sum_squared_diffs / (n - 1)
  end

  defp decimal_sqrt(decimal) do
    float_val = D.to_float(decimal)
    sqrt_val = :math.sqrt(float_val)
    D.from_float(sqrt_val)
  end
end
