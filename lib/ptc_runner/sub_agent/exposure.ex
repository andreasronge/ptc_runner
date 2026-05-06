defmodule PtcRunner.SubAgent.Exposure do
  @moduledoc """
  Pure helpers for tool exposure resolution and filtering.

  Tier 1a of the text-mode + PTC compute-tool plan
  (`Plans/text-mode-ptc-compute-tool.md`).

  Each tool may declare `expose: :native | :ptc_lisp | :both`. When the
  field is missing/`nil`, the resolved value depends on the agent's mode
  per the plan's "Tool Exposure Policy" table:

  | `output:` | `ptc_transport:`           | default `expose:` |
  |-----------|----------------------------|-------------------|
  | `:text`   | not `:tool_call` (or nil)  | `:native`         |
  | `:text`   | `:tool_call` (combined)    | `:native`         |
  | `:ptc_lisp` | any                      | `:ptc_lisp`       |

  This module is intentionally side-effect-free: validation lives in
  `PtcRunner.SubAgent.Validator`; runtime wiring (LLM request build,
  Lisp analyzer inventory) is wired in Tier 2/3.
  """

  alias PtcRunner.Tool

  @typedoc """
  Mode descriptor accepted by `effective_expose/2` and `filter_by_expose/3`.

  Either:

  - `{output, ptc_transport}` tuple — `output` is `:text | :ptc_lisp`,
    `ptc_transport` is `:content | :tool_call | nil`.
  - A `PtcRunner.SubAgent.Definition.t()` struct (the `:output` and
    `:ptc_transport` fields are read).
  """
  @type mode :: {atom(), atom() | nil} | struct()

  @doc """
  Resolve a tool's effective `expose:` value for the given agent mode.

  If the tool has an explicit `expose:`, returns it unchanged. Otherwise
  applies the per-mode default per "Tool Exposure Policy."

  ## Examples

      iex> tool = %PtcRunner.Tool{name: "x", expose: nil}
      iex> PtcRunner.SubAgent.Exposure.effective_expose(tool, {:text, nil})
      :native

      iex> tool = %PtcRunner.Tool{name: "x", expose: nil}
      iex> PtcRunner.SubAgent.Exposure.effective_expose(tool, {:text, :tool_call})
      :native

      iex> tool = %PtcRunner.Tool{name: "x", expose: nil}
      iex> PtcRunner.SubAgent.Exposure.effective_expose(tool, {:ptc_lisp, :content})
      :ptc_lisp

      iex> tool = %PtcRunner.Tool{name: "x", expose: :both}
      iex> PtcRunner.SubAgent.Exposure.effective_expose(tool, {:text, nil})
      :both
  """
  @spec effective_expose(Tool.t(), mode()) :: Tool.expose_layer()
  def effective_expose(%Tool{expose: expose}, _mode)
      when expose in [:native, :ptc_lisp, :both],
      do: expose

  def effective_expose(%Tool{expose: nil}, mode), do: default_for_mode(mode)

  @doc """
  Filter a tool collection to those whose effective `expose:` is in
  `allowed_set`.

  - `tools` — list of `PtcRunner.Tool` structs OR a map of
    `name => PtcRunner.Tool`. The output preserves the input shape's
    iteration order (lists keep order; maps are converted to a list of
    tools sorted by tool name, since map iteration order in Elixir is
    not guaranteed).
  - `allowed_set` — list/MapSet of `:native | :ptc_lisp | :both`.

  Returns a list of `PtcRunner.Tool` structs.

  ## Examples

      iex> a = %PtcRunner.Tool{name: "a", expose: :native}
      iex> b = %PtcRunner.Tool{name: "b", expose: :both}
      iex> c = %PtcRunner.Tool{name: "c", expose: :ptc_lisp}
      iex> result = PtcRunner.SubAgent.Exposure.filter_by_expose(
      ...>   [a, b, c], {:text, :tool_call}, [:native, :both]
      ...> )
      iex> Enum.map(result, & &1.name)
      ["a", "b"]
  """
  @spec filter_by_expose([Tool.t()] | %{optional(String.t()) => Tool.t()}, mode(), [
          Tool.expose_layer()
        ]) :: [Tool.t()]
  def filter_by_expose(tools, mode, allowed_set) when is_map(tools) do
    tools
    |> Enum.sort_by(fn {name, _tool} -> name end)
    |> Enum.map(fn {_name, tool} -> tool end)
    |> filter_by_expose(mode, allowed_set)
  end

  def filter_by_expose(tools, mode, allowed_set) when is_list(tools) do
    allowed = MapSet.new(allowed_set)

    Enum.filter(tools, fn %Tool{} = tool ->
      MapSet.member?(allowed, effective_expose(tool, mode))
    end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp default_for_mode({:ptc_lisp, _ptc_transport}), do: :ptc_lisp
  defp default_for_mode({:text, _ptc_transport}), do: :native

  defp default_for_mode(%_{output: output, ptc_transport: ptc_transport}),
    do: default_for_mode({output, ptc_transport})
end
