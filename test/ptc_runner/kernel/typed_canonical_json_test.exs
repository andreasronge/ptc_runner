defmodule PtcRunner.Kernel.TypedCanonicalJSONTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.TypedCanonicalJSON

  test "golden TJCS vectors preserve every JSON runtime type" do
    value = %{
      "array" => [nil, true, "x", 1, 1.0, -0.0, 9_007_199_254_740_993],
      "object" => %{"é" => false, "z" => 2}
    }

    assert {:ok, encoded} = TypedCanonicalJSON.encode(value)

    assert encoded ==
             ~S(["object",[["array",["array",[["null"],["boolean",true],["string","x"],["integer","1"],["float64","3ff0000000000000"],["float64","8000000000000000"],["integer","9007199254740993"]]]],["object",["object",[["z",["integer","2"]],["é",["boolean",false]]]]]]])
  end

  test "byte admission retains integer/float distinctions and equivalent float spellings" do
    assert {:ok, integer} = StrictJSON.decode("1")
    assert {:ok, float} = StrictJSON.decode("1.0")
    assert {:ok, exponent} = StrictJSON.decode("1e0")

    assert {:ok, integer_bytes} = TypedCanonicalJSON.encode(integer)
    assert {:ok, float_bytes} = TypedCanonicalJSON.encode(float)
    assert {:ok, exponent_bytes} = TypedCanonicalJSON.encode(exponent)

    assert integer_bytes == ~S(["integer","1"])
    assert float_bytes == ~S(["float64","3ff0000000000000"])
    assert exponent_bytes == float_bytes
    refute integer_bytes == float_bytes
  end

  test "arbitrary-size integers and the 2^53 neighborhood round-trip without float collapse" do
    for integer <- [
          9_007_199_254_740_991,
          9_007_199_254_740_992,
          9_007_199_254_740_993,
          123_456_789_012_345_678_901_234_567_890
        ] do
      assert {:ok, ^integer} = StrictJSON.decode(Integer.to_string(integer))
      assert {:ok, encoded} = TypedCanonicalJSON.encode(integer)
      assert encoded == ~s(["integer","#{integer}"])
    end
  end

  test "shared structural admission rejects duplicates, depth excess, and node excess" do
    assert {:error, :duplicate_json_key} = StrictJSON.decode(~S({"a":1,"a":2}))

    too_deep = String.duplicate("[", 65) <> String.duplicate("]", 65)
    assert {:error, :json_depth_exceeded} = StrictJSON.decode(too_deep)

    assert {:error, :json_node_limit_exceeded} =
             StrictJSON.admit([1, 2], max_nodes: 2)
  end

  test "structural admission rejects unknown and duplicate limit options" do
    assert {:error, :invalid_json} = StrictJSON.admit(%{}, max_node: 1)

    assert {:error, :invalid_json} =
             StrictJSON.decode("{}", max_nodes: 1, max_nodes: 2)
  end

  test "trusted in-memory admission rejects decoder-only ordered-object structs" do
    ordered = %Jason.OrderedObject{values: [{"key", 1}]}
    assert {:error, :invalid_json} = StrictJSON.admit(%{"nested" => ordered})
  end

  test "located admission identifies an invalid UTF-8 object key" do
    assert {:error, {:invalid_json, [{:map_key, 0}], :invalid_utf8}} =
             StrictJSON.admit_with_locations(%{<<255>> => true})
  end
end
