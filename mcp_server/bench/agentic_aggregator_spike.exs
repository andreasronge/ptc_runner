# Agentic aggregator spike.
#
# Purpose:
#   Test whether an internal cheap planner LLM can generate useful
#   PTC-Lisp for aggregator-mode MCP work from plain English, without
#   changing the production MCP server yet.
#
# What this measures:
#   * Can the planner emit executable PTC-Lisp from the same compact
#     authoring rules and upstream catalog the MCP client sees?
#   * Does the generated program reduce a large upstream-like payload
#     to a compact answer?
#   * How many planner tokens / bytes are spent before execution?
#
# What this does NOT measure:
#   * Real GitHub network behavior. The upstream is a deterministic
#     in-process Fake that mimics GitHub MCP search/read envelopes.
#   * Multi-turn memory. This is intentionally one task/run; memory is
#     a follow-up only if this clears the basic bar.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/agentic_aggregator_spike.exs
#   mix run --no-start bench/agentic_aggregator_spike.exs \
#     --runs=3 --model=gemini-flash-lite --report=../tmp/agentic-spike.md
#
# Stub mode for local script verification:
#
#   mix run --no-start bench/agentic_aggregator_spike.exs --provider=stub

System.put_env("PTC_RUNNER_MCP_UPSTREAMS", "/nonexistent/ptc_runner_mcp_agentic_spike")
Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

{:ok, _} = Application.ensure_all_started(:ptc_runner_mcp)
PtcRunner.Dotenv.load()
PtcRunnerMcp.Log.set_level("error")
Process.flag(:trap_exit, true)

for name <- [
      PtcRunnerMcp.Upstream.Fake.Names,
      PtcRunnerMcp.Upstream.Stdio.Names,
      PtcRunnerMcp.Upstream.Connection.Names
    ] do
  if Process.whereis(name) == nil do
    {:ok, _} = Registry.start_link(keys: :unique, name: name)
  end
end

if Process.whereis(PtcRunnerMcp.Upstream.DynamicSupervisor) == nil do
  {:ok, _} =
    DynamicSupervisor.start_link(
      name: PtcRunnerMcp.Upstream.DynamicSupervisor,
      strategy: :one_for_one
    )
end

