defmodule PtcRunner.QuickstartGuideTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias PtcRunner.TestSupport.GuideExamples
  alias PtcRunner.TestSupport.LLMSupport

  require GuideExamples

  setup context do
    case context[:requires_env] do
      nil ->
        :ok

      variable ->
        previous_environment = System.get_env()
        on_exit(fn -> restore_environment(previous_environment) end)
        :ok = load_environment()
        require_environment(variable)
    end
  end

  GuideExamples.test_registered_examples("test/support/executable_guides.txt")

  defp load_environment do
    case System.get_env("PTC_ENV_FILE") do
      nil -> LLMSupport.load_dotenv()
      path -> PtcRunner.Dotenv.load_file(path)
    end
  end

  defp require_environment(variable) do
    if System.get_env(variable) in [nil, ""] do
      {:skip, "#{variable} is not configured"}
    else
      :ok
    end
  end

  defp restore_environment(previous) do
    current_names = System.get_env() |> Map.keys() |> MapSet.new()
    previous_names = previous |> Map.keys() |> MapSet.new()

    current_names
    |> MapSet.difference(previous_names)
    |> Enum.each(&System.delete_env/1)

    Enum.each(previous, fn {name, value} -> System.put_env(name, value) end)
  end
end
