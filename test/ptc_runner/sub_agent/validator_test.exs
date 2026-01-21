defmodule PtcRunner.SubAgent.ValidatorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "timeout validation" do
    test "accepts positive integer timeout" do
      agent = SubAgent.new(prompt: "Test", timeout: 5000)
      assert agent.timeout == 5000
    end

    test "rejects timeout: 0" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        SubAgent.new(prompt: "Test", timeout: 0)
      end
    end

    test "rejects negative timeout" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        SubAgent.new(prompt: "Test", timeout: -1)
      end
    end

    test "rejects timeout: nil" do
      assert_raise ArgumentError, ~r/timeout cannot be nil/, fn ->
        SubAgent.new(prompt: "Test", timeout: nil)
      end
    end

    test "uses default timeout when not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.timeout == 5000
    end
  end

  describe "output validation" do
    test "accepts :ptc_lisp output mode" do
      agent = SubAgent.new(prompt: "Test", output: :ptc_lisp)
      assert agent.output == :ptc_lisp
    end

    test "accepts :json output mode with signature" do
      agent = SubAgent.new(prompt: "Test", output: :json, signature: "() -> {x :string}")
      assert agent.output == :json
    end

    test "rejects invalid output mode atom" do
      assert_raise ArgumentError, ~r/output must be :ptc_lisp or :json/, fn ->
        SubAgent.new(prompt: "Test", output: :invalid)
      end
    end

    test "defaults to :ptc_lisp when output not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.output == :ptc_lisp
    end
  end

  describe "json mode constraints" do
    test "rejects json mode with tools" do
      assert_raise ArgumentError, "output: :json cannot be used with tools", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          tools: %{foo: fn _ -> :ok end}
        )
      end
    end

    test "rejects json mode without signature" do
      assert_raise ArgumentError, "output: :json requires a signature", fn ->
        SubAgent.new(prompt: "Test", output: :json)
      end
    end

    test "rejects json mode with compression: true" do
      assert_raise ArgumentError, "output: :json cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: true
        )
      end
    end

    test "rejects json mode with compression module" do
      assert_raise ArgumentError, "output: :json cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: SomeModule
        )
      end
    end

    test "accepts json mode with compression: nil" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: nil
        )

      assert agent.output == :json
    end

    test "accepts json mode with compression: false" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: false
        )

      assert agent.output == :json
    end

    test "rejects json mode with firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_hidden\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {_hidden :string}"
                     )
                   end
    end

    test "rejects json mode with nested firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_nested\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {x {_nested :int}}"
                     )
                   end
    end

    test "rejects json mode with firewall field in array element" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_secret\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {items [{name :string, _secret :string}]}"
                     )
                   end
    end

    test "accepts json mode with non-firewall nested fields" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {user {name :string, email :string}}"
        )

      assert agent.output == :json
    end

    test "accepts json mode with list of primitives" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {items [:string]}"
        )

      assert agent.output == :json
    end

    test "accepts json mode with optional fields (non-firewall)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {name :string, nickname :string?}"
        )

      assert agent.output == :json
    end

    test "rejects json mode with firewall field inside optional map field" do
      # Optional map field containing another map with firewall field
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_id\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {data {user :string, _id :int}}"
                     )
                   end
    end
  end

  describe "ptc_lisp mode allows all features" do
    test "ptc_lisp mode allows tools" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          tools: %{foo: fn _ -> :ok end}
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows compression" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          compression: true
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows firewall fields in signature" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          signature: "() -> {visible :string, _hidden :string}"
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows no signature" do
      agent = SubAgent.new(prompt: "Test", output: :ptc_lisp)
      assert agent.output == :ptc_lisp
      assert agent.signature == nil
    end
  end
end
