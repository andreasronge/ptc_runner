alias PtcRunner.Lisp.CoreToSource
alias Alma.{MemoryHarness, Archive}
alias Alma.Environments.GraphWorld.Generator

llm = LLMClient.callback("bedrock:haiku")

archive =
  Alma.run(
    llm: llm,
    iterations: 1,
    episodes: 3,
    rooms: 4,
    seed: 42,
    verbose: false,
    trace: false
  )

best = Archive.best(archive)

IO.puts("=== Design: #{best.design.name} (score: #{best.score}) ===")
IO.puts("#{best.design.description}\n")

ns = Map.get(best.design, :namespace, %{})

if map_size(ns) > 0 do
  source = CoreToSource.export_namespace(ns)
  IO.puts("=== Full Namespace Source ===")
  IO.puts(source)
  IO.puts("")

  tasks = Generator.generate_batch(3, %{rooms: 4, objects: 3, connectivity: 0.4, seed: 42})

  IO.puts("=== Collection Phase Replay ===\n")

  Enum.reduce(tasks, {[], %{}}, fn task, {results, memory} ->
    advice = MemoryHarness.retrieve(best.design, task, memory)
    ep = length(results) + 1

    IO.puts(
      "--- Episode #{ep}: #{task.goal.object} -> #{task.goal.destination} (start: #{task.agent_location}) ---"
    )

    IO.puts("Recall: #{if advice == "", do: "(empty)", else: advice}\n")

    result = Alma.TaskAgent.run(task, advice, llm: llm)

    IO.puts(
      "Result: #{if result.success?, do: "SUCCESS", else: "FAIL"} (#{length(result.actions)} actions)"
    )

    episode = %{
      task: task,
      actions: result.actions,
      success: result.success?,
      observation_log: result.observation_log
    }

    # Call update manually to see errors
    namespace = Map.get(best.design, :namespace, %{})
    closure = best.design.mem_update

    if closure do
      ctx = %{
        "task" => task,
        "actions" => result.actions,
        "success" => result.success?,
        "observation_log" => result.observation_log
      }

      run_memory = namespace |> Map.merge(memory) |> Map.put(:"mem-update", closure)

      case PtcRunner.Lisp.run("(mem-update)",
             context: ctx,
             memory: run_memory,
             filter_context: false
           ) do
        {:ok, _step} -> IO.puts("mem-update: OK")
        {:error, step} -> IO.puts("mem-update ERROR: #{inspect(step.fail)}")
      end
    end

    {updated_memory, _error} = MemoryHarness.update(best.design, episode, memory)

    data_keys =
      updated_memory
      |> Enum.reject(fn {_k, v} -> match?({:closure, _, _, _, _, _}, v) end)
      |> Map.new()

    IO.puts("Memory: #{inspect(data_keys, pretty: true, limit: 200)}\n")

    {results ++ [result], updated_memory}
  end)
else
  IO.puts("(null design - no namespace to show)")
end
