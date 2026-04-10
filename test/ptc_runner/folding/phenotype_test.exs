defmodule PtcRunner.Folding.PhenotypeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Phenotype

  describe "develop/1" do
    test "produces valid PTC-Lisp from a hand-crafted genotype" do
      # This should fold into something with get + field_key at minimum
      assert {:ok, source} = Phenotype.develop("DaK5QAS")
      assert is_binary(source)
      assert String.length(source) > 0
    end

    test "returns error for spacer-only genotype" do
      assert {:error, :no_fragments} = Phenotype.develop("WWWXYZ")
    end

    test "single data source character produces a symbol" do
      assert {:ok, source} = Phenotype.develop("S")
      assert source == "data/products"
    end

    test "empty genotype returns error" do
      assert {:error, :no_fragments} = Phenotype.develop("")
    end
  end

  describe "develop_debug/1" do
    test "returns full pipeline state" do
      result = Phenotype.develop_debug("DaK5")
      assert is_map(result)
      assert Map.has_key?(result, :grid)
      assert Map.has_key?(result, :placements)
      assert Map.has_key?(result, :fragments)
      assert Map.has_key?(result, :source)
      assert Map.has_key?(result, :valid?)
      assert result.genotype == "DaK5"
      assert result.grid_size > 0
    end
  end

  describe "validity_rate/2" do
    test "returns a float between 0 and 1" do
      rate = Phenotype.validity_rate(10, 100)
      assert is_float(rate)
      assert rate >= 0.0
      assert rate <= 1.0
    end

    test "longer genotypes have some validity" do
      rate = Phenotype.validity_rate(20, 100)
      assert rate > 0.0
    end
  end
end
