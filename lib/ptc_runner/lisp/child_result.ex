defmodule PtcRunner.Lisp.ChildResult do
  @moduledoc false

  @key :ptc_lisp_child_result

  def put(trace_id, result) do
    Process.put(@key, {trace_id, result})
    :ok
  end

  def take, do: Process.delete(@key)
end
