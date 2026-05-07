defmodule PtcRunnerMcp.TraceConfig do
  @moduledoc """
  Per-call tracing configuration for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 6.6 and § 6.9, tracing is
  opt-in via `--trace-dir`. When unset, no JSONL files are written
  and no telemetry handler attaches (§ 6.6).

  Configuration is process-wide and stored in `:persistent_term`:

    * `:trace_dir` (string | nil) — destination directory for trace
      files; `nil` disables tracing.
    * `:trace_payloads` (`:none | :summary | :full`) — payload
      redaction policy (§ 6.9); default `:summary`.
    * `:trace_max_files` (pos_integer) — FIFO cap on files in the
      trace dir (§ 6.10); default 1000.

  Configured at boot from CLI flags or environment variables by
  `PtcRunnerMcp.Application`. Tests may also call `set/1` directly.
  """

  @default_trace_payloads :summary
  @default_trace_max_files 1000
  @valid_payloads [:none, :summary, :full]

  @typedoc "Trace configuration map."
  @type t :: %{
          trace_dir: String.t() | nil,
          trace_payloads: :none | :summary | :full,
          trace_max_files: pos_integer()
        }

  @doc "Default config — tracing disabled."
  @spec defaults() :: t()
  def defaults do
    %{
      trace_dir: nil,
      trace_payloads: @default_trace_payloads,
      trace_max_files: @default_trace_max_files
    }
  end

  @doc """
  Set the process-wide trace config.

  Accepts a map with any subset of `:trace_dir`, `:trace_payloads`,
  `:trace_max_files`. Missing keys fall back to defaults. Invalid
  payload levels fall back to `:summary`.
  """
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    defaults = defaults()

    payloads =
      case Map.get(overrides, :trace_payloads, defaults.trace_payloads) do
        v when v in @valid_payloads -> v
        _ -> @default_trace_payloads
      end

    max_files =
      case Map.get(overrides, :trace_max_files, defaults.trace_max_files) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_trace_max_files
      end

    merged = %{
      trace_dir: Map.get(overrides, :trace_dir, defaults.trace_dir),
      trace_payloads: payloads,
      trace_max_files: max_files
    }

    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @doc "Read the full trace config map."
  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @doc "Convenience: trace directory (nil → disabled)."
  @spec trace_dir() :: String.t() | nil
  def trace_dir, do: get().trace_dir

  @doc "Convenience: payload redaction policy."
  @spec trace_payloads() :: :none | :summary | :full
  def trace_payloads, do: get().trace_payloads

  @doc "Convenience: FIFO file cap."
  @spec trace_max_files() :: pos_integer()
  def trace_max_files, do: get().trace_max_files

  @doc "True when `--trace-dir` is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(trace_dir())

  @doc "Closed list of valid payload-policy atoms."
  @spec valid_payloads() :: [atom()]
  def valid_payloads, do: @valid_payloads

  @doc """
  Coerce a payload-policy value (atom or string, case-insensitive).

  Returns `{:ok, atom}` for valid inputs, `:error` for anything else.
  """
  @spec parse_payloads(term()) :: {:ok, :none | :summary | :full} | :error
  def parse_payloads(value) when value in @valid_payloads, do: {:ok, value}

  def parse_payloads(value) when is_binary(value) do
    case String.downcase(value) do
      "none" -> {:ok, :none}
      "summary" -> {:ok, :summary}
      "full" -> {:ok, :full}
      _ -> :error
    end
  end

  def parse_payloads(value) when is_atom(value) do
    parse_payloads(Atom.to_string(value))
  end

  def parse_payloads(_), do: :error
end
