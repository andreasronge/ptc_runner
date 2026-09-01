defmodule PtcRunner.Kernel.CommandDocsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.DocumentationLibrary
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic

  @run_ref "cmd-00000000000000000000000001"

  test "the served listing names every embedded page and its exact size" do
    assert {:ok, %CommandOutcome{envelope: %{"status" => "ok"} = envelope}} =
             CommandEngine.dispatch(["docs"])

    assert %{"pages" => pages} = envelope["result"]
    assert Enum.map(pages, & &1["name"]) == DocumentationLibrary.names()

    for %{"name" => name, "title" => title, "bytes" => bytes} <- pages do
      assert {:ok, content} = DocumentationLibrary.fetch(name)
      assert byte_size(content) == bytes
      assert title != ""
    end
  end

  test "every listed page serves its source document verbatim" do
    for name <- DocumentationLibrary.names() do
      assert {:ok, %CommandOutcome{envelope: envelope}} = CommandEngine.dispatch(["docs", name])
      assert envelope["result"] == %{"page" => name, "content" => page_content(name)}
    end
  end

  test "the packaged MCP schema is the exact site wire schema" do
    wire_schema_path =
      Path.expand("../../../site/schemas/mcp-2026-07-28.schema.json", __DIR__)

    assert DocumentationLibrary.source_path("schema-mcp") ==
             "site/schemas/mcp-2026-07-28.schema.json"

    assert {:ok, embedded} = DocumentationLibrary.fetch("schema-mcp")
    assert embedded == File.read!(wire_schema_path)

    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["docs", "schema-mcp"])

    assert envelope["result"] == %{"page" => "schema-mcp", "content" => embedded}
  end

  test "the agent guide is served and answers the questions it promises" do
    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["docs", "agent-guide"])

    guide = envelope["result"]["content"]

    assert String.starts_with?(guide, "# Drive ptc as an agent")
    assert guide =~ "ptc help COMMAND"
    assert guide =~ "--envelope"
    assert guide =~ "ptc repl"
  end

  test "the inspect-source guide routes four tasks and never copies shipped prelude files" do
    assert {:ok, content} = DocumentationLibrary.fetch("inspect-source")
    assert content =~ "(source "
    assert content =~ "(component "
    assert content =~ "retain_programs"
    assert content =~ "analysis/read"

    assert {:ok, customize} = DocumentationLibrary.fetch("components-and-preludes")
    refute customize =~ "cp priv/preludes"
    assert customize =~ "ptc materialize"
    assert customize =~ "inspect-only"
    assert customize =~ "source-out"
  end

  test "the debug page names both transcript destination rules before they can be violated" do
    assert {:ok, content} = DocumentationLibrary.fetch("debug")
    assert content =~ "symbolic link"
    assert content =~ "physically separate"
    assert content =~ "/tmp"
    assert content =~ "mkdir -p out"
    assert content =~ "--private-output"
  end

  test "designing-agent-workflows locates returned-value and quarantined in the example" do
    assert {:ok, content} = DocumentationLibrary.fetch("designing-agent-workflows")
    assert content =~ "returned-value"
    assert content =~ "quarantined"
    assert content =~ "03-specialists/workflow.clj"
    assert content =~ "not shipped"
    assert content =~ "built-ins"
    assert content =~ "ptc init support-triage --example support-triage"
  end

  test "served model docs distinguish cost reservations from measured spend" do
    assert {:ok, limits} = DocumentationLibrary.fetch("limits")
    limits = String.replace(limits, ~r/\s+/, " ")

    assert limits =~ "pre-dispatch reservation ceiling"
    assert limits =~ "not a pre-run price quote"
    assert limits =~ "2,419 microUSD reservation"
    assert limits =~ "limits.llm_request_output_tokens"
    assert limits =~ "params.max_tokens"
    assert limits =~ "not a sizing multiplier"
    assert limits =~ "trustworthy priced usage from successful and failed calls"
    assert limits =~ "possibly dispatched failure without trustworthy usage"

    assert {:ok, diagnostic} =
             RuntimeLimitDiagnostic.budget_message(:llm_cost_microusd, 2_400, 2_419, 2_338)

    assert limits =~ diagnostic

    assert {:ok, using_models} = DocumentationLibrary.fetch("using-models")
    using_models = String.replace(using_models, ~r/\s+/, " ")

    assert using_models =~ "ptc models"
    assert using_models =~ "ptc validate"
    assert using_models =~ "ptc doctor"
    assert using_models =~ "pre-run price quote"
    assert using_models =~ "ptc docs limits"
  end

  test "an unknown page is rejected without echoing the requested name" do
    assert {:error, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["docs", "sensitive-page-name"])

    assert envelope["command"] == "docs"
    assert envelope["error"]["phase"] == "arguments"
    assert envelope["error"]["code"] == "docs_page_unknown"
    refute envelope |> Jason.encode!() |> String.contains?("sensitive-page-name")

    # The failing form is the one place a reader holds a name and cannot see the
    # alternatives, so the rendering lists them.
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["docs", "sensitive-page-name"])

    assert {:stderr, rendered} =
             CommandRenderer.render(outcome, CommandRejection.docs_page_unknown())

    for name <- DocumentationLibrary.names() do
      assert rendered =~ name
    end
  end

  test "docs outcomes satisfy the published envelope schema" do
    assert {:ok, root} = CommandContract.envelope_schema_root()

    for argv <- [
          ["docs"],
          ["docs", "agent-guide"],
          ["docs", "schema-project"],
          ["docs", "schema-mcp"]
        ] do
      assert {:ok, %CommandOutcome{envelope: envelope}} = CommandEngine.dispatch(argv)
      assert {:ok, _validated} = JSV.validate(envelope, root, cast: false)
    end
  end

  test "a page renders verbatim while the listing renders one row per page" do
    listing = CommandOutcome.success(:docs, @run_ref, CommandContract.docs_result(nil))
    page = CommandOutcome.success(:docs, @run_ref, CommandContract.docs_result("limits"))

    assert {:stdout, listing_text} = CommandRenderer.render(listing)
    assert {:stdout, page_text} = CommandRenderer.render(page)

    for name <- DocumentationLibrary.names() do
      assert listing_text =~ name
    end

    assert page_text == page_content("limits")
  end

  test "a listing that omits, reorders, duplicates, or renames a page cannot be sealed" do
    listing = DocumentationLibrary.listing()

    assert %CommandOutcome{} =
             CommandOutcome.success(:docs, @run_ref, %{"pages" => listing})

    mutations = %{
      omitted: Enum.drop(listing, 1),
      reordered: Enum.reverse(listing),
      duplicated: [hd(listing) | listing],
      renamed: [%{hd(listing) | "name" => "not-a-page"} | tl(listing)]
    }

    for {mutation, pages} <- mutations do
      sealed? =
        try do
          CommandOutcome.success(:docs, @run_ref, %{"pages" => pages})
          true
        rescue
          ArgumentError -> false
        end

      refute sealed?, "the sealed outcome admitted a #{mutation} listing"
    end
  end

  test "the envelope schema pins no documentation content" do
    encoded = CommandContract.schema() |> Jason.encode!()

    # Titles, sizes, and bodies are derived from the shipped documents. Pinning
    # any of them here would make every documentation edit rebuild this
    # generated artifact and fail the staleness gate.
    # `schema-envelope` serves this very schema, so its title is the contract's
    # own and appears for that reason rather than because documentation was
    # pinned into it.
    for %{"name" => name, "title" => title, "bytes" => bytes} <- DocumentationLibrary.listing(),
        name != "schema-envelope" do
      refute encoded =~ ~s("#{title}")
      refute encoded =~ ~s("bytes":#{bytes})
    end
  end

  test "docs accepts no publication switch" do
    assert {:error, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["docs", "--envelope", "out.json"])

    assert envelope["error"]["phase"] == "arguments"
  end

  test "no served page prints a link the executable cannot follow" do
    for name <- DocumentationLibrary.names(), not String.starts_with?(name, "schema-") do
      links =
        ~r/!?\[[^\]]*\]\(([^)\s]+)\)/
        |> Regex.scan(page_content(name))
        |> Enum.map(fn [_match, target] -> target end)
        |> Enum.reject(
          &(String.starts_with?(&1, ["http://", "https://", "mailto:", "//"]) or
              String.starts_with?(&1, "#"))
        )

      assert links == [], "#{name} still prints repository-relative links: #{inspect(links)}"
    end
  end

  test "rewriting a page changes only the lines that carry a link" do
    root = Path.expand("../../..", __DIR__)

    for {name, source_path} <- catalog(), not String.starts_with?(name, "schema-") do
      source = File.read!(Path.join(root, source_path)) |> String.split("\n")
      served = page_content(name) |> String.split("\n")

      assert length(source) == length(served),
             "#{name} gained or lost lines while its links were rewritten"

      # A link match spans at most two lines and both carry a bracket, so a line
      # without one must survive untouched. A stray bracket that let link text
      # run across paragraphs corrupted prose exactly this way.
      for {source_line, served_line} <- Enum.zip(source, served),
          not String.contains?(source_line, "[") and not String.contains?(source_line, "]") do
        assert source_line == served_line, "#{name} rewrote a line that carries no link"
      end
    end
  end

  test "every page cross-reference inside the served documentation resolves" do
    for name <- DocumentationLibrary.names(),
        [_match, referenced] <- Regex.scan(~r/`ptc docs ([a-z][a-z-]*)`/, page_content(name)) do
      assert referenced in DocumentationLibrary.names(),
             "#{name} points at unserved page #{referenced}"
    end
  end

  @tag :tmp_dir
  test "the scaffolded AGENTS.md points only at commands and pages this executable serves", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])

    routing = File.read!(Path.join(target, "AGENTS.md"))
    known = Enum.map(CommandDeclaration.commands(), &Atom.to_string/1) ++ ["help"]

    referenced =
      Regex.scan(~r/`ptc ([a-z-]+)/, routing) |> Enum.map(fn [_match, command] -> command end)

    assert referenced != []
    assert Enum.all?(referenced, &(&1 in known)), "unknown command in AGENTS.md: #{routing}"

    for [_match, page] <- Regex.scan(~r/`ptc docs ([a-z-]+)`/, routing) do
      assert page in DocumentationLibrary.names()
    end
  end

  defp catalog do
    Enum.map(DocumentationLibrary.listing(), fn %{"name" => name} ->
      {name, DocumentationLibrary.source_path(name)}
    end)
  end

  defp page_content(name) do
    assert {:ok, content} = DocumentationLibrary.fetch(name)
    content
  end
end
