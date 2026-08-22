defmodule PtcRunner.Mix.PtcLlmHttpDepTest do
  use ExUnit.Case, async: true

  test "pins exact optional ptc_llm_http 0.1.0" do
    dependency =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> List.keyfind(:ptc_llm_http, 0)

    assert {:ptc_llm_http, "== 0.1.0", options} = dependency
    assert options[:optional]
    refute options[:runtime]
    refute Keyword.has_key?(options, :only)
  end

  test "does not start the optional ptc_llm_http application" do
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :ptc_llm_http))
  end

  test "keeps ReqLLM as the shipped default adapter" do
    assert PtcRunner.MixProject.application()[:env][:llm_adapter] ==
             PtcRunner.LLM.ReqLLMAdapter
  end
end
