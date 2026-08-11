defmodule PtcRunner.Kernel.RepoAnalystE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Runs the shipped `repo-analyst` facade against the real filesystem MCP server.

  The structural test covers the package as files. This one covers the part
  files cannot prove on their own: that `repo.clj` speaks the protocol the
  server actually implements, that evidence past the first page is reachable,
  and that once a prompt-visible facade exists the raw `tool/` entries leave
  the model's catalog.

  No model is involved. The workflow component here plays the part `agent.core`
  would play with a live provider, so the facade is exercised without
  credentials.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @root Path.expand("../../..", __DIR__)
  @server Path.join(@root, "examples/mcp/filesystem/dist/server.js")
  @facade Path.join(@root, "repo-analyst/repo.clj")

  # repo/search asks for 20 results a page, so evidence in the 25th match can
  # only be reached by following next_cursor.
  @filler 24

  @tag :tmp_dir
  test "the shipped facade reaches evidence that exists only after the first page", %{
    tmp_dir: dir
  } do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node, search_program())

    {:ok, host} = HostConfig.load(paths.host)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    assert {:ok, built} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)

    assert [provider_snapshot] = built.config.connector_snapshots
    assert {:ok, result} = PtcRunner.Kernel.run(built.entry_source, built.config)

    assert %{
             "status" => "ok",
             "value" => %{"outcome" => "returned", "value" => value}
           } = result.value

    # The literal is in every file, so page one is full and cannot contain the
    # last match. Finding it at all means the cursor was followed.
    assert value["pages"] == 2
    assert value["evidence_path"] == "zz-beacon.txt"
    assert value["first_page_paths"] |> length() == 20
    refute "zz-beacon.txt" in value["first_page_paths"]

    # Every citation is bound to the bytes that were queried.
    assert value["snapshot_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert value["read"]["snapshot_hash"] == value["snapshot_hash"]
    assert provider_snapshot["content_snapshot_hash"] == value["snapshot_hash"]

    # read-range asked for inclusive lines 2..3 and must translate that into
    # start_line 2 with line_count 2 rather than reading the whole file.
    assert value["read"]["lines"] == [
             %{"line" => 2, "text" => "beacon-alpha"},
             %{"line" => 3, "text" => "needle"}
           ]

    assert value["read"]["total_lines"] == 3
    assert value["read"]["end_of_file"]
    # The listing also contains this test's own manifest and component files,
    # so assert coverage rather than an exact count.
    assert "zz-beacon.txt" in value["listing_paths"]
    assert length(value["listing_paths"]) >= @filler + 1
  end

  @tag :tmp_dir
  test "a prompt-visible facade removes raw tool entries from the model catalog", %{
    tmp_dir: dir
  } do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node, nil, workflow: prompt_workflow())

    {:ok, host} = HostConfig.load(paths.host)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    # This workflow returns the rendered prompt directly rather than through
    # kernel-eval, so the projected value is the prompt string itself.
    assert {:ok, result} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()

    assert is_binary(prompt = result.value)

    for name <- ~w(repo/ls repo/find-files repo/search repo/read-range) do
      assert prompt =~ name, "#{name} must appear in the model's catalog"
    end

    refute prompt =~ "(tool/workspace.",
           "raw mapped tools must be suppressed once a facade is prompt-visible"

    refute prompt =~ "cap/unwrap!",
           "cap is composition-only and must not enter the catalog"
  end

  @tag :tmp_dir
  test "an invalid content identity closes provider assembly", %{tmp_dir: dir} do
    node = System.find_executable("node") || flunk("Node.js is required for this E2E")
    paths = write_application(dir, node, search_program())

    host =
      paths.host
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["install", "workspace", "snapshot_identity", "field"], "missing_hash")

    File.write!(paths.host, Jason.encode!(host))
    {:ok, decoded} = HostConfig.load(paths.host)

    {:ok, registry} =
      HostInstallation.catalog(decoded)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(decoded, catalog)
      end)

    assert {:error, :mcp_invalid_snapshot_identity} =
             paths.manifest
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
  end

  @tag :tmp_dir
  test "the shipped host config captures this repository without its dependency trees", %{
    tmp_dir: dir
  } do
    # The other tests build a host document, so they prove the facade rather
    # than the file an operator actually runs. This one spawns the server from
    # the committed repo-analyst.host.json, which is the only way to catch a
    # command that will not resolve or an argument the server rejects.
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"kind" :source "source" (get input "program")})))|
    )

    program = """
    (return {"info" (repo-probe/info) "dependency_hits" (repo-probe/find "node_modules")})
    """

    File.write!(Path.join(dir, "probe.clj"), """
    (ns repo-probe "Bounded snapshot probe." {:visibility :prompt})
    (defn info [] (cap/unwrap! (tool/workspace.info {})))
    (defn find [query] (cap/unwrap! (tool/workspace.find {"query" query "limit" 10})))
    """)

    manifest = %{
      "$schema" => Path.join(@root, "priv/schemas/ptc-application-manifest.schema.json"),
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "missions" => %{
        "default" => %{
          "components" => [
            %{"library" => "cap"},
            %{"id" => "repo-probe", "path" => "probe.clj", "dependencies" => ["cap"]}
          ],
          "data" => %{},
          "providers" => ["workspace"]
        }
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{"mission" => [%{"name" => "workspace"}]},
      "limits" => %{"evaluation_timeout_ms" => 60_000, "run_duration_ms" => 180_000}
    }

    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    {:ok, host} = HostConfig.load(Path.join(@root, "repo-analyst.host.json"))

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    assert {:ok, result} =
             manifest_path
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()

    assert %{
             "status" => "ok",
             "value" => %{"outcome" => "returned", "value" => value}
           } = result.value

    info = value["info"]
    assert info["file_count"] > 300, "the include set should reach most of the source tree"

    assert info["truncated"] == %{"bytes" => false, "depth" => false, "files" => false},
           "a truncated capture means the include set outgrew the server's ceilings"

    # examples/** and priv/** would otherwise pull in a dependency tree: the
    # server snapshots the working tree, not git, so a gitignored node_modules
    # still lands in the capture and in the model's reach.
    assert value["dependency_hits"]["items"] == []
  end

  # Pages repo/search explicitly, exactly as generated code would: nil first,
  # then the previous next_cursor, stopping as soon as the evidence appears.
  defp search_program do
    """
    (let [first-page (repo/search "needle" nil)
          found (loop [page first-page
                       pages 1]
                  (let [hit (first (filter #(= "zz-beacon.txt" (get % "path"))
                                           (get page "items")))]
                    (if hit
                      {"pages" pages "hit" hit}
                      (let [cursor (get page "next_cursor")]
                        (if cursor
                          (recur (repo/search "needle" cursor) (inc pages))
                          {"pages" pages "hit" nil})))))
          hit (get found "hit")
          listing (repo/ls "" nil)]
      (if (nil? hit)
        (fail {"error" "evidence-not-found"})
        (return
          {"pages" (get found "pages")
           "evidence_path" (get hit "path")
           "first_page_paths" (mapv #(get % "path") (get first-page "items"))
           "snapshot_hash" (get first-page "snapshot_hash")
           "listing_paths" (mapv #(get % "path") (get listing "items"))
           "read" (repo/read-range "zz-beacon.txt" 2 3)})))
    """
  end

  defp prompt_workflow do
    ~S|(ns app) (defn run [_input] (return (agent.prompt/render (agent.prompt/initial-state {"max_turns" 4}))))|
  end

  defp write_application(dir, node, program, opts \\ []) do
    File.write!(Path.join(dir, "zz-beacon.txt"), "first\nbeacon-alpha\nneedle\n")

    for index <- 1..@filler do
      name = "f#{String.pad_leading(Integer.to_string(index), 2, "0")}.txt"
      File.write!(Path.join(dir, name), "needle\n")
    end

    # The facade under test is the shipped file, copied verbatim so the manifest
    # can confine it to its own directory.
    facade_source = File.read!(@facade)
    File.write!(Path.join(dir, "repo.clj"), facade_source)

    workflow_source =
      Keyword.get(
        opts,
        :workflow,
        ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"kind" :source "source" (get input "program")})))|
      )

    File.write!(Path.join(dir, "workflow.clj"), workflow_source)

    manifest = manifest(program, Keyword.has_key?(opts, :workflow))
    host = host(dir, node)

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "ptc-host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))
    %{manifest: manifest_path, host: host_path}
  end

  defp manifest(program, prompt_mode?) do
    workflow_components =
      if prompt_mode? do
        [
          %{"library" => "kernel"},
          %{"library" => "agent.prompt"},
          %{"id" => "app", "path" => "workflow.clj", "dependencies" => ["agent.prompt"]}
        ]
      else
        [%{"id" => "app", "path" => "workflow.clj"}]
      end

    %{
      "$schema" => Path.join(@root, "priv/schemas/ptc-application-manifest.schema.json"),
      "version" => 1,
      "workflow" => %{"components" => workflow_components, "entry" => "app/run"},
      "missions" => %{
        "default" => %{
          "components" => [
            %{"library" => "cap"},
            %{"id" => "repo", "path" => "repo.clj", "dependencies" => ["cap"]}
          ],
          "data" => %{},
          "providers" => ["workspace"]
        }
      },
      "input" => %{"value" => if(program, do: %{"program" => program}, else: %{})},
      "providers" => %{
        "mission" => [
          %{
            "name" => "workspace",
            "config" => %{
              "allow" => [
                "workspace.list",
                "workspace.find",
                "workspace.search",
                "workspace.read"
              ]
            }
          }
        ]
      },
      "limits" => %{"evaluation_timeout_ms" => 20_000, "run_duration_ms" => 90_000}
    }
  end

  defp host(dir, node) do
    %{
      "$schema" => Path.join(@root, "priv/schemas/ptc-host-config.schema.json"),
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => node,
            "cwd" => dir,
            "args" => [@server, "--root", dir, "--include", "**"],
            "inherit_environment" => false,
            "env" => %{},
            "start_timeout_ms" => 15_000
          },
          "tools" => %{
            "list_directory" => %{"as" => "workspace.list", "effect" => "read"},
            "search_files" => %{"as" => "workspace.find", "effect" => "read"},
            "search_text" => %{
              "as" => "workspace.search",
              "effect" => "read",
              "error_feedback" => "bounded"
            },
            "read_text_file" => %{
              "as" => "workspace.read",
              "effect" => "read",
              "error_feedback" => "bounded"
            },
            "snapshot_info" => %{"as" => "workspace.info", "effect" => "read"}
          },
          "snapshot_identity" => %{
            "tool" => "snapshot_info",
            "field" => "snapshot_hash"
          },
          "installation_revision" => "filesystem-sample-0.1.0",
          "ceilings" => %{
            "timeout_ms" => 15_000,
            "max_catalog_tools" => 8,
            "max_result_bytes" => 262_144
          }
        }
      }
    }
  end
end
