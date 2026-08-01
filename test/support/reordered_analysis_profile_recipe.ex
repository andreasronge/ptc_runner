defmodule PtcRunner.TestSupport.ReorderedAnalysisProfileRecipe do
  @moduledoc false

  def id, do: "reordered-analysis-test-v1"
  def component_ids, do: ["consumer", "base"]
  def namespaces, do: ["consumer", "base"]
  def explicit_capabilities, do: []
  def persistence_policy, do: "none"
  def result_policy, do: "test"
  def identity_extension, do: %{}
  def invalid_profile_error, do: :invalid_reordered_analysis_profile
end
