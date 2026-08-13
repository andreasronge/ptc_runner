defmodule PtcRunner.Kernel.RepoAnalystLiveE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises the shipped `repo-analyst` answer application with its pinned live
  OpenRouter model and the real filesystem MCP server.

  The deterministic facade E2E proves pagination and tool mapping without a
  model. This acceptance test proves that the complete application can explore
  before returning, satisfy its result contract, and bind every citation to a
  range contained in bytes actually read from the frozen workspace snapshot.
  """

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.RunLifecycle

  @root Path.expand("../../..", __DIR__)
  @host_template Path.join(@root, "repo-analyst.host.json")
  @manifest_template Path.join(@root, "repo-analyst-answer.json")
  @input_template Path.join(@root, "repo-analyst/answer-input.json")
  @core_source Path.join(@root, "priv/preludes/kernel/agent.core.clj")
  @repo_facade Path.join(@root, "repo-analyst/repo.clj")
  @answer_schema Path.join(@root, "repo-analyst/answer.schema.json")
  @filesystem_server Path.join(@root, "examples/mcp/filesystem/dist/server.js")
  @deepseek_model "openrouter:deepseek/deepseek-v4-flash-0731"
  @workspace_revision "filesystem-sample-0.1.0"

  setup_all do
    :ok = PtcRunner.Dotenv.load()
    :ok = LLMSupport.admit_provider_application!()
    assert System.get_env("OPENROUTER_API_KEY"), "OPENROUTER_API_KEY is not configured"
    :ok
  end

  @tag :tmp_dir
  test "DeepSeek returns only citations backed by workspace reads", %{tmp_dir: dir} do
    paths = write_isolated_application(dir)
    trace_path = Path.join(dir, "answer.jsonl")
    inspection_path = Path.join(dir, "answer.inspection.jsonl")
    output_path = Path.join(dir, "answer.json")

    assert {:ok, host} = HostConfig.load(paths.host)
    assert_live_installations(host)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, result, :normal} =
             paths.manifest
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: trace_path,
               inspect: inspection_path,
               output: output_path
             )
             |> RunLifecycle.execute_with_class()

    assert %{"answer" => answer, "citations" => citations} = result.value
    assert is_binary(answer) and answer != ""
    assert [_ | _] = citations
    assert Jason.decode!(File.read!(output_path)) == result.value

    {raw_condition_line, raw_condition_source, raw_return_line, raw_return_source} =
      raw_result_evidence(paths.source)

    {count_line, count_source} = remaining_turn_evidence(paths.source)

    task = paths.task
    assert {:ok, records} = InspectionArtifact.load(inspection_path)
    reads = workspace_reads(records)
    assert [workspace_snapshot_hash] = reads |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    assert %{"snapshot_hash" => ^workspace_snapshot_hash} =
             citation_covering!(citations, paths.source_path, count_line)

    assert %{"snapshot_hash" => ^workspace_snapshot_hash} =
             citation_covering!(citations, paths.source_path, raw_condition_line)

    assert %{"snapshot_hash" => ^workspace_snapshot_hash} =
             citation_covering!(citations, paths.source_path, raw_return_line)

    assert read_line?(
             reads,
             paths.source_path,
             raw_condition_line,
             raw_condition_source,
             workspace_snapshot_hash
           )

    assert read_line?(
             reads,
             paths.source_path,
             raw_return_line,
             raw_return_source,
             workspace_snapshot_hash
           )

    assert read_line?(
             reads,
             paths.source_path,
             count_line,
             count_source,
             workspace_snapshot_hash
           )

    assert_evidence_reaches_terminal_answer(
      records,
      paths.source_path,
      raw_condition_line,
      raw_condition_source
    )

    assert_evidence_reaches_terminal_answer(
      records,
      paths.source_path,
      raw_return_line,
      raw_return_source
    )

    assert_evidence_reaches_terminal_answer(
      records,
      paths.source_path,
      count_line,
      count_source
    )

    assert_exact_conversation(records, task, paths.max_turns)
    assert_required_exploration(records, paths.source_path, paths.max_turns)

    for citation <- citations do
      assert Map.keys(citation) |> Enum.sort() ==
               ~w(lines path provider snapshot_hash)

      assert %{
               "provider" => "workspace",
               "snapshot_hash" => snapshot_hash,
               "path" => path,
               "lines" => [first, last]
             } = citation

      assert first <= last

      assert Enum.any?(reads, fn
               {^path, lines, ^snapshot_hash} ->
                 Enum.all?(first..last, &Map.has_key?(lines, &1))

               _other ->
                 false
             end),
             "citation #{inspect(citation)} has no matching workspace.read record"
    end

    trace_records = decode_jsonl(trace_path)
    assert_provider_snapshots(trace_records)
    assert_public_trace(trace_path, trace_records, hd(records), task, answer)

    inspection = File.read!(inspection_path)
    assert inspection =~ "Inspect the available source snapshot"
    assert inspection =~ "evaluation-source"
  end

  defp write_isolated_application(dir) do
    workspace = Path.join(dir, "workspace")
    application = Path.join(dir, "application")
    source_path = "loop.clj"
    source = File.read!(@core_source)
    source_target = Path.join(workspace, source_path)
    facade_source = File.read!(@repo_facade)

    source_example =
      ~S(Searching \"agent.core\" finds `priv/preludes/kernel/agent.core.clj`,) <>
        "\n" <> ~S(  while \"*.clj\" finds nothing.)

    facade =
      facade_source
      |> String.replace(
        source_example,
        ~S(For example, \"*.clj\" is a literal query, not a wildcard.)
      )

    refute facade == facade_source
    :ok = File.mkdir_p(Path.dirname(source_target))
    :ok = File.mkdir_p(application)
    :ok = File.write(source_target, source)
    :ok = File.write(Path.join(application, "repo.clj"), facade)
    :ok = File.cp(@answer_schema, Path.join(application, "answer.schema.json"))

    input = @input_template |> File.read!() |> Jason.decode!()
    input_path = Path.join(application, "answer-input.json")
    :ok = File.write(input_path, Jason.encode!(input))

    manifest =
      @manifest_template
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["missions", "default", "components"], [
        %{"library" => "cap"},
        %{"id" => "repo", "path" => "repo.clj", "dependencies" => ["cap"]}
      ])
      |> put_in(["input"], %{"path" => "answer-input.json"})
      |> put_in(["contracts", "result_schema"], %{"path" => "answer.schema.json"})

    manifest_path = Path.join(application, "ptc.json")
    :ok = File.write(manifest_path, Jason.encode!(manifest))

    node = System.find_executable("node") || flunk("Node.js is required for this E2E")

    host =
      @host_template
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["install"], &Map.take(&1, ~w(deepseek workspace)))
      |> put_in(["install", "workspace", "transport"], %{
        "type" => "stdio",
        "command" => node,
        "cwd" => workspace,
        "args" => [@filesystem_server, "--root", ".", "--include", "**"],
        "start_timeout_ms" => 15_000
      })

    host_path = Path.join(application, "host.json")
    :ok = File.write(host_path, Jason.encode!(host))

    %{
      host: host_path,
      manifest: manifest_path,
      source: source,
      source_path: source_path,
      task: Map.fetch!(input, "task"),
      max_turns: input |> Map.fetch!("agent") |> Map.fetch!("max_turns")
    }
  end

  defp assert_live_installations(host) do
    assert %{
             source: :llm,
             model: @deepseek_model
           } = host.install["deepseek"]

    assert %{
             source: :mcp,
             installation_revision: @workspace_revision,
             transport: %{
               type: :stdio,
               command: command,
               args: [@filesystem_server | _args]
             }
           } = host.install["workspace"]

    assert Path.basename(command) == "node"
  end

  defp assert_provider_snapshots(events) do
    run_started = Enum.find(events, &(&1["type"] == "run-started"))
    snapshots = get_in(run_started, ["data", "connector_snapshots"])

    assert Enum.any?(snapshots, fn snapshot ->
             snapshot["provider"] == "deepseek" and
               snapshot["declaration"]["source"] == "llm" and
               snapshot["acquisition"]["source"] == "llm"
           end)

    assert Enum.any?(snapshots, fn snapshot ->
             snapshot["provider"] == "workspace" and
               snapshot["acquisition"]["transport"] == "stdio" and
               snapshot["acquisition"]["protocol"] == "mcp-2026-07-28" and
               snapshot["declaration"]["installation_revision"] == @workspace_revision
           end)
  end

  defp assert_exact_conversation(records, task, max_turns) do
    inputs =
      records
      |> Enum.filter(&capability_record?(&1, "capability-input", "llm-request"))
      |> Map.new(&{&1["correlation"]["capability_id"], &1})

    outputs =
      records
      |> Enum.filter(&capability_record?(&1, "capability-output", "llm-request"))
      |> Map.new(&{&1["correlation"]["capability_id"], &1})

    assert map_size(inputs) > 0
    assert Map.keys(inputs) |> MapSet.new() == Map.keys(outputs) |> MapSet.new()

    initial_input =
      inputs
      |> Map.values()
      |> Enum.min_by(& &1["sequence"])

    initial_task =
      task <>
        "\n\nTURN BUDGET: #{max_turns} turns remain, including the next program."

    assert initial_input["payload"]["arguments"]["messages"] == [
             %{"role" => "user", "content" => initial_task}
           ]

    for {id, input} <- inputs do
      assert outputs[id]["sequence"] == input["sequence"] + 1
    end

    evaluations =
      records
      |> Enum.filter(&(&1["record_type"] == "evaluation-source"))
      |> Map.new(&{&1["sequence"], &1})

    ordered_outputs =
      outputs
      |> Map.values()
      |> Enum.sort_by(& &1["sequence"])

    ordered_inputs =
      inputs
      |> Map.values()
      |> Enum.sort_by(& &1["sequence"])

    for {output, index} <- Enum.with_index(ordered_outputs) do
      current_messages =
        ordered_inputs
        |> Enum.at(index)
        |> get_in(["payload", "arguments", "messages"])

      next_input = Enum.at(ordered_inputs, index + 1)

      value = get_in(output, ["payload", "result", "value"])
      evaluation = evaluations[output["sequence"] + 1]

      if evaluation do
        assert %{"tool_calls" => [tool_call]} = value
        assert is_binary(tool_call["id"]) and tool_call["id"] != ""
        assert is_binary(evaluation["payload"]["source"])

        if next_input do
          messages = next_input["payload"]["arguments"]["messages"]

          assert messages ==
                   current_messages ++
                     [
                       %{
                         "role" => "assistant",
                         "content" => normalized_rationale(value["content"]),
                         "tool_calls" => [tool_call]
                       },
                       %{
                         "role" => "tool",
                         "tool_call_id" => tool_call["id"],
                         "content" => List.last(messages)["content"]
                       }
                     ]

          observation = List.last(messages)["content"]
          assert is_binary(observation) and observation != ""
        end
      else
        assert next_input
        assert next_input["sequence"] == output["sequence"] + 1
        messages = next_input["payload"]["arguments"]["messages"]
        assert messages |> Enum.take(length(current_messages)) == current_messages

        assert [%{"role" => "user", "content" => correction}] =
                 Enum.drop(messages, length(current_messages))

        turns_remaining = max_turns - index - 1

        turn_budget =
          if turns_remaining == 1,
            do: "1 turn remains",
            else: "#{turns_remaining} turns remain"

        assert String.starts_with?(correction, "Protocol error: ")

        assert String.ends_with?(
                 correction,
                 ". Call run_ptc_lisp exactly once with one program string.\n\n" <>
                   "TURN BUDGET: #{turn_budget}, including the next program."
               )
      end
    end
  end

  defp normalized_rationale(content) when is_binary(content) do
    if String.trim(content) == "", do: nil, else: content
  end

  defp normalized_rationale(_content), do: nil

  defp assert_required_exploration(records, source_path, max_turns) do
    evaluations =
      records
      |> Enum.filter(&(&1["record_type"] == "evaluation-source"))
      |> Enum.sort_by(& &1["sequence"])

    assert length(evaluations) in 1..max_turns
    terminal = List.last(evaluations)

    discovery_names = ~w(workspace.list workspace.find workspace.search)
    workspace_names = MapSet.new(["workspace.read" | discovery_names])

    successful_calls =
      records
      |> capability_exchanges()
      |> Enum.filter(fn %{input: input, output: output} ->
        get_in(output, ["payload", "result", "status"]) == "ok" and
          MapSet.member?(workspace_names, input["payload"]["name"])
      end)

    discovery_calls =
      successful_calls
      |> Enum.filter(&(&1.input["payload"]["name"] in discovery_names))

    read_calls =
      successful_calls
      |> Enum.filter(&(&1.input["payload"]["name"] == "workspace.read"))

    assert [_ | _] = discovery_calls
    assert [_ | _] = read_calls
    first_read_sequence = read_calls |> Enum.map(& &1.input["sequence"]) |> Enum.min()

    assert Enum.any?(discovery_calls, &(&1.output["sequence"] < first_read_sequence))

    for %{input: input} = read <- read_calls do
      path = input["payload"]["arguments"]["path"]
      assert path == source_path

      assert Enum.any?(discovery_calls, fn discovery ->
               discovery.output["sequence"] < read.input["sequence"] and
                 path in result_paths(discovery.output)
             end),
             "workspace.read guessed #{inspect(path)} before discovery returned it"
    end

    terminal_source = terminal["payload"]["source"]

    assert String.contains?(terminal_source, "(return")

    facade_pattern = ~r/\(repo\/(?:ls|find-files|search|search-under|read-range)\s+/

    assert Enum.any?(evaluations, fn evaluation ->
             evaluation["payload"]["source"] =~ facade_pattern
           end)

    refute Enum.any?(evaluations, &String.contains?(&1["payload"]["source"], "tool/workspace."))
  end

  defp workspace_reads(records) do
    inputs =
      records
      |> Enum.filter(&capability_record?(&1, "capability-input", "workspace.read"))
      |> Map.new(fn record ->
        arguments = record["payload"]["arguments"]

        {record["correlation"]["capability_id"],
         {arguments["path"], arguments["start_line"], arguments["line_count"]}}
      end)

    records
    |> Enum.filter(&capability_record?(&1, "capability-output", "workspace.read"))
    |> Enum.flat_map(fn record ->
      id = record["correlation"]["capability_id"]

      with {:ok, {path, _first, _count}} <- Map.fetch(inputs, id),
           %{"status" => "ok", "value" => value} <- record["payload"]["result"],
           %{"path" => ^path, "lines" => [_ | _] = lines, "snapshot_hash" => snapshot_hash} <-
             value,
           returned_lines = Map.new(lines, &{&1["line"], &1["text"]}),
           true <- map_size(returned_lines) == length(lines) do
        [{path, returned_lines, snapshot_hash}]
      else
        _missing_or_unsuccessful -> []
      end
    end)
  end

  defp assert_evidence_reaches_terminal_answer(records, path, line, source) do
    evidence_sequences =
      records
      |> capability_exchanges()
      |> Enum.flat_map(fn %{input: input, output: output} ->
        value = get_in(output, ["payload", "result", "value"])

        if workspace_evidence?(input["payload"]["name"], value, path, line, source) do
          [output["sequence"]]
        else
          []
        end
      end)

    assert [_ | _] = evidence_sequences

    observation_sequences =
      records
      |> Enum.filter(&capability_record?(&1, "capability-input", "llm-request"))
      |> Enum.flat_map(fn record ->
        messages = get_in(record, ["payload", "arguments", "messages"])

        observed? =
          Enum.any?(messages, fn
            %{"role" => "tool", "content" => content} ->
              contains_text?(content, source) or
                contains_text?(content, String.replace(source, "\"", "\\\""))

            _other ->
              false
          end)

        if observed? and Enum.any?(evidence_sequences, &(&1 < record["sequence"])) do
          [record["sequence"]]
        else
          []
        end
      end)

    terminal =
      records
      |> Enum.filter(&(&1["record_type"] == "evaluation-source"))
      |> Enum.max_by(& &1["sequence"])

    assert String.contains?(terminal["payload"]["source"], "(return")

    observed_before_terminal? =
      Enum.any?(observation_sequences, &(&1 < terminal["sequence"]))

    produced_during_terminal? =
      Enum.any?(evidence_sequences, &(terminal["sequence"] < &1))

    assert observed_before_terminal? or produced_during_terminal?,
           "workspace evidence neither reached the model nor arose during the terminal program"
  end

  defp workspace_evidence?("workspace.read", value, path, line, source) do
    value["path"] == path and
      Enum.any?(value["lines"] || [], &(&1["line"] == line and &1["text"] == source))
  end

  defp workspace_evidence?("workspace.search", value, path, line, source) do
    Enum.any?(value["items"] || [], fn item ->
      item["path"] == path and item["line"] == line and item["text"] == source
    end)
  end

  defp workspace_evidence?(_name, _value, _path, _line, _source), do: false

  defp capability_record?(record, type, name) do
    record["record_type"] == type and record["payload"]["name"] == name
  end

  defp decode_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp assert_public_trace(path, events, inspection_identity, task, answer) do
    run_id = inspection_identity["run_id"]
    trace_id = inspection_identity["trace_id"]

    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, run} = TraceLog.query(trace_log, :get_run, %{"run_id" => run_id})
    assert run["run_id"] == run_id
    assert run["trace_id"] == trace_id
    assert run["status"] == "ok"

    private_record_types =
      ~w(capability-input capability-output evaluation-source prelude-source mcp-request mcp-response)

    for record_type <- private_record_types do
      refute contains_text?(events, record_type)
    end

    for sensitive <-
          ~w(arguments messages tool_calls program content result record_type correlation payload body) do
      refute contains_key?(events, sensitive)
    end

    for {path, source} <- key_occurrences(events, "source") do
      assert [
               event_index,
               "data",
               "connector_snapshots",
               snapshot_index,
               projection,
               "source"
             ] = path

      assert is_integer(event_index)
      assert is_integer(snapshot_index)
      assert projection in ["declaration", "acquisition"]
      assert source in ~w(llm mcp)
    end

    refute contains_text?(events, task)
    refute contains_text?(events, answer)
  end

  defp contains_key?(values, key) when is_list(values),
    do: Enum.any?(values, &contains_key?(&1, key))

  defp contains_key?(value, key) when is_map(value),
    do: Map.has_key?(value, key) or Enum.any?(Map.values(value), &contains_key?(&1, key))

  defp contains_key?(_value, _key), do: false

  defp capability_exchanges(records) do
    outputs =
      records
      |> Enum.filter(&(&1["record_type"] == "capability-output"))
      |> Map.new(&{&1["correlation"]["capability_id"], &1})

    records
    |> Enum.filter(&(&1["record_type"] == "capability-input"))
    |> Enum.flat_map(fn input ->
      case Map.fetch(outputs, input["correlation"]["capability_id"]) do
        {:ok, output} -> [%{input: input, output: output}]
        :error -> []
      end
    end)
  end

  defp result_paths(output) do
    case get_in(output, ["payload", "result", "value", "items"]) do
      items when is_list(items) ->
        Enum.flat_map(items, fn
          %{"path" => path} when is_binary(path) -> [path]
          _other -> []
        end)

      _no_items ->
        []
    end
  end

  defp key_occurrences(value, key), do: key_occurrences(value, key, [])

  defp key_occurrences(values, key, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> key_occurrences(value, key, path ++ [index]) end)
  end

  defp key_occurrences(value, key, path) when is_map(value) do
    Enum.flat_map(value, fn {field, nested} ->
      occurrence = if field == key, do: [{path ++ [field], nested}], else: []
      occurrence ++ key_occurrences(nested, key, path ++ [field])
    end)
  end

  defp key_occurrences(_value, _key, _path), do: []

  defp citation_covering!(citations, path, line) do
    Enum.find(citations, fn
      %{"path" => ^path, "lines" => [first, last]} -> first <= line and line <= last
      _other -> false
    end) || flunk("no citation covers #{path}:#{line}")
  end

  defp read_line?(reads, path, line, text, snapshot_hash) do
    Enum.any?(reads, fn
      {^path, lines, ^snapshot_hash} -> lines[line] == text
      _other -> false
    end)
  end

  defp raw_result_evidence(source_text) do
    {condition_line, condition_source} =
      source_line(source_text, fn source ->
        String.contains?(source, ~S|(if (false? (get cfg "result_envelope"))|)
      end)

    {return_line, return_source} =
      source_line(source_text, &String.contains?(&1, "(return value)"))

    {condition_line, condition_source, return_line, return_source}
  end

  defp remaining_turn_evidence(source_text) do
    {line, source} =
      source_line(source_text, fn source ->
        String.contains?(source, ":turns-remaining") and
          String.contains?(source, "max-turns")
      end)

    {line, source}
  end

  defp source_line(source_text, predicate) do
    source_text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {source, line} ->
      if predicate.(source), do: {line, source}
    end)
  end

  defp contains_text?(value, text) when is_binary(value),
    do: String.contains?(value, text)

  defp contains_text?(values, text) when is_list(values),
    do: Enum.any?(values, &contains_text?(&1, text))

  defp contains_text?(value, text) when is_map(value),
    do:
      Enum.any?(value, fn {key, nested} ->
        contains_text?(key, text) or contains_text?(nested, text)
      end)

  defp contains_text?(_value, _text), do: false
end