defmodule Bench.AgenticAggregatorSpike do
  @moduledoc false

  alias PtcRunnerMcp.Tools
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Connection
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @registry_name PtcRunnerMcp.Upstream.Registry

  def main(argv) do
    {opts, _positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          provider: :string,
          model: :string,
          runs: :integer,
          report: :string,
          task: :string
        ]
      )

    provider = opts[:provider] || "openrouter"
    model = opts[:model] || "gemini-flash-lite"
    runs = opts[:runs] || 1
    task = opts[:task] || default_task()

    setup_fake_github!()

    results =
      for i <- 1..runs do
        run_once(i, provider, model, task)
      end

    report = render_report(provider, model, task, results)

    IO.puts(report)

    if path = opts[:report] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, report)
    end
  end

  defp run_once(index, provider, model, task) do
    prompt = build_planner_prompt(task)

    t0 = System.monotonic_time(:millisecond)
    plan = generate_program(provider, model, prompt)
    planner_ms = System.monotonic_time(:millisecond) - t0

    case plan do
      {:ok, raw_text, usage} ->
        program = extract_program(raw_text)
        execution = execute_program(program)

        %{
          index: index,
          provider: provider,
          model: model,
          planner_ok?: true,
          planner_ms: planner_ms,
          prompt_bytes: byte_size(prompt),
          raw_text: raw_text,
          program: program,
          program_bytes: byte_size(program),
          usage: usage,
          execution: execution,
          score: score_execution(execution)
        }

      {:error, reason} ->
        %{
          index: index,
          provider: provider,
          model: model,
          planner_ok?: false,
          planner_ms: planner_ms,
          prompt_bytes: byte_size(prompt),
          error: inspect(reason),
          raw_text: "",
          program: "",
          program_bytes: 0,
          usage: %{},
          execution: %{status: "planner_error", result: "", result_bytes: 0},
          score: %{passed?: false, reasons: ["planner failed"]}
        }
    end
  end

  defp setup_fake_github! do
    stop_existing_registry()
    Catalog.clear_frozen()

    {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)

    :ok =
      UpstreamRegistry.put_fake(
        "github",
        %{tools: fake_github_tools()},
        @registry_name
      )

    pid = UpstreamRegistry.connection_for("github", @registry_name)
    {:ok, _} = Connection.ensure_started(pid)
    :ok = Catalog.freeze(Catalog.render(@registry_name))
  end

  defp fake_github_tools do
    %{
      "search_issues" =>
        {%{
           name: "search_issues",
           description: "Search GitHub issues and pull requests.",
           input_schema: %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string"},
               "owner" => %{"type" => "string"},
               "repo" => %{"type" => "string"},
               "state" => %{"type" => "string"},
               "perPage" => %{"type" => "integer"}
             },
             "required" => ["query"]
           }
         }, fn args, _opts -> {:ok, search_issues(args)} end},
      "issue_read" =>
        {%{
           name: "issue_read",
           description: "Read one GitHub issue by number.",
           input_schema: %{
             "type" => "object",
             "properties" => %{
               "owner" => %{"type" => "string"},
               "repo" => %{"type" => "string"},
               "issue_number" => %{"type" => "integer"}
             },
             "required" => ["owner", "repo", "issue_number"]
           }
         }, fn args, _opts -> {:ok, issue_read(args)} end}
    }
  end

  defp search_issues(args) do
    query = String.downcase(to_string(arg(args, "query", "")))
    per_page = arg(args, "perPage", 20)

    items =
      issue_fixtures()
      |> Enum.filter(&matches_query?(&1, query))
      |> Enum.sort_by(& &1["updated_at"], :desc)
      |> Enum.take(per_page)

    json_payload(%{
      "total_count" => length(items),
      "incomplete_results" => false,
      "items" => items
    })
  end

  defp issue_read(args) do
    n = arg(args, "issue_number")

    issue =
      Enum.find(issue_fixtures(), %{}, fn item ->
        item["number"] == n
      end)

    json_payload(issue)
  end

  defp arg(args, key, default \\ nil) when is_map(args) and is_binary(key) do
    Map.get(args, key, Map.get(args, String.to_atom(key), default))
  end

  defp json_payload(value) do
    text = Jason.encode!(value)

    %{
      "structuredContent" => value,
      "content" => [
        %{
          "type" => "text",
          "mimeType" => "application/json",
          "text" => text
        }
      ],
      "isError" => false
    }
  end

  defp matches_query?(item, query) do
    title = String.downcase(item["title"])
    body = String.downcase(item["body"])

    cond do
      String.contains?(query, "in:title") ->
        String.contains?(title, "auth") or String.contains?(title, "oauth")

      String.contains?(query, "oauth") or String.contains?(query, "authentication") ->
        String.contains?(title <> "\n" <> body, "oauth") or
          String.contains?(title <> "\n" <> body, "auth")

      true ->
        true
    end
  end

  defp issue_fixtures do
    [
      issue(
        2224,
        "Feature Request: Support External OAuth / Custom Authorization Server JWT Validation",
        "open",
        "2026-05-08T12:00:00Z",
        String.duplicate("OAuth validation details and JWT authorization server notes. ", 80)
      ),
      issue(
        2075,
        "Enforce fail-closed startup when PAT/OAuth scope requirements are unmet",
        "open",
        "2026-04-29T10:00:00Z",
        String.duplicate("Authentication scope startup behavior and OAuth failure modes. ", 75)
      ),
      issue(
        2235,
        "Copilot-generated PR review code suggestions are not returned by pull_request_read",
        "open",
        "2026-05-09T09:00:00Z",
        String.duplicate("Large unrelated body that mentions authentication incidentally. ", 100)
      ),
      issue(
        1991,
        "Improve issue search pagination for large repositories",
        "open",
        "2026-03-10T09:00:00Z",
        String.duplicate("Pagination and search API behavior. ", 90)
      ),
      issue(
        1880,
        "Document Docker startup configuration",
        "open",
        "2026-02-14T09:00:00Z",
        String.duplicate("Container configuration and startup notes. ", 70)
      )
    ]
  end

  defp issue(number, title, state, updated_at, body) do
    %{
      "number" => number,
      "title" => title,
      "state" => state,
      "html_url" => "https://github.com/github/github-mcp-server/issues/#{number}",
      "updated_at" => updated_at,
      "body" => body
    }
  end

  defp build_planner_prompt(task) do
    tool = Tools.tool_entry()

    """
    You are the internal planner for ptc_runner_mcp agentic aggregator mode.

    Convert the user's task into one PTC-Lisp program that calls upstream MCP
    tools through `(tool/mcp-call ...)`, reduces large upstream payloads inside
    the program, and returns only the compact final answer.

    Rules:
    - Return PTC-Lisp only. No Markdown fences. No explanation.
    - Do not include or discuss MCP `signature`; you are writing only `program`.
    - For GitHub `search_issues` results, inspect `(:ok r)` and use `(:value r)`.
    - Return selected fields only. Avoid returning full upstream envelopes.
    - Keep output under 1 KB.
    - For this task, prefer queries with `in:title authentication` and
      `in:title oauth`; body-only matches are noisy.

    Advertised tool description and upstream catalog:

    #{tool["description"]}

    User task:
    #{task}
    """
  end

  defp generate_program("stub", _model, _prompt) do
    {:ok, stub_program(), %{"provider" => "stub"}}
  end

  defp generate_program("openrouter", model, prompt) do
    with :ok <- ensure_req_loaded(),
         {:ok, api_key} <- fetch_env("OPENROUTER_API_KEY"),
         {:ok, openrouter_model} <- resolve_openrouter_model(model) do
      url = "https://openrouter.ai/api/v1/chat/completions"

      body = %{
        "model" => openrouter_model,
        "messages" => [
          %{"role" => "user", "content" => prompt}
        ],
        "temperature" => 0.1,
        "max_tokens" => 1200,
        "usage" => %{"include" => true}
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"},
        {"http-referer", "https://github.com/andreasronge/ptc_runner"},
        {"x-title", "ptc_runner agentic aggregator spike"}
      ]

      case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          text = extract_openrouter_text(response)
          usage = Map.get(response, "usage", %{})
          {:ok, text, usage}

        {:ok, %{status: status, body: response}} ->
          {:error, {:openrouter_http_error, status, response}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_program(other, _model, _prompt) do
    {:error, {:unknown_provider, other}}
  end

  defp ensure_req_loaded do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      {:error, :req_not_loaded}
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, {:missing_env, name}}
      "" -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  defp resolve_openrouter_model(model) do
    resolved = PtcRunner.LLM.Registry.resolve!(model)

    case resolved do
      "openrouter:" <> model_id -> {:ok, model_id}
      other -> {:error, {:not_openrouter_model, other}}
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp extract_openrouter_text(response) do
    response
    |> get_in(["choices", Access.at(0), "message", "content"])
    |> case do
      text when is_binary(text) -> String.trim(text)
      _ -> ""
    end
  end

  defp extract_program(raw_text) do
    raw_text
    |> String.trim()
    |> strip_fence()
    |> String.trim()
  end

  defp strip_fence("```" <> rest) do
    rest
    |> String.replace_prefix("clojure\n", "")
    |> String.replace_prefix("lisp\n", "")
    |> String.replace_prefix("ptc-lisp\n", "")
    |> String.trim_trailing("`")
    |> String.trim()
  end

  defp strip_fence(text), do: text

  defp execute_program(""), do: %{status: "empty_program", result: "", result_bytes: 0}

  defp execute_program(program) do
    t0 = System.monotonic_time(:millisecond)
    envelope = Tools.call_with_gate(%{"program" => program})
    execution_ms = System.monotonic_time(:millisecond) - t0
    structured = Map.get(envelope, "structuredContent", envelope)

    status = Map.get(structured, "status")
    result = Map.get(structured, "result", "")
    upstream_calls = Map.get(structured, "upstream_calls", [])

    %{
      status: status,
      reason: Map.get(structured, "reason"),
      message: Map.get(structured, "message"),
      result: result,
      result_bytes: byte_size(to_string(result)),
      truncated?: Map.get(structured, "truncated", false),
      upstream_calls: upstream_calls,
      upstream_call_count: length(upstream_calls),
      execution_ms: execution_ms
    }
  end

  defp score_execution(%{status: "ok", result: result, result_bytes: bytes} = execution) do
    text = to_string(result)

    checks = [
      {"status ok", true},
      {"contains #2224", String.contains?(text, "2224")},
      {"contains #2075", String.contains?(text, "2075")},
      {"omits noisy #2235", not String.contains?(text, "2235")},
      {"result under 1 KB", bytes < 1024},
      {"used upstream calls", Map.get(execution, :upstream_call_count, 0) > 0}
    ]

    failed =
      checks
      |> Enum.reject(fn {_label, passed?} -> passed? end)
      |> Enum.map(fn {label, _} -> label end)

    %{passed?: failed == [], reasons: failed}
  end

  defp score_execution(%{status: status, reason: reason}) do
    %{passed?: false, reasons: ["execution failed: #{inspect(status)} #{inspect(reason)}"]}
  end

  defp render_report(provider, model, task, results) do
    passed = Enum.count(results, & &1.score.passed?)

    rows =
      Enum.map_join(results, "\n", fn result ->
        execution = result.execution

        [
          result.index,
          bool(result.planner_ok?),
          bool(result.score.passed?),
          result.planner_ms,
          result.program_bytes,
          Map.get(execution, :status, ""),
          Map.get(execution, :upstream_call_count, 0),
          Map.get(execution, :result_bytes, 0),
          usage_summary(result.usage),
          failure_text(result)
        ]
        |> Enum.map(&escape_cell/1)
        |> Enum.join(" | ")
        |> then(&"| #{&1} |")
      end)

    sample =
      results
      |> List.first()
      |> case do
        nil -> ""
        result -> sample_block(result)
      end

    """
    # Agentic Aggregator Spike Report

    | Field | Value |
    |---|---|
    | Provider | `#{provider}` |
    | Model | `#{model}` |
    | Runs | #{length(results)} |
    | Passed | #{passed}/#{length(results)} |

    ## Task

    #{task}

    ## Results

    | run | planner ok | passed | planner ms | program bytes | exec status | upstream calls | result bytes | usage | failures |
    |---:|---|---|---:|---:|---|---:|---:|---|---|
    #{rows}

    ## First Run

    #{sample}
    """
    |> String.trim()
  end

  defp sample_block(result) do
    """
    Program:

    ```clojure
    #{result.program}
    ```

    Result:

    ```text
    #{Map.get(result.execution, :result, "")}
    ```
    """
    |> String.trim()
  end

  defp usage_summary(usage) when is_map(usage) do
    prompt = Map.get(usage, "promptTokenCount", "?")
    candidates = Map.get(usage, "candidatesTokenCount", "?")
    total = Map.get(usage, "totalTokenCount", "?")
    "p=#{prompt}, c=#{candidates}, t=#{total}"
  end

  defp bool(true), do: "yes"
  defp bool(false), do: "no"

  defp failure_text(%{score: %{reasons: []}}), do: ""

  defp failure_text(%{score: score, execution: execution}) do
    message = Map.get(execution, :message)

    [Enum.join(score.reasons, "; "), message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp escape_cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp stop_existing_registry do
    case Process.whereis(@registry_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp default_task do
    "Search GitHub issues in github/github-mcp-server for recent open issues " <>
      "mentioning authentication or OAuth. Return only a compact list of up to " <>
      "5 items with issue number, title, state, and URL. Prefer issues whose " <>
      "titles mention authentication or OAuth over incidental body matches."
  end

  defp stub_program do
    ~S"""
    (let [fetch (fn [n]
                  (let [r (tool/mcp-call {:server "github"
                                          :tool "issue_read"
                                          :args {:owner "github"
                                                 :repo "github-mcp-server"
                                                 :issue_number n}})
                        j (:value r)]
                    j))
          items [(fetch 2224) (fetch 2075)]]
      (clojure.string/join
        "\n"
        (map (fn [item]
               (str (get item "number")
                    " | " (get item "title")
                    " | " (get item "state")
                    " | " (get item "html_url")))
             items)))
    """
  end
end

Bench.AgenticAggregatorSpike.main(System.argv())
