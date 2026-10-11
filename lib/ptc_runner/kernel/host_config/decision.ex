defmodule PtcRunner.Kernel.HostConfig.Decision do
  @moduledoc false

  alias PtcRunner.Kernel.HostConfig.Replay

  alias PtcRunner.Kernel.LLMUsage

  import PtcRunner.Kernel.HostConfig.Common

  def decision_installation(%{"backend" => "chat"} = value, _credentials, limits) do
    with :ok <-
           exact_keys(
             value,
             ~w(source backend llm installation_revision ceilings data_class accepts_data max_cost_per_call max_total_tokens_per_call),
             ~w(source backend llm installation_revision max_cost_per_call max_total_tokens_per_call)
           ),
         true <- valid_name?(value["llm"]),
         {:ok, bounds} <- decision_bounds(value),
         {:ok, revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_ceilings(Map.get(value, "ceilings", %{}), limits),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <- accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       Map.merge(bounds, %{
         source: :decision,
         backend: :chat,
         llm: value["llm"],
         installation_revision: revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       })}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  def decision_installation(%{"backend" => "http"} = value, credentials, limits) do
    with :ok <-
           exact_keys(
             value,
             ~w(source backend endpoint model credential allow_insecure_loopback usage_guarantees installation_revision ceilings data_class accepts_data max_cost_per_call max_total_tokens_per_call),
             ~w(source backend endpoint model usage_guarantees installation_revision max_cost_per_call max_total_tokens_per_call)
           ),
         true <- valid_string?(value["model"], 256),
         true <-
           not Map.has_key?(value, "credential") or Map.has_key?(credentials, value["credential"]),
         :ok <- endpoint_rejection(value),
         {:ok, guarantees} <- usage_guarantees(value["usage_guarantees"]),
         :ok <- usage_guarantee_requirements(guarantees, limits),
         {:ok, bounds} <- decision_bounds(value),
         {:ok, revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_ceilings(Map.get(value, "ceilings", %{}), limits),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <- accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       Map.merge(bounds, %{
         source: :decision,
         backend: :http,
         endpoint: value["endpoint"],
         model: value["model"],
         credential: value["credential"],
         usage_guarantees: guarantees,
         reservation_tariff: nil,
         allow_insecure_loopback: Map.get(value, "allow_insecure_loopback", false),
         installation_revision: revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       })}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  def decision_installation(value, credentials, limits) do
    allowed =
      ~w(source model credential routing usage_guarantees reservation_tariff installation_revision ceilings data_class accepts_data max_cost_per_call max_total_tokens_per_call)

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(source model credential usage_guarantees installation_revision max_cost_per_call max_total_tokens_per_call)
           ),
         model when is_binary(model) <- value["model"],
         true <- valid_string?(model, 256),
         credential when is_binary(credential) <- value["credential"],
         true <- Map.has_key?(credentials, credential),
         {:ok, routing} <- decision_routing(Map.get(value, "routing", %{})),
         {:ok, guarantees} <- usage_guarantees(value["usage_guarantees"]),
         :ok <- usage_guarantee_requirements(guarantees, limits),
         {:ok, tariff} <- reservation_tariff(value["reservation_tariff"]),
         {:ok, bounds} <- decision_bounds(value),
         {:ok, revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_ceilings(Map.get(value, "ceilings", %{}), limits),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <- accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       Map.merge(bounds, %{
         source: :decision,
         model: model,
         credential: credential,
         routing: routing,
         usage_guarantees: guarantees,
         reservation_tariff: tariff,
         installation_revision: revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       })}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  def decision_replay_installation(value, limits) do
    with {:ok, bounds} <- decision_bounds(value),
         {:ok, guarantees} <-
           usage_guarantees(
             Map.get(value, "usage_guarantees", %{"tokens" => true, "cost_currency" => "USD"})
           ),
         :ok <- usage_guarantee_requirements(guarantees, limits),
         {:ok, replay} <-
           value
           |> Map.drop(~w(max_cost_per_call max_total_tokens_per_call usage_guarantees))
           |> Map.put("source", "llm_replay")
           |> Replay.llm_replay_installation() do
      {:ok,
       Map.merge(replay, bounds)
       |> Map.put(:source, :decision_replay)
       |> Map.put(:usage_guarantees, guarantees)}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  defp decision_bounds(%{
         "max_cost_per_call" => %{"currency" => "USD", "amount" => amount} = cost,
         "max_total_tokens_per_call" => tokens
       })
       when map_size(cost) == 2 and is_binary(amount) and is_integer(tokens) and tokens > 0 do
    with true <- tokens <= LLMUsage.maximum_integer(),
         true <- Regex.match?(~r/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/, amount),
         {:ok, microunits} when microunits >= 0 <-
           LLMUsage.ceil_scaled_decimal(amount, 1_000_000, 1) do
      {:ok, %{max_cost_microusd_per_call: microunits, max_total_tokens_per_call: tokens}}
    else
      _ -> {:error, :invalid_decision_bounds}
    end
  end

  defp decision_bounds(_), do: {:error, :invalid_decision_bounds}

  defp decision_routing(value) when is_map(value) do
    if Map.keys(value) -- ~w(zdr data_collection allow_fallbacks) == [] and
         Enum.all?(value, fn
           {"data_collection", v} -> v in ["allow", "deny"]
           {_, v} -> is_boolean(v)
         end), do: {:ok, value}, else: {:error, :invalid_routing}
  end

  defp decision_routing(_), do: {:error, :invalid_routing}
end
