defmodule PtcRunner.Kernel.HostConfig.LLM do
  @moduledoc false

  alias PtcRunner.Kernel.Limits

  @max_llm_tokens 1_000_000
  @max_llm_seed 2_147_483_647

  import PtcRunner.Kernel.HostConfig.Common

  def llm_installation(value, credentials, limits) do
    allowed =
      ~w(source model credential cache params structured_output_mode usage_guarantees reservation_tariff installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(source model structured_output_mode usage_guarantees installation_revision)
           ),
         model when is_binary(model) <- value["model"],
         true <- valid_string?(model, 256),
         {:ok, credential} <- llm_credential(value, model, credentials),
         cache when is_boolean(cache) <- Map.get(value, "cache", false),
         {:ok, params} <- llm_params(Map.get(value, "params", %{})),
         {:ok, structured_output_mode} <-
           structured_output_mode(value["structured_output_mode"]),
         {:ok, usage_guarantees} <- usage_guarantees(value["usage_guarantees"]),
         :ok <- usage_guarantee_requirements(usage_guarantees, limits),
         {:ok, reservation_tariff} <- reservation_tariff(Map.get(value, "reservation_tariff")),
         :ok <- reservation_tariff_requirement(reservation_tariff, limits),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_ceilings(Map.get(value, "ceilings", %{}), limits),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <-
           accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :llm,
         model: model,
         credential: credential,
         cache: cache,
         params: params,
         structured_output_mode: structured_output_mode,
         usage_guarantees: usage_guarantees,
         reservation_tariff: reservation_tariff,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      {:error, {:optional_budget_prerequisite, _limit, _prerequisite}} = error -> error
      _reason -> {:error, :invalid_installation}
    end
  end

  defp llm_credential(value, model, credentials) do
    case Map.fetch(value, "credential") do
      :error ->
        if String.starts_with?(model, "openai-compat:"),
          do: {:ok, nil},
          else: {:error, :invalid_installation}

      {:ok, name} when is_binary(name) ->
        if Map.has_key?(credentials, name),
          do: {:ok, name},
          else: {:error, :invalid_installation}

      _ ->
        {:error, :invalid_installation}
    end
  end

  defp llm_params(value) when is_map(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(temperature seed max_tokens top_p presence_penalty frequency_penalty reasoning_effort),
             []
           ),
         temperature when is_number(temperature) and temperature >= 0 and temperature <= 2 <-
           Map.get(value, "temperature", 0.0),
         seed when is_integer(seed) and seed in 0..@max_llm_seed <-
           Map.get(value, "seed", 0),
         max_tokens when is_integer(max_tokens) and max_tokens in 1..@max_llm_tokens <-
           Map.get(value, "max_tokens", 1),
         top_p when is_number(top_p) and top_p > 0 and top_p <= 1 <-
           Map.get(value, "top_p", 1.0),
         presence_penalty
         when is_number(presence_penalty) and presence_penalty >= -2 and presence_penalty <= 2 <-
           Map.get(value, "presence_penalty", 0.0),
         frequency_penalty
         when is_number(frequency_penalty) and frequency_penalty >= -2 and frequency_penalty <= 2 <-
           Map.get(value, "frequency_penalty", 0.0),
         {:ok, reasoning_effort} <-
           llm_reasoning_effort(Map.get(value, "reasoning_effort", :omitted)) do
      params =
        %{}
        |> maybe_put_param(:temperature, value, "temperature", temperature * 1.0)
        |> maybe_put_param(:seed, value, "seed", seed)
        |> maybe_put_param(:max_tokens, value, "max_tokens", max_tokens)
        |> maybe_put_param(:top_p, value, "top_p", top_p * 1.0)
        |> maybe_put_param(
          :presence_penalty,
          value,
          "presence_penalty",
          presence_penalty * 1.0
        )
        |> maybe_put_param(
          :frequency_penalty,
          value,
          "frequency_penalty",
          frequency_penalty * 1.0
        )
        |> maybe_put_param(:reasoning_effort, value, "reasoning_effort", reasoning_effort)

      {:ok, params}
    else
      _reason -> {:error, :invalid_llm_params}
    end
  end

  defp llm_params(_value), do: {:error, :invalid_llm_params}

  defp llm_reasoning_effort(:omitted), do: {:ok, nil}
  defp llm_reasoning_effort("none"), do: {:ok, :none}
  defp llm_reasoning_effort("minimal"), do: {:ok, :minimal}
  defp llm_reasoning_effort("low"), do: {:ok, :low}
  defp llm_reasoning_effort("medium"), do: {:ok, :medium}
  defp llm_reasoning_effort("high"), do: {:ok, :high}
  defp llm_reasoning_effort(_value), do: {:error, :invalid_reasoning_effort}

  defp structured_output_mode("json_schema"), do: {:ok, :json_schema}
  defp structured_output_mode("json_object"), do: {:ok, :json_object}
  defp structured_output_mode("unsupported"), do: {:ok, :unsupported}
  defp structured_output_mode(_value), do: {:error, :invalid_structured_output_mode}

  defp reservation_tariff_requirement(tariff, %Limits{} = limits),
    do:
      optional_budget_requirement(
        limits.llm_cost_microusd,
        is_map(tariff),
        :llm_cost_microusd,
        :reservation_tariff
      )

  defp maybe_put_param(params, atom_key, value, string_key, normalized) do
    if Map.has_key?(value, string_key), do: Map.put(params, atom_key, normalized), else: params
  end
end
