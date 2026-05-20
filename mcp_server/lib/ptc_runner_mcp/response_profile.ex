defmodule PtcRunnerMcp.ResponseProfile do
  @moduledoc """
  Boot-time configuration for `lisp_eval` response rendering.

  This is deliberately separate from the MCP capability profile
  (`:mcp_no_tools` vs `:mcp_aggregator`). Capability controls what the
  tool can do; response profile controls how the tool result is rendered.
  """

  alias PtcRunnerMcp.DebugConfig

  @profiles [:slim, :structured, :debug]
  @env "PTC_RUNNER_MCP_RESPONSE_PROFILE"

  @type t :: :slim | :structured | :debug

  @doc "Accepted response profiles."
  @spec profiles() :: [t()]
  def profiles, do: @profiles

  @doc "Parse a response profile string or atom."
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(profile) when profile in @profiles, do: {:ok, profile}

  def parse(profile) when is_binary(profile) do
    case String.trim(profile) do
      "slim" -> {:ok, :slim}
      "structured" -> {:ok, :structured}
      "debug" -> {:ok, :debug}
      other -> {:error, other}
    end
  end

  def parse(other), do: {:error, other}

  @doc """
  Resolve the active profile from CLI args, env, and debug-tool state.

  Precedence: CLI > env > debug-inferred > slim.
  """
  @spec resolve(map()) :: t()
  def resolve(args) when is_map(args) do
    cond do
      Map.has_key?(args, :response_profile) ->
        parse!(Map.fetch!(args, :response_profile))

      env_present?() ->
        parse!(System.get_env(@env))

      debug_enabled?(args) ->
        :debug

      true ->
        :slim
    end
  end

  @doc "Store the active response profile in persistent_term."
  @spec set(t() | String.t()) :: :ok
  def set(profile) do
    :persistent_term.put({__MODULE__, :profile}, parse!(profile))
    :ok
  end

  @doc "Current process-wide response profile."
  @spec current() :: t()
  def current do
    :persistent_term.get({__MODULE__, :profile}, :slim)
  end

  @doc "Reset to the production default."
  @spec reset() :: :ok
  def reset, do: set(:slim)

  defp parse!(profile) do
    case parse(profile) do
      {:ok, parsed} -> parsed
      {:error, bad} -> raise ArgumentError, "invalid MCP response profile: #{inspect(bad)}"
    end
  end

  defp env_present? do
    case System.get_env(@env) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp debug_enabled?(args) do
    cond do
      Map.has_key?(args, :debug_tool) -> Map.get(args, :debug_tool) == true
      System.get_env("PTC_RUNNER_MCP_DEBUG_TOOL") in ["1", "true", "TRUE", "yes", "YES"] -> true
      true -> DebugConfig.enabled?()
    end
  end
end
