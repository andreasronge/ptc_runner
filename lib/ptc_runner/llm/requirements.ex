defmodule PtcRunner.LLM.Requirements do
  @moduledoc """
  Closed, bounded model-contract requirements sealed into a prepared target.

  Kernel constructs this map after manifest selection and before credentials.
  `PtcRunner.LLM.prepare/2` validates both the requested map and the adapter
  attestation, then requires exact canonical equality.
  """

  @max_tariff_id_bytes 128
  @max_tokens 1_000_000
  @max_seed 2_147_483_647
  @option_keys [
    :max_tokens,
    :temperature,
    :seed,
    :top_p,
    :presence_penalty,
    :frequency_penalty,
    :reasoning_effort
  ]
  @requirement_keys [:exact_options, :structured_output_mode, :usage_guarantees, :reservation]
  @usage_keys [:tokens, :cost_currency]
  @reservation_keys [:total_tokens?, :cost_tariff]
  @structured_modes [:json_schema, :json_object, :unsupported]

  @type exact_options :: %{
          required(:max_tokens) => pos_integer(),
          optional(:temperature) => float(),
          optional(:seed) => non_neg_integer(),
          optional(:top_p) => float(),
          optional(:presence_penalty) => float(),
          optional(:frequency_penalty) => float(),
          optional(:reasoning_effort) => :none | :minimal | :low | :medium | :high
        }

  @type usage_guarantees :: %{
          tokens: boolean(),
          cost_currency: String.t() | nil
        }

  @type cost_tariff :: %{currency: String.t(), id: binary()}

  @type reservation :: %{
          total_tokens?: boolean(),
          cost_tariff: cost_tariff() | nil
        }

  @type t :: %{
          exact_options: exact_options(),
          structured_output_mode: :json_schema | :json_object | :unsupported,
          usage_guarantees: usage_guarantees(),
          reservation: reservation()
        }

  @doc """
  Returns the current contract around authorized `exact_options`.

  Structured-output mode and the complete portable inference-control set are
  active. Usage guarantees and reservation remain explicitly disabled until
  their later protocol slices.
  """
  @spec interim(exact_options()) :: t()
  def interim(exact_options) when is_map(exact_options), do: interim(exact_options, :unsupported)

  @spec interim(exact_options(), :json_schema | :json_object | :unsupported) :: t()
  def interim(exact_options, mode)
      when is_map(exact_options) and mode in @structured_modes do
    %{
      exact_options: exact_options,
      structured_output_mode: mode,
      usage_guarantees: %{tokens: false, cost_currency: nil},
      reservation: %{total_tokens?: false, cost_tariff: nil}
    }
  end

  @spec live(map(), pos_integer()) :: {:ok, t()} | :error
  @spec live(map(), pos_integer(), :json_schema | :json_object | :unsupported) ::
          {:ok, t()} | :error
  def live(params, output_tokens, structured_output_mode \\ :unsupported)

  def live(params, output_tokens, structured_output_mode)
      when is_map(params) and is_integer(output_tokens) and output_tokens in 1..@max_tokens and
             structured_output_mode in @structured_modes do
    max_tokens =
      case Map.get(params, :max_tokens) do
        nil -> output_tokens
        installed when is_integer(installed) -> min(output_tokens, installed)
      end

    canonical(interim(authorized_options(params, max_tokens), structured_output_mode))
  end

  def live(_params, _output_tokens, _structured_output_mode), do: :error

  @spec probe(map()) :: {:ok, t()} | :error
  def probe(params) when is_map(params), do: canonical(interim(authorized_options(params, 1)))
  def probe(_params), do: :error

  @spec canonical(term()) :: {:ok, t()} | :error
  def canonical(requirements) when is_map(requirements) and not is_struct(requirements) do
    with :ok <- exact_keys(requirements, @requirement_keys),
         {:ok, exact_options} <- canonical_exact_options(requirements.exact_options),
         mode when mode in @structured_modes <- requirements.structured_output_mode,
         {:ok, usage_guarantees} <- canonical_usage(requirements.usage_guarantees),
         {:ok, reservation} <- canonical_reservation(requirements.reservation) do
      {:ok,
       %{
         exact_options: exact_options,
         structured_output_mode: mode,
         usage_guarantees: usage_guarantees,
         reservation: reservation
       }}
    else
      _invalid -> :error
    end
  end

  def canonical(_requirements), do: :error

  @spec equal?(t(), t()) :: boolean()
  def equal?(left, right), do: left == right

  defp authorized_options(params, max_tokens) do
    params
    |> Map.take(@option_keys -- [:max_tokens])
    |> Map.put(:max_tokens, max_tokens)
  end

  defp canonical_exact_options(options) when is_map(options) and not is_struct(options) do
    with true <- Map.has_key?(options, :max_tokens),
         :ok <- subset_keys(options, @option_keys),
         {:ok, max_tokens} <- canonical_max_tokens(options.max_tokens),
         {:ok, exact} <- put_optional_temperature(%{max_tokens: max_tokens}, options),
         {:ok, exact} <- put_optional_seed(exact, options),
         {:ok, exact} <- put_optional_number(exact, options, :top_p, 0, 1, false),
         {:ok, exact} <- put_optional_number(exact, options, :presence_penalty, -2, 2, true),
         {:ok, exact} <- put_optional_number(exact, options, :frequency_penalty, -2, 2, true),
         {:ok, exact} <- put_optional_reasoning_effort(exact, options) do
      {:ok, exact}
    else
      _invalid -> :error
    end
  end

  defp canonical_exact_options(_options), do: :error

  defp canonical_max_tokens(value) when is_integer(value) and value in 1..@max_tokens,
    do: {:ok, value}

  defp canonical_max_tokens(_value), do: :error

  defp put_optional_temperature(exact, options) do
    case Map.fetch(options, :temperature) do
      :error ->
        {:ok, exact}

      {:ok, temperature} when is_number(temperature) and temperature >= 0 and temperature <= 2 ->
        {:ok, Map.put(exact, :temperature, temperature * 1.0)}

      {:ok, _invalid} ->
        :error
    end
  end

  defp put_optional_seed(exact, options) do
    case Map.fetch(options, :seed) do
      :error ->
        {:ok, exact}

      {:ok, seed} when is_integer(seed) and seed >= 0 and seed <= @max_seed ->
        {:ok, Map.put(exact, :seed, seed)}

      {:ok, _invalid} ->
        :error
    end
  end

  defp put_optional_number(exact, options, key, minimum, maximum, include_minimum?) do
    case Map.fetch(options, key) do
      :error ->
        {:ok, exact}

      {:ok, value}
      when is_number(value) and value <= maximum and
             (value > minimum or (include_minimum? and value == minimum)) ->
        {:ok, Map.put(exact, key, value * 1.0)}

      {:ok, _invalid} ->
        :error
    end
  end

  defp put_optional_reasoning_effort(exact, options) do
    case Map.fetch(options, :reasoning_effort) do
      :error ->
        {:ok, exact}

      {:ok, effort} when effort in [:none, :minimal, :low, :medium, :high] ->
        {:ok, Map.put(exact, :reasoning_effort, effort)}

      {:ok, _invalid} ->
        :error
    end
  end

  defp canonical_usage(usage) when is_map(usage) and not is_struct(usage) do
    with :ok <- exact_keys(usage, @usage_keys),
         tokens when is_boolean(tokens) <- usage.tokens,
         currency when currency in ["USD", nil] <- usage.cost_currency do
      {:ok, %{tokens: tokens, cost_currency: currency}}
    else
      _invalid -> :error
    end
  end

  defp canonical_usage(_usage), do: :error

  defp canonical_reservation(reservation)
       when is_map(reservation) and not is_struct(reservation) do
    with :ok <- exact_keys(reservation, @reservation_keys),
         total_tokens? when is_boolean(total_tokens?) <- reservation.total_tokens?,
         {:ok, tariff} <- canonical_tariff(reservation.cost_tariff) do
      {:ok, %{total_tokens?: total_tokens?, cost_tariff: tariff}}
    else
      _invalid -> :error
    end
  end

  defp canonical_reservation(_reservation), do: :error

  defp canonical_tariff(nil), do: {:ok, nil}

  defp canonical_tariff(%{currency: "USD", id: id} = tariff)
       when is_binary(id) and byte_size(id) in 1..@max_tariff_id_bytes and map_size(tariff) == 2 do
    if String.valid?(id), do: {:ok, %{currency: "USD", id: id}}, else: :error
  end

  defp canonical_tariff(_tariff), do: :error

  defp exact_keys(map, keys) do
    if Map.keys(map) -- keys == [] and keys -- Map.keys(map) == [], do: :ok, else: :error
  end

  defp subset_keys(map, keys) do
    if Map.keys(map) -- keys == [], do: :ok, else: :error
  end
end
