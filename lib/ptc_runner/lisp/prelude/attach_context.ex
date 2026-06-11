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
          tools: %{optional(String.t()) => term()}
        }

  defstruct runtime: nil, tools: %{}

  @doc """
  Builds an attach context from options.

  ## Options

    * `:runtime` - upstream runtime handle (default: `nil`)
    * `:tools` - granted tools, in any shape `PtcRunner.Lisp.run/2` accepts (a
      `%{name => tool}` map OR a `[{name, tool}, ...]` tuple/keyword list);
      canonicalized to a map so grant checks are shape-agnostic (default: `%{}`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      runtime: Keyword.get(opts, :runtime),
      tools: Map.new(Keyword.get(opts, :tools, %{}))
    }
  end

  @doc "True when the granted tools map contains a typed tool named `name`."
  @spec grants_tool?(t(), String.t()) :: boolean()
  def grants_tool?(%__MODULE__{tools: tools}, name) when is_binary(name) do
    Map.has_key?(tools, name)
  end
end
