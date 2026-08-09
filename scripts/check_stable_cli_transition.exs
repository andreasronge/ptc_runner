defmodule PtcRunner.StableCLITransitionCheck do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  @self Path.relative_to(__ENV__.file, @root)

  # The inventory starts from Git's complete tracked/unignored file set rather
  # than a hand-maintained directory list. That includes runtime and development
  # source, tests, examples, retained documentation, generated artifacts, and
  # package/CI inputs. Plans are excluded because they describe the deletion
  # work itself.
  @excluded_path_segments ["deps", "_build"]
  @excluded_path_prefixes [".agents/", ".claude/skills/", ".codex/skills/"]

  @expected_callers %{
    "CommandEngine.authorize" => %{},
    "CommandEngine.catalog" => %{},
    "CommandEngine.request" => %{},
    "Repl.persist_terminal_result" => %{},
    "Run.failure_message" => %{},
    "RunBuilder.check_built" => %{},
    "RunBuilder.check_built_claimed" => %{},
    "RunBuilder.load_and_build" => %{
      "test/ptc_runner/kernel/application_package_test.exs" => 1,
      "test/ptc_runner/kernel/artifact_publisher_test.exs" => 1,
      "test/ptc_runner/kernel/command_engine_test.exs" => 5,
      "test/ptc_runner/kernel/component_override_test.exs" => 4,
      "test/ptc_runner/kernel/filesystem_mcp_e2e_test.exs" => 1,
      "test/ptc_runner/kernel/host_installation_test.exs" => 1,
      "test/ptc_runner/kernel/inspection_snapshot_test.exs" => 2,
      "test/ptc_runner/kernel/manifest_test.exs" => 9,
      "test/ptc_runner/kernel/mcp_source_test.exs" => 66,
      "test/ptc_runner/kernel/provider_lifecycle_test.exs" => 11,
      "test/ptc_runner/kernel/repo_analyst_application_test.exs" => 1,
      "test/ptc_runner/kernel/repo_analyst_e2e_test.exs" => 2,
      "test/ptc_runner/kernel/run_builder_publication_test.exs" => 2
    },
    "RunBuilder.preflight_prepared" => %{},
    "RunBuilder.publish_execution" => %{},
    "RunBuilder.run" => %{
      "examples/kernel-inspection-lab/support/lab.exs" => 1,
      "test/ptc_runner/kernel/application_package_test.exs" => 1,
      "test/ptc_runner/kernel/command_engine_test.exs" => 5,
      "test/ptc_runner/kernel/component_override_test.exs" => 12,
      "test/ptc_runner/kernel/filesystem_mcp_e2e_test.exs" => 1,
      "test/ptc_runner/kernel/inspection_preflight_test.exs" => 14,
      "test/ptc_runner/kernel/inspection_sink_test.exs" => 1,
      "test/ptc_runner/kernel/llm_replay_test.exs" => 4,
      "test/ptc_runner/kernel/manifest_test.exs" => 7,
      "test/ptc_runner/kernel/mcp_remote_agent_e2e_test.exs" => 1,
      "test/ptc_runner/kernel/mcp_source_test.exs" => 1,
      "test/ptc_runner/kernel/provider_lifecycle_test.exs" => 3,
      "test/ptc_runner/kernel/repo_analyst_e2e_test.exs" => 2,
      "test/ptc_runner/kernel/repo_analyst_evaluation_e2e_test.exs" => 3,
      "test/ptc_runner/kernel/tutorial_examples_e2e_test.exs" => 1,
      "test/ptc_runner/kernel/tutorial_examples_test.exs" => 2
    },
    "RunBuilder.run_with_class" => %{
      "test/ptc_runner/kernel/repo_analyst_live_e2e_test.exs" => 1
    },
    "RunCoordinator.check" => %{}
  }

  @source_inventories [
    {"RunBuilder transitional definitions",
     ~r/(?:@spec|def) (?:load_and_build|run|run_with_class|preflight_prepared|publish_execution)\(/,
     %{"lib/ptc_runner/kernel/run_builder.ex" => 7}},
    {"CommandEngine transitional definitions", ~r/(?:@spec|def) (?:authorize|request|catalog)\(/,
     %{}},
    {"CommandEngine catalog local references", ~r/\bcatalog\(/, %{}},
    {"CommandEngine request local references", ~r/\brequest\(/, %{}},
    {"RunCoordinator check definitions", ~r/(?:@spec|def) check\(/, %{}},
    {"RunCoordinator check route", ~r/\bcheck\b/, %{}},
    {"RunBuilder check definitions", ~r/(?:@spec|def) check_built(?:_claimed)?\(/, %{}},
    {"RunBuilder check local references", ~r/\bcheck_built(?:_claimed)?\(/, %{}},
    {"execution-owner check route", ~r/:check|check_built/, %{}},
    {"provider-execution check route", ~r/:check|check_built/, %{}},
    {"provider-active-session check route", ~r/:check/, %{}},
    {"provider-session check route", ~r/:check/, %{}},
    {"Mix run check route", ~r/:check|RunCoordinator\.check|--check/, %{}},
    {"Mix run failure seam", ~r/\bfailure_message\(/, %{}},
    {"Mix REPL persistence seam", ~r/\bpersist_terminal_result\(/, %{}},
    {"RunBuilder mission option plumbing", ~r/opts, :mission\b|:mission,|:mission\]/, %{}},
    {"RunBuilder private-mission option plumbing", ~r/private_mission/, %{}},
    {"RunBuilder legacy trace input plumbing",
     ~r/Keyword\.(?:get|fetch)\(opts, :trace\)|:trace\]/, %{}},
    {"Mix run mission option plumbing", ~r/:mission\b/, %{}},
    {"Mix run private-mission option plumbing", ~r/private_mission/, %{}},
    {"Mix run trace option plumbing", ~r/:trace\b/, %{}}
  ]

  @mix_run_trace_pattern ~r/mix ptc\.run[^\n]*--trace(?=$|[ =])|^[ \t]*--trace(?=$|[ =])[^\n]*/m

  @text_inventories [
    {"legacy input option names", ~r/--mission|--private-mission/,
     %{"test/mix/tasks/ptc_run_test.exs" => 2}},
    {"Mix run trace syntax", @mix_run_trace_pattern, %{}},
    {"RunBuilder transitional documentation", ~r/\b(?:load_and_build|check_built)\/[13]\b/, %{}}
  ]

  @legacy_option_keys [:mission, :private_mission, :trace]
  @forbidden_source_references [
    {"deleted CommandEngine.authorize/1 alias", "lib/ptc_runner/kernel/command_engine.ex",
     ~r/(?:@spec|def) authorize\(/}
  ]

  # A dynamic entry records a transitional call whose option expression cannot
  # be resolved to a closed keyword list locally. Keeping it in the frozen
  # inventory makes that uncertainty explicit instead of silently omitting
  # options assembled by a helper, comprehension, or caller-supplied tail.
  @expected_legacy_call_options %{
    "dynamic" => %{
      "test/ptc_runner/kernel/artifact_publisher_test.exs" => 1,
      "test/ptc_runner/kernel/inspection_preflight_test.exs" => 2,
      "test/ptc_runner/kernel/repo_analyst_evaluation_e2e_test.exs" => 1
    }
  }

  def run! do
    validate_scanners!()
    files = scoped_files()
    {callers, legacy_options} = elixir_inventories(files)

    failures =
      compare_group("caller", @expected_callers, callers) ++
        compare_remote_text_callers(files) ++
        compare_group("legacy call option", @expected_legacy_call_options, legacy_options) ++
        compare_text_inventories(@source_inventories, files, :expected_files) ++
        compare_text_inventories(@text_inventories, files, :all_files) ++
        compare_forbidden_source_references()

    case failures do
      [] ->
        IO.puts("Stable CLI transitional caller inventories are exact.")

      failures ->
        IO.puts(:stderr, Enum.join(failures, "\n\n"))
        System.halt(1)
    end
  end

  defp scoped_files do
    {files, 0} =
      System.cmd(
        "git",
        ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cd: @root
      )

    files
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&File.regular?(Path.join(@root, &1)))
    |> Enum.reject(
      &(&1 == @self or String.starts_with?(&1, "docs/plans/") or
          excluded_path?(&1))
    )
    |> Enum.sort()
  end

  defp excluded_path?(file) do
    Enum.any?(@excluded_path_prefixes, &String.starts_with?(file, &1)) or
      file
      |> Path.split()
      |> Enum.any?(&(&1 in @excluded_path_segments))
  end

  defp elixir_inventories(files) do
    files
    |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
    |> Enum.reduce({%{}, %{}}, fn file, inventories ->
      source = File.read!(Path.join(@root, file))

      if String.valid?(source) do
        case Code.string_to_quoted(source, emit_warnings: false) do
          {:ok, ast} -> collect_ast_inventories(ast, file, inventories)
          {:error, _parse_error} -> inventories
        end
      else
        inventories
      end
    end)
    |> then(fn {callers, options} -> {normalize(callers), normalize(options)} end)
  end

  defp collect_ast_inventories(ast, file, {callers, options}) do
    {inventories, _environment} =
      scan_ast(ast, %{aliases: %{}, imports: %{}, bindings: %{}}, {callers, options}, file)

    inventories
  end

  defp scan_ast({:__block__, _, expressions}, environment, inventories, file) do
    Enum.reduce(expressions, {inventories, environment}, fn expression, {acc, env} ->
      scan_ast(expression, env, acc, file)
    end)
  end

  defp scan_ast({:alias, _, [module_ast | options]}, environment, inventories, _file) do
    aliases = collect_alias(module_ast, List.first(options) || [], environment.aliases)
    {inventories, %{environment | aliases: aliases}}
  end

  defp scan_ast({:import, _, [module_ast | options]}, environment, inventories, _file) do
    imports =
      case alias_parts(module_ast) do
        nil ->
          environment.imports

        parts ->
          Map.put(
            environment.imports,
            resolve_module(parts, environment.aliases),
            List.first(options) || []
          )
      end

    {inventories, %{environment | imports: imports}}
  end

  defp scan_ast({:=, _, [{name, _, context}, value]}, environment, inventories, file)
       when is_atom(name) and is_atom(context) do
    {inventories, _value_environment} = scan_ast(value, environment, inventories, file)
    binding = legacy_option_binding(value, environment.bindings)
    environment = %{environment | bindings: Map.put(environment.bindings, name, binding)}
    {inventories, environment}
  end

  defp scan_ast({kind, _, [head, body]}, environment, inventories, file)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(body) do
    inventories = scan_definition_head(head, environment, inventories, file)
    inner_environment = %{environment | bindings: %{}}
    {inventories, _inner_environment} = scan_ast(body, inner_environment, inventories, file)
    {inventories, environment}
  end

  defp scan_ast({:defmodule, _, [_module, body]}, environment, inventories, file)
       when is_list(body) do
    {inventories, _inner_environment} = scan_ast(body, environment, inventories, file)
    {inventories, environment}
  end

  defp scan_ast({:fn, _, clauses}, environment, inventories, file) do
    inventories = scan_children(clauses, %{environment | bindings: %{}}, inventories, file)
    {inventories, environment}
  end

  defp scan_ast(
         {:apply, _, [{:__aliases__, _, parts}, function, arguments]},
         environment,
         inventories,
         file
       )
       when is_atom(function) and is_list(arguments) do
    inventories =
      collect_call(
        resolve_module(parts, environment.aliases),
        function,
        arguments,
        file,
        inventories,
        environment
      )

    {scan_children(arguments, environment, inventories, file), environment}
  end

  defp scan_ast(
         {{:., _, [{:__aliases__, _, kernel_parts}, :apply]}, _,
          [{:__aliases__, _, parts}, function, arguments]},
         environment,
         inventories,
         file
       )
       when is_atom(function) and is_list(arguments) do
    inventories =
      if resolve_module(kernel_parts, environment.aliases) == [:Kernel] do
        collect_call(
          resolve_module(parts, environment.aliases),
          function,
          arguments,
          file,
          inventories,
          environment
        )
      else
        inventories
      end

    {scan_children(arguments, environment, inventories, file), environment}
  end

  defp scan_ast(
         {{:., _, [:erlang, :apply]}, _, [{:__aliases__, _, parts}, function, arguments]},
         environment,
         inventories,
         file
       )
       when is_atom(function) and is_list(arguments) do
    inventories =
      collect_call(
        resolve_module(parts, environment.aliases),
        function,
        arguments,
        file,
        inventories,
        environment
      )

    {scan_children(arguments, environment, inventories, file), environment}
  end

  defp scan_ast(
         {{:., _, [{:__aliases__, _, parts}, function]}, _, arguments},
         environment,
         inventories,
         file
       )
       when is_list(arguments) do
    inventories =
      collect_call(
        resolve_module(parts, environment.aliases),
        function,
        arguments,
        file,
        inventories,
        environment
      )

    {scan_children(arguments, environment, inventories, file), environment}
  end

  defp scan_ast(
         {:&, _, [{:/, _, [{function, _, nil}, arity]}]},
         environment,
         inventories,
         file
       )
       when is_atom(function) and is_integer(arity) and arity >= 0 do
    inventories =
      Enum.reduce(environment.imports, inventories, fn {module, options}, acc ->
        if imported?(options, function, arity) do
          collect_reference(module, function, file, acc)
        else
          acc
        end
      end)

    {inventories, environment}
  end

  defp scan_ast({function, _, arguments}, environment, inventories, file)
       when is_atom(function) and is_list(arguments) do
    inventories =
      Enum.reduce(environment.imports, inventories, fn {module, options}, acc ->
        if imported?(options, function, length(arguments)) do
          collect_call(module, function, arguments, file, acc, environment)
        else
          acc
        end
      end)

    {scan_children(arguments, environment, inventories, file), environment}
  end

  defp scan_ast(list, environment, inventories, file) when is_list(list) do
    {scan_children(list, environment, inventories, file), environment}
  end

  defp scan_ast(tuple, environment, inventories, file) when is_tuple(tuple) do
    {scan_children(Tuple.to_list(tuple), environment, inventories, file), environment}
  end

  defp scan_ast(_literal, environment, inventories, _file), do: {inventories, environment}

  defp scan_children(children, environment, inventories, file) do
    Enum.reduce(children, inventories, fn child, acc ->
      {acc, _child_environment} = scan_ast(child, environment, acc, file)
      acc
    end)
  end

  defp scan_definition_head({:when, _, [head | guards]}, environment, inventories, file) do
    inventories = scan_definition_head(head, environment, inventories, file)
    scan_children(guards, environment, inventories, file)
  end

  defp scan_definition_head({_name, _, arguments}, environment, inventories, file)
       when is_list(arguments) do
    scan_children(arguments, environment, inventories, file)
  end

  defp scan_definition_head(_head, _environment, inventories, _file), do: inventories

  defp collect_call(module, function, arguments, file, {caller_acc, option_acc}, environment) do
    {caller_acc, option_acc} =
      collect_reference(module, function, file, {caller_acc, option_acc})

    option_acc =
      if module == [:PtcRunner, :Kernel, :RunBuilder] and
           function in [:load_and_build, :run, :run_with_class] do
        collect_legacy_options(arguments, file, option_acc, environment.bindings)
      else
        option_acc
      end

    {caller_acc, option_acc}
  end

  defp collect_reference(module, function, file, {caller_acc, option_acc}) do
    caller = caller_key(module, function)
    caller_acc = if caller, do: increment(caller_acc, caller, file), else: caller_acc
    {caller_acc, option_acc}
  end

  defp collect_alias(module_ast, options, aliases) do
    module_ast
    |> alias_entries()
    |> Enum.reduce(aliases, fn parts, acc ->
      canonical = resolve_module(parts, acc)

      local =
        case Keyword.get(options, :as) do
          {:__aliases__, _, as_parts} -> List.last(as_parts)
          nil -> List.last(parts)
        end

      Map.put(acc, local, canonical)
    end)
  end

  defp alias_entries({{:., _, [{:__aliases__, _, prefix}, :{}]}, _, grouped_aliases}) do
    Enum.flat_map(grouped_aliases, fn alias_ast ->
      case alias_parts(alias_ast) do
        nil -> []
        suffix -> [prefix ++ suffix]
      end
    end)
  end

  defp alias_entries(module_ast) do
    case alias_parts(module_ast) do
      nil -> []
      parts -> [parts]
    end
  end

  defp alias_parts({:__aliases__, _, parts}), do: parts
  defp alias_parts(_other), do: nil

  defp resolve_module([local | rest] = parts, aliases) do
    case Map.fetch(aliases, local) do
      {:ok, prefix} -> prefix ++ rest
      :error -> parts
    end
  end

  defp imported?(options, function, arity) do
    signature = {function, arity}

    cond do
      only = Keyword.get(options, :only) -> signature in only
      except = Keyword.get(options, :except) -> signature not in except
      true -> true
    end
  end

  defp caller_key([:PtcRunner, :Kernel, :RunBuilder], function)
       when function in [
              :load_and_build,
              :run,
              :run_with_class,
              :preflight_prepared,
              :publish_execution,
              :check_built,
              :check_built_claimed
            ],
       do: "RunBuilder.#{function}"

  defp caller_key([:PtcRunner, :Kernel, :CommandEngine], function)
       when function in [:authorize, :request, :catalog],
       do: "CommandEngine.#{function}"

  defp caller_key([:PtcRunner, :Kernel, :RunCoordinator], :check), do: "RunCoordinator.check"
  defp caller_key([:Mix, :Tasks, :Ptc, :Run], :failure_message), do: "Run.failure_message"

  defp caller_key([:Mix, :Tasks, :Ptc, :Repl], :persist_terminal_result),
    do: "Repl.persist_terminal_result"

  defp caller_key(_module, _function), do: nil

  defp validate_scanners! do
    assert_scan_count!(@mix_run_trace_pattern, "mix ptc.run ptc.json --trace run.jsonl", 1)
    assert_scan_count!(@mix_run_trace_pattern, "  --trace=run.jsonl", 1)
    assert_scan_count!(@mix_run_trace_pattern, "mix ptc.run ptc.json --trace-dir traces", 0)

    source = """
    defmodule ScannerFixture do
      alias PtcRunner.Kernel.RunBuilder, as: Builder
      alias PtcRunner.Kernel.{RunCoordinator, CommandEngine}

      def exercise(catalog, runtime_opts) do
        Builder.run("ptc.json", [])
        apply(Builder, :load_and_build, ["ptc.json", catalog, []])
        Kernel.apply(RunCoordinator, :check, [:prepared, :authority])
        :erlang.apply(Builder, :run_with_class, ["ptc.json", catalog, []])

        opts = [private_mission: "input.json", trace: "run.jsonl"] ++ runtime_opts
        Builder.run("ptc.json", catalog, opts)

        alias String, as: Builder
        Builder.run("not a transitional call")
      end

      def imported(catalog) do
        import PtcRunner.Kernel.CommandEngine, only: [request: 3]
        request("ptc.json", catalog, [])
        &request/3
        &request/1_000_000_000
      end

      def import_does_not_leak(catalog), do: request("ptc.json", catalog, [])
      def alias_does_not_leak(), do: Builder.run("ptc.json", [])
    end
    """

    {:ok, ast} = Code.string_to_quoted(source)
    {callers, options} = collect_ast_inventories(ast, "fixture.ex", {%{}, %{}})

    expected = %{
      "CommandEngine.request" => %{"fixture.ex" => 2},
      "RunBuilder.load_and_build" => %{"fixture.ex" => 1},
      "RunBuilder.run" => %{"fixture.ex" => 3},
      "RunBuilder.run_with_class" => %{"fixture.ex" => 1},
      "RunCoordinator.check" => %{"fixture.ex" => 1}
    }

    if normalize(callers) != expected do
      raise "stable CLI alias/import scanner self-test failed"
    end

    expected_options = %{
      "dynamic" => %{"fixture.ex" => 1},
      "private_mission" => %{"fixture.ex" => 1},
      "trace" => %{"fixture.ex" => 1}
    }

    if normalize(options) != expected_options do
      raise "stable CLI indirect-option scanner self-test failed"
    end
  end

  defp assert_scan_count!(pattern, source, expected) do
    if length(Regex.scan(pattern, source)) != expected do
      raise "stable CLI text scanner self-test failed for #{inspect(source)}"
    end
  end

  defp collect_legacy_options(arguments, file, inventory, bindings) do
    binding =
      case arguments do
        [_path, _registry, options | _rest] -> legacy_option_binding(options, bindings)
        _other_arity -> empty_option_binding()
      end

    inventory =
      Enum.reduce(binding.keys, inventory, fn key, acc ->
        increment(acc, Atom.to_string(key), file)
      end)

    if binding.dynamic?, do: increment(inventory, "dynamic", file), else: inventory
  end

  defp legacy_option_binding(options, _bindings) when is_list(options) do
    Enum.reduce(options, empty_option_binding(), fn
      {key, _value}, binding when key in @legacy_option_keys ->
        %{binding | keys: MapSet.put(binding.keys, key)}

      {_key, _value}, binding ->
        binding

      _non_keyword, binding ->
        %{binding | dynamic?: true}
    end)
  end

  defp legacy_option_binding({:++, _, [left, right]}, bindings) do
    merge_option_bindings(
      legacy_option_binding(left, bindings),
      legacy_option_binding(right, bindings)
    )
  end

  defp legacy_option_binding({name, _, context}, bindings)
       when is_atom(name) and is_atom(context),
       do: Map.get(bindings, name, dynamic_option_binding())

  defp legacy_option_binding(_options, _bindings), do: dynamic_option_binding()

  defp empty_option_binding, do: %{keys: MapSet.new(), dynamic?: false}
  defp dynamic_option_binding, do: %{keys: MapSet.new(), dynamic?: true}

  defp merge_option_bindings(left, right) do
    %{keys: MapSet.union(left.keys, right.keys), dynamic?: left.dynamic? or right.dynamic?}
  end

  defp increment(inventory, key, file) do
    Map.update(inventory, key, %{file => 1}, fn files -> Map.update(files, file, 1, &(&1 + 1)) end)
  end

  defp normalize(inventory) do
    Map.new(inventory, fn {key, files} -> {key, Map.new(Enum.sort(files))} end)
  end

  defp compare_text_inventories(inventories, files, scope) do
    Enum.flat_map(inventories, fn {name, pattern, expected} ->
      inventory_files = if scope == :expected_files, do: Map.keys(expected), else: files

      actual =
        inventory_files
        |> Enum.reduce(%{}, fn file, acc ->
          source = File.read!(Path.join(@root, file))

          if String.valid?(source) do
            case length(Regex.scan(pattern, source)) do
              0 -> acc
              count -> Map.put(acc, file, count)
            end
          else
            acc
          end
        end)

      compare("reference #{name}", expected, actual)
    end)
  end

  # The AST inventory is authoritative for Elixir callers. Repeating the same
  # exact remote-call inventory as text covers retained guides, generated
  # artifacts, shell/JS/package inputs, and any other non-Elixir file without
  # turning broad transitional words such as `check` or `mission` into noise.
  defp compare_remote_text_callers(files) do
    actual =
      Map.new(@expected_callers, fn {caller, _expected} ->
        pattern = Regex.compile!("\\b" <> Regex.escape(caller) <> "\\s*\\(")

        counts =
          Enum.reduce(files, %{}, fn file, acc ->
            source = File.read!(Path.join(@root, file))

            if String.valid?(source) do
              case length(Regex.scan(pattern, source)) do
                0 -> acc
                count -> Map.put(acc, file, count)
              end
            else
              acc
            end
          end)

        {caller, counts}
      end)

    compare_group("text caller", @expected_callers, actual)
  end

  defp compare_forbidden_source_references do
    Enum.flat_map(@forbidden_source_references, fn {name, file, pattern} ->
      source = File.read!(Path.join(@root, file))

      case Regex.scan(pattern, source) do
        [] -> []
        matches -> ["Stable CLI transitional #{name} reappeared (#{length(matches)} references)."]
      end
    end)
  end

  defp compare_group(kind, expected, actual) do
    (Map.keys(expected) ++ Map.keys(actual))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      compare("#{kind} #{name}", Map.get(expected, name, %{}), Map.get(actual, name, %{}))
    end)
  end

  defp compare(_name, expected, actual) when expected == actual, do: []

  defp compare(name, expected, actual) do
    [
      "Stable CLI transitional #{name} changed.",
      "Expected: #{inspect(expected, pretty: true)}",
      "Actual:   #{inspect(actual, pretty: true)}",
      "Migrate or delete the caller with its transitional API; do not expand the inventory."
    ]
    |> Enum.join("\n")
    |> List.wrap()
  end
end

PtcRunner.StableCLITransitionCheck.run!()
