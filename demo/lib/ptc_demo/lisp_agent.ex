defmodule PtcDemo.LispAgent do
  @moduledoc """
  Alias for `PtcDemo.Agent` for backward compatibility.

  The demo now uses a unified agent implementation based on `PtcRunner.SubAgent`.
  Both JSON and Lisp demos use the same agent, which generates PTC-Lisp programs.
  """

  defdelegate start_link(opts \\ []), to: PtcDemo.Agent
  defdelegate ask(question), to: PtcDemo.Agent
  defdelegate ask(question, opts), to: PtcDemo.Agent
  defdelegate reset(), to: PtcDemo.Agent
  defdelegate last_program(), to: PtcDemo.Agent
  defdelegate last_result(), to: PtcDemo.Agent
  defdelegate programs(), to: PtcDemo.Agent
  defdelegate list_datasets(), to: PtcDemo.Agent
  defdelegate model(), to: PtcDemo.Agent
  defdelegate stats(), to: PtcDemo.Agent
  defdelegate data_mode(), to: PtcDemo.Agent
  defdelegate system_prompt(), to: PtcDemo.Agent
  defdelegate set_data_mode(mode), to: PtcDemo.Agent
  defdelegate set_prompt_profile(profile), to: PtcDemo.Agent
  defdelegate prompt_profile(), to: PtcDemo.Agent
  defdelegate set_model(model), to: PtcDemo.Agent
  defdelegate preset_models(), to: PtcDemo.Agent
  defdelegate detect_model(), to: PtcDemo.Agent
  defdelegate compression(), to: PtcDemo.Agent
  defdelegate set_compression(compression), to: PtcDemo.Agent
end
