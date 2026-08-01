defmodule PtcRunner.Kernel.LimitCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest

  @manifest_narrowable [
    {"capability_argument_bytes", :capability_argument_bytes, 262_144, 262_144},
    {"capability_result_bytes", :capability_result_bytes, 1_000_000, 1_000_000},
    {"entry_source_bytes", :entry_source_bytes, 262_144, 262_144},
    {"evaluation_heap_words", :evaluation_heap_words, 1_250_000, 1_250_000},
    {"evaluation_history_bytes", :evaluation_history_bytes, 1_000_000, 1_000_000},
    {"evaluation_memory_bytes", :evaluation_memory_bytes, 2_000_000, 2_000_000},
    {"evaluation_timeout_ms", :evaluation_timeout_ms, 1_000, 60_000},
    {"event_payload_bytes", :event_payload_bytes, 262_144, 262_144},
    {"live_provider_tasks", :live_provider_tasks, 8, 8},
    {"mission_capability_calls", :mission_capability_calls, 128, 128},
    {"mission_capability_calls_per_name", :mission_capability_calls_per_name, 32, 32},
    {"normal_event_bytes", :normal_event_bytes, 4_000_000, 4_000_000},
    {"normal_event_count", :normal_event_count, 256, 256},
    {"protocol_errors", :protocol_errors, 32, 32},
    {"provider_heap_words", :provider_heap_words, 5_000_000, 5_000_000},
    {"run_duration_ms", :run_duration_ms, 30_000, 300_000},
    {"subordinate_evaluations", :subordinate_evaluations, 16, 16},
    {"subordinate_source_bytes", :subordinate_source_bytes, 131_072, 131_072},
    {"terminal_result_bytes", :terminal_result_bytes, 1_000_000, 1_000_000},
    {"workflow_capability_calls", :workflow_capability_calls, 64, 64},
    {"workflow_capability_calls_per_name", :workflow_capability_calls_per_name, 16, 16},
    {"workflow_heap_words", :workflow_heap_words, 8_000_000, 8_000_000},
    {"workflow_timeout_ms", :workflow_timeout_ms, 30_000, 120_000}
  ]

  @installed_only %{
    "doctor_connectivity_timeout_ms" => %{
      field: :doctor_connectivity_timeout_ms,
      compiled_default: 10_000,
      installed_default: 10_000,
      identity: false
    },
    "provider_cleanup_timeout_ms" => %{
      field: :provider_cleanup_timeout_ms,
      compiled_default: 5_000,
      installed_default: 5_000,
      identity: true
    },
    "selection_validation_timeout_ms" => %{
      field: :selection_validation_timeout_ms,
      compiled_default: 5_000,
      installed_default: 5_000,
      identity: true
    }
  }

  @expected_catalog Map.new(
                      @manifest_narrowable,
                      fn {name, field, compiled_default, installed_default} ->
                        {name,
                         %{
                           field: field,
                           name: name,
                           scope: :manifest_narrowable,
                           compiled_default: compiled_default,
                           installed_default: installed_default,
                           minimum: 1,
                           maximum: 2_592_000_000,
                           identity: true
                         }}
                      end
                    )
                    |> Map.merge(
                      Map.new(@installed_only, fn {name, metadata} ->
                        {name,
                         metadata
                         |> Map.merge(%{
                           name: name,
                           scope: :installed_only,
                           minimum: 100,
                           maximum: 30_000
                         })}
                      end)
                    )

  test "the checked-in catalog completely and uniquely defines the Limits struct" do
    rows = LimitCatalog.rows()
    fields = Map.keys(Map.from_struct(Limits.defaults()))

    assert Map.new(rows, &{&1.name, &1}) == @expected_catalog
    assert Enum.map(rows, & &1.name) == Enum.sort(Enum.map(rows, & &1.name))
    assert Enum.uniq_by(rows, & &1.name) == rows
    assert Enum.uniq_by(rows, & &1.field) == rows
    assert Enum.sort(Enum.map(rows, & &1.field)) == Enum.sort(fields)
    assert :ok = LimitCatalog.validate_fields!(fields)

    assert_raise ArgumentError, ~r/LimitCatalog metadata/, fn ->
      LimitCatalog.validate_fields!([:uncatalogued_limit | fields])
    end
  end

  test "installed-only timeout metadata is exact" do
    for {name, expected} <- @installed_only do
      assert {:ok, row} = LimitCatalog.fetch(name)

      contract_fields = [
        :field,
        :scope,
        :compiled_default,
        :installed_default,
        :minimum,
        :maximum,
        :identity
      ]

      assert Map.take(row, contract_fields) ==
               expected
               |> Map.merge(%{
                 scope: :installed_only,
                 minimum: 100,
                 maximum: 30_000
               })
               |> Map.take(contract_fields)
    end
  end

  test "defaults, accepted boundaries, runtime lookup, and both schemas agree for every row" do
    compiled = Limits.defaults()
    installed = Limits.installed_defaults()
    host_properties = get_in(HostConfig.schema(), ["properties", "limits", "properties"])
    manifest_properties = get_in(Manifest.schema(), ["properties", "limits", "properties"])

    for row <- LimitCatalog.rows() do
      name = row.name
      minimum = row.minimum
      maximum = row.maximum

      assert Map.fetch!(compiled, row.field) == row.compiled_default
      assert Map.fetch!(installed, row.field) == row.installed_default
      assert {:ok, ^row} = LimitCatalog.fetch(row.field)
      assert {:ok, ^row} = LimitCatalog.fetch(row.name)
      assert {:ok, row.compiled_default} == Limits.fetch(compiled, row.name)

      assert %{
               "type" => "integer",
               "minimum" => ^minimum,
               "maximum" => ^maximum
             } = Map.fetch!(host_properties, row.name)

      case row.scope do
        :manifest_narrowable ->
          assert %{
                   "type" => "integer",
                   "minimum" => ^minimum,
                   "maximum" => ^maximum
                 } = Map.fetch!(manifest_properties, row.name)

        :installed_only ->
          refute Map.has_key?(manifest_properties, row.name)
      end

      assert {:ok, _limits} = Limits.new(%{row.field => row.minimum})
      assert {:ok, _limits} = Limits.new(%{row.field => row.maximum})
      assert {:error, :invalid_limits} = Limits.new(%{row.field => row.minimum - 1})
      assert {:error, :invalid_limits} = Limits.new(%{row.field => row.maximum + 1})

      assert {:ok, decoded} =
               HostConfig.decode(
                 host_config(%{row.name => row.minimum}),
                 "/tmp"
               )

      assert Map.fetch!(decoded.limits, row.field) == row.minimum

      assert {:ok, decoded} =
               HostConfig.decode(
                 host_config(%{row.name => row.maximum}),
                 "/tmp"
               )

      assert Map.fetch!(decoded.limits, row.field) == row.maximum

      assert {:error, :invalid_host_config} =
               HostConfig.decode(
                 host_config(%{row.name => row.minimum - 1}),
                 "/tmp"
               )

      assert {:error, {:installed_limit_invalid, [{:property, "limits"}, {:property, ^name}]}} =
               HostConfig.decode_command(
                 host_config(%{row.name => row.minimum - 1}),
                 "/tmp"
               )

      assert {:error, :invalid_host_config} =
               HostConfig.decode(
                 host_config(%{row.name => row.maximum + 1}),
                 "/tmp"
               )

      assert {:error, {:installed_limit_invalid, [{:property, "limits"}, {:property, ^name}]}} =
               HostConfig.decode_command(
                 host_config(%{row.name => row.maximum + 1}),
                 "/tmp"
               )
    end
  end

  test "installed-only limits cannot be declared by an application" do
    for name <- Map.keys(@installed_only) do
      manifest = valid_manifest(%{"limits" => %{name => 100}})

      assert {:error, {:manifest_path, [{:property, "limits"}], :unknown_properties}} =
               Manifest.load_memory("ptc.json", documents(manifest))
    end
  end

  test "manifest narrowing consumes only scoped rows and preserves installed-only values" do
    installed_overrides =
      Map.new(LimitCatalog.rows(), fn row ->
        value =
          case row.name do
            "provider_cleanup_timeout_ms" -> 100
            "selection_validation_timeout_ms" -> 30_000
            "doctor_connectivity_timeout_ms" -> 100
            _manifest_narrowable -> row.maximum
          end

        {row.field, value}
      end)

    assert {:ok, installed} = Limits.installed(installed_overrides)

    for requested_value <- [:minimum, :maximum] do
      requested =
        Map.new(LimitCatalog.rows(:manifest_narrowable), fn row ->
          {row.name, Map.fetch!(row, requested_value)}
        end)

      manifest = valid_manifest(%{"limits" => requested})

      assert {:ok, loaded} =
               Manifest.load_memory("ptc.json", documents(manifest), installed)

      for row <- LimitCatalog.rows(:manifest_narrowable) do
        assert Map.fetch!(loaded.limits, row.field) == Map.fetch!(row, requested_value)
      end

      assert loaded.limits.provider_cleanup_timeout_ms == 100
      assert loaded.limits.selection_validation_timeout_ms == 30_000
      assert loaded.limits.doctor_connectivity_timeout_ms == 100
    end
  end

  test "effective identity projection includes only participating catalog rows" do
    defaults = Limits.defaults()
    projection = LimitCatalog.effective_projection(defaults)

    assert projection |> Map.keys() |> Enum.sort() ==
             LimitCatalog.rows()
             |> Enum.filter(& &1.identity)
             |> Enum.map(& &1.name)
             |> Enum.sort()

    for {name, metadata} <- @installed_only do
      {:ok, row} = LimitCatalog.fetch(name)
      {:ok, changed} = Limits.new(%{row.field => metadata.compiled_default + 100})
      changed_projection = LimitCatalog.effective_projection(changed)

      if metadata.identity do
        refute changed_projection == projection
      else
        assert changed_projection == projection
      end
    end
  end

  defp documents(manifest) do
    %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns main) (defn run [input] (return input))"
    }
  end

  defp host_config(limits) do
    %{
      "limits" => limits,
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces"
        }
      }
    }
  end

  defp valid_manifest(extra) do
    Map.merge(
      %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{}}
      },
      extra
    )
  end
end
