defmodule PtcRunner.Kernel.PublicRunAnalysisProfile do
  @moduledoc "Fixed public authority recipe for bounded run-evidence navigation."

  use PtcRunner.Kernel.RunAnalysisProfile, kind: :public

  @id "run-analysis-v1"

  def id, do: @id
  def invalid_profile_error, do: :invalid_run_analysis_profile
  def invalid_assembly_error, do: :invalid_run_analysis_assembly
  def invalid_source_error, do: :invalid_run_analysis_source
  def session_failed_error, do: :run_analysis_session_failed
  def session_closed_error, do: :run_analysis_session_closed
  def run_id_prefix, do: "run-analysis-"
  def result_limit_message, do: "public evaluation result exceeded its byte limit"
end
