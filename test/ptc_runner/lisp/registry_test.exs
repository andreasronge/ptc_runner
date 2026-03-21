defmodule PtcRunner.Lisp.RegistryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Registry

  describe "sync validation" do
    test "all env builtins are in registry" do
      env_names = Env.initial() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      registry_names = Registry.implemented() |> Enum.map(& &1.name) |> MapSet.new()

      missing = MapSet.difference(env_names, registry_names)

      assert MapSet.size(missing) == 0,
             "Env builtins missing from registry: #{inspect(MapSet.to_list(missing))}"
    end

    test "all analyze special forms are in registry" do
      analyze_names = Analyze.supported_forms() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      registry_names = Registry.implemented() |> Enum.map(& &1.name) |> MapSet.new()

      missing = MapSet.difference(analyze_names, registry_names)

      assert MapSet.size(missing) == 0,
             "Analyze forms missing from registry: #{inspect(MapSet.to_list(missing))}"
    end

    test "no orphaned registry entries (in registry but not in code)" do
      env_names = Env.initial() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      analyze_names = Analyze.supported_forms() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      code_names = MapSet.union(env_names, analyze_names)

      registry_names = Registry.implemented() |> Enum.map(& &1.name) |> MapSet.new()

      orphaned = MapSet.difference(registry_names, code_names)

      assert MapSet.size(orphaned) == 0,
             "Registry entries not in code: #{inspect(MapSet.to_list(orphaned))}"
    end

    test "every :supported audit entry has a matching implemented entry" do
      implemented_names = Registry.implemented() |> Enum.map(& &1.name) |> MapSet.new()

      supported_audit =
        Registry.clojure_core_audit()
        |> Enum.filter(&(&1.status == :supported))

      for entry <- supported_audit do
        assert MapSet.member?(implemented_names, entry.name),
               "Audit entry '#{entry.name}' marked :supported but not in implemented list"
      end
    end

    test "binding type matches env.ex for dispatch: :env entries" do
      env = Env.initial()

      for entry <- Registry.implemented(), entry.dispatch == :env do
        atom_name = String.to_existing_atom(entry.name)
        binding = Map.get(env, atom_name)

        assert binding,
               "Registry entry '#{entry.name}' with dispatch :env not found in Env.initial()"

        expected_type = binding_type(binding)

        assert entry.binding == expected_type,
               "Registry entry '#{entry.name}' has binding #{inspect(entry.binding)} but env has #{inspect(expected_type)}"
      end
    end

    test "dispatch: :analyze entries have nil binding" do
      for entry <- Registry.implemented(), entry.dispatch == :analyze do
        assert entry.binding == nil,
               "Analyze entry '#{entry.name}' should have nil binding, got #{inspect(entry.binding)}"
      end
    end

    test "every entry has required fields" do
      for entry <- Registry.implemented() do
        assert is_binary(entry.name), "Entry missing name"

        assert entry.dispatch in [:env, :analyze],
               "Entry '#{entry.name}' has invalid dispatch: #{inspect(entry.dispatch)}"

        assert entry.category in [:core, :string, :set, :regex, :math, :interop],
               "Entry '#{entry.name}' has invalid category"

        assert is_list(entry.signatures), "Entry '#{entry.name}' missing signatures"
        assert is_binary(entry.description), "Entry '#{entry.name}' missing description"
      end
    end
  end

  describe "queries" do
    test "doc/1 returns entry for known function" do
      entry = Registry.doc("filter")
      assert entry.name == "filter"
      assert entry.dispatch == :env
    end

    test "doc/1 returns nil for unknown function" do
      assert Registry.doc("nonexistent") == nil
    end

    test "find_doc/1 searches by name" do
      results = Registry.find_doc("sort")
      names = Enum.map(results, & &1.name)
      assert "sort" in names
      assert "sort-by" in names
    end

    test "find_doc/1 searches by description" do
      results = Registry.find_doc("predicate")
      assert results != []
    end

    test "builtins_by_category/1 returns atoms" do
      string_builtins = Registry.builtins_by_category(:string)
      assert is_list(string_builtins)
      assert :join in string_builtins
      assert Enum.all?(string_builtins, &is_atom/1)
    end

    test "find_doc/1 handles invalid regex gracefully" do
      # Should fall back to substring match, not crash
      results = Registry.find_doc("[invalid")
      assert is_list(results)
    end
  end

  describe "audit regression" do
    test "non-supported clojure.core vars are classified" do
      audit = Registry.clojure_core_audit()
      non_supported = Enum.reject(audit, &(&1.status == :supported))

      not_classified = Enum.filter(non_supported, &(&1.status == :not_classified))

      assert not_classified == [],
             "#{length(not_classified)} audit entries are :not_classified — " <>
               "all should be :candidate, :not_relevant, or :supported"
    end

    test "audit has candidate and not_relevant entries" do
      audit = Registry.clojure_core_audit()
      counts = Enum.frequencies_by(audit, & &1.status)

      assert counts[:candidate] > 0, "No candidate entries in audit"
      assert counts[:not_relevant] > 0, "No not_relevant entries in audit"
    end
  end

  describe "constants" do
    test "constants have non-callable signatures" do
      for entry <- Registry.implemented(), entry.binding == :constant do
        for sig <- entry.signatures do
          refute String.starts_with?(sig, "("),
                 "Constant '#{entry.name}' has callable signature: #{sig}"
        end
      end
    end
  end

  describe "multi-arity" do
    test "representative multi-arity functions have multiple signatures" do
      for name <- ["map", "mapv", "get", "get-in", "reduce", "sort"] do
        entry = Registry.doc(name)
        assert entry, "Missing registry entry for #{name}"

        assert length(entry.signatures) > 1,
               "Multi-arity function '#{name}' should have multiple signatures, got: #{inspect(entry.signatures)}"
      end
    end
  end

  defp binding_type({:normal, _}), do: :normal
  defp binding_type({:variadic, _, _}), do: :variadic
  defp binding_type({:variadic_nonempty, _, _}), do: :variadic_nonempty
  defp binding_type({:multi_arity, _, _}), do: :multi_arity
  defp binding_type({:collect, _}), do: :collect
  defp binding_type({:constant, _}), do: :constant
  defp binding_type({:special, _}), do: :special
end
