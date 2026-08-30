defmodule PtcRunner.Kernel.TerminalResultLimit do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @spec within_limit?(term(), pos_integer()) :: boolean()
  def within_limit?(value, limit) when is_integer(limit) and limit > 0 do
    case {RetainedSize.bytes_with_cap(value, limit), encoded_size(value)} do
      {bytes, encoded} when is_integer(bytes) and bytes <= limit and encoded <= limit -> true
      _other -> false
    end
  end

  defp encoded_size(value) do
    :erlang.external_size(value)
  rescue
    _exception -> :infinity
  end
end
