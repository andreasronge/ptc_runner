defmodule PtcRunner.SubAgent.Signature.RendererTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Signature.Renderer

  alias PtcRunner.SubAgent.Signature.Renderer

  describe "to_lisp_key/1" do
    test "converts snake_case to kebab-case" do
      assert Renderer.to_lisp_key("q1_total") == "q1-total"
    end

    test "handles multiple underscores" do
      assert Renderer.to_lisp_key("first_name_last") == "first-name-last"
    end

    test "preserves leading underscore for firewalled names" do
      assert Renderer.to_lisp_key("_email_ids") == "_email-ids"
    end

    test "returns unchanged when no underscores" do
      assert Renderer.to_lisp_key("name") == "name"
    end
  end

  describe "render_type/2 with key_style: :lisp_prompt" do
    test "converts map field names to kebab-case" do
      type = {:map, [{"q1_total", :float}, {"q2_total", :int}]}

      assert Renderer.render_type(type, key_style: :lisp_prompt) ==
               "{q1-total :float, q2-total :int}"
    end

    test "converts nested map field names" do
      type = {:map, [{"user_info", {:map, [{"first_name", :string}]}}]}

      assert Renderer.render_type(type, key_style: :lisp_prompt) ==
               "{user-info {first-name :string}}"
    end

    test "converts field names inside list of maps" do
      type = {:list, {:map, [{"item_count", :int}]}}

      assert Renderer.render_type(type, key_style: :lisp_prompt) ==
               "[{item-count :int}]"
    end

    test "default render_type/1 keeps snake_case" do
      type = {:map, [{"q1_total", :float}]}
      assert Renderer.render_type(type) == "{q1_total :float}"
    end
  end

  describe ":datetime rendering" do
    test "bare :datetime renders as ':datetime'" do
      assert Renderer.render_type(:datetime) == ":datetime"
    end

    test ":datetime in a map field" do
      assert Renderer.render_type({:map, [{"at", :datetime}]}) == "{at :datetime}"
    end

    test "[:datetime] list" do
      assert Renderer.render_type({:list, :datetime}) == "[:datetime]"
    end

    test "optional :datetime" do
      assert Renderer.render_type({:optional, :datetime}) == ":datetime?"
    end
  end
end
