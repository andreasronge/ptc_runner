defmodule PtcRunner.Kernel.HostInstallation.Selection do
  @moduledoc false

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.SelectionRules

  def rules(%{source: :mcp} = installation) do
    public =
      installation.tools
      |> Map.values()
      |> Map.new(&{&1.as, &1})

    all = public |> Map.keys() |> Enum.sort()

    visible =
      public
      |> Enum.filter(fn {_name, mapping} -> mapping.model_visible end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    write =
      public
      |> Enum.reject(fn {_name, mapping} -> mapping.effect == :read end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    SelectionRules.new(
      fields: %{
        "allow" => %{
          type: {:unique_list, :string},
          input: true,
          default: {:named_set, "all"},
          minimum_items: 1,
          members: "all"
        },
        "catalog" => %{
          type: :boolean,
          input: true,
          default: false
        },
        "max_result_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_result_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_result_bytes
        },
        "model_visible" => %{
          type: {:unique_list, :string},
          input: true,
          default: {:intersection, "allow", "visible"},
          members: "all"
        },
        "timeout_ms" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.timeout_ms,
          minimum: 1,
          maximum: installation.ceilings.timeout_ms
        }
      },
      cross_rules: [
        {:required_when_set_nonempty, "allow", "write"},
        {:subset_of, "model_visible", "allow"},
        {:ceiling_of_context_limit, "timeout_ms", :evaluation_timeout_ms},
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes}
      ],
      named_sets: %{"all" => all, "visible" => visible, "write" => write}
    )
  end

  def rules(%{source: source} = installation) when source in [:llm, :decision] do
    SelectionRules.new(
      fields: %{
        "max_request_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_request_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_request_bytes
        },
        "max_response_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_response_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_response_bytes
        },
        "max_calls" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_calls,
          minimum: 1,
          maximum: installation.ceilings.max_calls
        },
        "default" => %{
          type: :boolean,
          input: true,
          default: false
        }
      },
      cross_rules: [
        {:ceiling_of_context_limit, "max_request_bytes", :capability_argument_bytes},
        {:ceiling_of_context_limit, "max_response_bytes", :capability_result_bytes},
        {:ceiling_of_context_limit, "max_calls", :workflow_capability_calls_per_name}
      ],
      named_sets: %{}
    )
  end

  def rules(%{source: source} = installation)
      when source in [:llm_replay, :decision_replay] do
    SelectionRules.new(
      fields: %{
        "max_entries" => %{
          type: :integer,
          input: false,
          default: installation.ceilings.max_entries,
          minimum: 1,
          maximum: installation.ceilings.max_entries
        },
        "max_result_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_result_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_result_bytes
        },
        "default" => %{
          type: :boolean,
          input: true,
          default: false
        },
        "max_calls" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_calls,
          minimum: 1,
          maximum: installation.ceilings.max_calls
        }
      },
      cross_rules: [
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes},
        {:ceiling_of_context_limit, "max_calls", :workflow_capability_calls_per_name}
      ],
      named_sets: %{}
    )
  end

  def rules(%{source: source} = installation)
      when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    snapshot_selection_rules(installation, false)
  end

  def rules(%{source: :ptc_inspection_snapshot} = installation) do
    snapshot_selection_rules(installation, true)
  end

  defp snapshot_selection_rules(installation, include_max_files?) do
    fields = %{
      "max_source_bytes" => %{
        type: :integer,
        input: true,
        default: installation.ceilings.max_source_bytes,
        minimum: 1,
        maximum: installation.ceilings.max_source_bytes
      },
      "max_result_bytes" => %{
        type: :integer,
        input: true,
        default: installation.ceilings.max_result_bytes,
        minimum: HostConfig.minimum_snapshot_result_bytes(),
        maximum: installation.ceilings.max_result_bytes
      }
    }

    fields =
      if include_max_files? do
        Map.put(fields, "max_files", %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_files,
          minimum: 1,
          maximum: installation.ceilings.max_files
        })
      else
        Map.put(fields, "expose", %{type: :boolean, input: true, default: true})
      end

    SelectionRules.new(
      fields: fields,
      cross_rules: [
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes}
      ],
      named_sets: %{}
    )
  end

  @doc false
  def normalize_selection(%{source: source} = installation, value, %{limits: limits})
      when source in [
             :mcp,
             :llm,
             :llm_replay,
             :decision,
             :decision_replay,
             :ptc_trace_snapshot,
             :ptc_private_trace_snapshot,
             :ptc_inspection_snapshot
           ] do
    with {:ok, rules} <- rules(installation),
         {:ok, rules} <- catalog_selection_rules(source, value, rules),
         {:ok, normalized} <- SelectionRules.normalize_runtime(rules, value, limits) do
      {:ok, normalized}
    else
      _reason -> {:error, selection_error(source)}
    end
  end

  def normalize_selection(_installation, _value, _context),
    do: {:error, :invalid_mcp_selection}

  defp catalog_selection_rules(:mcp, %{"catalog" => true}, rules) do
    cross_rules =
      Enum.reject(rules.cross_rules, &match?({:required_when_set_nonempty, "allow", "write"}, &1))

    SelectionRules.new(
      fields: rules.fields,
      cross_rules: cross_rules,
      named_sets: rules.named_sets
    )
  end

  defp catalog_selection_rules(_source, _value, rules), do: {:ok, rules}

  def normalize_runtime_selection(installation, value, context) do
    with {:ok, normalized} <- normalize_selection(installation, value, context) do
      {:ok, Map.new(normalized, fn {key, item} -> {String.to_existing_atom(key), item} end)}
    end
  end

  defp selection_error(:mcp), do: :invalid_mcp_selection
  defp selection_error(:llm), do: :invalid_llm_selection

  defp selection_error(source) when source in [:decision, :decision_replay],
    do: :invalid_llm_selection

  defp selection_error(:llm_replay), do: :invalid_llm_replay_selection
  defp selection_error(:ptc_trace_snapshot), do: :invalid_trace_snapshot_selection
  defp selection_error(:ptc_private_trace_snapshot), do: :invalid_trace_snapshot_selection
  defp selection_error(:ptc_inspection_snapshot), do: :invalid_inspection_snapshot_selection
end
