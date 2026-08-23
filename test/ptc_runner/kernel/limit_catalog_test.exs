defmodule PtcRunner.Kernel.LimitCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.LimitConfiguration
  alias PtcRunner.Kernel.LimitConfigurationDiagnostic
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.SchemaViolation

  @manifest_narrowable [
    {"capability_argument_bytes", :capability_argument_bytes, 262_144, 4_000_000},
    {"capability_result_bytes", :capability_result_bytes, 1_000_000, 16_000_000},
    {"entry_source_bytes", :entry_source_bytes, 262_144, 4_000_000},
    {"evaluation_admission_timeout_ms", :evaluation_admission_timeout_ms, 10_000, 600_000},
    {"evaluation_heap_words", :evaluation_heap_words, 1_250_000, 1_250_000},
    {"evaluation_history_bytes", :evaluation_history_bytes, 1_000_000, 16_000_000},
    {"evaluation_memory_bytes", :evaluation_memory_bytes, 2_000_000, 32_000_000},
    {"evaluation_timeout_ms", :evaluation_timeout_ms, 30_000, 600_000},
    {"event_payload_bytes", :event_payload_bytes, 262_144, 4_000_000},
    {"live_provider_tasks", :live_provider_tasks, 8, 8},
    {"mission_capability_calls", :mission_capability_calls, 256, 4_096},
    {"mission_capability_calls_per_name", :mission_capability_calls_per_name, 128, 2_048},
    {"normal_event_bytes", :normal_event_bytes, 4_000_000, 64_000_000},
    {"normal_event_count", :normal_event_count, 256, 4_096},
    {"parallel_timeout_ms", :parallel_timeout_ms, 60_000, 600_000},
    {"protocol_errors", :protocol_errors, 64, 512},
    {"provider_heap_words", :provider_heap_words, 5_000_000, 5_000_000},
    {"run_duration_ms", :run_duration_ms, 30_000, 1_800_000},
    {"subordinate_evaluations", :subordinate_evaluations, 128, 2_048},
    {"subordinate_source_bytes", :subordinate_source_bytes, 131_072, 2_000_000},
    {"subordinate_source_checks", :subordinate_source_checks, 128, 2_048},
    {"terminal_result_bytes", :terminal_result_bytes, 1_000_000, 16_000_000},
    {"workflow_capability_calls", :workflow_capability_calls, 256, 4_096},
    {"workflow_capability_calls_per_name", :workflow_capability_calls_per_name, 128, 2_048},
    {"workflow_heap_words", :workflow_heap_words, 8_000_000, 8_000_000},
    {"workflow_timeout_ms", :workflow_timeout_ms, 30_000, 1_800_000}
  ]

  @installed_only %{
    "doctor_connectivity_timeout_ms" => %{
      field: :doctor_connectivity_timeout_ms,
      compiled_default: 10_000,
      installed_default: 10_000,
      identity: false
    },
    "local_preflight_timeout_ms" => %{
      field: :local_preflight_timeout_ms,
      compiled_default: 5_000,
      installed_default: 5_000,
      identity: true
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
                           minimum:
                             case name do
                               "event_payload_bytes" -> EventBudget.minimum_normal_payload_bytes()
                               "normal_event_count" -> 3
                               _other -> 1
                             end,
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

  # A ceiling equal to the default leaves a manifest no way to raise its own
  # value except by writing a host document. Twenty-one rows were in that
  # state. The four aggregate-memory rows stay there on purpose: live memory is
  # a product, and raising it is a resource decision.
  @aggregate_memory_names ~w(
    evaluation_heap_words
    live_provider_tasks
    provider_heap_words
    workflow_heap_words
  )

  test "every application-narrowable limit can be raised from the manifest alone" do
    {zero_headroom, raisable} =
      Enum.split_with(
        LimitCatalog.rows(:manifest_narrowable),
        &(&1.installed_default <= &1.compiled_default)
      )

    assert Enum.sort(Enum.map(zero_headroom, & &1.name)) == @aggregate_memory_names

    for row <- zero_headroom do
      assert row.installed_default == row.compiled_default,
             "#{row.name} is exempt but its installed ceiling #{row.installed_default} is not its default #{row.compiled_default}"
    end

    for row <- raisable do
      assert row.installed_default > row.compiled_default,
             "#{row.name} has no headroom: default and installed ceiling are both #{row.compiled_default}"
    end
  end

  test "a manifest may request any value up to the installed ceiling without a host document" do
    for row <- LimitCatalog.rows(:manifest_narrowable) do
      assert {:ok, limits} =
               Limits.new(%{row.field => row.installed_default}),
             "#{row.name} rejected its own installed ceiling"

      assert Map.fetch!(limits, row.field) == row.installed_default
    end
  end

  test "the checked-in catalog completely and uniquely defines the Limits struct" do
    rows = LimitCatalog.rows()
    fields = Map.keys(Map.from_struct(Limits.defaults()))

    assert Map.new(rows, &{&1.name, Map.drop(&1, [:description, :unit])}) == @expected_catalog
    assert Enum.all?(rows, &(is_binary(&1.description) and &1.description != ""))
    assert Enum.all?(rows, &(&1.unit in [:milliseconds, :heap_words, :bytes, :count]))
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

      if row.name == "normal_event_count" do
        assert {:error,
                {:host_schema_invalid,
                 %SchemaViolation{
                   rule: :minimum,
                   path: [{:property, "limits"}, {:property, ^name}]
                 }}} =
                 HostConfig.decode_command(
                   host_config(%{row.name => row.minimum - 1}),
                   "/tmp"
                 )
      else
        assert {:error, {:installed_limit_invalid, [{:property, "limits"}, {:property, ^name}]}} =
                 HostConfig.decode_command(
                   host_config(%{row.name => row.minimum - 1}),
                   "/tmp"
                 )
      end

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

  test "normal traces require three retained event slots" do
    assert {:ok, row} = LimitCatalog.fetch(:normal_event_count)
    assert row.minimum == 3

    for schema <- [HostConfig.schema(), Manifest.schema()] do
      assert get_in(schema, [
               "properties",
               "limits",
               "properties",
               "normal_event_count",
               "minimum"
             ]) ==
               3
    end
  end

  test "the event payload minimum admits every normal terminal payload" do
    minimum = EventBudget.minimum_normal_payload_bytes()
    assert {:ok, row} = LimitCatalog.fetch(:event_payload_bytes)
    assert row.minimum == minimum
    refute EventBudget.normal_terminal_payload_capacity?(minimum - 1)
    assert EventBudget.normal_terminal_payload_capacity?(minimum)

    for schema <- [HostConfig.schema(), Manifest.schema()] do
      assert get_in(schema, [
               "properties",
               "limits",
               "properties",
               "event_payload_bytes",
               "minimum"
             ]) == minimum
    end
  end

  test "effective normal trace bytes retain one ordinary event and terminal reserve" do
    payload_bytes = 7_000
    {:ok, base} = Limits.new(event_payload_bytes: payload_bytes)
    required_bytes = EventSink.terminal_reserve(:normal, base).bytes + payload_bytes

    {:ok, invalid} =
      Limits.new(event_payload_bytes: payload_bytes, normal_event_bytes: required_bytes - 1)

    assert {:error,
            {:limit_configuration_invalid, configured_bytes, ^required_bytes, ^payload_bytes}} =
             LimitConfiguration.validate_effective(invalid, :normal)

    assert {:ok, message} =
             LimitConfigurationDiagnostic.message(
               configured_bytes,
               required_bytes,
               payload_bytes
             )

    assert LimitConfigurationDiagnostic.valid_message?(message)
    refute LimitConfigurationDiagnostic.valid_message?(message <> "\n")

    assert :ok = LimitConfiguration.validate_effective(invalid, :private)

    assert {:ok, valid} =
             Limits.new(event_payload_bytes: payload_bytes, normal_event_bytes: required_bytes)

    assert :ok = LimitConfiguration.validate_effective(valid, :normal)
  end

  test "installed-only limits cannot be declared by an application" do
    for name <- Map.keys(@installed_only) do
      manifest = valid_manifest(%{"limits" => %{name => 100}})

      assert {:error,
              {:manifest_schema_invalid,
               %SchemaViolation{rule: :unknown_property, path: [property: "limits"]}}} =
               Manifest.load_memory("ptc.json", documents(manifest))
    end
  end

  test "manifest narrowing consumes only scoped rows and preserves installed-only values" do
    minimum_payload_bytes = EventBudget.minimum_normal_payload_bytes()
    {:ok, minimum_payload_limits} = Limits.new(event_payload_bytes: minimum_payload_bytes)

    minimum_normal_event_bytes =
      EventSink.terminal_reserve(:normal, minimum_payload_limits).bytes + minimum_payload_bytes

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
          value =
            case {requested_value, row.name} do
              {:minimum, "normal_event_bytes"} -> minimum_normal_event_bytes
              {:maximum, "event_payload_bytes"} -> 863_999_233
              _other -> Map.fetch!(row, requested_value)
            end

          {row.name, value}
        end)

      manifest = valid_manifest(%{"limits" => requested})

      assert {:ok, loaded} =
               Manifest.load_memory("ptc.json", documents(manifest), installed)

      for row <- LimitCatalog.rows(:manifest_narrowable) do
        assert Map.fetch!(loaded.limits, row.field) == Map.fetch!(requested, row.name)
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
          "installation_revision" => "trace-v1",
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
