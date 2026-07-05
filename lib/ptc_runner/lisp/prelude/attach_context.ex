defmodule PtcRunner.Lisp.Prelude.AttachContext do
  @moduledoc """
  The capability context a prelude's `requires` are validated against at attach
  time (plan P3).

  V1 attach validation saw only the upstream runtime. The introspection prelude
  (and any future host-bound capability) declares `tool:<name>` requirements
  that are satisfied by the run's granted `tools:` map, not the upstream
  runtime — so attach needs both. This struct bundles them (with room for
  future grant kinds) so the grant surface grows as a single context value
  rather than a widening positional argument list.

  Fields:

    * `:runtime` — the selected upstream runtime handle (a
      `%PtcRunner.Upstream.Runtime{}`, a pid, a registered name), or `nil` when
      no upstream runtime is configured. Validates `upstream:<server>/<tool>`
      requirements.
    * `:tools` — the granted `tools:` map (`%{name => closure | Tool}`) whose
      keys name the typed-tool capabilities the host has granted. Validates
      `tool:<name>` requirements.
    * `:upstream_tools` — `:all` or a set of canonical
      `"upstream:<server>/<tool>"` ids granted for upstream `(tool/call ...)`
      dispatch. Validates `upstream:<server>/<tool>` requirements independent
      of runtime catalog materialization.

  Tool names are **strings**, matching `PtcRunner.Lisp.run/2`'s execution
  contract (a `(tool/foo ...)` call resolves the tool by the string `"foo"`).
  `tool:<name>` grant checks compare against string keys, so atom-keyed tools
  are treated as ungranted — consistent with execution, where they would also be
  unresolved. This is intentionally not papered over here: stringifying keys at
  attach while execution stays string-keyed would let attach pass and the call
  then fail at runtime.
  """

  alias PtcRunner.Lisp.Prelude.Attach

  @type t :: %__MODULE__{
          runtime: Attach.runtime(),
          tools: %{optional(String.t()) => term()},
          upstream_tools: :all | MapSet.t(String.t())
        }

  defstruct runtime: nil, tools: %{}, upstream_tools: :all

  @doc """
  Builds an attach context from options.

  ## Options

    * `:runtime` - upstream runtime handle (default: `nil`)
    * `:tools` - granted tools, in any shape `PtcRunner.Lisp.run/2` accepts (a
      `%{name => tool}` map OR a `[{name, tool}, ...]` tuple/keyword list);
      canonicalized to a map so grant checks are shape-agnostic (default: `%{}`)
    * `:upstream_tools` - `:all` or granted canonical upstream operation ids
      (default: `:all`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      runtime: Keyword.get(opts, :runtime),
      tools: Map.new(Keyword.get(opts, :tools, %{})),
      upstream_tools: normalize_upstream_tools(Keyword.get(opts, :upstream_tools, :all))
    }
  end

  @doc "True when the granted tools map contains a typed tool named `name`."
  @spec grants_tool?(t(), String.t()) :: boolean()
  def grants_tool?(%__MODULE__{tools: tools}, name) when is_binary(name) do
    Map.has_key?(tools, name)
  end

  @doc "True when upstream operation `server/tool` is granted."
  @spec grants_upstream_tool?(t(), String.t(), String.t()) :: boolean()
  def grants_upstream_tool?(%__MODULE__{upstream_tools: :all}, server, tool)
      when is_binary(server) and is_binary(tool),
      do: true

  def grants_upstream_tool?(%__MODULE__{upstream_tools: tools}, server, tool)
      when is_struct(tools, MapSet) and is_binary(server) and is_binary(tool) do
    MapSet.member?(tools, "upstream:#{server}/#{tool}")
  end

  defp normalize_upstream_tools(:all), do: :all
  defp normalize_upstream_tools(%MapSet{} = tools), do: tools
  defp normalize_upstream_tools(tools) when is_list(tools), do: MapSet.new(tools)
  defp normalize_upstream_tools(_tools), do: MapSet.new()
end
