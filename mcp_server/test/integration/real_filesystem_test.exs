defmodule PtcRunnerMcp.Integration.RealFilesystemTest do
  @moduledoc """
  Phase 2.2 real-upstream integration test
  (`Plans/ptc-runner-mcp-aggregator.md` §12.4.2).

  Spawns an actual `@modelcontextprotocol/server-filesystem` subprocess
  via `npx` and exercises the aggregator end-to-end through the real
  `Upstream.Stdio` implementation (no Fake). A PTC-Lisp program reads
  one known small file via `tool/mcp-call`, transforms the result to
  a line count, and returns ONLY the transform — verifying that the
  raw file contents stay inside the sandbox.

  ## Running

      MCP_REAL_UPSTREAM=1 mix test --include real_upstream \\
        test/integration/real_filesystem_test.exs

  Excluded from the default `mix test` (test_helper.exs adds
  `:real_upstream` to the exclude list). Opt in with the
  `--include real_upstream` flag.

  ## Prerequisites

    * `npx` on `$PATH` (Node ≥ 16). The test SKIPS with a clear
      message if `npx` is not found, so accidental runs on a
      Node-less host are friendly rather than red.
    * Network access on first run: `npx --yes` auto-installs
      `@modelcontextprotocol/server-filesystem` into the npm cache.
      Subsequent runs are cache-hit and start in well under a
      second.

  ## Version pin

  The npm package version is pinned in `args` (see
  `@filesystem_mcp_version` below). Without a pin, `npx --yes`
  floats to whatever npm tags as `latest`, and an upstream release
  that changes the `read_text_file` tool name OR the `content[0]
  .text` response shape would silently break the test on machines
  whose npm cache happens to predate the release. With the pin, the
  failure mode is reproducible: bump `@filesystem_mcp_version`
  after verifying the new release's tool surface against the
  assertions in this file. The `serverInfo.version` reported on the
  wire (currently "0.2.0") is independent from the npm package
  version (calendar-versioned, currently `2026.1.14`); both are
  controlled by the upstream and may diverge.

  ## Timeouts

  `handshake_timeout_ms` is bumped to 60s (vs the Stdio default of
  10s) so the first-run `npx` install does not race the handshake
  deadline. Steady-state (cache-hit) handshakes complete in
  ~200–400ms; the bump only matters on the very first run.

  ## Path resolution (macOS)

  On macOS `/tmp` is a symlink to `/private/tmp`. The
  filesystem-MCP server resolves its allowed-roots against the
  realpath and rejects access via the symlinked form
  ("Access denied - path outside allowed directories"). Tests use
  `Path.expand/1` (which calls `:filename.absname`) plus
  `:filelib.is_file`-friendly canonicalization via `File.cwd!()`'s
  expansion so the temp-dir path matches what the server sees.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Limits, Tools}
  alias PtcRunnerMcp.Upstream.{Connection, Registry, Stdio}

  @moduletag :real_upstream
  # Keep generous: first-run npx install + handshake + a couple of
  # tools/call round trips. Steady-state runs finish in ~1s.
  @moduletag timeout: 120_000

  # Compile-time precondition gate: if `npx` is not on `$PATH` at
  # module-load time, tag the entire module `:skip`. ExUnit honors
  # `:skip` per-test by reporting the test as skipped (no error,
  # no setup_all crash). This is the documented Elixir pattern for
  # "skip the whole module when a precondition is missing":
  # `setup_all` does NOT accept a `{:skip, reason}` return tuple —
  # only `:ok`, `{:ok, context}`, a keyword list, or a map — so
  # putting the precondition check in `setup_all` would surface as
  # a setup_all runtime error on a Node-less machine instead of a
  # friendly skip. The check runs at compile time, so a fresh
  # `mix test` run after installing Node picks up the new
  # availability without any module-level config flip.
  if System.find_executable("npx") == nil do
    @moduletag skip:
                 "npx not found on $PATH. Install Node.js (>= 16) to run Phase 2.2 real-upstream tests."
  end

  @registry_name PtcRunnerMcp.Upstream.Registry
  @upstream_name "fs"
  @file_basename "known.txt"
  @file_content "line one alpha\nline two bravo\nline three charlie\nline four delta\nline five echo\n"
  @file_line_count 5

  # Pinned npm package version of `@modelcontextprotocol/server-
  # filesystem`. See moduledoc § "Version pin" for the rationale.
  # When bumping: re-verify `read_text_file` tool name and the
  # `%{"content" => [%{"type" => "text", "text" => _}], "isError" =>
  # false}` response shape, then update this constant.
  @filesystem_mcp_version "2026.1.14"

  setup do
    stop_existing_registry()

    tmpdir = make_tmpdir()
    file_path = Path.join(tmpdir, @file_basename)
    File.write!(file_path, @file_content)

    {:ok, _pid} =
      Registry.start_link(
        name: @registry_name,
        upstreams: [
          %{
            name: @upstream_name,
            impl: PtcRunnerMcp.Upstream.Stdio,
            config: %{
              command: "npx",
              args: [
                "--yes",
                "@modelcontextprotocol/server-filesystem@#{@filesystem_mcp_version}",
                tmpdir
              ],
              env: %{},
              # First-run `npx --yes` may install the package; bump
              # well above the 10s default so the handshake survives.
              handshake_timeout_ms: 60_000
            }
          }
        ]
      )

    # `program_timeout_ms` must exceed the cold-start budget.
    # `handshake_timeout_ms` (60s, set on the Stdio config above)
    # bounds the upstream-side `initialize` + `tools/list`, but
    # `program_timeout_ms` is the OUTER cap on the entire sandboxed
    # PTC-Lisp program — including `ensure_started/1`, which itself
    # waits for `handshake_timeout_ms`. On a cold npm cache,
    # `npx --yes` can spend 20–60s installing the package BEFORE
    # the handshake even starts; the aggregator default of 10s
    # would kill the program before npm finishes, even though the
    # individual handshake budget allows for it.
    #
    # 90s gives a healthy margin: 60s handshake budget + ~20s for
    # the cold npm install upper bound + buffer for the actual
    # `tools/call` round trip. The ExUnit `@moduletag timeout:`
    # (120s) sits above this, so the per-test reaper still fires
    # cleanly if `program_timeout_ms` ever runs to completion.
    # Steady-state (warm npm cache) runs finish in ~2.5s — the
    # bumped ceiling is invisible on the happy path.
    Limits.set(
      Limits.defaults()
      |> Map.merge(Limits.aggregator_defaults())
      |> Map.put(:program_timeout_ms, 90_000)
    )

    on_exit(fn ->
      stop_existing_registry()
      Limits.set(Limits.defaults())
      File.rm_rf(tmpdir)
    end)

    {:ok, tmpdir: tmpdir, file_path: file_path}
  end

  describe "§12.4.2 happy path" do
    test "PTC-Lisp reads file via filesystem-MCP, returns only the line count", %{
      file_path: file_path
    } do
      # The program calls `tool/mcp-call` against the real filesystem
      # MCP server, extracts the file text from the upstream's
      # `content[0].text` field, splits into lines, and returns ONLY
      # the count. The raw file contents never leave the sandbox.
      #
      # Stdio.extract_call_result/1 returns the upstream's full
      # `result` map verbatim. `@modelcontextprotocol/server-
      # filesystem` (probed against v0.2.0 via `npx --yes`) returns
      #
      #     %{"content" => [%{"type" => "text", "text" => "<file>"}],
      #       "isError" => false}
      #
      # The map keys are strings (PTC-Lisp's JSON convention), and
      # `get-in` accepts integer list indices, so the path
      # `["content" 0 "text"]` resolves to the file's text.
      program = """
      (let [resp (tool/mcp-call {:server "#{@upstream_name}"
                                 :tool "read_text_file"
                                 :args {:path "#{file_path}"}})
            text (get-in resp ["content" 0 "text"])
            lines (split-lines text)]
        {:line-count (count lines)})
      """

      env = Tools.call_with_gate(%{"program" => program})

      # 1. Envelope is success.
      assert env["isError"] == false,
             "expected success envelope, got: #{inspect(env, limit: :infinity, printable_limit: :infinity)}"

      structured = env["structuredContent"]

      # 2. The structured `result` (LLM-readable preview) contains
      #    the transformed value (line count) — and ONLY that. The
      #    program's last expression is the {:line-count N} map.
      result_str = structured["result"]
      assert is_binary(result_str)
      assert result_str =~ "line-count"
      assert result_str =~ "#{@file_line_count}"

      # 3. upstream_calls has exactly one ok entry for fs.read_text_file.
      assert [entry] = structured["upstream_calls"]
      assert entry["server"] == @upstream_name
      assert entry["tool"] == "read_text_file"
      assert entry["status"] == "ok"

      assert is_integer(entry["duration_ms"]) and entry["duration_ms"] > 0,
             "expected positive duration_ms, got: #{inspect(entry["duration_ms"])}"

      refute Map.has_key?(entry, "reason")
      refute Map.has_key?(entry, "error")

      # 4. Discriminating leak check: the full encoded envelope must
      #    NOT contain the file's literal content. If the program
      #    accidentally returned the raw text — or the framework
      #    snuck the upstream payload into `prints`, `validated`, or
      #    a debug field — this assertion fires.
      encoded = Jason.encode!(env)

      refute String.contains?(encoded, "alpha"),
             "envelope leaked file content (looking for 'alpha'): #{encoded}"

      refute String.contains?(encoded, "bravo"),
             "envelope leaked file content (looking for 'bravo'): #{encoded}"

      refute String.contains?(encoded, "echo"),
             "envelope leaked file content (looking for 'echo'): #{encoded}"
    end
  end

  describe "§12.4.2 failure path (§7.4 unknown tool on started upstream)" do
    test "calling a nonexistent tool short-circuits with programmer-fault before dispatch" do
      # Warm the cache: a real call to a known tool so
      # ensure_started/1 succeeds and the upstream lands in
      # `started_upstreams` with a populated `tools/list`.
      warm_program = """
      (tool/mcp-call {:server "#{@upstream_name}"
                      :tool "list_allowed_directories"
                      :args {}})
      """

      warm = Tools.call_with_gate(%{"program" => warm_program})
      assert warm["isError"] == false, "warm-up failed: #{inspect(warm, limit: :infinity)}"

      # Now invoke an unknown tool. Per §7.4 with the upstream in
      # `started_upstreams` AND its cached `tools/list` lacking the
      # name, this MUST raise programmer-fault BEFORE any dispatch.
      program = """
      (tool/mcp-call {:server "#{@upstream_name}"
                      :tool "nonexistent_tool_xyz"
                      :args {}})
      """

      env = Tools.call_with_gate(%{"program" => program})

      # 1. Error envelope.
      assert env["isError"] == true,
             "expected error envelope, got: #{inspect(env, limit: :infinity)}"

      structured = env["structuredContent"]
      assert structured["reason"] == "runtime_error"

      # 2. The message identifies the offending tool/server pair
      #    exactly as §7.2 requires.
      assert structured["message"] =~
               "no tool 'nonexistent_tool_xyz' in upstream '#{@upstream_name}'",
             "unexpected message: #{inspect(structured["message"])}"

      # 3. upstream_calls is empty: the raise short-circuits
      #    BEFORE any upstream dispatch (no record). If the unknown-
      #    tool check let the call through to Stdio.call/4, the
      #    upstream would reply with an error and we'd see one entry
      #    here with status: "error" — that would mean §7.4's
      #    short-circuit guarantee is broken.
      assert (structured["upstream_calls"] || []) == [],
             "expected no upstream_calls for short-circuited unknown tool, got: #{inspect(structured["upstream_calls"])}"
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # Tears down any existing routing Registry AND waits for the Stdio
  # GenServer holding the `@upstream_name` slot in `Stdio.Names` to
  # actually exit before returning. Both tests in this file reuse
  # the same upstream name (`"fs"`); without this synchronization,
  # `setup` for test N+1 races test N's async `impl.stop/1` cascade
  # and trips on `{:already_started, _}` when the Connection's init
  # tries to register the Stdio name.
  #
  # Ordering invariants (each step's signal cannot precede the
  # previous step's effect):
  #
  #   1. Snapshot `Stdio.Names` BEFORE any teardown — capture the
  #      pre-teardown Stdio pid, if any.
  #   2. `Process.monitor` that pid BEFORE asking anything to die.
  #      This avoids the classic race where the process exits
  #      between `whereis` and `monitor` (the monitor still fires
  #      with `:noproc` synchronously, but the explicit ordering
  #      is defensive).
  #   3. Drive `Connection.stop/1` synchronously — `GenServer.stop`
  #      with `:normal` runs the Connection's `terminate/2`, which
  #      runs `impl.stop/1`, which closes the Port (stdin EOF) and
  #      releases the `Stdio.Names` registration. Connection.stop
  #      does NOT return until terminate/2 finishes.
  #   4. Force-kill the Registry GenServer as belt-and-braces (so
  #      isolated test paths that don't go through the
  #      Connection-cascade still come down).
  #   5. `assert_receive {:DOWN, ^stdio_ref, ...}` — discriminating
  #      assertion. If the cleanup fell through and Stdio is still
  #      alive (and thus still owns the registration), this times
  #      out and the helper raises rather than silently letting the
  #      next setup race.
  defp stop_existing_registry do
    stdio_monitor = monitor_existing_stdio(@upstream_name)

    stop_existing_connection(@upstream_name)
    kill_named_genserver(@registry_name)

    wait_for_stdio_down(stdio_monitor)
  end

  # Returns `nil` if no Stdio pid is currently registered for `name`,
  # or `{ref, pid}` if one is — caller must `assert_receive {:DOWN,
  # ref, ...}` before assuming the registration is free.
  defp monitor_existing_stdio(name) do
    # Note: this is Elixir's `Registry`, not our aliased
    # `PtcRunnerMcp.Upstream.Registry`. Fully-qualified to disambiguate.
    case Elixir.Registry.lookup(Stdio.Names, name) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        {ref, pid}

      [] ->
        nil
    end
  end

  defp stop_existing_connection(name) do
    routing_pid = Process.whereis(@registry_name)

    if is_pid(routing_pid) and Process.alive?(routing_pid) do
      case Connection.whereis(routing_pid, name) do
        nil ->
          :ok

        conn_pid ->
          # Synchronous cascade: terminate/2 on Connection runs
          # `impl.stop/1` (Stdio.stop -> GenServer.stop -> Stdio
          # terminate/2 -> Port.close + Stdio.Names release).
          Connection.stop(conn_pid)
      end
    end
  end

  defp kill_named_genserver(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  defp wait_for_stdio_down(nil), do: :ok

  defp wait_for_stdio_down({ref, pid}) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      10_000 ->
        raise "Stdio process for upstream '#{@upstream_name}' (pid=#{inspect(pid)}) " <>
                "did not exit within 10s of teardown — its Stdio.Names " <>
                "registration is still held and the next setup will race " <>
                "{:already_started, _}."
    end
  end

  # On macOS `/tmp` is a symlink to `/private/tmp`, and likewise
  # `/var` -> `/private/var` (so `System.tmp_dir!()` returns a path
  # whose ANCESTOR — not the leaf — is the symlink). The
  # filesystem-MCP server canonicalizes its allowed-roots via the
  # realpath and rejects access through the un-canonicalized form
  # ("Access denied - path outside allowed directories"). We
  # component-walk the path with `:file.read_link/1` at every
  # depth so an intermediate symlink (`/var`) is resolved even
  # though the LEAF is a regular directory.
  defp make_tmpdir do
    base =
      System.tmp_dir!()
      |> Path.expand()
      |> realpath()

    dir =
      Path.join(base, "ptc_runner_phase22_#{:erlang.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(dir)
    dir
  end

  # Resolve every symlink along the path, not just the leaf. POSIX
  # `realpath(3)` semantics: walk components left-to-right, expand
  # symlinks as encountered, restart from the resolved point. We
  # cap the loop at a fixed depth as a defensive break against
  # circular links (the Erlang VM otherwise has no cycle detection
  # for `read_link`).
  defp realpath(path) do
    realpath(path, 64)
  end

  defp realpath(_path, 0), do: raise("realpath: too many symlink levels")

  defp realpath(path, depth) do
    case :file.read_link(path) do
      {:ok, target} ->
        # Symlink at the leaf — resolve target relative to parent
        # and recurse. `read_link` returns charlist.
        target
        |> List.to_string()
        |> Path.expand(Path.dirname(path))
        |> realpath(depth - 1)

      {:error, _} ->
        # Leaf is not a symlink. But ancestors might be. Walk up to
        # the parent, resolve IT recursively, then re-attach the
        # leaf. Termination: `Path.dirname/1` is fixed at the root
        # ("/") so we stop when parent equals path.
        parent = Path.dirname(path)

        if parent == path do
          # Hit the filesystem root.
          path
        else
          resolved_parent = realpath(parent, depth - 1)
          Path.join(resolved_parent, Path.basename(path))
        end
    end
  end
end
