defmodule PtcRunner.QuickstartGuideTest do
  use ExUnit.Case, async: false

  alias PtcRunner.TestSupport.GuideExamples
  alias PtcRunner.TestSupport.LLMSupport

  require GuideExamples

  setup context do
    :ok = load_environment()

    case context[:requires_env] do
      nil -> :ok
      variable -> require_environment(variable)
    end
  end

  GuideExamples.test_examples("docs/guides/quickstart.md")

  defp load_environment do
    case System.get_env("PTC_ENV_FILE") do
      nil -> LLMSupport.load_dotenv()
      path -> PtcRunner.Dotenv.load_file(path)
    end
  end

  defp require_environment(variable) do
    if System.get_env(variable) do
      :ok
    else
      {:skip, "#{variable} is not configured"}
    end
  end
end
