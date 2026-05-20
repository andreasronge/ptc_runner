# Agentic prompt-size benchmark.
#
# Deterministically measures how catalog mode and fleet size affect:
#
#   * the server-side planner system prompt used by `lisp_task`
#   * the client-visible `lisp_task` tool entry advertised by tools/list
#   * the client-visible `lisp_eval` tool entry for comparison
#
# No LLM/provider calls are made. Synthetic upstream catalogs are frozen
# through the same persistent-term seams used at boot.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/agentic_prompt_bench.exs
#   mix run --no-start bench/agentic_prompt_bench.exs --runs=3
#   mix run --no-start bench/agentic_prompt_bench.exs --out=../tmp/agentic_prompt_bench.json

defmodule AgenticPromptBench.Cli do
  @moduledoc false

  def parse(argv) do
    {opts, _argv, invalid} =
      OptionParser.parse(argv,
        strict: [runs: :integer, out: :string, help: :boolean],
        aliases: [h: :help, n: :runs, o: :out]
      )

    if invalid != [] do
      abort("Invalid options: #{inspect(invalid)}")
    end

    if Keyword.get(opts, :help, false) do
      IO.puts("""
      Usage:
        mix run --no-start bench/agentic_prompt_bench.exs [options]

      Options:
        --runs=N   Repeat each deterministic measurement N times and assert stability (default: 1)
        --out=PATH Write JSON report to PATH
        -h, --help Show this help
      """)

      System.halt(0)
    end

    runs = Keyword.get(opts, :runs, 1)

    if not is_integer(runs) or runs < 1 do
      abort("--runs must be a positive integer")
    end

    %{runs: runs, out: Keyword.get(opts, :out)}
  end

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

