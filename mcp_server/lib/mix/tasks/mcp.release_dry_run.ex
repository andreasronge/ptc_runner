defmodule Mix.Tasks.Mcp.ReleaseDryRun do
  @shortdoc "Build, package, and smoke-test the MCP release without publishing"

  @moduledoc """
  Runs the MCP release dry run documented in `RELEASING.md`.

  This task intentionally stops before any external release action. It does not
  create tags, push tags, create GitHub Releases, or upload artifacts.

      mix mcp.release_dry_run

  It runs the release gate, builds the production Mix release, packages the
  release directory, verifies checksums, extracts the archive, and smoke-tests
  the extracted binary in stateless and session modes.
  """

  use Mix.Task

  @requirements []

  @archive_name "ptc_runner_mcp-darwin-arm64.tar.gz"
  @release_name "ptc_runner_mcp"
  @dist_dir Path.join(["tmp", "release_dist"])
  @smoke_dir Path.join(["tmp", "release_smoke"])
  @extract_dir Path.join([@smoke_dir, "extract"])
  @release_dir Path.join(["_build", "prod", "rel", @release_name])
  @stdio_timeout_ms 30_000
  @no_upstreams_env [
    {"PTC_RUNNER_MCP_UPSTREAMS", "/nonexistent/ptc_runner_mcp_release_dry_run"},
    {"PTC_RUNNER_MCP_RESPONSE_PROFILE", "slim"},
    {"RELEASE_DISTRIBUTION", "none"}
  ]

  @impl Mix.Task
  def run(args) do
    reject_args!(args)

    Mix.shell().info("==> MCP release dry run")

    run_mix!(["deps.get"])
    run_mix!(["format", "--check-formatted"])
    run_mix!(["compile", "--warnings-as-errors"])
    run_mix!(["credo", "--strict"])
    run_mix!(["test", "--max-failures", "1", "--trace", "--warnings-as-errors"])
    run_mix!(["release", "--overwrite"], env: [{"MIX_ENV", "prod"}])

    archive = package_release!()
    verify_checksum!()

    bin = extract_archive!(archive)
    smoke_version!(bin)
    smoke_repl_wrapper!(bin)
    smoke_stateless!(bin)
    smoke_sessions!(bin)

    Mix.shell().info("""

    Dry run complete.
    Artifact: #{archive}
    Checksums: #{Path.join(@dist_dir, "SHA256SUMS")}
    No tag was created, pushed, or uploaded.
    """)
  end

  defp reject_args!([]), do: :ok

  defp reject_args!(args) do
    Mix.raise("mix mcp.release_dry_run does not accept arguments, got: #{Enum.join(args, " ")}")
  end

  defp run_mix!(args, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    command = ["mix" | args] |> Enum.join(" ")

    Mix.shell().info("==> #{command}")

    case System.cmd("mix", args, into: IO.stream(:stdio, :line), env: env) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("#{command} failed with exit status #{status}")
    end
  end

  defp package_release! do
    unless File.dir?(@release_dir) do
      Mix.raise("release directory missing at #{@release_dir}")
    end

    archive = Path.join(@dist_dir, @archive_name)

    Mix.shell().info("==> package #{archive}")
    File.rm_rf!(@dist_dir)
    File.mkdir_p!(@dist_dir)

    run_cmd!("tar", [
      "-czf",
      archive,
      "-C",
      Path.dirname(@release_dir),
      Path.basename(@release_dir)
    ])

    sha_path = Path.join(@dist_dir, "SHA256SUMS")
    {sum, 0} = System.cmd("shasum", ["-a", "256", @archive_name], cd: @dist_dir)
    File.write!(sha_path, sum)

    archive
  end

  defp verify_checksum! do
    Mix.shell().info("==> verify #{Path.join(@dist_dir, "SHA256SUMS")}")
    run_cmd!("shasum", ["-a", "256", "-c", "SHA256SUMS"], cd: @dist_dir)
  end

  defp extract_archive!(archive) do
    Mix.shell().info("==> extract #{archive}")
    File.rm_rf!(@smoke_dir)
    File.mkdir_p!(@extract_dir)
    run_cmd!("tar", ["-xzf", archive, "-C", @extract_dir])

    bin = Path.expand(Path.join([@extract_dir, @release_name, "bin", @release_name]))

    unless executable?(bin) do
      Mix.raise("extracted release binary missing or not executable at #{bin}")
    end

    bin
  end

  defp smoke_version!(bin) do
    Mix.shell().info("==> smoke version")

    case System.cmd(bin, ["version"], stderr_to_stdout: true, env: @no_upstreams_env) do
      {output, 0} ->
        Mix.shell().info(String.trim(output))

      {output, status} ->
        Mix.raise("version smoke failed with exit status #{status}:\n#{output}")
    end
  end

  defp smoke_repl_wrapper!(bin) do
    Mix.shell().info("==> smoke bundled ptc_lisp_repl wrapper")
    repl = Path.join(Path.dirname(bin), "ptc_lisp_repl")

    unless executable?(repl) do
      Mix.raise("ptc_lisp_repl wrapper missing or not executable at #{repl}")
    end

    case System.cmd(repl, ["--help"], stderr_to_stdout: true, env: @no_upstreams_env) do
      {output, 0} ->
        assert!(
          output =~ "Usage: ptc_lisp_repl",
          "ptc_lisp_repl --help did not print expected usage"
        )

      {output, status} ->
        Mix.raise("ptc_lisp_repl --help failed with exit status #{status}:\n#{output}")
    end
  end

  defp smoke_stateless!(bin) do
    Mix.shell().info("==> smoke stateless stdio")

    frames = [
      init_request(1),
      initialized_notif(),
      tools_list_request(2),
      tools_call_request(3, "lisp_eval", %{"program" => "(+ 1 2)"}),
      exit_notif()
    ]

    replies = run_stdio!(bin, ["start"], frames)

    list = reply!(replies, 2)
    tools = get_in(list, ["result", "tools"]) || []
    names = Enum.map(tools, & &1["name"])
    tool = Enum.find(tools, &(&1["name"] == "lisp_eval"))

    assert!("lisp_eval" in names, "stateless tools/list did not advertise lisp_eval")
    assert!(is_map(tool["inputSchema"]), "lisp_eval did not include inputSchema")

    assert!(
      not Map.has_key?(tool, "outputSchema"),
      "lisp_eval included outputSchema in slim mode"
    )

    call = reply!(replies, 3)
    result = call["result"]

    assert!(result["isError"] == false, "lisp_eval returned an error result")

    assert!(
      result["content"] == [%{"type" => "text", "text" => "user=> 3"}],
      "lisp_eval did not return expected slim text"
    )

    assert!(
      not Map.has_key?(result, "structuredContent"),
      "lisp_eval included structuredContent in slim mode"
    )
  end

  defp smoke_sessions!(bin) do
    Mix.shell().info("==> smoke session stdio")

    frames = [
      init_request(1),
      initialized_notif(),
      tools_list_request(2),
      tools_call_request(3, "lisp_eval", %{"program" => "(+ 1 2)"}),
      tools_call_request(4, "lisp_session_start", %{"title" => "dry-run smoke"}),
      exit_notif()
    ]

    replies = run_stdio!(bin, ["start", "--sessions"], frames)

    list = reply!(replies, 2)
    tools = get_in(list, ["result", "tools"]) || []
    names = Enum.map(tools, & &1["name"])

    assert!("lisp_eval" not in names, "session tools/list advertised lisp_eval")

    assert!(
      "lisp_session_start" in names,
      "session tools/list did not advertise lisp_session_start"
    )

    assert!(
      "lisp_session_eval" in names,
      "session tools/list did not advertise lisp_session_eval"
    )

    disabled_eval = reply!(replies, 3)

    assert!(
      get_in(disabled_eval, ["result", "structuredContent", "reason"]) == "unknown_tool",
      "lisp_eval did not return unknown_tool in session mode"
    )

    session_start = reply!(replies, 4)
    session_id = get_in(session_start, ["result", "structuredContent", "session_id"])

    assert!(
      is_binary(session_id) and session_id != "",
      "lisp_session_start did not return session_id"
    )
  end

  defp run_stdio!(bin, args, frames) do
    nonce = System.unique_integer([:positive])
    stdin_path = Path.join(System.tmp_dir!(), "ptc_runner_mcp_release_dry_run_#{nonce}.stdin")
    stdout_path = Path.join(System.tmp_dir!(), "ptc_runner_mcp_release_dry_run_#{nonce}.stdout")
    stderr_path = Path.join(System.tmp_dir!(), "ptc_runner_mcp_release_dry_run_#{nonce}.stderr")

    try do
      File.write!(stdin_path, encode_frames(frames))

      shell_cmd =
        "exec " <>
          Enum.map_join([bin | args], " ", &shell_quote/1) <>
          " < " <>
          shell_quote(stdin_path) <>
          " > " <>
          shell_quote(stdout_path) <>
          " 2> " <>
          shell_quote(stderr_path)

      case system_cmd_with_timeout("/bin/sh", ["-c", shell_cmd],
             env: @no_upstreams_env,
             timeout_ms: @stdio_timeout_ms
           ) do
        {_output, 0} ->
          stdout_path
          |> File.read!()
          |> decode_replies()

        {_output, status} ->
          Mix.raise("""
          stdio smoke failed with exit status #{status}

          stderr:
          #{File.read!(stderr_path)}
          """)
      end
    after
      _ = File.rm(stdin_path)
      _ = File.rm(stdout_path)
      _ = File.rm(stderr_path)
    end
  end

  defp encode_frames(frames) do
    frames
    |> Enum.map(fn frame -> Jason.encode!(frame) <> "\n" end)
    |> IO.iodata_to_binary()
  end

  defp decode_replies(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"jsonrpc" => "2.0"} = reply} -> [reply]
        _ -> []
      end
    end)
  end

  defp reply!(replies, id) do
    Enum.find(replies, &(&1["id"] == id)) ||
      Mix.raise("missing JSON-RPC reply for id #{id}; got #{inspect(replies, limit: :infinity)}")
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: Mix.raise(message)

  defp run_cmd!(command, args, opts \\ []) do
    Mix.shell().info("==> #{Enum.join([command | args], " ")}")

    case System.cmd(command, args, Keyword.merge([into: IO.stream(:stdio, :line)], opts)) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("#{command} failed with exit status #{status}")
    end
  end

  defp system_cmd_with_timeout(command, args, opts) do
    {timeout_ms, opts} = Keyword.pop!(opts, :timeout_ms)

    task = Task.async(fn -> System.cmd(command, args, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        _ = System.cmd("/bin/sh", ["-c", "pkill -TERM -f #{@release_name} 2>/dev/null; true"])
        Mix.raise("#{command} #{Enum.join(args, " ")} timed out after #{timeout_ms}ms")
    end
  end

  defp executable?(path) do
    File.exists?(path) and
      case File.stat(path) do
        {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _ -> false
      end
  end

  defp shell_quote(arg) do
    arg = to_string(arg)

    if Regex.match?(~r{\A[A-Za-z0-9_\-./:]+\z}, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  defp init_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "release-dry-run", "version" => "1"}
      }
    }
  end

  defp initialized_notif do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
  end

  defp tools_list_request(id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}
  end

  defp tools_call_request(id, tool_name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }
  end

  defp exit_notif do
    %{"jsonrpc" => "2.0", "method" => "exit"}
  end
end
