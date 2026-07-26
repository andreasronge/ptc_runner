defmodule PtcRunner.Kernel.AnalysisTerminal do
  @moduledoc false

  @doc false
  @spec attached?() :: boolean()
  def attached? do
    tty?(:stdin) and tty?(:stdout)
  end

  defp tty?(device) do
    :prim_tty.isatty(device) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end
end
