defmodule PtcRunner.Kernel.SemanticRevisionTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.SemanticRevision
  alias PtcRunner.Lisp.Eval.Context

  test "a cache entry from an earlier module build cannot supply the current revision" do
    legacy_key = {SemanticRevision, :current}
    previous = :persistent_term.get(legacy_key, :missing)
    stale = "sem1-" <> String.duplicate("0", 64)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(legacy_key)
        value -> :persistent_term.put(legacy_key, value)
      end
    end)

    :persistent_term.put(legacy_key, stale)
    refute SemanticRevision.current() == stale
  end

  test "the checked-in source projection includes code-owned Mix application defaults" do
    assert Enum.any?(
             SemanticRevision.build_projection()["sources"],
             &(&1["path"] == "mix.exs")
           )
  end

  test "dependency streaming avoids File.stream!/3 whose contract changed after Elixir 1.15" do
    beam = :code.which(SemanticRevision)
    assert {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    refute {File, :stream!, 3} in imports
  end

  test "the build projection classifies conditionally compiled semantic modules" do
    assert SemanticRevision.build_projection()["conditional_semantic_modules"] == [
             "Elixir.PtcRunner.LLM.ReqLLMAdapter"
           ]

    absent =
      SemanticRevision.actual_compile_feature_projection(
        [PtcRunner.LLM.ReqLLMAdapter],
        fn _module -> false end
      )

    present =
      SemanticRevision.actual_compile_feature_projection(
        [PtcRunner.LLM.ReqLLMAdapter],
        fn _module -> true end
      )

    refute SemanticRevision.revision_for(%{"source" => "same"}, %{"features" => absent}) ==
             SemanticRevision.revision_for(%{"source" => "same"}, %{"features" => present})
  end

  test "the scheduler-derived compiled default participates in semantic identity" do
    original = :erlang.system_info(:schedulers_online)
    total = :erlang.system_info(:schedulers)
    compiled_default = Context.default_pmap_max_concurrency()
    before_revision = SemanticRevision.current()

    if total > 1 do
      alternate = if original > 1, do: original - 1, else: original + 1
      on_exit(fn -> :erlang.system_flag(:schedulers_online, original) end)
      :erlang.system_flag(:schedulers_online, alternate)
    end

    context = Context.new(%{}, %{}, %{}, fn _name, _args, _meta -> nil end, [])

    assert context.pmap_max_concurrency == compiled_default
    assert SemanticRevision.current() == before_revision

    build = %{"source" => "same"}

    refute SemanticRevision.revision_for(
             build,
             %{"compiled_pmap_max_concurrency" => compiled_default}
           ) ==
             SemanticRevision.revision_for(
               build,
               %{"compiled_pmap_max_concurrency" => compiled_default + 2}
             )
  end

  @tag :tmp_dir
  test "actual dependency presence and compiled bytes change the semantic revision", %{
    tmp_dir: directory
  } do
    core = Path.join(directory, "core")
    optional = Path.join(directory, "optional")
    nested = Path.join(directory, "nested")
    File.mkdir_p!(Path.join(core, "ebin"))
    File.mkdir_p!(Path.join(optional, "ebin"))
    File.mkdir_p!(Path.join(nested, "ebin"))
    File.write!(Path.join(core, "ebin/core.beam"), "core-v1")
    File.write!(Path.join(optional, "ebin/optional.beam"), "optional-v1")
    File.write!(Path.join(nested, "ebin/nested.beam"), "nested-v1")

    absent_optional = fn
      :core -> {:ok, core, [:optional]}
      :optional -> :absent
    end

    present_optional = fn
      :core -> {:ok, core, [:optional]}
      :optional -> {:ok, optional, [:nested]}
      :nested -> {:ok, nested, []}
    end

    without_optional =
      SemanticRevision.actual_dependency_projection(
        [:core],
        absent_optional
      )

    with_optional =
      SemanticRevision.actual_dependency_projection(
        [:core],
        present_optional
      )

    File.write!(Path.join(core, "ebin/core.beam"), "core-v2")

    changed_resolution =
      SemanticRevision.actual_dependency_projection(
        [:core],
        present_optional
      )

    build = %{"source_closure_hash" => "source"}

    assert Enum.map(without_optional, & &1["name"]) == ["core", "optional"]
    assert Enum.map(with_optional, & &1["name"]) == ["core", "nested", "optional"]

    refute SemanticRevision.revision_for(build, %{"dependencies" => without_optional}) ==
             SemanticRevision.revision_for(build, %{"dependencies" => with_optional})

    refute SemanticRevision.revision_for(build, %{"dependencies" => with_optional}) ==
             SemanticRevision.revision_for(build, %{"dependencies" => changed_resolution})
  end

  @tag :tmp_dir
  test "dependency executable permissions change the semantic revision", %{tmp_dir: directory} do
    root = Path.join(directory, "launcher")
    executable = Path.join([root, "priv", "launcher"])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "same bytes")
    File.chmod!(executable, 0o600)

    resolver = fn :launcher -> {:ok, root, []} end
    without_execute = SemanticRevision.actual_dependency_projection([:launcher], resolver)

    File.chmod!(executable, 0o700)
    with_execute = SemanticRevision.actual_dependency_projection([:launcher], resolver)

    refute without_execute == with_execute
  end

  @tag :tmp_dir
  test "dependency execute classes remain distinct in semantic identity", %{tmp_dir: directory} do
    root = Path.join(directory, "launcher")
    executable = Path.join([root, "priv", "launcher"])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "same bytes")
    resolver = fn :launcher -> {:ok, root, []} end

    File.chmod!(executable, 0o500)
    owner_execute = SemanticRevision.actual_dependency_projection([:launcher], resolver)

    File.chmod!(executable, 0o401)
    other_execute = SemanticRevision.actual_dependency_projection([:launcher], resolver)

    refute owner_execute == other_execute
  end

  @tag :tmp_dir
  test "dependency identity streams artifacts under a bounded heap", %{tmp_dir: directory} do
    root = Path.join(directory, "streamed")
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)

    for index <- 1..12 do
      File.write!(
        Path.join(ebin, "artifact-#{index}.beam"),
        :binary.copy(<<index>>, 1_000_000)
      )
    end

    resolver = fn :streamed -> {:ok, root, []} end

    assert {:ok, [%{"name" => "streamed", "content_identity" => identity}]} =
             BoundedWorker.run(
               fn -> SemanticRevision.actual_dependency_projection([:streamed], resolver) end,
               timeout_ms: 30_000,
               max_heap_words: 800_000
             )

    assert identity =~ ~r/\A[0-9a-f]{64}\z/
  end
end
