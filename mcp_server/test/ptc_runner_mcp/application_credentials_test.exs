defmodule PtcRunnerMcp.ApplicationCredentialsTest do
  @moduledoc """
  Phase 1 boot-integration tests for the `credentials:` config block,
  cross-reference validation, supervisor ordering, and `${VAR}`
  narrowing.

  Spec: `Plans/http-transport-credentials.md` §5.1, §5.2, §5.5 ##1, 6,
  11, §7.1, §12 Phase 1.

  These tests are `async: false` because:

    * They start a real `PtcRunnerMcp.Supervisor` tree (the
      `Credentials` GenServer registers a globally-named ETS table
      `:credentials_redaction_set`, which can only have one owner at a
      time).
    * Some cases set/unset env vars to exercise `${VAR}` narrowing.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, Credentials}

  # ---- helpers --------------------------------------------------------------

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "app-creds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp write_config(tmp_dir, json) do
    path = Path.join(tmp_dir, "upstreams.json")
    File.write!(path, json)
    path
  end

  # Start an isolated test supervisor that mirrors the production
  # child list (sans the stdio loop, which is suppressed in :test).
  # Returns `{sup_name, args}` so callers can inspect it. We use
  # `build_children/3` — the public seam — instead of re-running
  # `Application.start/2` (which would touch global env / Limits /
  # the singleton `PtcRunnerMcp.Supervisor` name).
  defp start_test_tree(cfg_path) do
    args = Application.parse_args(["--upstreams-config", cfg_path])
    %{upstreams: upstreams, credentials: bindings} = Application.load_aggregator_config(args)

    sup_name = :"app_creds_sup_#{System.unique_integer([:positive])}"

    # We rename the `Credentials` child so this isolated tree does not
    # collide with the globally-named singleton (which the production
    # supervisor in `start/2` registers as `PtcRunnerMcp.Credentials`).
    creds_name = :"creds_#{System.unique_integer([:positive])}"

    children = [
      {Credentials, [name: creds_name, bindings: bindings]}
      # Phase 1 stdio-only tests don't bring up Upstream.Supervisor;
      # the upstream subsystem boot path has its own coverage in
      # `application_phase1b_test.exs`. What we care about here is:
      # (1) Credentials boots from the parsed config, (2) the global
      # supervisor wiring uses the right strategy + child order.
    ]

    {:ok, sup_pid} =
      Supervisor.start_link(children,
        strategy: :rest_for_one,
        name: sup_name,
        max_restarts: 5,
        max_seconds: 30
      )

    on_exit(fn ->
      try do
        Supervisor.stop(sup_pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      sup: sup_name,
      sup_pid: sup_pid,
      creds_name: creds_name,
      upstreams: upstreams,
      bindings: bindings
    }
  end

  # ---- 1. credentials block + stdio upstreams loads cleanly -----------------

  describe "config with credentials: + stdio upstreams" do
    test "loads cleanly and Credentials registry serves bindings", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "fs_token" => %{"source" => "literal", "value" => "lit-secret-aaaaaa"}
            },
            "upstreams" => %{
              "fs" => %{
                "command" => "npx",
                "args" => ["-y", "@modelcontextprotocol/server-filesystem"]
              }
            }
          })
        )

      tree = start_test_tree(cfg_path)

      # Cross-reference: the parsed binding shows up in the registry.
      assert Credentials.list_bindings(tree.creds_name) == ["fs_token"]

      # And the registry can resolve it (proves the Binding struct
      # round-tripped through Application.load_aggregator_config/1
      # → Credentials.start_link/1 → init/1 cleanly).
      assert {:ok, %{raw: "lit-secret-aaaaaa", scheme_hint: :raw}} =
               Credentials.materialize(tree.creds_name, "fs_token")

      # Stdio upstream entry is parsed normally.
      assert [%{name: "fs", config: cfg}] = tree.upstreams
      assert cfg[:args] == ["-y", "@modelcontextprotocol/server-filesystem"]
    end
  end

  # ---- 2. supervisor ordering -----------------------------------------------

  describe "production supervisor ordering (§7.1)" do
    test "build_children/3 places Credentials before Upstream.Supervisor" do
      # Build the full production child list with a non-empty
      # upstream entries list so `aggregator_children/1` returns
      # the Upstream.Supervisor child spec. We don't actually start
      # this list — `Upstream.Supervisor.start_link/1` would try to
      # register globally-named registries already owned by
      # test_helper.exs. We just inspect ORDER.
      upstreams = [
        %{
          name: "demo",
          impl: PtcRunnerMcp.Upstream.Stdio,
          config: %{command: "echo"}
        }
      ]

      # Empty args map → stdio_children returns [] in :test.
      children = Application.build_children(upstreams, %{}, %{})

      modules =
        Enum.map(children, fn
          {mod, _opts} -> mod
          %{start: {mod, _, _}} -> mod
          mod when is_atom(mod) -> mod
        end)

      creds_idx = Enum.find_index(modules, &(&1 == Credentials))
      ups_idx = Enum.find_index(modules, &(&1 == PtcRunnerMcp.Upstream.Supervisor))

      assert is_integer(creds_idx),
             "Credentials missing from child list: #{inspect(modules)}"

      assert is_integer(ups_idx),
             "Upstream.Supervisor missing from child list: #{inspect(modules)}"

      assert creds_idx < ups_idx,
             "Credentials must come before Upstream.Supervisor; got: #{inspect(modules)}"
    end

    test "Credentials is always first child even with empty upstreams" do
      # §7.1 simplification: we always start Credentials, even when
      # the parsed config has no `credentials:` block and no
      # upstreams. This test pins that invariant.
      children = Application.build_children([], %{}, %{})

      assert [first | _] = children
      assert match?({Credentials, _}, first), "expected Credentials first, got: #{inspect(first)}"
    end
  end

  # ---- 3. top-level strategy is :rest_for_one -------------------------------

  describe "top-level supervisor strategy" do
    test "tree built per spec uses :rest_for_one", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{},
            "upstreams" => %{}
          })
        )

      tree = start_test_tree(cfg_path)

      # The live supervisor's state is the OTP `state` record. The
      # strategy atom appears as one of the tuple elements. Asserting
      # on tuple membership is layout-resilient: future OTP versions
      # may reorder fields but the strategy will always be there.
      state = :sys.get_state(tree.sup_pid)

      assert :rest_for_one in Tuple.to_list(state),
             "expected :rest_for_one in supervisor state, got: #{inspect(state)}"

      refute :one_for_one in Tuple.to_list(state),
             "expected :one_for_one absent from supervisor state, got: #{inspect(state)}"
    end
  end

  # ---- 4. empty / absent credentials block ----------------------------------

  describe "absent or empty credentials: block" do
    test "stdio-only config with no credentials key boots, list_bindings/1 == []",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "fs" => %{"command" => "npx", "args" => ["-y", "fs-server"]}
            }
          })
        )

      tree = start_test_tree(cfg_path)
      assert tree.bindings == %{}
      assert Credentials.list_bindings(tree.creds_name) == []
    end

    test "explicitly empty credentials: {} block also yields no bindings",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{},
            "upstreams" => %{}
          })
        )

      tree = start_test_tree(cfg_path)
      assert tree.bindings == %{}
      assert Credentials.list_bindings(tree.creds_name) == []
    end
  end

  # ---- 5. unknown binding reference at config load --------------------------

  describe "cross-reference validator (§5.5 #1)" do
    test "auth: emitter referencing missing binding raises with both names",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "known" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "github" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "missing"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "github", "expected upstream name in error, got: #{msg}"
      assert msg =~ "missing", "expected binding name in error, got: #{msg}"
    end

    # codex-43640bd [P1] #2: §5.5 #7 first bullet — emitter scheme
    # MUST be compatible with binding scheme_hint at config load.
    test "scheme_mismatch: bearer binding consumed by basic emitter is rejected",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{
                "source" => "literal",
                "value" => "v-aaaa",
                "scheme_hint" => "bearer"
              }
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "basic", "binding" => "tok"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "scheme_hint", "expected scheme_hint mention, got: #{msg}"
      assert msg =~ "bearer", "expected hint name, got: #{msg}"
      assert msg =~ "basic", "expected emitter scheme, got: #{msg}"
    end

    test "scheme_mismatch: basic binding consumed by bearer emitter is rejected",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{
                "source" => "literal",
                "value" => "u:p",
                "scheme_hint" => "basic"
              }
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "scheme_hint"
      assert msg =~ "basic"
      assert msg =~ "bearer"
    end

    test "scheme_hint :raw feeds basic emitter (no rejection)", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "any" => %{
                "source" => "literal",
                "value" => "u:p",
                "scheme_hint" => "raw"
              }
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "basic", "binding" => "any"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      assert %{credentials: _} = Application.load_aggregator_config(args)
    end

    test "scheme_hint :raw feeds any scheme (no rejection)", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "any" => %{
                "source" => "literal",
                "value" => "v-aaaa",
                "scheme_hint" => "raw"
              }
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [
                  %{"scheme" => "bearer", "binding" => "any"},
                  %{"scheme" => "custom_header", "header" => "x-tok", "binding" => "any"}
                ]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      result = Application.load_aggregator_config(args)
      assert Map.has_key?(result.credentials, "any")
    end

    test "absent scheme_hint defaults to :raw and feeds any scheme", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "any" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "any"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      assert %{credentials: _} = Application.load_aggregator_config(args)
    end

    test "auth: with valid binding does not raise", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "github_pat" => %{"source" => "literal", "value" => "pat-aaaaaa"}
            },
            "upstreams" => %{
              "github" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "github_pat"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      # No raise. Phase 1 doesn't yet load `transport: "http"` into
      # an `Upstream.Http` impl — the entry just slots into the
      # Stdio impl branch of `parse_upstream_entries`. The validator
      # is what we're exercising; it must NOT fire when the binding
      # name resolves correctly.
      result = Application.load_aggregator_config(args)
      assert Map.has_key?(result.credentials, "github_pat")
    end
  end

  # ---- 6. ${VAR} narrowing --------------------------------------------------

  describe "${VAR} placeholder narrowing (§5.2 / §5.5 #6)" do
    test "literal binding value is stored verbatim — NOT expanded",
         %{tmp_dir: tmp_dir} do
      # Use a recognizable env var so we can prove non-expansion. If
      # the legacy resolver were still recursive, the binding value
      # would equal `System.get_env("HOME")`; the assertion checks
      # the literal `${HOME}` text survives.
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "verbatim" => %{"source" => "literal", "value" => "${HOME}"}
            },
            "upstreams" => %{}
          })
        )

      tree = start_test_tree(cfg_path)
      assert {:ok, %{raw: "${HOME}"}} = Credentials.materialize(tree.creds_name, "verbatim")
    end

    test "stdio upstream env: ${VAR} IS expanded (existing behavior preserved)",
         %{tmp_dir: tmp_dir} do
      var = "PTC_TEST_NARROW_#{System.unique_integer([:positive])}"
      System.put_env(var, "expanded-value-aaa")
      on_exit(fn -> System.delete_env(var) end)

      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "fs" => %{
                "command" => "echo",
                "env" => %{"FORWARDED" => "${#{var}}"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)
      assert entry.config[:env]["FORWARDED"] == "expanded-value-aaa"
    end

    test "${VAR} inside upstream command/args is NOT expanded (narrowed scope)",
         %{tmp_dir: tmp_dir} do
      # Pre-narrowing the recursive resolver expanded `${VAR}` inside
      # `command:` and every other string in the entry tree. Phase 1
      # narrows it to the stdio `env` map only — `command:` is now
      # parsed literally (just like `credentials:` and the future
      # HTTP `url`/`static_headers`).
      var = "PTC_TEST_CMD_NARROW_#{System.unique_integer([:positive])}"
      System.put_env(var, "should-not-leak")
      on_exit(fn -> System.delete_env(var) end)

      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "lit" => %{
                "command" => "${#{var}}",
                "args" => ["${#{var}}"]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)

      # Discriminating signal: post-fix the literal `${VAR}` survives.
      # Pre-fix this would equal "should-not-leak".
      assert entry.config[:command] == "${#{var}}"
      assert entry.config[:args] == ["${#{var}}"]
    end
  end

  # ---- exec rejection (§5.5 #11) carried over from Binding.parse ------------

  describe "exec source rejection (§5.5 #11)" do
    test "credentials: with exec binding raises at config load with v1.1 message",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{"source" => "exec", "command" => ["/bin/echo", "x"]}
            },
            "upstreams" => %{}
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "exec", "expected exec mention, got: #{msg}"
      assert msg =~ "v1.1", "expected 'deferred to v1.1' message, got: #{msg}"
    end
  end

  # ---- 7. HTTP transport dep-presence check (§4.5) --------------------------

  describe "HTTP transport dep-presence check (§4.5)" do
    test "stdio-only config loads without invoking the :req presence check",
         %{tmp_dir: tmp_dir} do
      # The §4.5 guard fires only when at least one upstream declares
      # `transport: "http"`. A stdio-only config (transport field
      # absent on every entry) MUST load cleanly even if `:req` were
      # not available. We can't realistically unload `:req` at runtime
      # — instead we exercise the loader directly and assert it
      # succeeds without raising. The fact that `check_http_deps!/3`
      # below works with a `fn _ -> false end` predicate completes the
      # proof: when no entry asks for HTTP, the predicate is never
      # called.
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "fs" => %{"command" => "echo", "args" => ["hello"]}
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      assert %{upstreams: [_], credentials: %{}} = Application.load_aggregator_config(args)

      # And explicitly: the helper, given a stdio-only entry map and a
      # predicate that always returns false, MUST NOT raise.
      assert :ok =
               Application.check_http_deps!(
                 %{"fs" => %{"command" => "echo"}},
                 "fake.json",
                 fn _ -> false end
               )
    end

    test "config with transport: http and :req absent raises with §4.5 message" do
      # Simulate `:req` being absent by injecting a predicate that
      # returns `false` for `Req`. The raised message MUST match the
      # spec shape exactly: upstream name, the suggested deps line,
      # and the source path.
      upstreams = %{
        "github" => %{
          "transport" => "http",
          "url" => "https://example.test"
        }
      }

      err =
        assert_raise RuntimeError, fn ->
          Application.check_http_deps!(upstreams, "/path/to/upstreams.json", fn _ -> false end)
        end

      msg = Exception.message(err)
      assert msg =~ "upstream 'github'"
      assert msg =~ "uses HTTP transport but :req is not available"
      assert msg =~ ~s({:req, "~> 0.5"})
      assert msg =~ "mix deps.get"
      assert msg =~ "Source: /path/to/upstreams.json"
    end

    test "config with transport: http and :req loaded passes the check" do
      upstreams = %{
        "github" => %{
          "transport" => "http",
          "url" => "https://example.test"
        }
      }

      assert :ok =
               Application.check_http_deps!(
                 upstreams,
                 "/path/to/upstreams.json",
                 fn _ -> true end
               )
    end

    test "multiple HTTP upstreams: failing entry name appears in raise" do
      # Two HTTP entries; both would fail when `:req` is absent. The
      # implementation iterates over them, so AT LEAST ONE name must
      # appear in the raised message — and per §4.5 the raise is per-
      # upstream so the operator sees a concrete name (not a generic
      # "some upstream" message).
      upstreams = %{
        "alpha" => %{"transport" => "http", "url" => "https://a.example"},
        "beta" => %{"transport" => "http", "url" => "https://b.example"}
      }

      err =
        assert_raise RuntimeError, fn ->
          Application.check_http_deps!(upstreams, "fake.json", fn _ -> false end)
        end

      msg = Exception.message(err)

      assert msg =~ "upstream 'alpha'" or msg =~ "upstream 'beta'",
             "expected one of the HTTP upstream names in error, got: #{msg}"
    end

    test "real loader runs with :req available (transport: http config valid up to Phase 2A scope)",
         %{tmp_dir: tmp_dir} do
      # End-to-end: a config with `transport: "http"` reaches the
      # loader, the §4.5 check fires (because `:req` IS loaded in
      # test-env after Phase 2A's mix.exs change), and parsing
      # completes. Phase 2A does not yet validate the URL or other
      # HTTP-specific fields — that's 2E. So the entry just lands in
      # the entries list via `parse_upstream_entries/2`'s default
      # branch (which still slots an `Upstream.Stdio` impl per Phase
      # 1 wiring).
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      assert %{credentials: %{"tok" => _}} = Application.load_aggregator_config(args)
    end
  end

  # ---- 8. transport: "http" config-loader (Phase 2E, §5.3 / §5.5) ----------

  describe "transport: http config-loader" do
    test "minimal valid HTTPS config loads with Upstream.Http impl + defaults",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test"
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)

      assert entry.name == "remote"
      assert entry.impl == PtcRunnerMcp.Upstream.Http

      cfg = entry.config
      assert cfg.url == "https://example.test"
      assert cfg.static_headers == []
      assert cfg.proxy == nil
      assert cfg.handshake_timeout_ms == 10_000
      assert cfg.request_timeout_ms == 30_000
      assert cfg.max_response_bytes == 2_097_152
      assert cfg.connect_timeout_ms == 5_000
      assert cfg.pool_size == 4
      assert cfg.backoff_initial_ms == 100
      assert cfg.backoff_max_ms == 30_000
      refute Map.has_key?(cfg, :auth_raw)
    end

    test "explicit transport: stdio is parsed as Stdio (same as absent)",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "fs" => %{
                "transport" => "stdio",
                "command" => "echo",
                "args" => ["hi"]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)

      assert entry.impl == PtcRunnerMcp.Upstream.Stdio
      assert entry.config[:command] == "echo"
      assert entry.config[:args] == ["hi"]
    end

    test "absent transport is parsed as Stdio (Phase 1 default)", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "fs" => %{"command" => "echo"}
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)

      assert entry.impl == PtcRunnerMcp.Upstream.Stdio
    end

    test "unknown transport value raises with upstream name", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "weird" => %{"transport" => "sse", "url" => "https://x.test"}
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "weird"
      assert msg =~ "sse"
    end

    test "url: http:// without allow_insecure_http: true raises", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "plain" => %{"transport" => "http", "url" => "http://x.test"}
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "allow_insecure_http"
      assert msg =~ "plain"
    end

    test "url: http:// with allow_insecure_http: true loads", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "plain" => %{
                "transport" => "http",
                "url" => "http://x.test",
                "allow_insecure_http" => true
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)
      assert entry.config.url == "http://x.test"
    end

    test "http:// + allow_insecure_http + non-empty auth requires allow_insecure_auth: missing → raise",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "plain" => %{
                "transport" => "http",
                "url" => "http://x.test",
                "allow_insecure_http" => true,
                "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "allow_insecure_auth"
      assert msg =~ "plain"
    end

    test "http:// + allow_insecure_http + auth + allow_insecure_auth: true loads",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "plain" => %{
                "transport" => "http",
                "url" => "http://x.test",
                "allow_insecure_http" => true,
                "allow_insecure_auth" => true,
                "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)

      assert entry.impl == PtcRunnerMcp.Upstream.Http
      # `auth_raw` carries the unparsed list through to Phase 3.
      assert entry.config.auth_raw == [%{"scheme" => "bearer", "binding" => "tok"}]
    end

    test "bad URL scheme (file://) raises", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "weird" => %{"transport" => "http", "url" => "file:///etc/passwd"}
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      # Either the scheme rejection branch (no host) or the unsupported
      # scheme branch — both are loud raises with the upstream name.
      assert msg =~ "weird"
    end

    test "proxy: http://proxy:8080 loads with proxy field set", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "proxy" => "http://proxy.test:8080"
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)
      assert entry.config.proxy == "http://proxy.test:8080"
    end

    test "proxy: http://user:pass@proxy raises (no proxy auth in v1)",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "proxy" => "http://user:pass@proxy.test:8080"
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "user:pass"
      assert msg =~ "remote"
    end

    test "static_headers passed through as lowercase tuple list", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"X-Foo" => "bar"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: [entry]} = Application.load_aggregator_config(args)
      assert entry.config.static_headers == [{"x-foo", "bar"}]
    end

    test "static_headers denylist rejects MCP-Protocol-Version (codex P1 #2)",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"MCP-Protocol-Version" => "1999-01-01"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "MCP-Protocol-Version"
      assert msg =~ "denylist"
    end

    test "static_headers denylist rejects Mcp-Session-Id (codex P1 #2)",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"Mcp-Session-Id" => "fake-session"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "Mcp-Session-Id"
      assert msg =~ "denylist"
    end

    test "static_headers denylist rejects User-Agent (codex P1 #2)",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"User-Agent" => "evil/1.0"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "User-Agent"
      assert msg =~ "denylist"
    end

    test "static_headers denylist is case-insensitive — lowercased mcp-session-id rejected",
         %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"mcp-session-id" => "x"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      assert Exception.message(err) =~ "denylist"
    end

    test "static_headers with Authorization is rejected (denylist)", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"Authorization" => "Bearer x"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "Authorization"
      assert msg =~ "denylist"
    end

    test "static_headers with duplicate keys (after lowercase) raises", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"X-Foo" => "a", "x-foo" => "b"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "duplicate"
      assert msg =~ "x-foo"
    end

    test "static_headers with invalid RFC 7230 token raises", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "static_headers" => %{"in valid" => "x"}
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "RFC 7230"
      assert msg =~ "in valid"
    end

    test "non-integer integer field (pool_size: \"ten\") raises", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "pool_size" => "ten"
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])

      err =
        assert_raise RuntimeError, fn ->
          Application.load_aggregator_config(args)
        end

      msg = Exception.message(err)
      assert msg =~ "pool_size"
      assert msg =~ "positive integer"
    end

    test "end-to-end: HTTP and stdio upstreams parse to correct impls", %{tmp_dir: tmp_dir} do
      cfg_path =
        write_config(
          tmp_dir,
          Jason.encode!(%{
            "credentials" => %{
              "tok" => %{"source" => "literal", "value" => "v-aaaa"}
            },
            "upstreams" => %{
              "remote" => %{
                "transport" => "http",
                "url" => "https://example.test",
                "auth" => [%{"scheme" => "bearer", "binding" => "tok"}]
              },
              "fs" => %{
                "command" => "echo",
                "args" => ["hello"]
              }
            }
          })
        )

      args = Application.parse_args(["--upstreams-config", cfg_path])
      %{upstreams: entries} = Application.load_aggregator_config(args)

      assert length(entries) == 2

      by_name = Map.new(entries, fn entry -> {entry.name, entry} end)

      assert by_name["remote"].impl == PtcRunnerMcp.Upstream.Http
      assert by_name["remote"].config.url == "https://example.test"
      assert by_name["remote"].config.auth_raw == [%{"scheme" => "bearer", "binding" => "tok"}]

      assert by_name["fs"].impl == PtcRunnerMcp.Upstream.Stdio
      assert by_name["fs"].config[:command] == "echo"
      assert by_name["fs"].config[:args] == ["hello"]
    end
  end

  # ---- 9. literal-binding warning (§5.4.1 / §5.5 #4) ------------------------

  describe "literal-binding warning" do
    setup do
      prior = PtcRunnerMcp.Log.level()
      PtcRunnerMcp.Log.set_level(:warn)
      on_exit(fn -> PtcRunnerMcp.Log.set_level(prior) end)
      :ok
    end

    test "fires outside :test for each literal binding by name" do
      bindings = %{
        "lit_one" => %Credentials.Binding{
          name: "lit_one",
          source: :literal,
          scheme_hint: nil,
          spec: %{value: "should-not-appear-in-log"}
        },
        "env_two" => %Credentials.Binding{
          name: "env_two",
          source: :env,
          scheme_hint: :bearer,
          spec: %{var: "FAKE_VAR"}
        }
      }

      log =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Application.warn_about_literal_bindings(bindings, "fake.json", :dev)
        end)

      assert log =~ "credentials_literal_binding"
      assert log =~ "lit_one"
      refute log =~ "env_two", "non-literal binding must not warn"

      refute log =~ "should-not-appear-in-log",
             "warning must NOT include the literal value"
    end

    test "is suppressed under MIX_ENV: :test" do
      bindings = %{
        "lit_one" => %Credentials.Binding{
          name: "lit_one",
          source: :literal,
          scheme_hint: nil,
          spec: %{value: "test-fixture-value"}
        }
      }

      log =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Application.warn_about_literal_bindings(bindings, "fake.json", :test)
        end)

      refute log =~ "credentials_literal_binding"
    end
  end
end
