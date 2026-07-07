defmodule PtcRunnerMcp.SessionsLifecycleTest do
  @moduledoc """
  Deterministic branch coverage for the stateful-sessions surface that the
  `:soak`-tagged churn test otherwise exercises only under load.

  These tests drive the REAL production paths:

    * `PtcRunnerMcp.Tools.call/1` for the public MCP lifecycle
      (`lisp_session_start` -> `_eval` -> `_inspect` -> `_forget` ->
      `_list` -> `_close`).
    * The `PtcRunnerMcp.Sessions` facade for the authorization boundary,
      the `session_busy` rejection, deterministic ttl/idle eviction, and
      the registry quota / tombstone / disabled branches.

  Pure-table assertions cover `Sessions.Config`, `Sessions.Limits`,
  `Sessions.Projection`, and `Sessions.Owner` derivation — the branches
  reachable only with direct input, not the dead `Owner.same?/2` and
  `Owner.hash/1` helpers.
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Evidence.Bundle, as: EvidenceBundle
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler, as: PreludeCompiler
  alias PtcRunner.PreludeStore
  alias PtcRunner.TraceLog.{Analyzer, Collector, Introspection}
  alias PtcRunner.Upstream.Runtime
  alias PtcRunnerMcp.{Application, JsonRpc, Log, McpTestHelpers, ResponseProfile, Sessions, Tools}
  alias PtcRunnerMcp.RootUpstreamRuntime
  alias PtcRunnerMcp.Sessions.{Config, Limits, Owner, Projection, Session}
  alias PtcRunnerMcp.Sessions.Policy
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TestSupport.SoakHelpers
  alias PtcRunnerMcp.{TurnLogCollector, TurnLogConfig}

  @schema Path.expand("../fixtures/openapi/observatory.openapi.json", __DIR__)
  @fixture_recv_timeout_ms 5_000

  # A second stdio owner with a *different* instance id. Because the
  # session is created under the process-wide stdio owner, this map is a
  # forged caller that should fail every authorization check.
  @forged_owner %{transport: :stdio, instance_id: "forged_other_instance"}

  setup do
    old_profile = ResponseProfile.current()
    # SoakHelpers.setup_sessions/1 stops stale session procs, installs the
    # config, resets the gate, starts the registry/supervisor, and
    # registers an on_exit that tears it all back down + resets config.
    SoakHelpers.setup_sessions(%{enabled: true})
    ResponseProfile.set(:structured)
    old_turn_log_config = TurnLogConfig.get()

    on_exit(fn ->
      ResponseProfile.set(old_profile)
      TurnLogConfig.set(old_turn_log_config)
      TurnLogConfig.put_collector(nil)
      Runtime.stop(RootUpstreamRuntime.name())
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "full lifecycle via Tools.call" do
    test "start response lists prompt-visible prelude namespaces with discovery forms" do
      Config.set(
        Map.put(Config.get(), :prelude_source, """
        (ns smoke
          "Smoke helpers with extra whitespace."
          {:visibility :prompt})

        (defn plus-one "Increment a number." [x] (+ x 1))

        (ns hidden
          "Hidden helpers."
          {:visibility :discoverable})

        (defn secret [] 42)
        """)
      )

      start = call("lisp_session_start", %{})

      assert start["isError"] == false
      assert start["structuredContent"]["status"] == "ok"

      assert start["structuredContent"]["preludes"] == [
               %{
                 "namespace" => "smoke",
                 "doc" => "Smoke helpers with extra whitespace.",
                 "discover" => "(ns-publics 'smoke)",
                 "source" => "(source smoke/plus-one)"
               }
             ]
    end

    test "start response omits preludes when no prompt-visible exports exist" do
      Config.set(
        Map.put(Config.get(), :prelude_source, """
        (ns hidden "Hidden helpers." {:visibility :discoverable})
        (defn secret [] 42)
        """)
      )

      start = call("lisp_session_start", %{})

      assert start["isError"] == false
      assert start["structuredContent"]["status"] == "ok"
      refute Map.has_key?(start["structuredContent"], "preludes")
    end

    test "configured prelude is attached to session evals" do
      Config.set(Map.put(Config.get(), :prelude_source, test_prelude_source()))
      sid = SoakHelpers.start_session()

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(smoke/plus-one 41)"
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["status"] == "ok"
      assert eval["structuredContent"]["result"] == "user=> 42"
    end

    @tag :tmp_dir
    test "role policy echoes role and filters ungranted PTC tools", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(
        Config.get()
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, PtcRunner.Evidence.prelude_source())
        |> Map.put(:runtime_prelude, nil)
        |> Map.put(:policy, role_policy!("analyst", ptc_tools: ["evidence_bundle"]))
      )

      start = call("lisp_session_start", %{"role" => "analyst"})

      assert start["isError"] == false
      assert start["structuredContent"]["role"] == "analyst"
      assert start["structuredContent"]["grant_fingerprint"] =~ "sha256:"
      sid = start["structuredContent"]["session_id"]

      unrelated =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(+ 1 2)"
        })

      assert unrelated["isError"] == false
      assert unrelated["structuredContent"]["result"] == "user=> 3"

      publics =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(keys (ns-publics 'evidence))"
        })

      assert publics["isError"] == false
      assert publics["structuredContent"]["result"] =~ "bundle"
      refute publics["structuredContent"]["result"] =~ "read"
      refute publics["structuredContent"]["result"] =~ "page"

      source =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(source evidence/read)"
        })

      assert source["isError"] == false
      assert source["structuredContent"]["prints"] == ["no source available for evidence/read"]

      helper_source =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(source evidence/first-opts)"
        })

      assert helper_source["isError"] == false
      assert [private_helper] = helper_source["structuredContent"]["prints"]
      assert private_helper =~ "(defn- first-opts"

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(evidence/read "summary")|
        })

      assert eval["isError"] == true
      assert eval["structuredContent"]["message"] =~ "evidence/read"
    end

    test "outer policy filters session tools/list and tools/call" do
      Config.set(%{Config.get() | policy: outer_policy!(["lisp_session_start"])})

      names = Tools.list()["tools"] |> Enum.map(& &1["name"])
      assert "lisp_session_start" in names
      refute "lisp_session_eval" in names

      env = call("lisp_session_eval", %{"session_id" => "ptcs_nope", "program" => "(+ 1 2)"})
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "unknown_tool"
    end

    test "outer policy filters JSON-RPC async session eval path" do
      Config.set(%{Config.get() | policy: outer_policy!(["lisp_session_start"])})

      frame = %{
        "jsonrpc" => "2.0",
        "id" => 41,
        "method" => "tools/call",
        "params" => %{
          "name" => "lisp_session_eval",
          "arguments" => %{"session_id" => "ptcs_nope", "program" => "(+ 1 2)"}
        }
      }

      assert {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})
      refute match?({:async_call, _, _, _, _, _}, reply)
      assert reply["result"]["isError"] == true
      assert reply["result"]["structuredContent"]["reason"] == "unknown_tool"
    end

    test "role policy rejects malformed and unknown requested roles" do
      Config.set(%{Config.get() | policy: role_policy!("analyst")})

      malformed = call("lisp_session_start", %{"role" => "bad role"})
      assert malformed["isError"] == true
      assert malformed["structuredContent"]["reason"] == "session_args_error"
      assert malformed["structuredContent"]["message"] =~ "invalid role"

      unknown = call("lisp_session_start", %{"role" => "reviewer"})
      assert unknown["isError"] == true
      assert unknown["structuredContent"]["reason"] == "session_args_error"
      assert unknown["structuredContent"]["message"] =~ "unknown session role"
    end

    test "explicit empty selected preludes keeps configured runtime prelude available" do
      Config.set(Map.put(Config.get(), :prelude_source, test_prelude_source()))

      start = call("lisp_session_start", %{"preludes" => []})

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(smoke/plus-one 41)"
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["status"] == "ok"
      assert eval["structuredContent"]["result"] == "user=> 42"
    end

    test "configured runtime prelude does not receive store read backing tools implicitly" do
      {:ok, store} = PreludeStore.new()

      {:ok, _candidate} =
        PreludeStore.write(store, "picked", """
        (ns picked)
        (defn value [] 1)
        """)

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:prelude_source, """
        (ns operator {:visibility :prompt})
        (defn list-store [] (tool/prelude_store_list {}))
        """)
      )

      sid = SoakHelpers.start_session()

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(operator/list-store)"
        })

      assert eval["isError"] == true
      assert eval["structuredContent"]["reason"] == "prelude_attach_failed"
      assert eval["structuredContent"]["message"] =~ "prelude_store_list"
    end

    test "start accepts selected preludes and freezes them for eval and list" do
      {:ok, store} = PreludeStore.new()

      v1 = """
      (ns picked "Selected helpers." {:visibility :prompt})
      (defn value [] 1)
      """

      v2 = """
      (ns picked "Selected helpers." {:visibility :prompt})
      (defn value [] 2)
      """

      {:ok, first} = PreludeStore.write(store, "picked", v1)
      Config.set(Config.get() |> Map.put(:prelude_store, store))

      start = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]

      assert start["structuredContent"]["prelude_refs"] == [
               %{
                 "id" => "picked",
                 "version" => 1,
                 "checksum" => first.checksum,
                 "origin" => "memory",
                 "required_by" => []
               }
             ]

      assert Enum.find(start["structuredContent"]["preludes"], &(&1["namespace"] == "prelude")) ==
               %{
                 "namespace" => "prelude",
                 "doc" => "Read versioned capability preludes.",
                 "discover" => "(ns-publics 'prelude)",
                 "source" => "(source prelude/deps)"
               }

      assert Enum.find(start["structuredContent"]["preludes"], &(&1["namespace"] == "picked")) ==
               %{
                 "namespace" => "picked",
                 "doc" => "Selected helpers.",
                 "discover" => "(ns-publics 'picked)",
                 "source" => "(source picked/value)"
               }

      {:ok, _second} = PreludeStore.write(store, "picked", v2)

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(picked/value)"
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["result"] == "user=> 1"

      listed = call("lisp_session_list_preludes", %{"session_id" => sid})

      assert listed["isError"] == false

      assert listed["structuredContent"]["prelude_refs"] ==
               start["structuredContent"]["prelude_refs"]
    end

    @tag :tmp_dir
    test "selected preludes compose with configured evidence bundle", %{tmp_dir: dir} do
      {:ok, store} = PreludeStore.new()

      {:ok, candidate} =
        PreludeStore.write(store, "picked", """
        (ns picked "Selected helpers." {:visibility :prompt})
        (defn value [] 7)
        """)

      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, PtcRunner.Evidence.prelude_source())
        |> Map.put(:runtime_prelude, nil)
      )

      start = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]

      checksum = candidate.checksum

      assert [
               %{
                 "id" => "picked",
                 "version" => 1,
                 "checksum" => ^checksum,
                 "origin" => "memory",
                 "required_by" => []
               }
             ] = start["structuredContent"]["prelude_refs"]

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|[(picked/value) (get (evidence/read "summary") "content")]|
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["status"] == "ok"
      assert eval["structuredContent"]["result"] =~ "7"
      assert eval["structuredContent"]["result"] =~ "operator-selected facts"
    end

    test "role policy requires exact prelude refs" do
      {:ok, store} = PreludeStore.new()

      {:ok, _first} =
        PreludeStore.write(store, "picked", """
        (ns picked {:visibility :prompt})
        (defn value [] 1)
        """)

      {:ok, _second} =
        PreludeStore.write(store, "picked", """
        (ns picked {:visibility :prompt})
        (defn value [] 2)
        """)

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:policy, role_policy!("analyst", preludes: ["picked@1"]))
      )

      allowed = call("lisp_session_start", %{"role" => "analyst", "preludes" => ["picked@1"]})
      assert allowed["isError"] == false

      denied = call("lisp_session_start", %{"role" => "analyst", "preludes" => ["picked@2"]})
      assert denied["isError"] == true
      assert denied["structuredContent"]["message"] =~ "not granted"
    end

    @tag :tmp_dir
    test "operator prelude plus evidence stays mutually exclusive with selected preludes", %{
      tmp_dir: dir
    } do
      {:ok, store} = PreludeStore.new()

      {:ok, _candidate} =
        PreludeStore.write(store, "picked", """
        (ns picked "Selected helpers." {:visibility :prompt})
        (defn value [] 7)
        """)

      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, operator_prelude_source_with_evidence())
        |> Map.put(:runtime_prelude, nil)
      )

      start = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert start["isError"] == true
      assert start["structuredContent"]["reason"] == "session_args_error"

      assert start["structuredContent"]["message"] =~
               ":runtime_prelude/:prelude and :preludes are mutually exclusive"
    end

    test "read-only selected prelude sessions can introspect store forms without write wrappers" do
      {:ok, store} = PreludeStore.new()

      {:ok, _candidate} =
        PreludeStore.write(store, "picked", """
        (ns picked "Selected helpers." {:visibility :prompt})
        (defn value [] 1)
        """)

      Config.set(Config.get() |> Map.put(:prelude_store, store))

      start = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      forms =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(count (prelude/forms "picked"))|
        })

      assert forms["isError"] == false
      assert forms["structuredContent"]["result"] == "user=> 1"

      write_attempt =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(prelude/write {:id "new" :source "(ns new)"})|
        })

      assert write_attempt["isError"] == true
      assert write_attempt["structuredContent"]["reason"] in ["invalid_form", "unbound_var"]
      assert write_attempt["structuredContent"]["message"] =~ "prelude/write"
    end

    test "selected preludes can be pinned by version and checksum" do
      {:ok, store} = PreludeStore.new()

      {:ok, first} =
        PreludeStore.write(store, "picked", """
        (ns picked)
        (defn value [] 1)
        """)

      {:ok, _second} =
        PreludeStore.write(store, "picked", """
        (ns picked)
        (defn value [] 2)
        """)

      Config.set(Config.get() |> Map.put(:prelude_store, store))

      start =
        call("lisp_session_start", %{
          "preludes" => [%{"id" => "picked", "version" => 1, "checksum" => first.checksum}]
        })

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(picked/value)"
        })

      assert eval["structuredContent"]["result"] == "user=> 1"

      mismatch =
        call("lisp_session_start", %{
          "preludes" => [%{"id" => "picked", "version" => 1, "checksum" => "bad"}]
        })

      assert mismatch["isError"] == true
      assert mismatch["structuredContent"]["reason"] == "session_args_error"
      assert mismatch["structuredContent"]["message"] =~ "checksum"
    end

    test "direct start_session resolves selected preludes before registry startup" do
      {:ok, store} = PreludeStore.new()

      {:ok, first} =
        PreludeStore.write(store, "picked", """
        (ns picked)
        (defn value [] 1)
        """)

      Config.set(Config.get() |> Map.put(:prelude_store, store))

      assert {:ok, %{"session_id" => sid, "prelude_refs" => refs}} =
               Sessions.start_session(nil, %{preludes: ["picked"]})

      assert refs == [
               %{
                 "id" => "picked",
                 "version" => 1,
                 "checksum" => first.checksum,
                 "origin" => "memory",
                 "required_by" => []
               }
             ]

      assert {:ok, %{"prelude_refs" => ^refs}} = Sessions.list_preludes(sid, nil)

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(picked/value)"
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["result"] == "user=> 1"
    end

    test "strict_transitive_calls rejects MCP session calls into transitive preludes" do
      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "base", """
        (ns base)
        (defn helper [x] (str "helper:" x))
        """)

      {:ok, _audit} =
        PreludeStore.write(
          store,
          "audit",
          """
          (ns audit)
          (defn check [x] (base/helper x))
          """,
          %{"requires_preludes" => ["base"]}
        )

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:policy, role_policy!("strict", strict_transitive_calls: true))
      )

      {:ok, %{"session_id" => sid}} =
        Sessions.start_session(nil, %{role: "strict", preludes: ["audit"]})

      internal =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(audit/check "x")|
        })

      assert internal["isError"] == false
      assert internal["structuredContent"]["result"] == ~S|user=> "helper:x"|

      transitive =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(base/helper "x")|
        })

      assert transitive["isError"] == true
      assert transitive["structuredContent"]["message"] =~ "transitive dependency of `audit`"
      assert transitive["structuredContent"]["message"] =~ "attach it directly"

      {:ok, %{"session_id" => direct_sid}} =
        Sessions.start_session(nil, %{role: "strict", preludes: ["audit", "base"]})

      direct =
        call("lisp_session_eval", %{
          "session_id" => direct_sid,
          "program" => ~S|(base/helper "x")|
        })

      assert direct["isError"] == false
      assert direct["structuredContent"]["result"] == ~S|user=> "helper:x"|
    end

    @tag :tmp_dir
    test "scoped_base_surface masks transitive prelude discovery without restricting execution",
         %{
           tmp_dir: dir
         } do
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "base", """
        (ns base "Base helpers." {:visibility :prompt})
        (defn helper "Used helper." [x] (str "helper:" x))
        (defn unused "Debug helper." [x] (str "unused:" x))
        """)

      {:ok, _audit} =
        PreludeStore.write(
          store,
          "audit",
          """
          (ns audit "Audit helpers." {:visibility :prompt})
          (defn check [x] (base/helper x))
          (defn- unused-path [x] (base/unused x))
          """,
          %{"requires_preludes" => ["base"]}
        )

      Config.set(%{Config.get() | prelude_store: store})

      start =
        call("lisp_session_start", %{
          "preludes" => ["audit"],
          "scoped_base_surface" => true
        })

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]
      assert start["structuredContent"]["scoped_base_surface"] == true

      assert start["structuredContent"]["prelude_presentation"] == %{
               "scoped_base_surface" => true,
               "masked_namespaces" => ["base"],
               "fallback_warnings" => []
             }

      assert %{"namespace" => "base", "source" => "(source base/helper)"} =
               Enum.find(start["structuredContent"]["preludes"], &(&1["namespace"] == "base"))

      refute inspect(start["structuredContent"]["preludes"]) =~ "unused"

      ns_publics =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(ns-publics 'base)|
        })

      assert ns_publics["isError"] == false
      assert ns_publics["structuredContent"]["result"] =~ "helper"
      refute ns_publics["structuredContent"]["result"] =~ "unused"

      masked_dir =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(dir 'base)|
        })

      assert masked_dir["structuredContent"]["result"] =~ "helper"
      refute masked_dir["structuredContent"]["result"] =~ "unused"

      full_dir =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(dir 'base {:full true})|
        })

      assert full_dir["structuredContent"]["result"] =~ "helper"
      assert full_dir["structuredContent"]["result"] =~ "unused"

      apropos =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(apropos "unused")|
        })

      refute apropos["structuredContent"]["result"] =~ "base/unused"

      meta =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(meta 'base/unused)|
        })

      assert meta["structuredContent"]["result"] =~ "base/unused"

      source =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(source 'base/unused)|
        })

      assert source["structuredContent"]["prints"] |> Enum.join("\n") =~ "defn unused"

      direct_call =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(base/unused "x")|
        })

      assert direct_call["structuredContent"]["result"] == ~S|user=> "unused:x"|

      {:ok, %{"session_id" => direct_sid}} =
        Sessions.start_session(nil, %{
          preludes: ["audit", "base"],
          scoped_base_surface: true
        })

      direct_ns = Sessions.eval(direct_sid, ~S|(ns-publics 'base)|)
      assert {:ok, direct_response} = direct_ns
      assert direct_response["result"] =~ "helper"
      assert direct_response["result"] =~ "unused"

      stop_turn_log!()

      turns = path |> Analyzer.load() |> Analyzer.session_turns(sid)

      full_dir_turn =
        Enum.find(turns, fn turn ->
          preview = get_in(turn, ["data", "result_preview"])
          is_binary(preview) and preview =~ "unused"
        end)

      assert [catalog_op] = get_in(full_dir_turn, ["data", "catalog_ops"])
      assert catalog_op["operation"] == "dir"
      assert catalog_op["args"] == %{"server" => "base", "opts" => %{"full" => true}}
      assert catalog_op["outcome"] == "ok"

      assert get_in(full_dir_turn, [
               "data",
               "prelude_presentation",
               "scoped_base_surface"
             ]) == true

      assert get_in(full_dir_turn, [
               "data",
               "prelude_presentation",
               "masked_namespaces"
             ]) == ["base"]

      apropos_turn =
        Enum.find(turns, fn turn ->
          get_in(turn, ["data", "program"]) == ~S|(apropos "unused")|
        end)

      assert [apropos_op] = get_in(apropos_turn, ["data", "catalog_ops"])
      assert apropos_op["operation"] == "apropos"
      assert apropos_op["args"] == %{"query" => "unused"}
      assert apropos_op["outcome"] == "ok"
    end

    @tag :tmp_dir
    test "scoped_base_surface records before after catalog measurement with no task regression",
         %{tmp_dir: dir} do
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "paged_base", """
        (ns paged_base "Paged base helpers." {:visibility :prompt})
        (defn sample [x] (str "sample:" x))
        (defn page-count [x] (str "count:" x))
        (defn page-window [x] (str "window:" x))
        (defn page-token [x] (str "token:" x))
        (defn fold-pages [x] (str "fold:" x))
        (defn describe-page [x] (str "describe:" x))
        """)

      {:ok, _audit} =
        PreludeStore.write(
          store,
          "paged_audit",
          """
          (ns paged_audit "Paged audit helpers." {:visibility :prompt})
          (defn check [x] (paged_base/sample x))
          """,
          %{"requires_preludes" => ["paged_base"]}
        )

      Config.set(%{Config.get() | prelude_store: store})

      before_measurement = measured_scoped_base_session("before", false)
      after_measurement = measured_scoped_base_session("after", true)

      stop_turn_log!()

      events = Analyzer.load(path)
      tools = Introspection.tools(path)

      assert %{"catalog_ops" => 1, "failed" => 0} =
               tools["log_counters"].(%{"tags" => %{"stage" => "before", "cell" => "dir"}})

      assert %{"catalog_ops" => 1, "failed" => 0} =
               tools["log_counters"].(%{"tags" => %{"stage" => "after", "cell" => "dir"}})

      before_dir = single_tagged_turn(events, "before", "dir")
      after_dir = single_tagged_turn(events, "after", "dir")

      assert [before_op] = get_in(before_dir, ["data", "catalog_ops"])
      assert [after_op] = get_in(after_dir, ["data", "catalog_ops"])
      assert before_op["operation"] == "dir"
      assert after_op["operation"] == "dir"
      assert before_op["args"] == %{"server" => "paged_base"}
      assert after_op["args"] == %{"server" => "paged_base"}

      before_preview = get_in(before_dir, ["data", "result_preview"])
      after_preview = get_in(after_dir, ["data", "result_preview"])

      assert before_preview =~ "sample"
      assert before_preview =~ "fold-pages"
      assert before_preview =~ "describe-page"
      assert after_preview =~ "sample"
      refute after_preview =~ "fold-pages"
      refute after_preview =~ "describe-page"

      assert before_measurement.result == ~S|user=> "sample:case-1"|
      assert after_measurement.result == before_measurement.result
    end

    test "scoped_base_surface fails open when pinned presentation metadata is missing" do
      direct = %{
        id: "audit",
        version: 1,
        checksum: "audit-checksum",
        namespaces: ["audit"],
        form_graph: %{
          "audit" => %{
            "check" => %{dep_calls: %{transitive: ["base/helper"]}}
          }
        },
        required_by: []
      }

      transitive = %{
        id: "base",
        namespaces: ["base"],
        form_graph: %{"base" => %{}},
        required_by: ["audit"]
      }

      assert %{export_mask: nil, warnings: [warning]} =
               Sessions.__prelude_presentation_for_test__([transitive, direct], ["audit"], true)

      assert warning =~ "missing presentation metadata"
    end

    test "scoped_base_surface fails open when public graph entries lack dependency metadata" do
      direct = %{
        id: "audit",
        version: 1,
        checksum: "audit-checksum",
        namespaces: ["audit"],
        form_graph: %{
          "audit" => %{
            "check" => %{visibility: :public}
          }
        },
        required_by: []
      }

      transitive = %{
        id: "base",
        version: 1,
        checksum: "base-checksum",
        namespaces: ["base"],
        form_graph: %{
          "base" => %{
            "helper" => %{visibility: :public, dep_calls: %{transitive: []}}
          }
        },
        required_by: ["audit"]
      }

      assert %{export_mask: nil, warnings: [warning]} =
               Sessions.__prelude_presentation_for_test__([transitive, direct], ["audit"], true)

      assert warning =~ "missing presentation metadata"
    end

    test "start projection surfaces scoped_base_surface fallback warnings" do
      response =
        Projection.start(%{
          id: "sess-warning",
          expires_at: DateTime.utc_now(),
          limits: Config.session_limits(),
          scoped_base_surface: true,
          prelude_presentation: %{export_mask: nil, warnings: ["missing metadata"]},
          preludes: []
        })

      assert response["prelude_presentation"] == %{
               "scoped_base_surface" => true,
               "masked_namespaces" => [],
               "fallback_warnings" => ["missing metadata"]
             }
    end

    test "scoped_base_surface follows reachable exports through dependency chains" do
      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "base", """
        (ns base "Base helpers." {:visibility :prompt})
        (defn helper [x] (str "helper:" x))
        (defn unused [x] (str "unused:" x))
        """)

      {:ok, _mid} =
        PreludeStore.write(
          store,
          "mid",
          """
          (ns mid "Middle helpers." {:visibility :prompt})
          (defn run [x] (base/helper x))
          """,
          %{"requires_preludes" => ["base"]}
        )

      {:ok, _app} =
        PreludeStore.write(
          store,
          "app",
          """
          (ns app "App helpers." {:visibility :prompt})
          (defn go [x] (mid/run x))
          """,
          %{"requires_preludes" => ["mid"]}
        )

      Config.set(%{Config.get() | prelude_store: store})

      start =
        call("lisp_session_start", %{
          "preludes" => ["app"],
          "scoped_base_surface" => true
        })

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]

      assert %{"namespace" => "mid", "source" => "(source mid/run)"} =
               Enum.find(start["structuredContent"]["preludes"], &(&1["namespace"] == "mid"))

      assert %{"namespace" => "base", "source" => "(source base/helper)"} =
               Enum.find(start["structuredContent"]["preludes"], &(&1["namespace"] == "base"))

      refute inspect(start["structuredContent"]["preludes"]) =~ "unused"

      base_publics =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(ns-publics 'base)|
        })

      assert base_publics["structuredContent"]["result"] =~ "helper"
      refute base_publics["structuredContent"]["result"] =~ "unused"

      app_call =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(app/go "x")|
        })

      assert app_call["structuredContent"]["result"] == ~S|user=> "helper:x"|
    end

    test "scoped_base_surface derives reachability from role-filtered direct exports" do
      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "base", """
        (ns base "Base helpers." {:visibility :prompt})
        (defn helper [x] (str "helper:" x))
        (defn unused [x] (str "unused:" x))
        """)

      {:ok, _audit} =
        PreludeStore.write(
          store,
          "audit",
          """
          (ns audit "Audit helpers." {:visibility :prompt})
          (defn visible [x] (base/helper x))
          (defn blocked [x]
            (tool/call {:server "crm" :tool "get_user" :args {}})
            (base/unused x))
          """,
          %{"requires_preludes" => ["base"]}
        )

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:policy, role_policy!("analyst", upstream_tools: []))
      )

      start =
        call("lisp_session_start", %{
          "role" => "analyst",
          "preludes" => ["audit"],
          "scoped_base_surface" => true
        })

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]

      assert inspect(start["structuredContent"]["preludes"]) =~ "base/helper"
      refute inspect(start["structuredContent"]["preludes"]) =~ "base/unused"
      refute inspect(start["structuredContent"]["preludes"]) =~ "audit/blocked"

      base_publics =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(ns-publics 'base)|
        })

      assert base_publics["structuredContent"]["result"] =~ "helper"
      refute base_publics["structuredContent"]["result"] =~ "unused"
    end

    @tag :tmp_dir
    test "relaxed transitive prelude sessions are marked in turn evidence", %{tmp_dir: dir} do
      {:ok, store} = PreludeStore.new()

      {:ok, _base} =
        PreludeStore.write(store, "base", """
        (ns base)
        (defn helper [x] (str "helper:" x))
        """)

      {:ok, _audit} =
        PreludeStore.write(
          store,
          "audit",
          """
          (ns audit)
          (defn check [x] (base/helper x))
          """,
          %{"requires_preludes" => ["base"]}
        )

      Config.set(%{Config.get() | prelude_store: store, policy: role_policy!("relaxed")})
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} =
        Sessions.start_session(nil, %{role: "relaxed", preludes: ["audit"]})

      assert {:ok, _response} = Sessions.eval(sid, ~S|(base/helper "x")|)
      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)

      assert turn["data"]["prelude_call_policy"] == %{
               "strict_transitive_calls" => false,
               "relaxed_transitive_calls" => true,
               "direct_namespaces" => ["audit"],
               "transitive_namespaces" => ["base"]
             }
    end

    test "start rejects selected preludes when a configured prelude is already attached" do
      {:ok, store} = PreludeStore.new()

      {:ok, _candidate} =
        PreludeStore.write(store, "picked", """
        (ns picked)
        (defn value [] 1)
        """)

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:prelude_source, test_prelude_source())
      )

      rejected = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert rejected["isError"] == true
      assert rejected["structuredContent"]["reason"] == "session_args_error"
      assert rejected["structuredContent"]["message"] =~ "mutually exclusive"
    end

    test "start rejects preludes without configured store and malformed preludes arg" do
      missing_store = call("lisp_session_start", %{"preludes" => ["picked"]})

      assert missing_store["isError"] == true
      assert missing_store["structuredContent"]["reason"] == "session_args_error"
      assert missing_store["structuredContent"]["message"] =~ ":prelude_store is required"

      malformed = call("lisp_session_start", %{"preludes" => "picked"})

      assert malformed["isError"] == true
      assert malformed["structuredContent"]["reason"] == "session_args_error"
      assert malformed["structuredContent"]["message"] =~ "preludes must be an array"

      leaked =
        call("lisp_session_start", %{
          "preludes" => [
            %{
              "id" => "picked",
              "version" => 1,
              "source" => "(ns secret) (def token \"do-not-echo\")"
            }
          ]
        })

      assert leaked["isError"] == true
      assert leaked["structuredContent"]["reason"] == "session_args_error"
      assert leaked["structuredContent"]["message"] =~ "preludes[0]"
      refute leaked["structuredContent"]["message"] =~ "do-not-echo"

      string_leak =
        call("lisp_session_start", %{
          "preludes" => ["(ns secret) (def token \"do-not-echo\")"]
        })

      assert string_leak["isError"] == true
      assert string_leak["structuredContent"]["reason"] == "session_args_error"
      assert string_leak["structuredContent"]["message"] =~ "preludes[0]"
      refute string_leak["structuredContent"]["message"] =~ "do-not-echo"

      {:ok, store} = PreludeStore.new()
      Config.set(Config.get() |> Map.put(:prelude_store, store))

      string_leak_with_store =
        call("lisp_session_start", %{
          "preludes" => ["(ns secret) (def token \"do-not-echo\")"]
        })

      assert string_leak_with_store["isError"] == true
      assert string_leak_with_store["structuredContent"]["reason"] == "session_args_error"
      assert string_leak_with_store["structuredContent"]["message"] =~ "preludes[0]"
      refute string_leak_with_store["structuredContent"]["message"] =~ "do-not-echo"
    end

    test "configured prelude source discovery is visible in session eval output" do
      Config.set(Map.put(Config.get(), :prelude_source, test_prelude_source()))
      sid = SoakHelpers.start_session()

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(source smoke/plus-one)"
        })

      assert eval["isError"] == false
      assert eval["structuredContent"]["status"] == "ok"
      assert [source] = eval["structuredContent"]["prints"]
      assert source =~ "(defn plus-one"
      assert get_in(eval, ["content", Access.at(0), "text"]) =~ "(defn plus-one"
    end

    test "configured prelude is attached to one-shot lisp_eval" do
      Config.set(%{enabled: false, prelude_source: test_prelude_source()})

      eval =
        Tools.call(%{"name" => "lisp_eval", "arguments" => %{"program" => "(smoke/plus-one 4)"}})

      assert eval["isError"] == false
      assert eval["structuredContent"]["status"] == "ok"
      assert eval["structuredContent"]["result"] == "user=> 5"
    end

    test "start -> eval -> inspect(all views) -> forget -> list -> close" do
      sid = SoakHelpers.start_session()

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(do (println \"hello\") (def x 41) (def y 2) (+ x y))"
        })

      assert eval["isError"] == false
      sc = eval["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["memory"]["changed_keys"] == ["x", "y"]
      assert sc["memory"]["stored_keys"] == ["x", "y"]
      assert sc["session"]["turn"] == 1
      refute Map.has_key?(sc, "feedback")

      # Every inspect view must shape distinctly and stay authorized.
      for view <- ~w(overview memory prints tool_calls history limits) do
        r = call("lisp_session_inspect", %{"session_id" => sid, "view" => view})
        assert r["isError"] == false
        vsc = r["structuredContent"]
        assert vsc["status"] == "ok"
        assert vsc["view"] == view
        assert vsc["session_id"] == sid
        # Each view carries its committed metadata summary.
        assert vsc["session"]["binding_count"] == 2
      end

      # View-specific shaping branches.
      mem = inspect_view(sid, "memory")
      assert mem["stored_keys"] == ["x", "y"]
      assert mem["text"] =~ "x"

      prints = inspect_view(sid, "prints")
      assert prints["prints"] == ["hello"]

      limits = inspect_view(sid, "limits")
      assert is_map(limits["limits"])
      assert is_list(limits["top_bindings"])

      # forget a single binding
      forget =
        call("lisp_session_forget", %{"session_id" => sid, "bindings" => ["x"]})

      fsc = forget["structuredContent"]
      assert fsc["status"] == "ok"
      assert fsc["removed_bindings"] == ["x"]
      assert fsc["stored_keys"] == ["y"]

      # list shows the single live session
      list = call("lisp_session_list", %{})
      lsc = list["structuredContent"]
      assert lsc["status"] == "ok"
      assert lsc["count"] == 1
      assert [session] = lsc["sessions"]
      assert session["session_id"] == sid

      # close
      close = call("lisp_session_close", %{"session_id" => sid})
      csc = close["structuredContent"]
      assert csc["status"] == "ok"
      assert csc["closed"] == true
      assert csc["session_id"] == sid
    end

    test "session memory preserves nested keyword values across eval turns" do
      sid = SoakHelpers.start_session()

      first =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(def m2 {:page {:parse :jsonl}})"
        })

      assert first["isError"] == false

      closure_call =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(do (defn touch [x] x) (touch 1))"
        })

      assert closure_call["isError"] == false

      second =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(keyword? (get (get m2 :page) :parse))"
        })

      assert second["isError"] == false
      assert second["structuredContent"]["result"] == "user=> true"
    end

    test "session turn history preserves keyword return values across eval turns" do
      sid = SoakHelpers.start_session()

      first =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ":jsonl"
        })

      assert first["isError"] == false
      assert first["structuredContent"]["result"] == "user=> :jsonl"

      second =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(keyword? *1)"
        })

      assert second["isError"] == false
      assert second["structuredContent"]["result"] == "user=> true"
    end

    test "session memory sanitizes nested runtime callables across eval turns" do
      sid = SoakHelpers.start_session()
      owner = Owner.stdio()
      {:ok, meta} = SessionsRegistry.lookup(sid)
      request_id = make_ref()
      program = "(def m {:f tool/echo :xs [tool/echo] :parse :jsonl})"

      {:ok, snapshot} =
        Session.begin_eval(meta.pid, owner, request_id, %{program: program})

      result =
        Sessions.run_snapshot(snapshot, program, %{
          tools: %{"echo" => fn args -> args end}
        })

      assert {:ok, %{"status" => "ok"}} =
               Session.commit_eval(meta.pid, owner, request_id, result, %{})

      second =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" =>
            "[(keyword? (get m :parse)) (= (get m :f) \"tool/echo\") (= (first (get m :xs)) \"tool/echo\")]"
        })

      assert second["isError"] == false
      assert second["structuredContent"]["result"] == "user=> [true true true]"
    end

    test "clear directive empties a history bucket but preserves memory" do
      sid = SoakHelpers.start_session()
      SoakHelpers.eval_ok!(sid, "(do (println \"a\") (def keep 1) keep)")

      forget =
        call("lisp_session_forget", %{"session_id" => sid, "clear" => ["prints"]})

      assert forget["structuredContent"]["status"] == "ok"
      assert forget["structuredContent"]["cleared"] == ["prints"]

      prints = inspect_view(sid, "prints")
      assert prints["prints"] == []
      # memory binding survives the prints clear
      assert inspect_view(sid, "memory")["stored_keys"] == ["keep"]
    end

    test "an invalid clear target is a session_args_error" do
      sid = SoakHelpers.start_session()

      env =
        call("lisp_session_forget", %{"session_id" => sid, "clear" => ["not_a_bucket"]})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
    end
  end

  describe "registry lookup error branches via Tools.call" do
    test "unknown session id reports session_not_found" do
      env =
        call("lisp_session_inspect", %{
          "session_id" => "ptcs_does_not_exist",
          "view" => "overview"
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_not_found"
    end

    test "operating on a closed session reports the session_closed tombstone" do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      call("lisp_session_close", %{"session_id" => sid})

      # Drive the real public inspect path only after the session pid is
      # down AND the `Sessions.Names` fast-path entry is pruned, so the
      # production tombstone — not a transient noproc — is what we assert.
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      await_names_pruned(sid)
      drain_registry()

      env =
        call("lisp_session_inspect", %{"session_id" => sid, "view" => "overview"})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_closed"
    end

    test "list_preludes reports unknown, closed, and malformed requests" do
      unknown = call("lisp_session_list_preludes", %{"session_id" => "ptcs_does_not_exist"})

      assert unknown["isError"] == true
      assert unknown["structuredContent"]["reason"] == "session_not_found"

      missing = call("lisp_session_list_preludes", %{})

      assert missing["isError"] == true
      assert missing["structuredContent"]["reason"] == "session_args_error"
      assert missing["structuredContent"]["message"] =~ "session_id"

      malformed = call("lisp_session_list_preludes", %{"session_id" => "x", "extra" => true})

      assert malformed["isError"] == true
      assert malformed["structuredContent"]["reason"] == "session_args_error"
      assert malformed["structuredContent"]["message"] =~ "extra"

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      call("lisp_session_close", %{"session_id" => sid})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      await_names_pruned(sid)
      drain_registry()

      closed = call("lisp_session_list_preludes", %{"session_id" => sid})

      assert closed["isError"] == true
      assert closed["structuredContent"]["reason"] == "session_closed"
    end

    test "lisp_session_list rejects any argument" do
      env = call("lisp_session_list", %{"session_id" => "x"})
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
    end

    test "lisp_session_start rejects unexpected arguments" do
      env = call("lisp_session_start", %{"bogus" => 1})
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
      assert env["structuredContent"]["message"] =~ "bogus"
    end

    test "lisp_session_start accepts scoped_base_surface only as a boolean" do
      default = call("lisp_session_start", %{})
      refute Map.has_key?(default["structuredContent"], "scoped_base_surface")

      enabled = call("lisp_session_start", %{"scoped_base_surface" => true})
      assert enabled["isError"] == false
      assert enabled["structuredContent"]["scoped_base_surface"] == true

      malformed = call("lisp_session_start", %{"scoped_base_surface" => "true"})
      assert malformed["isError"] == true
      assert malformed["structuredContent"]["reason"] == "session_args_error"
      assert malformed["structuredContent"]["message"] =~ "scoped_base_surface"
    end
  end

  describe "authorization boundary (forged owner)" do
    setup do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      %{sid: sid}
    end

    test "inspect by a non-owner is rejected", %{sid: sid} do
      assert {:error, response} = Sessions.inspect(sid, %{owner: @forged_owner}, "overview")
      assert response["reason"] == "session_owner_mismatch"
      assert response["message"] =~ "does not own"
    end

    test "forget by a non-owner is rejected", %{sid: sid} do
      assert {:error, response} = Sessions.forget(sid, %{owner: @forged_owner}, %{})
      assert response["reason"] == "session_owner_mismatch"
    end

    test "list_preludes by a non-owner is rejected", %{sid: sid} do
      assert {:error, response} = Sessions.list_preludes(sid, %{owner: @forged_owner})
      assert response["reason"] == "session_owner_mismatch"
    end

    test "close by a non-owner is rejected and the session stays live", %{sid: sid} do
      assert {:error, response} = Sessions.close(sid, %{owner: @forged_owner}, "x")
      assert response["reason"] == "session_owner_mismatch"

      # The rightful owner can still reach it: authorization failed closed.
      assert {:ok, _summary} = Sessions.inspect(sid, nil, "overview")
    end

    test "forged owner also blocked through the Tools.call transport seam", %{sid: sid} do
      env =
        call("lisp_session_inspect", %{
          "session_id" => sid,
          "view" => "overview",
          "owner" => %{"transport" => "stdio", "instance_id" => "forged_via_tools"}
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_owner_mismatch"

      prelude_env =
        call("lisp_session_list_preludes", %{
          "session_id" => sid,
          "owner" => %{"transport" => "stdio", "instance_id" => "forged_via_tools"}
        })

      assert prelude_env["isError"] == true
      assert prelude_env["structuredContent"]["reason"] == "session_owner_mismatch"
    end
  end

  describe "session_busy rejection" do
    test "forget while an eval is reserved is rejected as session_busy" do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      owner = Owner.stdio()
      {:ok, meta} = SessionsRegistry.lookup(sid)

      # Reserve the session for an eval but never commit it: the session is
      # now busy from the GenServer's point of view.
      {:ok, _snapshot} =
        Session.begin_eval(meta.pid, owner, make_ref(), %{program: "(+ 1 1)"})

      assert {:error, response} = Sessions.forget(sid, nil, %{})
      assert response["reason"] == "session_busy"
      assert response["session_id"] == sid
    end
  end

  describe "turn log recording" do
    @tag :tmp_dir
    test "records accepted MCP session eval attempts as canonical turn events", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      assert String.starts_with?(sid, "ptcs_")

      commit_discovery_eval!(sid)
      commit_tool_eval!(sid)

      assert {:error, sandbox_error} = Sessions.eval(sid, "(no-such-fn 1)")
      assert sandbox_error["reason"] == "unbound_var"

      validation_error =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "\"not-an-integer\"",
          "output_schema" => %{"type" => "integer"}
        })

      assert validation_error["isError"] == true
      assert validation_error["structuredContent"]["reason"] == "validation_error"

      stop_turn_log!()

      events = Analyzer.load(path)
      turns = Analyzer.session_turns(events, sid)

      assert length(turns) == 4
      assert Enum.map(turns, & &1["session_id"]) == [sid, sid, sid, sid]
      assert Enum.map(turns, & &1["driver"]) == ["session", "session", "session", "session"]
      assert Enum.map(turns, & &1["attempt"]) == [1, 2, 3, 4]
      assert Enum.map(turns, & &1["turn"]) == [1, 2, 2, 2]
      assert Enum.map(turns, & &1["committed"]) == [true, true, false, false]
      assert Enum.map(turns, & &1["status"]) == ["ok", "ok", "error", "error"]

      assert [catalog_op] = get_in(hd(turns), ["data", "catalog_ops"])
      assert catalog_op["operation"] == "apropos"
      assert catalog_op["args"] == %{"query" => "github", "opts" => %{"limit" => 1}}
      assert catalog_op["outcome"] == "ok"

      [[], [tool_call], [], []] = Enum.map(turns, &get_in(&1, ["data", "tool_calls"]))
      assert tool_call["tool"] == "fetch"
      assert is_binary(tool_call["args_hash"])
      assert byte_size(tool_call["args_hash"]) > 0

      sandbox_turn = Enum.at(turns, 2)
      assert get_in(sandbox_turn, ["data", "fail", "reason"]) == "unbound_var"

      validation_turn = Enum.at(turns, 3)
      assert get_in(validation_turn, ["data", "fail", "reason"]) == "validation_failed"
      assert get_in(validation_turn, ["data", "result_preview"]) =~ "not-an-integer"

      assert [summary] = Analyzer.sessions(events)
      assert summary.correlation_id == sid
      assert summary.turns == 4
      assert summary.committed == 2
      assert summary.failed == 2
      assert summary.tool_calls == 1

      log_program =
        ~s|[(count (get (log/turns "#{sid}") "items")) (get (log/programs "#{sid}") "items")]|

      assert {:ok,
              %{
                return: [
                  4,
                  [
                    ~s|(apropos "github" {:limit 1})|,
                    "(tool/fetch {:id 1})",
                    "(no-such-fn 1)",
                    "\"not-an-integer\""
                  ]
                ]
              }} =
               Lisp.run(
                 log_program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(path)
               )
    end

    @tag :tmp_dir
    test "records lisp_session_start tags on MCP turn events", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      start =
        call("lisp_session_start", %{
          "tags" => %{"run" => "demo", "stage" => "editor", "attempt" => 1}
        })

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      assert {:ok, _response} = Sessions.eval(sid, "(+ 1 2)")
      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert turn["tags"] == %{"run" => "demo", "stage" => "editor", "attempt" => 1}

      rejected = call("lisp_session_start", %{"tags" => %{"nested" => %{"bad" => true}}})
      assert rejected["isError"] == true
      assert rejected["structuredContent"]["reason"] == "session_args_error"
    end

    @tag :tmp_dir
    test "boot-stamped turn-log tags are applied when caller omits tags", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir, default_tags: %{"run" => "r", "stage" => "s"}})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      start = call("lisp_session_start", %{})

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]
      assert start["structuredContent"]["tags"] == %{"run" => "r", "stage" => "s"}

      assert {:ok, _response} = Sessions.eval(sid, "(+ 1 2)")
      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert turn["tags"] == %{"run" => "r", "stage" => "s"}
    end

    @tag :tmp_dir
    test "boot-stamped tags accept matching caller tags and merge additions", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir, default_tags: %{"run" => "r", "stage" => "s"}})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      start =
        call("lisp_session_start", %{
          "tags" => %{"run" => "r", "stage" => "s", "attempt" => 1}
        })

      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      assert start["structuredContent"]["tags"] == %{
               "run" => "r",
               "stage" => "s",
               "attempt" => 1
             }

      assert {:ok, _response} = Sessions.eval(sid, "(+ 1 2)")
      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert turn["tags"] == %{"run" => "r", "stage" => "s", "attempt" => 1}
    end

    test "lisp_session_start rejects caller tags conflicting with boot-stamped tags" do
      TurnLogConfig.set(%{default_tags: %{"stage" => "stage2"}})

      rejected = call("lisp_session_start", %{"tags" => %{"stage" => 2}})

      assert rejected["isError"] == true
      assert rejected["structuredContent"]["reason"] == "session_args_error"

      assert rejected["structuredContent"]["message"] =~
               ~s|tag "stage" is boot-stamped to "stage2"|
    end

    test "internal session creators are server-stamped with default tags" do
      TurnLogConfig.set(%{default_tags: %{"stage" => "server", "run" => "r"}})

      assert {:ok, %{"session_id" => sid, "tags" => tags}} =
               Sessions.start_session(nil, %{tags: %{"stage" => "caller", "cell" => "dir"}})

      assert tags == %{"stage" => "server", "run" => "r", "cell" => "dir"}
      assert {:ok, %{"session" => %{"tags" => inspected_tags}}} = Sessions.inspect(sid)
      assert inspected_tags == tags
    end

    @tag :tmp_dir
    test "turn logs and log prelude project role and grant fingerprint", %{tmp_dir: dir} do
      Config.set(%{Config.get() | policy: role_policy!("editor")})
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      start =
        call("lisp_session_start", %{
          "role" => "editor",
          "tags" => %{"run" => "demo", "stage" => "editor"}
        })

      sid = start["structuredContent"]["session_id"]
      fingerprint = start["structuredContent"]["grant_fingerprint"]

      assert {:ok, _response} = Sessions.eval(sid, "(+ 1 2)")
      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert turn["role"] == "editor"
      assert turn["grant_fingerprint"] == fingerprint

      tools = Introspection.tools(path)
      %{"items" => [summary]} = tools["log_sessions"].(%{"tags" => %{"stage" => "editor"}})
      assert summary["role"] == "editor"
      assert summary["grant_fingerprint"] == fingerprint

      %{"items" => [projected_turn]} = tools["log_turns"].(%{"session-id" => sid})
      assert projected_turn["role"] == "editor"
      assert projected_turn["grant_fingerprint"] == fingerprint
    end

    @tag :tmp_dir
    test "configured evidence bundle is readable in sessions and stamps evidence_reads", %{
      tmp_dir: dir
    } do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(
        Config.get()
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, PtcRunner.Evidence.prelude_source())
        |> Map.put(:runtime_prelude, nil)
        |> Map.put(
          :policy,
          role_policy!("analyst",
            ptc_tools: ["evidence_bundle", "evidence_page", "evidence_read"]
          )
        )
      )

      TurnLogConfig.set(%{turn_log_dir: Path.join(dir, "turn-log")})
      start_supervised!({TurnLogCollector, [dir: TurnLogConfig.turn_log_dir()]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{role: "analyst"})

      assert {:ok, response} =
               Sessions.eval(sid, ~S|(get (evidence/read "summary") "content")|)

      assert response["status"] == "ok"
      assert response["result"] =~ "operator-selected facts"

      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)

      assert [
               %{
                 "bundle_id" => "mcp/evidence",
                 "item_id" => "summary",
                 "source_ref" => "summary.md",
                 "checksum" => "sha256:" <> _,
                 "bytes" => 24,
                 "truncated" => false
               }
             ] = get_in(turn, ["data", "evidence_reads"])

      assert [%{"tool" => "evidence_read", "evidence_reads" => [_]}] =
               get_in(turn, ["data", "tool_calls"])
    end

    @tag :tmp_dir
    test "large evidence reads keep audit metadata after tool-ledger previewing", %{
      tmp_dir: dir
    } do
      large_content = String.duplicate("large-evidence-line\n", 1_100)
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"), large_content)

      Config.set(
        Config.get()
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, PtcRunner.Evidence.prelude_source())
        |> Map.put(:runtime_prelude, nil)
      )

      TurnLogConfig.set(%{turn_log_dir: Path.join(dir, "turn-log")})
      start_supervised!({TurnLogCollector, [dir: TurnLogConfig.turn_log_dir()]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})

      assert {:ok, response} =
               Sessions.eval(sid, ~S|(count (get (evidence/read "summary") "content"))|)

      assert response["status"] == "ok"
      assert response["result"] =~ Integer.to_string(byte_size(large_content))

      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)

      assert [
               %{
                 "bundle_id" => "mcp/evidence",
                 "item_id" => "summary",
                 "source_ref" => "summary.md",
                 "checksum" => "sha256:" <> _,
                 "bytes" => bytes,
                 "truncated" => false
               }
             ] = get_in(turn, ["data", "evidence_reads"])

      assert bytes == byte_size(large_content)
    end

    @tag :tmp_dir
    test "configured prelude composes with evidence bundle in sessions", %{tmp_dir: dir} do
      prelude_path = Path.join(dir, "operator.clj")
      File.write!(prelude_path, test_prelude_source())
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      {:ok, config} =
        Config.resolve(%{
          prelude: prelude_path,
          evidence_bundle: evidence_manifest
        })

      Config.set(Map.put(config, :enabled, true))

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})

      assert {:ok, response} =
               Sessions.eval(
                 sid,
                 ~S|[(smoke/plus-one 41) (get (evidence/read "summary") "content")]|
               )

      assert response["status"] == "ok"
      assert response["result"] =~ "42"
      assert response["result"] =~ "operator-selected facts"
    end

    @tag :tmp_dir
    test "write_capable sessions retain configured evidence prelude", %{tmp_dir: dir} do
      {:ok, store} = PreludeStore.new()
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(
        Config.get()
        |> Map.put(:allow_prelude_write, true)
        |> Map.put(:prelude_store, store)
        |> Map.put(:evidence_bundle_path, evidence_manifest)
        |> Map.put(:evidence_bundle, EvidenceBundle.load!(evidence_manifest))
        |> Map.put(:prelude_source, PtcRunner.Evidence.prelude_source())
        |> Map.put(:runtime_prelude, nil)
      )

      {:ok, %{"session_id" => sid}} =
        Sessions.start_session(nil, %{"mode" => "write_capable"})

      assert {:ok, response} =
               Sessions.eval(sid, ~S|(get (evidence/read "summary") "content")|)

      assert response["status"] == "ok"
      assert response["result"] =~ "operator-selected facts"
    end

    test "write_capable requires role prelude_store write grant" do
      {:ok, store} = PreludeStore.new()

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:allow_prelude_write, true)
        |> Map.put(
          :policy,
          role_policy!("analyst", prelude_store: "read", modes: ["write_capable"])
        )
      )

      denied = call("lisp_session_start", %{"role" => "analyst", "mode" => "write_capable"})
      assert denied["isError"] == true
      assert denied["structuredContent"]["message"] =~ "prelude_store write grant"
    end

    test "prelude_store write grant supplies private backing tools outside ptc_tools allowlist" do
      {:ok, store} = PreludeStore.new()

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:allow_prelude_write, true)
        |> Map.put(
          :policy,
          role_policy!("editor",
            prelude_store: "write",
            modes: ["write_capable"],
            ptc_tools: ["evidence_read"]
          )
        )
      )

      start = call("lisp_session_start", %{"role" => "editor", "mode" => "write_capable"})
      assert start["isError"] == false
      sid = start["structuredContent"]["session_id"]

      write =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" =>
            ~S|(prelude/write {:id "created" :source "(ns created {:visibility :prompt})\n(defn value [] 1)"})|
        })

      assert write["isError"] == false
      assert {:ok, candidate} = PreludeStore.read(store, "created")
      assert candidate.id == "created"
    end

    @tag :tmp_dir
    test "result previews render native keyword returns", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})

      assert {:ok, response} = Sessions.eval(sid, ":jsonl")
      assert response["status"] == "ok"

      stop_turn_log!()

      [turn] = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert get_in(turn, ["data", "result_preview"]) == ":jsonl"
      refute get_in(turn, ["data", "result_preview"]) =~ "PtcRunner.Lisp.Keyword"
    end

    @tag :tmp_dir
    test "records upstream-style tool/call entries once with real tool identity", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})

      commit_call_tool_eval!(
        sid,
        ~S|(tool/call {:server "observatory" :tool "list_traces" :args {:org_id "acme"}})|
      )

      commit_call_tool_eval!(
        sid,
        ~S|(tool/call {:server "observatory" :tool "fail_trace" :args {:id "missing"}})|
      )

      stop_turn_log!()

      turns = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert length(turns) == 2

      assert [ok_call] = get_in(Enum.at(turns, 0), ["data", "tool_calls"])
      assert ok_call["server"] == "observatory"
      assert ok_call["tool"] == "list_traces"
      assert ok_call["outcome"] == "ok"
      assert is_binary(ok_call["args_hash"])

      assert [error_call] = get_in(Enum.at(turns, 1), ["data", "tool_calls"])
      assert error_call["server"] == "observatory"
      assert error_call["tool"] == "fail_trace"
      assert error_call["outcome"] == "error"
      assert is_binary(error_call["args_hash"])
      assert ok_call["args_hash"] != error_call["args_hash"]
    end
  end

  describe "deterministic eviction (no Process.sleep)" do
    test "idle timeout evicts the session and leaves a tombstone" do
      Config.set(%{enabled: true, session_idle_timeout_ms: 5, session_ttl_ms: 60_000})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000

      assert tombstone_lookup(sid) == {:error, :session_closed}
    end

    test "ttl expiry evicts the session even while idle timer is long" do
      Config.set(%{enabled: true, session_ttl_ms: 5, session_idle_timeout_ms: 60_000})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000

      assert tombstone_lookup(sid) == {:error, :session_closed}
    end
  end

  describe "registry quota branches" do
    test "max_sessions cap rejects the next start as session_limit_exceeded" do
      SoakHelpers.setup_sessions(%{enabled: true, max_sessions: 1})

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, response} = Sessions.start_session(nil, %{})
      assert response["reason"] == "session_limit_exceeded"
      assert response["message"] =~ "maximum number of sessions"
    end

    test "per-owner cap rejects an over-quota owner while leaving global room" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, response} = Sessions.start_session(nil, %{})
      assert response["reason"] == "session_limit_exceeded"
      assert response["message"] =~ "for this owner"
    end

    test "a distinct owner is unaffected by another owner's per-owner cap" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      other = %{owner: %{transport: :http, mcp_session_id: "other-owner-1"}}

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, _} = Sessions.start_session(nil, %{})
      # Different owner still has its own quota headroom.
      assert {:ok, _} = Sessions.start_session(other, %{})
    end

    test "DOWN of a session frees a per-owner quota slot" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      assert {:error, _} = Sessions.start_session(nil, %{})

      assert {:ok, _} = Sessions.close(sid, nil, "done")
      await_session_removed(sid)

      # The owner index slot was reclaimed on :DOWN, so a new start succeeds.
      assert {:ok, _} = Sessions.start_session(nil, %{})
    end

    test "inspect on a closed session with an unpruned Names entry returns the tombstone" do
      SoakHelpers.setup_sessions(%{enabled: true})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      pid = meta.pid

      # Freeze the partitioned `Sessions.Names` registry so it cannot prune the
      # dead-pid entry — deterministically recreating the post-`:DOWN` /
      # pre-prune window where `lookup/1`'s fast path still resolves `sid` to
      # the dead session pid. Registry reads hit ETS directly, so lookups still
      # work while the partition processes are suspended.
      names_partitions =
        for {_, p, _, _} <- Supervisor.which_children(PtcRunnerMcp.Sessions.Names),
            is_pid(p),
            do: p

      Enum.each(names_partitions, &:sys.suspend/1)

      try do
        ref = Process.monitor(pid)
        assert {:ok, _} = Sessions.close(sid, nil, "done")
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
        await_session_removed(sid)

        # The Names fast path still hands back the now-dead pid; `lookup/1` must
        # not return it, so `inspect` resolves to the session_closed tombstone
        # instead of crashing the caller with a `:noproc` exit.
        assert {:error, %{"reason" => "session_closed"}} =
                 Sessions.inspect(sid, nil, "overview")
      after
        Enum.each(names_partitions, &:sys.resume/1)
      end
    end
  end

  describe "disabled surface" do
    test "every session tool reports sessions_disabled when the feature is off" do
      Config.set(%{enabled: false})
      SoakHelpers.stop_sessions_processes()

      for {name, args} <- [
            {"lisp_session_start", %{}},
            {"lisp_session_list", %{}},
            {"lisp_session_list_preludes", %{"session_id" => "ptcs_any"}}
          ] do
        env = call(name, args)
        assert env["isError"] == true
        assert env["structuredContent"]["reason"] == "sessions_disabled"
      end
    end
  end

  describe "Sessions.Config table behavior" do
    test "resolve/1 returns disabled defaults from an empty args map" do
      assert {:ok, d} = Config.resolve(%{})
      assert d.enabled == false
      assert d.max_sessions == 64
      assert d.max_sessions_per_owner == 16
    end

    test "resolve/1 preserves an explicit prelude store" do
      {:ok, store} = PreludeStore.new()

      assert {:ok, config} = Config.resolve(%{sessions: true, prelude_store: store})
      assert config.enabled == true
      assert config.prelude_store == store
    end

    @tag :tmp_dir
    test "resolve/1 compiles configured prelude composed with evidence", %{tmp_dir: dir} do
      prelude_path = Path.join(dir, "operator.clj")
      File.write!(prelude_path, test_prelude_source())
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      assert {:ok, config} =
               Config.resolve(%{
                 sessions: true,
                 prelude: prelude_path,
                 evidence_bundle: evidence_manifest
               })

      assert config.runtime_prelude != nil
      assert "smoke" in config.runtime_prelude.namespaces
      assert "evidence" in config.runtime_prelude.namespaces
    end

    @tag :tmp_dir
    test "resolve/1 loads session roles with upstream tool grants", %{tmp_dir: dir} do
      path =
        write_role_policy!(dir, %{
          "roles" => %{"analyst" => %{"upstream_tools" => ["upstream:x/y"]}},
          "default_role" => "analyst"
        })

      assert {:ok, config} = Config.resolve(%{session_roles: path})
      grant = config.policy.roles["analyst"]

      assert Policy.upstream_tool_allowed?(grant, "upstream:x/y")
      assert Policy.upstream_tool_allowed?(grant, "x", "y")
      refute Policy.upstream_tool_allowed?(grant, "upstream:x/z")
      assert Policy.upstream_tool_grants(grant) == MapSet.new(["upstream:x/y"])
      refute Policy.strict_transitive_calls?(grant)

      strict_path =
        write_role_policy!(dir, role_policy_json("analyst", strict_transitive_calls: true))

      assert {:ok, strict_config} = Config.resolve(%{session_roles: strict_path})
      strict_grant = strict_config.policy.roles["analyst"]
      assert Policy.strict_transitive_calls?(strict_grant)
      refute strict_grant.fingerprint == grant.fingerprint

      bad_strict_path =
        write_role_policy!(
          dir,
          role_policy_json("analyst", strict_transitive_calls: "true")
        )

      assert {:error, strict_message} = Config.resolve(%{session_roles: bad_strict_path})
      assert strict_message =~ "strict_transitive_calls"
      assert strict_message =~ "boolean"

      bad_path =
        write_role_policy!(dir, %{
          "roles" => %{"analyst" => %{"upstream_tools" => ["x/y"]}},
          "default_role" => "analyst"
        })

      assert {:error, message} = Config.resolve(%{session_roles: bad_path})
      assert message =~ "--session-roles"
      assert message =~ "upstream:<server>/<tool>"

      path = write_role_policy!(dir, role_policy_json("analyst"))

      assert {:ok, config} = Config.resolve(%{session_roles: path})
      assert config.roles_path == path
      assert config.policy.default_role == "analyst"
      assert config.policy.roles["analyst"].fingerprint =~ "sha256:"

      assert config.policy.roles["analyst"].fingerprint ==
               "sha256:210d4e3bc41c7d11aa99c8a0aedf0a6bc5a9a15e2a9da18e29b01405f26caea5"
    end

    test "role prelude filtering removes exports with denied upstream requirements" do
      {:ok, prelude} =
        PreludeCompiler.compile("""
        (ns crm {:visibility :prompt})
        (defn allowed [] (tool/call {:server "crm" :tool "get_user" :args {}}))
        (defn denied [] (tool/call {:server "crm" :tool "delete_user" :args {}}))
        (defn dynamic [server tool] (tool/call {:server server :tool tool :args {}}))
        """)

      policy =
        role_policy!("analyst", ptc_tools: [], upstream_tools: ["upstream:crm/get_user"])

      grant = policy.roles["analyst"]

      filtered = Policy.filter_prelude(prelude, grant)
      projection = Policy.project_prelude(prelude, grant)

      assert Enum.map(filtered.exports, & &1.ref) == ["crm/allowed"]
      assert Enum.map(projection.prelude.exports, & &1.ref) == ["crm/allowed"]

      assert projection.filtered_exports == [
               %{
                 ref: "crm/denied",
                 namespace: "crm",
                 name: "denied",
                 reason: :upstream_tool_denied
               },
               %{
                 ref: "crm/dynamic",
                 namespace: "crm",
                 name: "dynamic",
                 reason: :dynamic_upstream_requires_broad_grant
               }
             ]

      assert Map.has_key?(filtered.source_index, "crm/allowed")
      refute Map.has_key?(filtered.source_index, "crm/denied")
      refute Map.has_key?(filtered.source_index, "crm/dynamic")

      assert Policy.filter_ptc_tools(%{"call" => fn _args -> :ok end}, grant)
             |> Map.has_key?("call")

      no_upstream_policy = role_policy!("analyst", ptc_tools: [], upstream_tools: [])

      assert Policy.filter_ptc_tools(
               %{"call" => fn _args -> :ok end},
               no_upstream_policy.roles["analyst"]
             )
             |> Map.has_key?("call")

      broad_policy = role_policy!("analyst", upstream_tools: "all")
      broad_filtered = Policy.filter_prelude(prelude, broad_policy.roles["analyst"])

      assert Enum.map(broad_filtered.exports, & &1.ref) == [
               "crm/allowed",
               "crm/denied",
               "crm/dynamic"
             ]
    end

    @tag :tmp_dir
    test "grant-filtered prelude exports are explained at start, call, and turn log", %{
      tmp_dir: dir
    } do
      {:ok, store} = PreludeStore.new()

      {:ok, _candidate} =
        PreludeStore.write(store, "crm", """
        (ns crm "CRM helpers." {:visibility :prompt})
        (defn dynamic [server tool] (tool/call {:server server :tool tool :args {}}))
        """)

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(:policy, role_policy!("analyst", upstream_tools: ["upstream:crm/get_user"]))
      )

      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      start =
        call("lisp_session_start", %{
          "role" => "analyst",
          "preludes" => ["crm"]
        })

      assert start["isError"] == false
      assert %{"session_id" => sid} = start["structuredContent"]

      assert start["structuredContent"]["prelude_projection"] == %{
               "filtered_export_count" => 1,
               "filtered_exports_truncated" => false,
               "empty_namespaces" => ["crm"],
               "filtered_namespaces" => [
                 %{"namespace" => "crm", "filtered_export_count" => 1}
               ],
               "filtered_exports" => [
                 %{
                   "ref" => "crm/dynamic",
                   "namespace" => "crm",
                   "name" => "dynamic",
                   "reason" => "dynamic_upstream_requires_broad_grant"
                 }
               ]
             }

      ns_publics =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(ns-publics 'crm)|
        })

      assert ns_publics["isError"] == false
      assert ns_publics["structuredContent"]["result"] == "user=> {}"

      filtered_call =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(crm/dynamic "crm" "get_user")|
        })

      assert filtered_call["isError"] == true

      assert filtered_call["structuredContent"]["message"] =~
               "crm/dynamic is public in an attached prelude but was removed"

      assert filtered_call["structuredContent"]["message"] =~
               "dynamic_upstream_requires_broad_grant"

      assert filtered_call["structuredContent"]["message"] =~ "prelude_projection"

      missing_call =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~S|(crm/missing)|
        })

      assert missing_call["isError"] == true

      assert missing_call["structuredContent"]["message"] =~
               "crm/missing is not a public export of namespace crm. " <>
                 "Discover its public exports with (ns-publics 'crm) or (apropos \"missing\")."

      stop_turn_log!()

      turns = path |> Analyzer.load() |> Analyzer.session_turns(sid)

      assert Enum.any?(turns, fn turn ->
               get_in(turn, ["data", "prelude_projection"]) ==
                 start["structuredContent"]["prelude_projection"]
             end)
    end

    @tag :tmp_dir
    test "seeded explicit upstream requires attach and filter under finite role grants", %{
      tmp_dir: dir
    } do
      seed_dir = Path.join(dir, "seed")
      File.mkdir_p!(seed_dir)

      File.write!(Path.join(seed_dir, "seeded.clj"), """
      (ns seeded "Seeded dynamic upstream helpers." {:visibility :prompt})

      (defn- fetch [server tool args]
        (tool/call {:server server :tool tool :args args}))

      (defn collect
        "Collect traces through dynamic upstream dispatch."
        {:requires ["upstream:observatory/list-traces"]}
        [org]
        (fetch "observatory" "list-traces" {:org_id org :limit 1}))

      (defn ungranted-control
        "Control export whose declared operation is not role-granted."
        {:requires ["upstream:observatory/get-trace"]}
        [trace-id]
        (fetch "observatory" "get-trace" {:trace_id trace-id}))
      """)

      File.write!(Path.join(seed_dir, "unmarked.clj"), """
      (ns unmarked "Seeded helper without explicit upstream metadata." {:visibility :prompt})

      (defn- fetch [server tool args]
        (tool/call {:server server :tool tool :args args}))

      (defn collect [org]
        (fetch "observatory" "list-traces" {:org_id org :limit 1}))
      """)

      %{prelude_store: store} =
        Application.maybe_seed_prelude_store(%{prelude_store_seed: seed_dir})

      {:ok, server} = start_http_fixture(%{"traces" => [%{"id" => "trace-1"}]})

      {:ok, _pid} =
        Runtime.start_supervised(
          config: observatory_root_config(server.base_url),
          name: RootUpstreamRuntime.name(),
          catalog_snapshot_mode: :frozen
        )

      Config.set(
        Config.get()
        |> Map.put(:prelude_store, store)
        |> Map.put(
          :policy,
          role_policy!("analyst",
            upstream_tools: ["upstream:observatory/list-traces"],
            strict_transitive_calls: true
          )
        )
      )

      try do
        start =
          call("lisp_session_start", %{
            "role" => "analyst",
            "preludes" => ["seeded", "unmarked"]
          })

        assert start["isError"] == false
        assert %{"session_id" => sid} = start["structuredContent"]

        assert %{
                 "filtered_export_count" => 2,
                 "filtered_exports" => filtered_exports
               } = start["structuredContent"]["prelude_projection"]

        assert Enum.any?(filtered_exports, fn export ->
                 match?(
                   %{
                     "ref" => "seeded/ungranted-control",
                     "reason" => "upstream_tool_denied"
                   },
                   export
                 )
               end)

        assert Enum.any?(filtered_exports, fn export ->
                 match?(
                   %{
                     "ref" => "unmarked/collect",
                     "reason" => "dynamic_upstream_requires_broad_grant"
                   },
                   export
                 )
               end)

        publics =
          call("lisp_session_eval", %{
            "session_id" => sid,
            "program" => ~S|(ns-publics 'seeded)|
          })

        assert publics["isError"] == false
        assert publics["structuredContent"]["result"] =~ "collect"
        refute publics["structuredContent"]["result"] =~ "ungranted-control"

        result =
          call("lisp_session_eval", %{
            "session_id" => sid,
            "program" => ~S|(seeded/collect "acme")|
          })

        assert result["isError"] == false
        assert result["structuredContent"]["result"] =~ "trace-1"

        assert_receive {:http_fixture_request, request}, 1_000
        assert request =~ "GET /api/v1/traces?"
        assert request =~ "org_id=acme"

        unmarked =
          call("lisp_session_eval", %{
            "session_id" => sid,
            "program" => ~S|(unmarked/collect "acme")|
          })

        assert unmarked["isError"] == true

        assert unmarked["structuredContent"]["message"] =~
                 "dynamic_upstream_requires_broad_grant"
      after
        Process.unlink(server.pid)

        if Process.alive?(server.pid) do
          Process.exit(server.pid, :kill)
        end
      end
    end

    @tag :tmp_dir
    test "resolve/1 loads role credential grants into grant fingerprints", %{tmp_dir: dir} do
      path =
        write_role_policy!(
          dir,
          role_policy_json("analyst", credentials: ["reader_token", "audit_token"])
        )

      assert {:ok, config} = Config.resolve(%{session_roles: path})
      grant = config.policy.roles["analyst"]

      assert Policy.credential_allowed?(grant, "reader_token")
      assert Policy.credential_allowed?(grant, "audit_token")
      refute Policy.credential_allowed?(grant, "writer_token")
      assert Policy.credential_grants(grant) == MapSet.new(["audit_token", "reader_token"])

      path_without_credentials = write_role_policy!(dir, role_policy_json("analyst"))

      assert {:ok, config_without_credentials} =
               Config.resolve(%{session_roles: path_without_credentials})

      refute config_without_credentials.policy.roles["analyst"].fingerprint == grant.fingerprint
    end

    @tag :tmp_dir
    test "resolve/1 rejects unknown session role policy keys", %{tmp_dir: dir} do
      bad_top =
        write_role_policy!(dir, Map.put(role_policy_json("analyst"), "default_roles", "typo"))

      assert {:error, top_message} = Config.resolve(%{session_roles: bad_top})
      assert top_message =~ "unknown key"
      assert top_message =~ "default_roles"

      bad_outer =
        write_role_policy!(dir, %{
          "outer_policy" => %{"mcp_toolz" => ["lisp_session_start"]},
          "roles" => %{"analyst" => %{}}
        })

      assert {:error, outer_message} = Config.resolve(%{session_roles: bad_outer})
      assert outer_message =~ "unknown key"
      assert outer_message =~ "mcp_toolz"

      bad_role =
        write_role_policy!(dir, %{
          "roles" => %{"analyst" => %{"prelude_stroe" => "write"}}
        })

      assert {:error, role_message} = Config.resolve(%{session_roles: bad_role})
      assert role_message =~ "unknown key"
      assert role_message =~ "prelude_stroe"

      bad_prelude =
        write_role_policy!(dir, %{
          "roles" => %{
            "analyst" => %{
              "preludes" => [%{"id" => "base", "version" => 1, "checksumm" => "typo"}]
            }
          }
        })

      assert {:error, prelude_message} = Config.resolve(%{session_roles: bad_prelude})
      assert prelude_message =~ "unknown key"
      assert prelude_message =~ "checksumm"
    end

    @tag :tmp_dir
    test "get/0 installs holder-backed evidence tools for env-only config", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))
      old_env = System.get_env("PTC_RUNNER_MCP_EVIDENCE_BUNDLE")

      on_exit(fn ->
        restore_env("PTC_RUNNER_MCP_EVIDENCE_BUNDLE", old_env)
        Config.reset()
      end)

      Config.reset()
      System.put_env("PTC_RUNNER_MCP_EVIDENCE_BUNDLE", evidence_manifest)

      config = Config.get()

      assert config.evidence_bundle != nil
      assert is_pid(config.evidence_holder)
      assert Map.has_key?(config.evidence_tools, "evidence_read")

      assert {:ok, response} =
               Lisp.run(
                 ~S|(get (evidence/read "summary") "content")|,
                 prelude: Config.prelude_source(),
                 tools: Config.with_evidence_tools(%{})
               )

      assert response.return == "operator-selected facts\n"
    end

    @tag :tmp_dir
    test "set/1 composes evidence prelude when installing evidence bundle directly", %{
      tmp_dir: dir
    } do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(%{
        Config.get()
        | evidence_bundle_path: evidence_manifest,
          evidence_bundle: EvidenceBundle.load!(evidence_manifest),
          prelude_source: nil,
          runtime_prelude: nil
      })

      assert "evidence" in Config.runtime_prelude().namespaces

      assert {:ok, response} =
               Lisp.run(
                 ~S|(get (evidence/read "summary") "content")|,
                 prelude: Config.prelude_source(),
                 tools: Config.with_evidence_tools(%{})
               )

      assert response.return == "operator-selected facts\n"
    end

    @tag :tmp_dir
    test "evidence tool grant rejects atom and keyword name collisions", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      Config.set(%{
        Config.get()
        | evidence_bundle_path: evidence_manifest,
          evidence_bundle: EvidenceBundle.load!(evidence_manifest),
          prelude_source: nil,
          runtime_prelude: nil
      })

      assert_raise ArgumentError, ~r/evidence_read/, fn ->
        Config.with_evidence_tools(%{evidence_read: fn _args -> :bad end})
      end

      assert_raise ArgumentError, ~r/evidence_page/, fn ->
        Config.with_evidence_tools(evidence_page: fn _args -> :bad end)
      end
    end

    @tag :tmp_dir
    test "set/1 fails closed on non-official evidence namespace collisions", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      assert_raise ArgumentError, ~r/namespace `evidence` is declared more than once/, fn ->
        Config.set(%{
          Config.get()
          | evidence_bundle_path: evidence_manifest,
            evidence_bundle: EvidenceBundle.load!(evidence_manifest),
            prelude_source: """
            (ns evidence)
            (defn bogus [] 1)
            """,
            runtime_prelude: nil
        })
      end
    end

    @tag :tmp_dir
    test "set/1 refreshes stale evidence holders when restoring saved config", %{tmp_dir: dir} do
      first_manifest = write_evidence_bundle!(Path.join(dir, "first"), "first facts\n")
      second_manifest = write_evidence_bundle!(Path.join(dir, "second"), "second facts\n")

      Config.set(%{
        Config.get()
        | evidence_bundle_path: first_manifest,
          evidence_bundle: EvidenceBundle.load!(first_manifest),
          prelude_source: nil,
          runtime_prelude: nil
      })

      saved = Config.get()
      saved_holder = saved.evidence_holder

      Config.set(%{
        Config.get()
        | evidence_bundle_path: second_manifest,
          evidence_bundle: EvidenceBundle.load!(second_manifest),
          prelude_source: nil,
          runtime_prelude: nil
      })

      refute Process.alive?(saved_holder)

      Config.set(saved)
      restored = Config.get()

      assert is_pid(restored.evidence_holder)
      assert restored.evidence_holder != saved_holder
      assert Process.alive?(restored.evidence_holder)

      assert {:ok, response} =
               Lisp.run(
                 ~S|(get (evidence/read "summary") "content")|,
                 prelude: Config.prelude_source(),
                 tools: Config.with_evidence_tools(%{})
               )

      assert response.return == "first facts\n"
    end

    test "resolve/1 honors CLI keys and parses integer strings" do
      assert {:ok, resolved} =
               Config.resolve(%{
                 sessions: true,
                 max_sessions: 7,
                 session_ttl_ms: "1234"
               })

      assert resolved.enabled == true
      assert resolved.max_sessions == 7
      assert resolved.session_ttl_ms == 1234
    end

    test "resolve/1 rejects invalid explicit integer config" do
      assert {:error, message} = Config.resolve(%{max_sessions_per_owner: "not-a-number"})

      assert message =~ "--max-sessions-per-owner"
      assert message =~ "PTC_RUNNER_MCP_MAX_SESSIONS_PER_OWNER"
      assert message =~ "must be a positive integer"
    end

    test "resolve/1 rejects numeric-prefix garbage" do
      assert {:error, message} = Config.resolve(%{max_sessions_per_owner: "64mb"})

      assert message =~ "--max-sessions-per-owner"
      assert message =~ "must be a positive integer"
    end

    test "set/1 normalizes non-positive integers back to defaults" do
      Config.set(%{enabled: true, max_sessions: -5, max_sessions_per_owner: 3})
      config = Config.get()
      assert config.max_sessions == 64
      assert config.max_sessions_per_owner == 3
    after
      Config.reset()
    end

    test "clamp_ttl_ms/1 caps requested ttl at the configured maximum" do
      Config.set(%{enabled: true, session_ttl_ms: 1_000})
      assert Config.clamp_ttl_ms(nil) == 1_000
      assert Config.clamp_ttl_ms(500) == 500
      assert Config.clamp_ttl_ms(5_000) == 1_000
      assert Config.clamp_ttl_ms("garbage") == 1_000
    after
      Config.reset()
    end

    test "session_limits/0 projects only the per-session caps" do
      Config.set(%{enabled: true, session_idle_timeout_ms: 4_242})
      limits = Config.session_limits()
      assert limits.max_idle_ms == 4_242
      assert Map.has_key?(limits, :max_memory_bytes)
      refute Map.has_key?(limits, :max_sessions)
    after
      Config.reset()
    end
  end

  describe "evidence tool grant diagnostics" do
    setup do
      original_log_level = Log.level()
      Log.set_level(:info)

      on_exit(fn ->
        Log.set_level(original_log_level)
        Config.reset()
      end)

      :ok
    end

    @tag :tmp_dir
    test "partial evidence grant does not warn", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      roles_path =
        write_role_policy!(dir, role_policy_json("analyst", ptc_tools: ["evidence_bundle"]))

      logs =
        install_config_and_capture_logs!(
          evidence_bundle: evidence_manifest,
          session_roles: roles_path
        )

      refute Enum.any?(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
    end

    @tag :tmp_dir
    test "zero-overlap ptc_tools allowlist warns with role and grant fingerprint", %{
      tmp_dir: dir
    } do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      roles_path =
        write_role_policy!(dir, role_policy_json("guest", ptc_tools: ["some_unrelated_tool"]))

      logs =
        install_config_and_capture_logs!(
          evidence_bundle: evidence_manifest,
          session_roles: roles_path
        )

      assert [warning] = Enum.filter(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
      assert warning["level"] == "warn"
      assert warning["fields"]["role"] == "guest"

      assert warning["fields"]["grant_fingerprint"] ==
               Config.get().policy.roles["guest"].fingerprint

      assert warning["fields"]["evidence_tools"] == [
               "evidence_bundle",
               "evidence_page",
               "evidence_read"
             ]
    end

    @tag :tmp_dir
    test "explicit deny-all ptc_tools allowlist warns", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))
      roles_path = write_role_policy!(dir, role_policy_json("locked_out", ptc_tools: []))

      logs =
        install_config_and_capture_logs!(
          evidence_bundle: evidence_manifest,
          session_roles: roles_path
        )

      assert Enum.any?(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
    end

    @tag :tmp_dir
    test "ptc_tools: :all never warns", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))
      roles_path = write_role_policy!(dir, role_policy_json("admin"))

      logs =
        install_config_and_capture_logs!(
          evidence_bundle: evidence_manifest,
          session_roles: roles_path
        )

      refute Enum.any?(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
    end

    @tag :tmp_dir
    test "no evidence bundle configured never warns", %{tmp_dir: dir} do
      roles_path =
        write_role_policy!(dir, role_policy_json("guest", ptc_tools: ["some_unrelated_tool"]))

      logs = install_config_and_capture_logs!(session_roles: roles_path)

      refute Enum.any?(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
    end

    @tag :tmp_dir
    test "unrestricted policy with no configured roles never warns", %{tmp_dir: dir} do
      evidence_manifest = write_evidence_bundle!(Path.join(dir, "evidence"))

      logs = install_config_and_capture_logs!(evidence_bundle: evidence_manifest)

      refute Enum.any?(logs, &(&1["event"] == "role_evidence_tools_unreachable"))
    end
  end

  describe "Sessions.Limits table behavior" do
    setup do
      Config.set(%{enabled: true})
      on_exit(&Config.reset/0)
      %{limits: Config.session_limits()}
    end

    test "usage/5 summarizes committed state counts and bytes" do
      usage = Limits.usage(%{a: 1, b: 2}, [1, 2], ["p"], [], [])
      assert usage.binding_count == 2
      assert usage.history_count == 2
      assert usage.print_entries == 1
      assert usage.memory_bytes > 0
    end

    test "validate_memory/2 rejects too many bindings", %{limits: limits} do
      tight = Map.put(limits, :max_bindings, 0)
      assert {:error, detail} = Limits.validate_memory(%{a: 1}, tight)
      assert detail.limit == "max_bindings"
    end

    test "validate_memory/2 rejects an oversized single binding", %{limits: limits} do
      tight = Map.put(limits, :max_binding_bytes, 1)
      assert {:error, detail} = Limits.validate_memory(%{big: String.duplicate("x", 64)}, tight)
      assert detail.limit == "max_binding_bytes"
      assert detail.name == "big"
    end

    test "validate_memory/2 accepts state within limits", %{limits: limits} do
      assert Limits.validate_memory(%{a: 1}, limits) == :ok
    end

    test "stored_keys/1 returns sorted string keys" do
      assert Limits.stored_keys(%{b: 1, a: 2}) == ["a", "b"]
    end

    test "drop_bindings/2 removes named keys without atom creation" do
      assert Limits.drop_bindings(%{"a" => 1, "b" => 2}, ["a"]) == %{"b" => 2}
    end

    test "top_bindings/2 ranks by approximate external size" do
      assert [%{name: "b"}] = Limits.top_bindings(%{a: 1, b: String.duplicate("x", 64)}, 1)
    end

    test "cap_turn_history/3 keeps small values verbatim with no notices", %{limits: limits} do
      {history, notices} = Limits.cap_turn_history([], 42, limits)
      assert history == [42]
      assert notices == []
    end

    test "cap_turn_history/3 replaces an oversized entry with a preview marker", %{limits: limits} do
      tight = Map.put(limits, :max_history_entry_bytes, 8)
      big = String.duplicate("z", 256)
      {[entry], [notice]} = Limits.cap_turn_history([], big, tight)
      assert entry.lisp_session_preview == true
      assert notice.reason == "max_history_entry_bytes"
    end

    test "append_prints/3 trims to the most recent entries under the count cap", %{limits: limits} do
      tight = Map.put(limits, :max_print_entries, 2)
      result = Limits.append_prints(["old"], ["a", "b", "c"], tight)
      assert result == ["b", "c"]
    end
  end

  describe "Sessions.Projection table behavior" do
    test "error/3 stringifies the reason and merges extra fields" do
      response = Projection.error(:custom_reason, "boom", %{detail: 7})
      assert response["status"] == "error"
      assert response["reason"] == "custom_reason"
      assert response["message"] == "boom"
      assert response["feedback"] == "boom"
      assert response["detail"] == 7
    end

    test "list/1 of no sessions reports an empty, zero-count payload" do
      assert Projection.list([]) == %{
               "status" => "ok",
               "count" => 0,
               "sessions" => []
             }
    end

    test "list/1 reports the count of provided summaries" do
      payload = Projection.list([%{"session_id" => "a"}, %{"session_id" => "b"}])
      assert payload["count"] == 2
    end

    test "eval_success uses configured session preview chars" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})

      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: String.duplicate("a", 200),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == true
      assert String.length(payload["result"]) < 120
      assert payload["feedback"] =~ "truncated"
      assert payload["feedback"] =~ "(describe *1)"
      assert payload["feedback"] =~ "(describe *1 {:paths true :depth 2})"
      assert length(String.split(payload["feedback"], "(describe *1)")) == 2
    end

    test "lisp_session_eval envelope surfaces result truncation describe hint" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})
      sid = SoakHelpers.start_session()

      envelope =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~s("#{String.duplicate("a", 200)}")
        })

      assert envelope["structuredContent"]["truncated"] == true
      assert envelope["structuredContent"]["feedback"] =~ "(describe *1)"

      refute envelope["structuredContent"]["feedback"] =~ "<untrusted_ptc_output"

      text = get_in(envelope, ["content", Access.at(0), "text"])

      assert text =~ "(describe *1)"
      assert length(String.split(text, "user=>")) == 2
      refute text =~ "<untrusted_ptc_output"
    end

    test "slim lisp_session_eval non-truncated success does not duplicate feedback" do
      ResponseProfile.set(:slim)
      sid = SoakHelpers.start_session()

      envelope =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(+ 1 2)"
        })

      text = get_in(envelope, ["content", Access.at(0), "text"])

      refute Map.has_key?(envelope, "structuredContent")
      assert text =~ "user=> 3"
      assert length(String.split(text, "user=> 3")) == 2
      refute text =~ "<result>"
    end

    test "eval_success does not add describe hint without truncation" do
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: "short",
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == false
      refute payload["feedback"] =~ "(describe *1)"
    end

    test "eval_success does not add result describe hint for print-only truncation" do
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: "short",
        memory: %{},
        prints: [String.duplicate("p", 3_000)],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == true
      assert payload["feedback"] =~ "truncated"
      refute payload["feedback"] =~ "(describe *1)"
    end

    test "eval_success adds collection hint for large map collections when enabled" do
      Config.set(%{Config.get() | collection_hint: true})

      previous = %{memory: %{}}
      committed = collection_hint_committed()
      rows = for i <- 1..25, do: %{"id" => i, "v" => "x"}
      step = %{return: rows, memory: %{}, prints: [], tool_calls: [], upstream_calls: []}

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["feedback"] =~ "collection of 25 maps"
      assert payload["feedback"] =~ "(describe *1 {:paths true})"
      # the collection hint replaces the generic truncation hint — one hint only
      assert length(String.split(payload["feedback"], "describe *1")) == 2
    end

    test "collection hint fires even when the result preview is not truncated" do
      Config.set(%{Config.get() | collection_hint: true, max_session_preview_chars: 100_000})

      previous = %{memory: %{}}
      committed = collection_hint_committed()
      rows = for i <- 1..25, do: %{"id" => i}
      step = %{return: rows, memory: %{}, prints: [], tool_calls: [], upstream_calls: []}

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == false
      assert payload["feedback"] =~ "collection of 25 maps"
    end

    test "no collection hint below threshold, for non-map items, or when disabled" do
      previous = %{memory: %{}}
      committed = collection_hint_committed()

      Config.set(%{Config.get() | collection_hint: true, max_session_preview_chars: 100_000})

      small = %{
        return: for(i <- 1..5, do: %{"id" => i}),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      refute Projection.eval_success(previous, committed, small, [])["feedback"] =~
               "collection of"

      scalars = %{
        return: Enum.to_list(1..50),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      refute Projection.eval_success(previous, committed, scalars, [])["feedback"] =~
               "collection of"

      Config.set(%{Config.get() | collection_hint: false})

      rows = %{
        return: for(i <- 1..25, do: %{"id" => i}),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      refute Projection.eval_success(previous, committed, rows, [])["feedback"] =~ "collection of"
    end

    test "lisp_session_eval compact envelope omits non-truncated collection hint" do
      Config.set(%{Config.get() | collection_hint: true})
      sid = SoakHelpers.start_session()

      envelope =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(def rows (mapv (fn [i] {:id i :v \"x\"}) (range 30))) (count rows)"
        })

      feedback = envelope["structuredContent"]["feedback"] || ""
      refute feedback =~ "Binding `rows` is a collection of 30 maps"
      refute feedback =~ "(describe rows {:paths true})"
    end

    test "collection hint fires by name when an eval defs a large map collection" do
      Config.set(%{Config.get() | collection_hint: true, max_session_preview_chars: 100_000})

      previous = %{memory: %{}}
      committed = collection_hint_committed()
      rows = for i <- 1..30, do: %{"id" => i}

      step = %{
        return: "#'rows",
        memory: %{"rows" => rows},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["feedback"] =~ "Binding `rows` is a collection of 30 maps"
      assert payload["feedback"] =~ "(describe rows {:paths true})"
    end

    test "binding hint preserves the result truncation hint when both apply" do
      Config.set(%{Config.get() | collection_hint: true, max_session_preview_chars: 20})

      previous = %{memory: %{}}
      committed = collection_hint_committed()
      rows = for i <- 1..30, do: %{"id" => i}

      step = %{
        return: String.duplicate("a", 200),
        memory: %{"rows" => rows},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["feedback"] =~ "(describe *1)"
      assert payload["feedback"] =~ "Binding `rows` is a collection of 30 maps"
    end

    test "no repeated binding hint when the binding did not change this eval" do
      Config.set(%{Config.get() | collection_hint: true, max_session_preview_chars: 100_000})

      rows = for i <- 1..30, do: %{"id" => i}
      previous = %{memory: %{"rows" => rows}}
      committed = collection_hint_committed()

      step = %{
        return: 42,
        memory: %{"rows" => rows},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      refute payload["feedback"] =~ "collection of"
    end

    test "no collection hint when history stores a preview marker instead of the value" do
      Config.set(%{Config.get() | collection_hint: true})

      previous = %{memory: %{}}
      committed = collection_hint_committed()
      rows = for i <- 1..25, do: %{"id" => i}
      step = %{return: rows, memory: %{}, prints: [], tool_calls: [], upstream_calls: []}

      history_notices = [
        %{reason: "max_history_entry_bytes", message: "*1 stored as preview"}
      ]

      payload = Projection.eval_success(previous, committed, step, history_notices)

      refute payload["feedback"] =~ "collection of"
      refute payload["feedback"] =~ "(describe *1"
    end

    test "eval_success does not add result describe hint when history stores a preview marker" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: String.duplicate("a", 200),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      history_notices = [
        %{reason: "max_history_entry_bytes", message: "*1 stored as preview"}
      ]

      payload = Projection.eval_success(previous, committed, step, history_notices)

      assert payload["truncated"] == true
      refute payload["feedback"] =~ "(describe *1)"
      assert payload["feedback"] =~ "*1 stored as preview"
    end
  end

  describe "Sessions.Owner derivation" do
    test "from_context/1 maps nil and empty map to the process stdio owner" do
      {:ok, a} = Owner.from_context(nil)
      {:ok, b} = Owner.from_context(%{})
      assert a.transport == :stdio
      assert a == b
    end

    test "from_context/1 derives an http owner from string keys" do
      assert {:ok, owner} =
               Owner.from_context(%{"transport" => "http", "mcp_session_id" => "sess-1"})

      assert owner.transport == :http
      assert owner.mcp_session_id == "sess-1"
    end

    test "from_context/1 normalizes an explicit owner override" do
      assert {:ok, owner} =
               Owner.from_context(%{owner: %{transport: :stdio, instance_id: "abc"}})

      assert owner == %{transport: :stdio, instance_id: "abc"}
    end

    test "from_context/1 rejects an unknown transport" do
      assert Owner.from_context(%{transport: :carrier_pigeon}) == {:error, :session_args_error}
    end

    test "from_context/1 rejects a non-map, non-list context" do
      assert Owner.from_context(123) == {:error, :session_args_error}
    end

    test "normalize/1 rejects an http owner with a blank session id" do
      assert Owner.normalize(%{transport: :http, mcp_session_id: ""}) ==
               {:error, :session_args_error}
    end

    test "check/2 authorizes equal owners and rejects mismatches" do
      owner = Owner.stdio()
      assert Owner.check(owner, owner) == :ok
      assert Owner.check(owner, @forged_owner) == {:error, :session_owner_mismatch}
    end

    test "fingerprint/1 is stable and distinguishes distinct owners" do
      owner = Owner.stdio()
      assert Owner.fingerprint(owner) == Owner.fingerprint(owner)
      refute Owner.fingerprint(owner) == Owner.fingerprint(@forged_owner)
    end
  end

  describe "Session.lisp_opts setup ceiling" do
    # Heap re-baseline (docs/plans/sandbox-heap-rebaseline.md): every eval
    # passes a setup ceiling sized for the program budget plus the session
    # memory copied in at spawn, at the pinned 5x refc amplification.
    test "derives setup_max_heap from max_heap and the session memory limit" do
      snapshot = %{
        memory: %{},
        turn_history: [],
        limits: %{Config.session_limits() | max_memory_bytes: 8_000_000}
      }

      opts = Session.lisp_opts(snapshot, "(+ 1 2)", %{})
      max_heap = Keyword.fetch!(opts, :max_heap)

      assert Keyword.fetch!(opts, :setup_max_heap) ==
               4 * max_heap + 5 * div(8_000_000, 8)
    end

    test "an explicit :setup_max_heap override wins" do
      snapshot = %{memory: %{}, turn_history: [], limits: Config.session_limits()}

      opts = Session.lisp_opts(snapshot, "(+ 1 2)", %{setup_max_heap: 123_456})
      assert Keyword.fetch!(opts, :setup_max_heap) == 123_456
    end
  end

  defp collection_hint_committed do
    %{
      id: "sess-coll",
      turn: 1,
      memory: %{},
      turn_history: [],
      prints: [],
      tool_calls: [],
      upstream_calls: []
    }
  end

  defp call(name, args) do
    Tools.call(%{"name" => name, "arguments" => args})
  end

  defp measured_scoped_base_session(stage, scoped?) do
    start =
      call("lisp_session_start", %{
        "tags" => %{"stage" => stage, "cell" => "dir"},
        "preludes" => ["paged_audit"],
        "scoped_base_surface" => scoped?
      })

    assert start["isError"] == false
    assert %{"session_id" => sid} = start["structuredContent"]

    dir =
      call("lisp_session_eval", %{
        "session_id" => sid,
        "program" => ~S|(dir 'paged_base)|
      })

    assert dir["isError"] == false

    call("lisp_session_close", %{
      "session_id" => sid,
      "reason" => "retag measurement"
    })

    start =
      call("lisp_session_start", %{
        "tags" => %{"stage" => stage, "cell" => "task"},
        "preludes" => ["paged_audit"],
        "scoped_base_surface" => scoped?
      })

    assert start["isError"] == false
    assert %{"session_id" => sid} = start["structuredContent"]

    task =
      call("lisp_session_eval", %{
        "session_id" => sid,
        "program" => ~S|(paged_audit/check "case-1")|
      })

    assert task["isError"] == false
    %{dir: dir["structuredContent"], result: task["structuredContent"]["result"]}
  end

  defp single_tagged_turn(events, stage, cell) do
    tags = %{"stage" => stage, "cell" => cell}

    assert [turn] =
             Enum.filter(Analyzer.turn_events(events), fn turn ->
               turn_matches_tags?(turn, tags)
             end)

    turn
  end

  defp turn_matches_tags?(%{"tags" => event_tags}, tags) when is_map(event_tags) do
    Enum.all?(tags, fn {key, value} -> Map.get(event_tags, key) == value end)
  end

  defp turn_matches_tags?(_turn, _tags), do: false

  defp test_prelude_source do
    """
    (ns smoke {:visibility :prompt})
    (defn plus-one "Increment a number." [x] (+ x 1))
    """
  end

  defp observatory_root_config(base_url) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => base_url,
          "schema_file" => @schema,
          "include_operations" => ["list_traces", "get_trace"],
          "allow_insecure_http" => true
        }
      }
    }
  end

  defp start_http_fixture(response_body) do
    parent = self()
    response_json = Jason.encode!(response_body)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
        send(parent, {:http_fixture_request, request})

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: application/json\r\n",
          "content-length: #{byte_size(response_json)}\r\n",
          "connection: close\r\n",
          "\r\n",
          response_json
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}"}}
  end

  defp operator_prelude_source_with_evidence do
    """
    (ns operator {:visibility :prompt})
    (defn list-store [] (tool/prelude_store_list {}))
    """ <>
      "\n\n;; --- ptc_runner evidence prelude ---\n\n" <> PtcRunner.Evidence.prelude_source()
  end

  defp role_policy!(role, opts \\ []) do
    {:ok, policy} =
      role
      |> role_policy_json(opts)
      |> Policy.from_map()

    policy
  end

  defp outer_policy!(mcp_tools) do
    {:ok, policy} =
      %{"outer_policy" => %{"mcp_tools" => mcp_tools}}
      |> Policy.from_map()

    policy
  end

  defp role_policy_json(role, opts \\ []) do
    grant =
      %{}
      |> maybe_put_json("ptc_tools", Keyword.get(opts, :ptc_tools))
      |> maybe_put_json("upstream_tools", Keyword.get(opts, :upstream_tools, []))
      |> maybe_put_json("credentials", Keyword.get(opts, :credentials))
      |> maybe_put_json("prelude_store", Keyword.get(opts, :prelude_store))
      |> maybe_put_json("preludes", Keyword.get(opts, :preludes))
      |> maybe_put_json("modes", Keyword.get(opts, :modes))
      |> maybe_put_json("strict_transitive_calls", Keyword.get(opts, :strict_transitive_calls))

    %{
      "default_role" => role,
      "roles" => %{
        role => grant
      }
    }
  end

  defp maybe_put_json(map, _key, nil), do: map
  defp maybe_put_json(map, key, value), do: Map.put(map, key, value)

  defp write_role_policy!(dir, policy) do
    path = Path.join(dir, "roles.json")
    File.write!(path, Jason.encode!(policy, pretty: true))
    path
  end

  defp write_evidence_bundle!(dir, content \\ "operator-selected facts\n") do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "summary.md"), content)

    manifest = %{
      "schema_version" => 1,
      "bundle_id" => "mcp/evidence",
      "items" => [
        %{
          "id" => "summary",
          "kind" => "markdown",
          "path" => "summary.md",
          "model_visible" => true
        }
      ]
    }

    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest, pretty: true))
    path
  end

  defp install_config_and_capture_logs!(resolve_args) do
    McpTestHelpers.capture_json_logs(fn ->
      {:ok, config} = Config.resolve(Map.new(resolve_args))
      Config.set(config)
    end)
  end

  defp inspect_view(sid, view) do
    call("lisp_session_inspect", %{"session_id" => sid, "view" => view})["structuredContent"]
  end

  defp commit_tool_eval!(sid) do
    owner = Owner.stdio()
    {:ok, meta} = SessionsRegistry.lookup(sid)
    request_id = make_ref()
    program = "(tool/fetch {:id 1})"

    {:ok, snapshot} =
      Session.begin_eval(meta.pid, owner, request_id, %{program: program})

    tools = %{"fetch" => fn %{"id" => id} -> %{"id" => id} end}
    result = Sessions.run_snapshot(snapshot, program, %{tools: tools})

    assert {:ok, response} =
             Session.commit_eval(meta.pid, owner, request_id, result, %{})

    assert response["status"] == "ok"
  end

  defp commit_discovery_eval!(sid) do
    owner = Owner.stdio()
    {:ok, meta} = SessionsRegistry.lookup(sid)
    request_id = make_ref()
    program = ~s|(apropos "github" {:limit 1})|

    {:ok, snapshot} =
      Session.begin_eval(meta.pid, owner, request_id, %{program: program})

    discovery_exec = fn
      :apropos, ["github" | _] ->
        {:ok, ["github.search(query) - Search repositories"]}

      operation, args ->
        {:programmer_fault, "unexpected discovery call #{inspect({operation, args})}"}
    end

    result = Sessions.run_snapshot(snapshot, program, %{discovery_exec: discovery_exec})

    assert {:ok, response} =
             Session.commit_eval(meta.pid, owner, request_id, result, %{})

    assert response["status"] == "ok"
  end

  defp commit_call_tool_eval!(sid, program) do
    owner = Owner.stdio()
    {:ok, meta} = SessionsRegistry.lookup(sid)
    request_id = make_ref()

    {:ok, snapshot} =
      Session.begin_eval(meta.pid, owner, request_id, %{program: program})

    result = Sessions.run_snapshot(snapshot, program, %{tools: %{"call" => &call_tool_stub/1}})

    response = Session.commit_eval(meta.pid, owner, request_id, result, %{})
    assert match?({:ok, _}, response) or match?({:error, _}, response)
    response
  end

  defp call_tool_stub(%{"tool" => "fail_trace"}), do: raise("upstream failed")

  defp call_tool_stub(%{"server" => server, "tool" => tool, "args" => args}) do
    %{"server" => server, "tool" => tool, "args" => args}
  end

  defp stop_turn_log! do
    case TurnLogConfig.collector() do
      nil -> :ok
      collector -> assert {:ok, _path, 0} = Collector.stop(collector)
    end

    TurnLogConfig.put_collector(nil)
  end

  # `lisp_session_close` / eviction makes the Session GenServer reply (or
  # stop) and then `cast`s `mark_closed` to the Registry. A synchronous
  # `:sys.get_state` drains all preceding casts so the tombstone is
  # observable — no `Process.sleep` poll loop.
  defp drain_registry do
    case Process.whereis(SessionsRegistry) do
      nil -> :ok
      pid -> _ = :sys.get_state(pid, 5_000)
    end

    :ok
  end

  # `Sessions.close/3` stops the session process; the Registry frees the
  # per-owner quota slot only when it handles that process's monitor `:DOWN`
  # (registry.ex `handle_info({:DOWN, ...})` removes the session from
  # `sessions` and releases the owner index together). `:sys.get_state` orders
  # only messages already enqueued, so it cannot wait for that async `:DOWN`.
  # Poll the Registry's authoritative state until the session is gone —
  # deterministic, yields the scheduler between checks, no `Process.sleep`.
  defp await_session_removed(sid, attempts \\ 5_000) do
    pid = Process.whereis(SessionsRegistry)

    cond do
      is_nil(pid) ->
        :ok

      not Map.has_key?(:sys.get_state(pid, 5_000).sessions, sid) ->
        :ok

      attempts > 0 ->
        :erlang.yield()
        await_session_removed(sid, attempts - 1)

      true ->
        flunk("Sessions.Registry did not process :DOWN for session #{sid}")
    end
  end

  # The public `lookup/1` first consults the partitioned `Sessions.Names`
  # `Registry`, whose dead-pid pruning is asynchronous and can briefly
  # return a stale live entry after a `:DOWN`. For a deterministic
  # tombstone assertion, drain the `Sessions.Registry` GenServer (so its
  # own `:DOWN` handler has run) and query it authoritatively by pid,
  # which skips the racy fast-path.
  defp tombstone_lookup(sid) do
    pid = Process.whereis(SessionsRegistry)
    _ = :sys.get_state(pid, 5_000)
    SessionsRegistry.lookup(sid, pid)
  end

  @names_registry PtcRunnerMcp.Sessions.Names

  # Deterministically wait for the partitioned `Sessions.Names` registry to
  # prune a dead session's entry. The session pid is already confirmed down
  # by a `:DOWN` assertion at the call site; here we only yield the
  # scheduler (never `Process.sleep`) on a bounded budget until the
  # registry's own monitor has cleaned up.
  defp await_names_pruned(sid, attempts \\ 1_000)

  defp await_names_pruned(_sid, 0), do: :ok

  defp await_names_pruned(sid, attempts) do
    case Elixir.Registry.lookup(@names_registry, sid) do
      [] ->
        :ok

      _live ->
        :erlang.yield()
        await_names_pruned(sid, attempts - 1)
    end
  end
end
