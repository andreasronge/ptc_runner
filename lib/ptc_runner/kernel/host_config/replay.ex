defmodule PtcRunner.Kernel.HostConfig.Replay do
  @moduledoc false

  @max_result_bytes 1_048_576
  @max_replay_entries 10_000

  import PtcRunner.Kernel.HostConfig.Common

  def llm_replay_installation(value) do
    allowed = ~w(source fixtures installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(value, allowed, ~w(source fixtures installation_revision)),
         fixtures when is_binary(fixtures) <- value["fixtures"],
         true <- valid_path_string?(fixtures),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_replay_ceilings(Map.get(value, "ceilings", %{})),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <- accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :llm_replay,
         fixtures: fixtures,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp llm_replay_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_entries max_result_bytes max_calls), []),
         max_entries when is_integer(max_entries) and max_entries > 0 <-
           Map.get(value, "max_entries", @max_replay_entries),
         true <- max_entries <= @max_replay_entries,
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes,
         {:ok, max_calls} <- optional_max_calls(value) do
      {:ok, %{max_entries: max_entries, max_result_bytes: max_result_bytes, max_calls: max_calls}}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp llm_replay_ceilings(_value), do: {:error, :invalid_ceilings}
end
