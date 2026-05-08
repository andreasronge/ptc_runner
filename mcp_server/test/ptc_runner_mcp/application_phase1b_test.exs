defmodule PtcRunnerMcp.ApplicationPhase1bTest do
  @moduledoc """
  Phase 1b regression test for the JSON-config → Stdio integration
  path. Codex review of `3c2754d` flagged a [P1]: the loader passed
  Jason's string-keyed map straight through to `Upstream.Stdio`,
  which read atom keys (`:args`, `:env`, `:cd`) and silently
  saw `nil`. Production configs would launch the bare command with
  no args / no env, breaking real upstreams.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §5.2 (config format),
  §6.3 (Stdio behaviour). The fix normalizes once in
  `Application.normalize_stdio_config/1`; this test exercises the
  full path:

      JSON file
        → Application.load_upstreams_config/1
        → Upstream.Registry bootstrap (:upstreams option)
        → Connection.ensure_started/1
        → Upstream.Stdio.start_link/2 with atom keys
        → MockServer subprocess receives args + env

  The discriminating assertion is on the **MockServer side**: the
  mock writes its received args / env to a side-channel file at
  startup, and the test reads that file to confirm the JSON-
  specified args + env were faithfully delivered. Pre-fix the
  args list and env map would be empty (the JSON-string-keyed
  values silently dropped); post-fix they round-trip exactly.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Upstream.{Connection, Registry, Stdio}

  @mock_path "test/support/mock_server.exs"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "phase1b-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp project_root, do: File.cwd!()

  defp write_config(tmp_dir, json) do
    path = Path.join(tmp_dir, "upstreams.json")
    File.write!(path, json)
    path
  end

  describe "JSON-config → Stdio happy path (codex [P1] regression)" do
    @tag timeout: 30_000
    test "args + env from JSON reach the subprocess unmodified", %{tmp_dir: tmp_dir} do
      # Side-channel: the MockServer writes a JSON record of its
      # argv + selected env vars to this path on startup. The test
      # asserts on its contents post-handshake.
      probe_path = Path.join(tmp_dir, "probe.json")

      json =
        Jason.encode!(%{
          "upstreams" => %{
            "mock" => %{
              "command" => "mix",
              "args" => [
                "run",
                "--no-start",
                "--no-compile",
                @mock_path,
                "argv-flag-from-json"
              ],
              "env" => %{
                "MOCK_PROBE_PATH" => probe_path,
                "MOCK_ENV_VAR_FROM_JSON" => "expected-value"
              },
              "cd" => project_root()
            }
          }
        })

      cfg_path = write_config(tmp_dir, json)

      args_map = PtcRunnerMcp.Application.parse_args(["--upstreams-config", cfg_path])

      [entry] = PtcRunnerMcp.Application.load_upstreams_config(args_map)

      # Post-fix: Stdio sees an atom-keyed config. Pre-fix this map
      # was string-keyed and the next step's `Map.get(config, :args, [])`
      # silently returned []. The assertion below would fail.
      assert entry.name == "mock"
      assert entry.impl == Stdio
      assert is_list(entry.config[:args])
      assert "argv-flag-from-json" in entry.config[:args]
      assert entry.config[:env]["MOCK_ENV_VAR_FROM_JSON"] == "expected-value"
      assert entry.config[:cd] == project_root()

      registry_name = :"reg-#{System.unique_integer([:positive])}"

      {:ok, _reg} = Registry.start_link(name: registry_name, upstreams: [entry])

      on_exit(fn ->
        try do
          GenServer.stop(registry_name, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

        Stdio.stop("mock")
      end)

      conn = Registry.connection_for("mock", registry_name)
      assert is_pid(conn)

      # Add a longer handshake timeout because cold `mix run` is
      # ~1s on a warm BEAM and longer when the test scheduler is busy.
      # The Connection's config is pulled directly from `entry`,
      # which we already asserted carries atom keys; we DON'T mutate
      # it here — the regression we're guarding is "as decoded
      # from JSON".
      assert {:ok, _} = Connection.ensure_started(conn)

      # MockServer wrote its received argv + env to probe_path during
      # startup; we read it back to confirm faithful delivery. The
      # discriminating signal:
      #
      #   - "argv-flag-from-json" is in the subprocess argv list
      #     (proves :args round-trip).
      #   - "MOCK_ENV_VAR_FROM_JSON=expected-value" is in the env
      #     (proves :env round-trip).
      #
      # Pre-fix both would be missing because Stdio launched the
      # subprocess with no args / no env.
      assert File.exists?(probe_path),
             "MockServer never wrote its probe — handshake almost certainly used wrong args/env"

      probe = probe_path |> File.read!() |> Jason.decode!()

      assert "argv-flag-from-json" in probe["argv"],
             "expected JSON args to reach subprocess argv, got: #{inspect(probe["argv"])}"

      assert probe["env"]["MOCK_ENV_VAR_FROM_JSON"] == "expected-value",
             "expected JSON env to reach subprocess env, got: #{inspect(probe["env"])}"
    end
  end

  describe "normalize_stdio_config/1" do
    test "drops unknown JSON keys with a warning (no silent passthrough)" do
      # Typos like `"comand"` or schema-violating extras should NOT
      # silently land in the impl config. The whitelist drops them
      # at the boundary so Stdio sees only well-formed atom shapes.
      input = %{
        "command" => "mix",
        "args" => ["a", "b"],
        "typo_key" => "ignored",
        "fake" => "should-not-pass-through"
      }

      output = PtcRunnerMcp.Application.normalize_stdio_config(input)

      assert output == %{
               command: "mix",
               args: ["a", "b"]
             }

      refute Map.has_key?(output, :typo_key)
      refute Map.has_key?(output, :fake)
    end

    test "preserves env values as string-keyed (env-var names are external strings)" do
      # `String.to_atom/1` on user input is forbidden (CLAUDE.md).
      # Env-var names stay string-keyed; only the OUTER config map
      # gets atom keys.
      input = %{
        "command" => "x",
        "env" => %{"GITHUB_TOKEN" => "abc", "FOO" => "bar"}
      }

      output = PtcRunnerMcp.Application.normalize_stdio_config(input)

      assert output[:env] == %{"GITHUB_TOKEN" => "abc", "FOO" => "bar"}
    end

    test "preserves :handshake_timeout_ms (codex [P2] #2 regression)" do
      # Codex review of `0f6c1cd` flagged that
      # `:handshake_timeout_ms` was missing from the whitelist —
      # `Upstream.Stdio` reads `Map.get(config, :handshake_timeout_ms, 10_000)`
      # but the loader silently dropped any JSON-supplied value
      # (and emitted a "dropping unknown key" warning). Slow-handshake
      # upstreams that explicitly bumped the timeout were stuck on
      # the 10s default.
      #
      # Discriminator: pre-fix `output` is `%{command: "x"}` (the
      # custom timeout silently dropped); post-fix it is
      # `%{command: "x", handshake_timeout_ms: 30_000}`. Round-trip
      # the value end-to-end from JSON-shape input.
      input = %{
        "command" => "x",
        "handshake_timeout_ms" => 30_000
      }

      output = PtcRunnerMcp.Application.normalize_stdio_config(input)

      assert output[:handshake_timeout_ms] == 30_000,
             "expected handshake_timeout_ms: 30000 in output, got #{inspect(output)}"

      # And the full JSON-load path also preserves it (sanity floor:
      # the boundary normalize is invoked by `parse_upstreams_body/2`).
      tmp_dir =
        Path.join(System.tmp_dir!(), "phase1b-hs-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      cfg_path = Path.join(tmp_dir, "upstreams.json")

      File.write!(
        cfg_path,
        Jason.encode!(%{
          "upstreams" => %{
            "slow" => %{
              "command" => "npx",
              "handshake_timeout_ms" => 30_000
            }
          }
        })
      )

      args_map = PtcRunnerMcp.Application.parse_args(["--upstreams-config", cfg_path])

      [entry] = PtcRunnerMcp.Application.load_upstreams_config(args_map)
      assert entry.config[:handshake_timeout_ms] == 30_000
    end

    test "preserves :backoff_initial_ms and :backoff_max_ms (Connection-side audit)" do
      # The whitelist audit codex requested also flagged that
      # `Upstream.Connection` reads `:backoff_initial_ms` and
      # `:backoff_max_ms` from the same upstream config map.
      # Without these in the whitelist, an operator who tunes
      # backoff in JSON would have it silently dropped — same
      # class of bug as :handshake_timeout_ms.
      input = %{
        "command" => "x",
        "backoff_initial_ms" => 250,
        "backoff_max_ms" => 60_000
      }

      output = PtcRunnerMcp.Application.normalize_stdio_config(input)

      assert output[:backoff_initial_ms] == 250
      assert output[:backoff_max_ms] == 60_000
    end
  end

  describe "self-as-upstream rejection (§5.3, codex [P2] #3 regression)" do
    test "JSON config whose command path matches the PtcRunner release raises at load time" do
      # Spec §5.3: "If the config loader detects PtcRunner configured
      # as an upstream of itself (by command path match), the server
      # MUST fail fast with an error pointing at the offending entry."
      #
      # Heuristic: a command whose basename is `ptc_runner_mcp`
      # (the configured release name) is rejected. Pre-fix the
      # loader silently accepted such configs and the recursion
      # would only manifest at Stdio handshake time.
      #
      # Discriminating signal: `Application.load_upstreams_config/1`
      # raises with a message that names the offending entry AND
      # includes the matching command path.
      tmp_dir = Path.join(System.tmp_dir!(), "phase1b-self-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      # Drop a fake "ptc_runner_mcp" executable in tmp_dir so the
      # `String.contains?(command, "/")` branch resolves to it.
      # The file's contents don't matter; only the path basename.
      offender = Path.join(tmp_dir, "ptc_runner_mcp")
      File.write!(offender, "#!/bin/sh\nexit 0\n")
      File.chmod!(offender, 0o755)

      cfg_path = Path.join(tmp_dir, "upstreams.json")

      File.write!(
        cfg_path,
        Jason.encode!(%{
          "upstreams" => %{
            "self-recurse" => %{
              "command" => offender
            }
          }
        })
      )

      args_map = PtcRunnerMcp.Application.parse_args(["--upstreams-config", cfg_path])

      assert_raise RuntimeError, fn ->
        PtcRunnerMcp.Application.load_upstreams_config(args_map)
      end

      # Capture-and-assert pattern: re-run inside a try/rescue to
      # inspect the error message contents. The spec mandates the
      # error "point at the offending entry."
      err =
        try do
          PtcRunnerMcp.Application.load_upstreams_config(args_map)
          flunk("expected self-as-upstream raise")
        rescue
          e in RuntimeError -> e
        end

      msg = Exception.message(err)

      assert msg =~ "self-as-upstream",
             "expected error to mention self-as-upstream, got: #{msg}"

      assert msg =~ "self-recurse",
             "expected error to name the offending upstream entry, got: #{msg}"

      assert msg =~ offender,
             "expected error to include the matching command path, got: #{msg}"
    end

    test "RELEASE_ROOT-resolved executable path is rejected too" do
      # Releases set RELEASE_ROOT; the rejection ALSO fires when the
      # configured command path equals `${RELEASE_ROOT}/bin/ptc_runner_mcp`,
      # even if the on-disk basename has been renamed (e.g. someone
      # symlinks the release binary as `mcp` and references THAT
      # path). The discriminating signal: setting RELEASE_ROOT to a
      # tmp dir, dropping a `bin/ptc_runner_mcp` file, and pointing
      # the JSON at that path — load raises.
      tmp_root =
        Path.join(System.tmp_dir!(), "phase1b-rel-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_root, "bin"))
      release_bin = Path.join([tmp_root, "bin", "ptc_runner_mcp"])
      File.write!(release_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(release_bin, 0o755)

      System.put_env("RELEASE_ROOT", tmp_root)

      on_exit(fn ->
        System.delete_env("RELEASE_ROOT")
        File.rm_rf(tmp_root)
      end)

      tmp_dir =
        Path.join(System.tmp_dir!(), "phase1b-self-rel-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      cfg_path = Path.join(tmp_dir, "upstreams.json")

      File.write!(
        cfg_path,
        Jason.encode!(%{
          "upstreams" => %{
            "release-recurse" => %{
              "command" => release_bin
            }
          }
        })
      )

      args_map = PtcRunnerMcp.Application.parse_args(["--upstreams-config", cfg_path])

      assert_raise RuntimeError, ~r/self-as-upstream/, fn ->
        PtcRunnerMcp.Application.load_upstreams_config(args_map)
      end
    end

    test "non-self upstreams pass through unchanged" do
      # Sanity floor: a normal config (e.g., `npx`) is NOT mistakenly
      # flagged. Pre-fix this path was always permissive; we re-assert
      # post-fix that the §5.3 guard is precisely scoped.
      tmp_dir =
        Path.join(System.tmp_dir!(), "phase1b-noself-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      cfg_path = Path.join(tmp_dir, "upstreams.json")

      File.write!(
        cfg_path,
        Jason.encode!(%{
          "upstreams" => %{
            "github" => %{
              "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-github"]
            }
          }
        })
      )

      args_map = PtcRunnerMcp.Application.parse_args(["--upstreams-config", cfg_path])

      [entry] = PtcRunnerMcp.Application.load_upstreams_config(args_map)
      assert entry.name == "github"
    end
  end
end
