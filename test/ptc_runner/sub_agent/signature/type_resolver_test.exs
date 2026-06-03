defmodule PtcRunner.SubAgent.Signature.TypeResolverTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Signature.Parser
  alias PtcRunner.SubAgent.Signature.TypeResolver

  doctest PtcRunner.SubAgent.Signature.TypeResolver

  # The Parser produces exactly the `{:signature, params, return}` tuples that
  # TypeResolver consumes, so most tests below drive the REAL parse -> resolve
  # flow rather than hand-building AST. A helper keeps that path explicit.
  defp parse!(signature_string) do
    {:ok, ast} = Parser.parse(signature_string)
    ast
  end

  describe "resolve_path/2 (real parse -> resolve flow)" do
    test "resolves a single scalar param to its type" do
      sig = parse!("(user :string) -> :any")
      assert TypeResolver.resolve_path(sig, ["user"]) == {:ok, :string}
    end

    test "resolves a single list param to the whole list type" do
      sig = parse!("(items [{name :string}]) -> :any")

      assert TypeResolver.resolve_path(sig, ["items"]) ==
               {:ok, {:list, {:map, [{"name", :string}]}}}
    end

    test "returns :param_not_found for an unknown single-segment path" do
      sig = parse!("(user :string) -> :any")

      assert TypeResolver.resolve_path(sig, ["nope"]) ==
               {:error, {:param_not_found, "nope"}}
    end

    test "returns :param_not_found when the first segment of a nested path is unknown" do
      sig = parse!("(items [{name :string}]) -> :any")

      assert TypeResolver.resolve_path(sig, ["missing", "name"]) ==
               {:error, {:param_not_found, "missing"}}
    end

    test "descends through {:list, {:map, _}} to a nested field type" do
      sig = parse!("(items [{name :string, age :int}]) -> :any")
      assert TypeResolver.resolve_path(sig, ["items", "name"]) == {:ok, :string}
      assert TypeResolver.resolve_path(sig, ["items", "age"]) == {:ok, :int}
    end

    test "descends directly through a {:map, _} param" do
      sig = parse!("(profile {name :string, age :int}) -> :any")
      assert TypeResolver.resolve_path(sig, ["profile", "name"]) == {:ok, :string}
    end

    test "descends through an {:optional, {:map, _}} param (optional unwrap)" do
      # The Parser only emits :optional for scalars (e.g. `:string?`), so this
      # branch is exercised with a hand-built AST that is otherwise shaped
      # exactly like a parsed signature.
      sig = {:signature, [{"profile", {:optional, {:map, [{"name", :string}]}}}], :any}
      assert TypeResolver.resolve_path(sig, ["profile", "name"]) == {:ok, :string}
    end

    test "descends through nested list-of-map-of-list to the leaf type" do
      sig = parse!("(orders [{lines [:int]}]) -> :any")

      assert TypeResolver.resolve_path(sig, ["orders", "lines"]) ==
               {:ok, {:list, :int}}
    end

    test "returns :field_not_found when a nested map lacks the requested field" do
      sig = parse!("(items [{name :string}]) -> :any")

      assert TypeResolver.resolve_path(sig, ["items", "missing"]) ==
               {:error, {:field_not_found, "missing"}}
    end

    test "returns :cannot_access_field when descending into a scalar" do
      sig = parse!("(user :string) -> :any")

      assert TypeResolver.resolve_path(sig, ["user", "deep"]) ==
               {:error, {:cannot_access_field, "deep", :string}}
    end

    test "returns :cannot_access_field when descending into a list element scalar" do
      sig = parse!("(tags [:string]) -> :any")

      # path descends into the {:list, :string} element type (:string), which
      # is a scalar -> cannot access a field on it.
      assert TypeResolver.resolve_path(sig, ["tags", "deep"]) ==
               {:error, {:cannot_access_field, "deep", :string}}
    end

    test "returns :empty_path for an empty path against a signature" do
      sig = parse!("(user :string) -> :any")
      assert TypeResolver.resolve_path(sig, []) == {:error, :empty_path}
    end

    test "returns :empty_path for an empty path against any non-signature term" do
      assert TypeResolver.resolve_path(:not_a_signature, []) == {:error, :empty_path}
    end
  end

  describe "list_element_type/2 (real parse -> resolve flow)" do
    test "returns the element type for a list-of-map param" do
      sig = parse!("(items [{name :string}]) -> :any")

      assert TypeResolver.list_element_type(sig, "items") ==
               {:ok, {:map, [{"name", :string}]}}
    end

    test "returns the element type for a list-of-scalar param" do
      sig = parse!("(tags [:string]) -> :any")
      assert TypeResolver.list_element_type(sig, "tags") == {:ok, :string}
    end

    test "returns :not_a_list when the param is a scalar" do
      sig = parse!("(name :string) -> :any")

      assert TypeResolver.list_element_type(sig, "name") ==
               {:error, {:not_a_list, :string}}
    end

    test "returns :not_a_list when the param is a map" do
      sig = parse!("(profile {name :string}) -> :any")

      assert TypeResolver.list_element_type(sig, "profile") ==
               {:error, {:not_a_list, {:map, [{"name", :string}]}}}
    end

    test "returns :param_not_found when the param is unknown" do
      sig = parse!("(items [:string]) -> :any")

      assert TypeResolver.list_element_type(sig, "ghost") ==
               {:error, {:param_not_found, "ghost"}}
    end
  end

  describe "scalar_type?/1" do
    test "returns true for every primitive scalar type" do
      for t <- [:string, :int, :float, :bool, :keyword, :any, :datetime] do
        assert TypeResolver.scalar_type?(t), "expected #{inspect(t)} to be scalar"
      end
    end

    test "unwraps {:optional, scalar} to true" do
      assert TypeResolver.scalar_type?({:optional, :string})
      assert TypeResolver.scalar_type?({:optional, :datetime})
    end

    test "returns false for {:optional, non-scalar}" do
      refute TypeResolver.scalar_type?({:optional, {:list, :string}})
      refute TypeResolver.scalar_type?({:optional, {:map, [{"x", :int}]}})
    end

    test "returns false for list and map composite types" do
      refute TypeResolver.scalar_type?({:list, :string})
      refute TypeResolver.scalar_type?({:map, [{"x", :int}]})
      refute TypeResolver.scalar_type?(:map)
    end

    test "returns false for arbitrary non-type terms (fallthrough clause)" do
      refute TypeResolver.scalar_type?(:something_else)
      refute TypeResolver.scalar_type?(42)
      refute TypeResolver.scalar_type?(nil)
    end
  end

  describe "iterable_type?/1" do
    test "returns true for {:list, _}" do
      assert TypeResolver.iterable_type?({:list, :string})
      assert TypeResolver.iterable_type?({:list, {:map, [{"x", :int}]}})
    end

    test "returns true for parameterized and bare maps" do
      assert TypeResolver.iterable_type?({:map, [{"x", :int}]})
      assert TypeResolver.iterable_type?(:map)
    end

    test "unwraps {:optional, iterable} to true" do
      assert TypeResolver.iterable_type?({:optional, {:list, :int}})
      assert TypeResolver.iterable_type?({:optional, :map})
    end

    test "returns false for {:optional, scalar}" do
      refute TypeResolver.iterable_type?({:optional, :string})
    end

    test "returns false for scalar and arbitrary terms (fallthrough clause)" do
      refute TypeResolver.iterable_type?(:string)
      refute TypeResolver.iterable_type?(:int)
      refute TypeResolver.iterable_type?(nil)
      refute TypeResolver.iterable_type?(123)
    end
  end

  describe "map_fields/1" do
    test "returns the field list for a {:map, fields} type" do
      assert TypeResolver.map_fields({:map, [{"name", :string}, {"age", :int}]}) ==
               {:ok, [{"name", :string}, {"age", :int}]}
    end

    test "returns an empty field list for an empty map type" do
      assert TypeResolver.map_fields({:map, []}) == {:ok, []}
    end

    test "unwraps {:optional, {:map, _}} to its fields" do
      assert TypeResolver.map_fields({:optional, {:map, [{"a", :int}]}}) ==
               {:ok, [{"a", :int}]}
    end

    test "returns :not_a_map for a scalar type" do
      assert TypeResolver.map_fields(:string) == {:error, {:not_a_map, :string}}
    end

    test "returns :not_a_map for a list type" do
      assert TypeResolver.map_fields({:list, :int}) ==
               {:error, {:not_a_map, {:list, :int}}}
    end

    test "returns :not_a_map when an optional wraps a non-map (recursive fallthrough)" do
      assert TypeResolver.map_fields({:optional, :string}) ==
               {:error, {:not_a_map, :string}}
    end
  end
end
