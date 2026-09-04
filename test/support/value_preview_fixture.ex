defmodule PtcRunner.TestSupport.ValuePreviewFixture do
  @moduledoc false

  @fixture Path.expand("../fixtures/value_preview/revenue_forecast.json", __DIR__)

  def tutorial_page do
    text = File.read!(@fixture)

    %{
      "content_hash" => String.duplicate("a", 64),
      "items" => [%{"byte_offset" => 0, "text" => text}],
      "next_cursor" => nil,
      "total_chars" => String.length(text)
    }
  end

  def debug_navigation_page do
    %{
      "page" => %{
        "items" => [
          %{
            "component_id" => "pricing.rule",
            "relationships" => [
              %{
                "filters" => %{"component_id" => "pricing.base"},
                "name" => "dependencies",
                "state" => "complete"
              }
            ],
            "source" => "(ns pricing.rule)"
          }
        ],
        "next_cursor" => nil
      }
    }
  end
end