defmodule AgenticPromptBench.Helpers do
  @moduledoc false

  alias PtcRunnerMcp.{
    Agentic,
    AgenticConfig,
    CatalogConfig,
    ResponseProfile,
    Tools
  }

  alias PtcRunnerMcp.Agentic.Prompt
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @bytes_per_token 4
  @modes [:auto, :inline, :lazy]
  @summary_caps [800, 2_000]
  @fleet_shapes [
    %{name: "small", servers: 3, tools_per_server: 10},
    %{name: "medium", servers: 5, tools_per_server: 30},
    %{name: "large", servers: 10, tools_per_server: 100}
  ]

  def modes, do: @modes
  def summary_caps, do: @summary_caps
  def fleet_shapes, do: @fleet_shapes

  def setup_runtime do
    Process.flag(:trap_exit, true)

    # Keep this benchmark detached from user machine upstream configs and
    # stdio. We only need enough runtime state for Tools.list/0 to expose
    # the aggregator + agentic tool surface.
    System.put_env("PTC_RUNNER_MCP_UPSTREAMS", "/nonexistent/ptc_runner_mcp_agentic_prompt_bench")
    Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

    ensure_registry(PtcRunnerMcp.Upstream.Fake.Names)
    ensure_registry(PtcRunnerMcp.Upstream.Stdio.Names)
    ensure_registry(PtcRunnerMcp.Upstream.Http.Names)
    ensure_registry(PtcRunnerMcp.Upstream.Connection.Names)

    if Process.whereis(PtcRunnerMcp.Upstream.DynamicSupervisor) == nil do
      {:ok, _pid} =
        DynamicSupervisor.start_link(
          name: PtcRunnerMcp.Upstream.DynamicSupervisor,
          strategy: :one_for_one
        )
    end

    PtcRunnerMcp.Log.set_level("error")
    ResponseProfile.set(:slim)
    PtcRunnerMcp.AggregatorConfig.set(%{read_only: true})
  end

  def measure_all(runs) do
    for fleet <- @fleet_shapes, cap <- @summary_caps do
      entries = synthetic_entries(fleet)

      %{
        "fleet" => fleet.name,
        "servers" => fleet.servers,
        "tools_per_server" => fleet.tools_per_server,
        "total_tools" => fleet.servers * fleet.tools_per_server,
        "capability_summary_max_bytes" => cap,
        "catalog_inline_max_tools" => CatalogConfig.defaults().catalog_inline_max_tools,
        "catalog_inline_max_chars" => CatalogConfig.defaults().catalog_inline_max_chars,
        "modes" =>
          Map.new(@modes, fn mode ->
            {Atom.to_string(mode), stable_cell(entries, mode, cap, runs)}
          end),
        "representative_catalog_list_servers" => representative_catalog_list_servers(entries)
      }
    end
  after
    cleanup()
  end

  defp stable_cell(entries, mode, cap, runs) do
    first = measure_cell(entries, mode, cap)

    if runs > 1 do
      Enum.each(2..runs, fn _ ->
        next = measure_cell(entries, mode, cap)

        unless next == first do
          raise "non-deterministic measurement for #{inspect(mode)} cap=#{cap}"
        end
      end)
    end

    first
  end

  defp measure_cell(entries, mode, cap) do
    freeze_cell(entries, mode, cap)

    tools = Tools.list()["tools"]
    task = fetch_tool!(tools, Agentic.tool_name())
    execute = fetch_tool!(tools, "lisp_eval")
    system_prompt = Prompt.system_prompt(catalog_mode: mode)
    effective_mode = effective_catalog_mode(entries, mode)
    task_entry_bytes = encoded_bytes(task)
    execute_entry_bytes = encoded_bytes(execute)

    %{
      "effective_catalog_mode" => Atom.to_string(effective_mode),
      "planner_system_prompt_bytes" => byte_size(system_prompt),
      "planner_system_prompt_tokens_est" => tokens(system_prompt),
      "lisp_task_description_bytes" => byte_size(task["description"]),
      "lisp_task_description_tokens_est" => tokens(task["description"]),
      "lisp_task_tool_entry_bytes" => task_entry_bytes,
      "lisp_task_tool_entry_tokens_est" => tokens(task_entry_bytes),
      "lisp_eval_description_bytes" => byte_size(execute["description"]),
      "lisp_eval_description_tokens_est" => tokens(execute["description"]),
      "lisp_eval_tool_entry_bytes" => execute_entry_bytes,
      "lisp_eval_tool_entry_tokens_est" => tokens(execute_entry_bytes)
    }
  end

  defp freeze_cell(entries, mode, cap) do
    Catalog.clear_frozen()
    Catalog.freeze(Catalog.render_entries(entries))
    Catalog.freeze_snapshot(entries)

    CatalogConfig.set(%{
      catalog_mode: mode,
      catalog_inline_max_tools: CatalogConfig.defaults().catalog_inline_max_tools,
      catalog_inline_max_chars: CatalogConfig.defaults().catalog_inline_max_chars
    })

    AgenticConfig.set(%{
      enabled: true,
      capability_summary_max_bytes: cap,
      capability_summary: nil
    })

    reset_upstream_registry(entries)
  end

  defp reset_upstream_registry(entries) do
    stop_existing(PtcRunnerMcp.Upstream.Registry)

    {:ok, _pid} = UpstreamRegistry.start_link(name: PtcRunnerMcp.Upstream.Registry)

    Enum.each(entries, fn entry ->
      :ok =
        UpstreamRegistry.put_fake(
          entry.name,
          %{tools: %{}, metadata: entry.metadata},
          PtcRunnerMcp.Upstream.Registry
        )
    end)
  end

  defp representative_catalog_list_servers(entries) do
    payload =
      entries
      |> Enum.map(fn entry ->
        %{
          "name" => entry.name,
          "description" => get_in(entry, [:metadata, :description]) || "",
          "tool_count" => length(entry.tools),
          "catalog_loaded" => true
        }
      end)

    %{
      "bytes" => encoded_bytes(payload),
      "tokens_est" => tokens(payload)
    }
  end

  defp synthetic_entries(%{servers: server_count, tools_per_server: tools_per_server}) do
    Enum.map(1..server_count, fn server_index ->
      server = "srv_#{pad(server_index, 2)}"

      %{
        name: server,
        impl: PtcRunnerMcp.Upstream.Fake,
        metadata: %{
          description:
            "Synthetic #{domain(server_index)} MCP server with realistic task tools for prompt-size benchmarking",
          capabilities: [domain(server_index), "search", "records"]
        },
        tools:
          Enum.map(1..tools_per_server, fn tool_index ->
            synthetic_tool(server, server_index, tool_index)
          end)
      }
    end)
  end

  defp synthetic_tool(server, server_index, tool_index) do
    verb = Enum.at(["search", "fetch", "summarize", "update", "list"], rem(tool_index - 1, 5))
    noun = domain(server_index)
    name = "#{verb}_#{noun}_#{pad(tool_index, 3)}"

    %{
      name: name,
      description:
        "#{String.capitalize(verb)} #{noun} records from #{server}. " <>
          "Supports scoped filters, pagination, and concise structured results.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search or lookup text"},
          "limit" => %{"type" => "integer", "description" => "Maximum result count"},
          "include_archived" => %{
            "type" => "boolean",
            "description" => "Include archived records"
          },
          "metadata" => %{
            "type" => "object",
            "description" => "Optional caller metadata"
          }
        },
        "required" => ["query"]
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => %{"type" => "object"}
          },
          "next_cursor" => %{"type" => "string"},
          "summary" => %{"type" => "string"}
        }
      }
    }
  end

  defp domain(index) do
    Enum.at(
      [
        "documents",
        "tickets",
        "contacts",
        "calendar",
        "mail",
        "repos",
        "metrics",
        "billing",
        "inventory",
        "incidents"
      ],
      rem(index - 1, 10)
    )
  end

  defp fetch_tool!(tools, name) do
    Enum.find(tools, fn tool -> tool["name"] == name end) ||
      raise "expected tool #{inspect(name)} to be advertised; saw #{inspect(Enum.map(tools, & &1["name"]))}"
  end

  defp effective_catalog_mode(_entries, :lazy), do: :lazy
  defp effective_catalog_mode(_entries, :inline), do: :inline

  defp effective_catalog_mode(entries, :auto) do
    case PtcRunnerMcp.CatalogDescription.resolve_mode(entries, CatalogConfig.get()) do
      :lazy -> :lazy
      {:inline, _warnings} -> :inline
    end
  end

  defp ensure_registry(name) do
    if Process.whereis(name) == nil do
      {:ok, _pid} = Registry.start_link(keys: :unique, name: name)
    end
  end

  defp stop_existing(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp cleanup do
    stop_existing(PtcRunnerMcp.Upstream.Registry)
    Catalog.clear_frozen()
    CatalogConfig.set(CatalogConfig.defaults())
    AgenticConfig.set(AgenticConfig.defaults())
    ResponseProfile.reset()
  end

  def encoded_bytes(value), do: byte_size(Jason.encode!(value))

  def tokens(value) when is_integer(value),
    do: div(value + @bytes_per_token - 1, @bytes_per_token)

  def tokens(value) when is_binary(value),
    do: div(byte_size(value) + @bytes_per_token - 1, @bytes_per_token)

  def tokens(value), do: value |> encoded_bytes() |> tokens()

  def pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end

defmodule AgenticPromptBench.Report do
  @moduledoc false

  alias AgenticPromptBench.Helpers

  def print(results, runs) do
    IO.puts("")
    IO.puts("Agentic Prompt-Size Benchmark")
    IO.puts("Runs per cell: #{runs} (deterministic stability check)")
    IO.puts("Token estimates: ceil(UTF-8 bytes / 4)")

    Enum.each(results, &print_result/1)
  end

  defp print_result(result) do
    IO.puts("")

    IO.puts(
      "fleet=#{result["fleet"]} (#{result["servers"]} srv x #{result["tools_per_server"]} tools), " <>
        "capability_summary_max_bytes=#{result["capability_summary_max_bytes"]}"
    )

    rows = [
      {"effective catalog mode", "effective_catalog_mode", :text},
      {"planner system-prompt bytes (~tokens)", "planner_system_prompt_bytes", :bytes},
      {"lisp_task description bytes (~tokens)", "lisp_task_description_bytes", :bytes},
      {"lisp_task tool-entry bytes (~tokens)", "lisp_task_tool_entry_bytes", :bytes},
      {"lisp_eval description bytes (~tokens)", "lisp_eval_description_bytes",
       :bytes},
      {"lisp_eval tool-entry bytes (~tokens)", "lisp_eval_tool_entry_bytes",
       :bytes},
      {"delta vs :auto planner bytes (~tokens)", "planner_delta_vs_auto", :delta}
    ]

    auto = get_in(result, ["modes", "auto"])

    rendered_rows =
      Enum.map(rows, fn {label, key, kind} ->
        values =
          Enum.map(Helpers.modes(), fn mode ->
            cell = get_in(result, ["modes", Atom.to_string(mode)])
            render_value(kind, key, cell, auto)
          end)

        [label | values]
      end)

    print_table(["", ":auto", ":inline", ":lazy"], rendered_rows)

    lazy = get_in(result, ["modes", "lazy"])
    inline = get_in(result, ["modes", "inline"])

    planner_lazy_tokens =
      token_delta(lazy["planner_system_prompt_bytes"], auto["planner_system_prompt_bytes"])

    planner_inline_tokens =
      token_delta(inline["planner_system_prompt_bytes"], auto["planner_system_prompt_bytes"])

    task_lazy_tokens =
      token_delta(lazy["lisp_task_description_bytes"], auto["lisp_task_description_bytes"])

    task_inline_tokens =
      token_delta(inline["lisp_task_description_bytes"], auto["lisp_task_description_bytes"])

    IO.puts("")

    IO.puts(
      "Summary: with this fleet, --catalog-mode lazy changes the planner system prompt by " <>
        "#{signed(planner_lazy_tokens)} estimated tokens per lisp_task invocation vs :auto; " <>
        ":inline changes it by #{signed(planner_inline_tokens)}. The lisp_task description " <>
        "(paid once per session) moves by #{signed(task_lazy_tokens)} / #{signed(task_inline_tokens)} " <>
        "estimated tokens for lazy / inline vs :auto."
    )

    list_servers = result["representative_catalog_list_servers"]

    IO.puts(
      "Representative catalog/list-servers payload: #{list_servers["bytes"]} bytes " <>
        "(~#{list_servers["tokens_est"]} tokens)."
    )
  end

  defp render_value(:text, key, cell, _auto), do: cell[key]

  defp render_value(:bytes, key, cell, _auto) do
    token_key = String.replace(key, "_bytes", "_tokens_est")
    "#{cell[key]} (~#{cell[token_key]})"
  end

  defp render_value(:delta, _key, cell, auto) do
    delta_bytes = cell["planner_system_prompt_bytes"] - auto["planner_system_prompt_bytes"]

    delta_tokens =
      token_delta(cell["planner_system_prompt_bytes"], auto["planner_system_prompt_bytes"])

    case delta_bytes do
      0 -> "--"
      _ -> "#{signed(delta_bytes)} (#{signed(delta_tokens)})"
    end
  end

  defp print_table(headers, rows) do
    widths =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {header, index} ->
        rows
        |> Enum.map(fn row -> row |> Enum.at(index) |> to_string() |> String.length() end)
        |> Enum.concat([String.length(header)])
        |> Enum.max()
      end)

    print_row(headers, widths)
    print_row(Enum.map(widths, &String.duplicate("-", &1)), widths)
    Enum.each(rows, &print_row(&1, widths))
  end

  defp print_row(values, widths) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      String.pad_trailing(to_string(value), Enum.at(widths, index))
    end)
    |> Enum.join(" | ")
    |> IO.puts()
  end

  defp token_delta(value, baseline), do: div(value - baseline, 4)
  defp signed(0), do: "0"
  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n), do: Integer.to_string(n)
end

opts = AgenticPromptBench.Cli.parse(System.argv())
AgenticPromptBench.Helpers.setup_runtime()
results = AgenticPromptBench.Helpers.measure_all(opts.runs)
AgenticPromptBench.Report.print(results, opts.runs)

if opts.out do
  File.mkdir_p!(Path.dirname(opts.out))

  File.write!(
    opts.out,
    Jason.encode!(
      %{
        "benchmark" => "agentic_prompt_bench",
        "runs" => opts.runs,
        "token_estimate" => "ceil(utf8_bytes / 4)",
        "results" => results
      },
      pretty: true
    )
  )

  IO.puts("")
  IO.puts("Wrote #{opts.out}")
end
