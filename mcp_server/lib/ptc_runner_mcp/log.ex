defmodule PtcRunnerMcp.Log do
  @moduledoc """
  JSON-Lines structured logger writing to stderr.

  Per `Plans/ptc-runner-mcp-server.md` § 6.5, every log line is a
  single JSON object with at least `ts`, `level`, and `event` fields.
  Optional `request_id` and `fields` keys carry per-event context.

  Stdout is reserved for MCP messages (§ 6.1); this logger writes to
  stderr only.

  ## Configuration

    * Level is set process-wide via `set_level/1`. Default `:info`.
    * Configurable from the CLI via `--log-level` and from the env
      via `PTC_RUNNER_MCP_LOG_LEVEL`; both are wired up in
      `PtcRunnerMcp.Application.start/2`.

  Levels: `:debug`, `:info`, `:warn`, `:error`. Lower-priority levels
  are dropped silently.
  """

  @levels %{debug: 0, info: 1, warn: 2, error: 3}
  @default_level :info

  @typedoc "Recognized log levels."
  @type level :: :debug | :info | :warn | :error

  @doc """
  Set the process-wide log level.

  Accepts an atom or a string (e.g. `"info"`, `"DEBUG"`). Unknown
  values fall back to `:info`.
  """
  @spec set_level(level() | String.t() | atom()) :: :ok
  def set_level(level) do
    :persistent_term.put({__MODULE__, :level}, normalize_level(level))
    :ok
  end

  @doc "Get the current process-wide log level."
  @spec level() :: level()
  def level do
    :persistent_term.get({__MODULE__, :level}, @default_level)
  end

  @doc """
  Emit a log event.

  ## Examples

      Log.log(:info, "tools_call_start", %{request_id: 42})
      Log.log(:debug, "stdin_byte_count", %{bytes: 128})
  """
  @spec log(level(), String.t(), map()) :: :ok
  def log(level, event, fields \\ %{}) when is_atom(level) and is_binary(event) do
    if enabled?(level) do
      do_log(level, event, fields)
    else
      :ok
    end
  end

  defp enabled?(level) do
    Map.get(@levels, level, 99) >= Map.get(@levels, level(), 1)
  end

  defp do_log(level, event, fields) do
    {request_id, rest} = Map.pop(fields, :request_id)

    base = %{
      "ts" => iso8601_now(),
      "level" => Atom.to_string(level),
      "event" => event
    }

    base =
      case request_id do
        nil -> base
        id -> Map.put(base, "request_id", to_string(id))
      end

    payload =
      if rest == %{} do
        base
      else
        Map.put(base, "fields", stringify(rest))
      end

    line =
      case Jason.encode(payload) do
        {:ok, json} ->
          json

        {:error, _} ->
          Jason.encode!(%{
            "ts" => base["ts"],
            "level" => base["level"],
            "event" => event,
            "fields" => %{"_encode_error" => true}
          })
      end

    IO.puts(:stderr, line)
    :ok
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp normalize_level(level) when level in [:debug, :info, :warn, :error], do: level

  defp normalize_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warn
      "warning" -> :warn
      "error" -> :error
      _ -> @default_level
    end
  end

  defp normalize_level(level) when is_atom(level), do: normalize_level(Atom.to_string(level))
  defp normalize_level(_), do: @default_level

  # Best-effort recursive stringification of map keys for clean JSON.
  defp stringify(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
