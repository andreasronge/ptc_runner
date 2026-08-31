defmodule PtcRunner.Kernel.PrivateRunAnalysisProfile do
  @moduledoc """
  Fixed private authority recipe for correlated run-evidence navigation.

  Its source class is sealed as `private_inspection`; private inspection
  presence never dynamically changes a public recipe's classification.
  """

  use PtcRunner.Kernel.RunAnalysisProfile, kind: :private

  @id "private-run-analysis-v2"

  def id, do: @id
  def invalid_profile_error, do: :invalid_private_run_analysis_profile
  def invalid_assembly_error, do: :invalid_private_run_analysis_assembly
  def invalid_source_error, do: :invalid_private_run_analysis_source
  def session_failed_error, do: :private_run_analysis_session_failed
  def session_closed_error, do: :private_run_analysis_session_closed
  def run_id_prefix, do: "private-run-analysis-"
  def result_limit_message, do: "private terminal evaluation result exceeded its byte limit"
end
