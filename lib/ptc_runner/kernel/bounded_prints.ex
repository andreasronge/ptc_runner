defmodule PtcRunner.Kernel.BoundedPrints do
  @moduledoc """
  Shared bound for projecting a raw `println` list into a caller-facing form.

  One rule for "how many prints, and how many bytes" is used everywhere a
  `PtcRunner.Lisp.Result.t()`'s `prints` list crosses into a bounded owner-facing
  projection: `PtcRunner.Kernel.AnalysisSession` result projection and
  `PtcRunner.Kernel.Runner` execution-phase inspection capture. A non-binary or
  invalid-UTF-8 entry is retained as an empty string rather than dropped, so
  bounded position and count stay aligned with the source list.
  """

  @spec bound([term()], pos_integer(), pos_integer()) :: {[String.t()], boolean()}
  @doc "Bounds `prints` to at most `max_count` entries and `max_bytes` JSON-encoded bytes."
  def bound(prints, max_count, max_bytes)
      when is_list(prints) and is_integer(max_count) and max_count > 0 and
             is_integer(max_bytes) and max_bytes > 0 do
    {bounded, _count, _encoded_bytes, truncated?} =
      Enum.reduce_while(prints, {[], 0, 2, false}, fn print,
                                                      {acc, count, encoded_bytes, _truncated?} ->
        print = if is_binary(print) and String.valid?(print), do: print, else: ""
        {:ok, encoded_print} = Jason.encode(print)
        separator_bytes = if count == 0, do: 0, else: 1
        next_bytes = encoded_bytes + separator_bytes + byte_size(encoded_print)

        if count < max_count and next_bytes <= max_bytes do
          {:cont, {[print | acc], count + 1, next_bytes, false}}
        else
          {:halt, {acc, count, encoded_bytes, true}}
        end
      end)

    {Enum.reverse(bounded), truncated?}
  end

  def bound(_prints, max_count, max_bytes)
      when is_integer(max_count) and max_count > 0 and is_integer(max_bytes) and max_bytes > 0,
      do: {[], true}
end
