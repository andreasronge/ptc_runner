defmodule PtcRunnerMcp.CatalogConfig do
  @moduledoc """
  Runtime configuration for size-aware catalog exposure.

  Per `Plans/ptc-runner-mcp-catalog-exposure.md` §5, these settings
  control how the aggregator exposes upstream tool catalogs in the
  `lisp_eval` MCP tool description:

    * `:catalog_mode` — `:auto`, `:inline`, or `:lazy`.
    * `:catalog_inline_max_chars` — maximum rendered inline description
      size in `auto` mode.
    * `:catalog_inline_max_tools` — maximum total upstream tool count
      in `auto` mode.
    * `:max_catalog_ops_per_program` — maximum catalog builtin calls
      per `lisp_eval` invocation.
    * `:max_catalog_result_bytes` — maximum JSON-encoded result bytes
      from one catalog builtin.

  Stored in `:persistent_term` for O(1) lock-free reads on every
  `tools/list` request.
  """

  @default_catalog_mode :auto
  @default_catalog_inline_max_chars 800
  @default_catalog_inline_max_tools 8
  @default_max_catalog_ops_per_program 25
  @default_max_catalog_result_bytes 262_144

  @valid_modes [:auto, :inline, :lazy]

  @typedoc "Catalog exposure configuration stored in persistent_term."
  @type t :: %{
          catalog_mode: :auto | :inline | :lazy,
          catalog_inline_max_chars: pos_integer(),
          catalog_inline_max_tools: pos_integer(),
          max_catalog_ops_per_program: pos_integer(),
          max_catalog_result_bytes: pos_integer()
        }

  @doc "Default catalog config."
  @spec defaults() :: t()
  def defaults do
    %{
      catalog_mode: @default_catalog_mode,
      catalog_inline_max_chars: @default_catalog_inline_max_chars,
      catalog_inline_max_tools: @default_catalog_inline_max_tools,
      max_catalog_ops_per_program: @default_max_catalog_ops_per_program,
      max_catalog_result_bytes: @default_max_catalog_result_bytes
    }
  end

  @doc """
  Set process-wide catalog config.

  Unknown keys are ignored. Missing keys fall back to defaults.
  """
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @doc "Read current process-wide catalog config."
  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @doc "Returns the list of valid catalog mode atoms."
  @spec valid_modes() :: [:auto | :inline | :lazy]
  def valid_modes, do: @valid_modes

  @doc """
  Parses a string catalog mode value to the corresponding atom.

  Returns `{:ok, mode}` for valid values, `:error` for invalid.
  """
  @spec parse_mode(String.t()) :: {:ok, :auto | :inline | :lazy} | :error
  def parse_mode("auto"), do: {:ok, :auto}
  def parse_mode("inline"), do: {:ok, :inline}
  def parse_mode("lazy"), do: {:ok, :lazy}
  def parse_mode(_), do: :error
end
