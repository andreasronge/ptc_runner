defmodule LLMClient.ProvidersTest do
  use ExUnit.Case, async: true

  describe "generate_object/4" do
    test "returns structured_output_not_supported for ollama" do
      assert {:error, :structured_output_not_supported} =
               LLMClient.generate_object("ollama:model", [], %{})
    end

    test "returns structured_output_not_supported for openai-compat" do
      assert {:error, :structured_output_not_supported} =
               LLMClient.generate_object("openai-compat:http://localhost|model", [], %{})
    end
  end

  describe "generate_object!/4" do
    test "raises for ollama" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        LLMClient.generate_object!("ollama:model", [], %{})
      end
    end

    test "raises for openai-compat" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        LLMClient.generate_object!("openai-compat:http://localhost|model", [], %{})
      end
    end
  end
end
