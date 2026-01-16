defmodule PtcRunner.SubAgent.JsonParserTest do
  use ExUnit.Case

  alias PtcRunner.SubAgent.JsonParser

  doctest PtcRunner.SubAgent.JsonParser

  describe "parse/1" do
    test "extracts JSON from ```json code block" do
      response = """
      ```json
      {"sentiment": "positive", "score": 0.95}
      ```
      """

      assert {:ok, %{"sentiment" => "positive", "score" => 0.95}} = JsonParser.parse(response)
    end

    test "extracts JSON from ``` code block (no language)" do
      response = """
      ```
      {"name": "Alice", "age": 30}
      ```
      """

      assert {:ok, %{"name" => "Alice", "age" => 30}} = JsonParser.parse(response)
    end

    test "extracts raw JSON object" do
      response = ~s|{"count": 42, "valid": true}|

      assert {:ok, %{"count" => 42, "valid" => true}} = JsonParser.parse(response)
    end

    test "extracts raw JSON array" do
      response = ~s|[1, 2, 3, "four"]|

      assert {:ok, [1, 2, 3, "four"]} = JsonParser.parse(response)
    end

    test "handles trailing text after JSON" do
      response = ~s|{"a": 1} Let me know if you need anything else!|

      assert {:ok, %{"a" => 1}} = JsonParser.parse(response)
    end

    test "handles explanation prefix before JSON" do
      response = """
      Here's the result:
      {"message": "hello"}
      """

      assert {:ok, %{"message" => "hello"}} = JsonParser.parse(response)
    end

    test "returns :no_json_found when no JSON present" do
      response = "This is just plain text with no JSON content."

      assert {:error, :no_json_found} = JsonParser.parse(response)
    end

    test "returns :invalid_json for malformed JSON" do
      response = """
      ```json
      {"invalid": missing_quotes}
      ```
      """

      assert {:error, :invalid_json} = JsonParser.parse(response)
    end

    test "handles nested JSON structures" do
      response =
        ~s|{"user": {"name": "Bob", "profile": {"bio": "Developer", "skills": ["elixir", "rust"]}}}|

      assert {:ok, result} = JsonParser.parse(response)
      assert result["user"]["name"] == "Bob"
      assert result["user"]["profile"]["bio"] == "Developer"
      assert result["user"]["profile"]["skills"] == ["elixir", "rust"]
    end

    test "handles JSON with escaped characters" do
      response = ~s|{"message": "Hello \\"World\\"", "path": "C:\\\\Users\\\\test"}|

      assert {:ok, result} = JsonParser.parse(response)
      assert result["message"] == "Hello \"World\""
      assert result["path"] == "C:\\Users\\test"
    end

    test "prefers code block over raw JSON when both present" do
      response = """
      Here's some raw json: {"raw": true}

      ```json
      {"from_block": true}
      ```
      """

      assert {:ok, %{"from_block" => true}} = JsonParser.parse(response)
    end

    test "handles code block with extra whitespace" do
      response = """
      ```json

        {"spaced": "out"}

      ```
      """

      assert {:ok, %{"spaced" => "out"}} = JsonParser.parse(response)
    end

    test "handles empty code block" do
      response = """
      ```json
      ```
      """

      # Should fall through to try raw JSON extraction
      assert {:error, :no_json_found} = JsonParser.parse(response)
    end

    test "handles array in code block" do
      response = """
      ```json
      ["item1", "item2", {"nested": true}]
      ```
      """

      assert {:ok, ["item1", "item2", %{"nested" => true}]} = JsonParser.parse(response)
    end

    test "handles JSON with braces in strings" do
      response = ~s|{"template": "Hello {name}!", "regex": "[a-z]{3}"}|

      assert {:ok, result} = JsonParser.parse(response)
      assert result["template"] == "Hello {name}!"
      assert result["regex"] == "[a-z]{3}"
    end

    test "handles deeply nested arrays and objects" do
      response = ~s|{"level1": [{"level2": [{"level3": {"value": 42}}]}]}|

      assert {:ok, result} = JsonParser.parse(response)

      assert get_in(result, ["level1", Access.at(0), "level2", Access.at(0), "level3", "value"]) ==
               42
    end

    test "handles JSON with unicode characters" do
      response = ~s|{"greeting": "Hello, \u4e16\u754c!", "emoji": "\u2764\ufe0f"}|

      assert {:ok, result} = JsonParser.parse(response)
      assert result["greeting"] == "Hello, \u4E16\u754C!"
    end

    test "handles raw array with trailing text" do
      response = ~s|["a", "b", "c"] That's the list you requested.|

      assert {:ok, ["a", "b", "c"]} = JsonParser.parse(response)
    end

    test "handles JSON embedded mid-sentence" do
      response = ~s|The answer is {"result": "success"} as expected.|

      assert {:ok, %{"result" => "success"}} = JsonParser.parse(response)
    end
  end
end
