defmodule PtcRunnerMcp.AgenticCapabilitySummaryTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Agentic.CapabilitySummary
  alias PtcRunnerMcp.Upstream.Catalog

  setup do
    Catalog.clear_frozen()

    on_exit(fn ->
      Catalog.clear_frozen()
    end)

    :ok
  end

  test "empty upstream set produces an empty summary" do
    assert CapabilitySummary.generate([]) == ""
  end

  test "sorts upstreams and marks tools without schemas as unknown content" do
    entries = [
      %{
        name: "github",
        tools: [
          %{name: "search_code", input_schema: %{"properties" => %{"q" => %{}}}},
          %{name: "get_issue", description: "Read an issue"}
        ]
      },
      %{name: "docs", tools: [%{name: "search"}, %{name: "get_page"}]}
    ]

    assert CapabilitySummary.generate(entries) ==
             "- docs: get_page->:unknown_content, search->:unknown_content\n- github: get_issue->:unknown_content, search_code->:unknown_content"

    refute CapabilitySummary.generate(entries) =~ "input_schema"
    refute CapabilitySummary.generate(entries) =~ "properties"
  end

  test "includes compact output hints when output_schema is available" do
    entries = [
      %{
        name: "docs",
        tools: [
          %{
            name: "search",
            output_schema: %{
              "type" => "object",
              "properties" => %{
                "items" => %{"type" => "array", "items" => %{"type" => "string"}}
              }
            }
          }
        ]
      }
    ]

    assert CapabilitySummary.generate(entries) == "- docs: search->{items [:string]}"
  end

  test "distinguishes malformed and empty output schemas" do
    entries = [
      %{
        name: "alpha",
        tools: [
          %{name: "missing"},
          %{name: "nil_schema", output_schema: nil},
          %{name: "bad_schema", output_schema: "not-a-schema"},
          %{name: "empty_schema", output_schema: %{}}
        ]
      }
    ]

    assert CapabilitySummary.generate(entries) ==
             "- alpha: bad_schema->:unknown_content, empty_schema->:any, missing->:unknown_content, nil_schema->:unknown_content"
  end

  test "uses the frozen structured snapshot" do
    Catalog.freeze_snapshot([
      %{name: "zeta", tools: [%{name: "last"}]},
      %{name: "alpha", tools: [%{name: "first"}]}
    ])

    assert CapabilitySummary.from_frozen() ==
             "- alpha: first->:unknown_content\n- zeta: last->:unknown_content"
  end

  test "clips tool lists and never exceeds max bytes" do
    entries = [
      %{
        name: "github",
        tools: [
          %{name: "alpha_long"},
          %{name: "beta_long"},
          %{name: "gamma_long"},
          %{name: "delta_long"},
          %{name: "epsilon_long"}
        ]
      },
      %{name: "linear", tools: [%{name: "tickets"}]}
    ]

    summary = CapabilitySummary.generate(entries, max_bytes: 35)

    assert byte_size(summary) <= 35
    assert summary =~ "(+5 more)"
    refute summary =~ "beta_long"
  end

  test "marks omitted upstreams when the marker fits" do
    entries = [
      %{name: "a", tools: [%{name: "one"}]},
      %{name: "b_with_extremely_long_name", tools: []},
      %{name: "c", tools: [%{name: "three"}]}
    ]

    summary = CapabilitySummary.generate(entries, max_bytes: 37)

    assert summary == "- a: one->:unknown_content"
    assert byte_size(summary) <= 37
  end

  test "operator override is accepted verbatim when in budget and rejected when oversize" do
    path = Path.join(System.tmp_dir!(), "ptc_capability_summary_#{System.unique_integer()}.txt")
    File.write!(path, "custom\nsummary")

    on_exit(fn -> File.rm(path) end)

    assert CapabilitySummary.read_override(path, 20) == {:ok, "custom\nsummary"}
    assert CapabilitySummary.read_override(path, 5) == {:error, {:too_large, 14, 5}}
  end
end
