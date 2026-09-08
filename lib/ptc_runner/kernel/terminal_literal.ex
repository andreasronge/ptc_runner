defmodule PtcRunner.Kernel.TerminalLiteral do
  @moduledoc false

  @spec render(binary(), Regex.t()) :: binary()
  def render(text, pattern) when is_binary(text) do
    if text =~ pattern,
      do: text,
      else: inspect(text, binaries: :as_strings, limit: :infinity, printable_limit: :infinity)
  end
end
