defmodule PtcRunnerMcp.Version do
  @moduledoc """
  MCP protocol version negotiation.

  Per `Plans/ptc-runner-mcp-server.md` § 7.1 and § 7.3, this server
  supports two MCP protocol revisions:

    * `"2025-11-25"` — primary (latest at v1).
    * `"2025-06-18"` — compatibility floor (first revision with the
      wire features this server depends on).

  Negotiation:

    * If the client advertises a supported revision, the server replies
      with the same revision.
    * Any other client value falls back to the server's primary
      (`"2025-11-25"`).
  """

  @primary "2025-11-25"
  @floor "2025-06-18"
  @supported [@primary, @floor]
  @repo_root Path.expand("../../..", __DIR__)
  @git_commit_env "PTC_RUNNER_MCP_GIT_COMMIT"
  @git_dirty_env "PTC_RUNNER_MCP_GIT_DIRTY"
  @git_commit System.get_env(@git_commit_env) ||
                (try do
                   case System.cmd("git", ["rev-parse", "--short=12", "HEAD"],
                          cd: @repo_root,
                          stderr_to_stdout: true
                        ) do
                     {value, 0} -> String.trim(value)
                     _ -> "unknown"
                   end
                 rescue
                   _ -> "unknown"
                 end)
  @git_dirty System.get_env(@git_dirty_env) ||
               (try do
                  case System.cmd("git", ["status", "--porcelain"],
                         cd: @repo_root,
                         stderr_to_stdout: true
                       ) do
                    {"", 0} -> "false"
                    {_, 0} -> "true"
                    _ -> "false"
                  end
                rescue
                  _ -> "false"
                end)

  @doc "Server's primary (latest) supported protocol version."
  @spec primary() :: String.t()
  def primary, do: @primary

  @doc "Server's compatibility floor."
  @spec floor() :: String.t()
  def floor, do: @floor

  @doc "List of all client `protocolVersion` values negotiated to themselves."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc """
  Pick the server's reply `protocolVersion` for a given client request.

  ## Examples

      iex> PtcRunnerMcp.Version.negotiate("2025-11-25")
      "2025-11-25"

      iex> PtcRunnerMcp.Version.negotiate("2025-06-18")
      "2025-06-18"

      iex> PtcRunnerMcp.Version.negotiate("1999-01-01")
      "2025-11-25"

      iex> PtcRunnerMcp.Version.negotiate(nil)
      "2025-11-25"
  """
  @spec negotiate(term()) :: String.t()
  def negotiate(version) do
    case version do
      v when v in @supported -> v
      _ -> @primary
    end
  end

  @doc "The package version (`mix.exs` `@version`)."
  @spec package_version() :: String.t()
  def package_version do
    case :application.get_key(:ptc_runner_mcp, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      :undefined -> "0.0.0"
    end
  end

  @doc """
  The externally advertised server version.

  This keeps the OTP application version as the source of truth and appends
  git build metadata when the release was built from a checkout:

      iex> String.starts_with?(PtcRunnerMcp.Version.display_version(), PtcRunnerMcp.Version.package_version())
      true
  """
  @spec display_version() :: String.t()
  def display_version do
    case git_commit() do
      "unknown" -> package_version()
      commit -> package_version() <> "+" <> commit <> dirty_suffix()
    end
  end

  @doc "The git commit embedded when this module was compiled."
  @spec git_commit() :: String.t()
  def git_commit, do: @git_commit

  @doc "True when the source checkout had uncommitted changes at compile time."
  @spec git_dirty?() :: boolean()
  def git_dirty?, do: @git_dirty == "true"

  @doc "Structured build metadata for diagnostics and MCP initialize responses."
  @spec build_info() :: map()
  def build_info do
    %{
      "package_version" => package_version(),
      "git_commit" => git_commit(),
      "git_dirty" => git_dirty?()
    }
  end

  defp dirty_suffix do
    if git_dirty?(), do: ".dirty", else: ""
  end
end
