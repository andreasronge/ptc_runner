defmodule PtcRunner.Kernel.DecisionHostConfigTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.HostConfig

  test "chat decisions require an installed json_schema LLM alias" do
    chat = %{
      "source" => "llm",
      "model" => "test:model",
      "credential" => "key",
      "structured_output_mode" => "json_schema",
      "installation_revision" => "chat-v1",
      "usage_guarantees" => %{"tokens" => true, "cost_currency" => nil}
    }

    decision = %{
      "source" => "decision",
      "backend" => "chat",
      "llm" => "chat",
      "installation_revision" => "decision-v1",
      "max_cost_per_call" => %{"currency" => "USD", "amount" => "0.01"},
      "max_total_tokens_per_call" => 8000
    }

    config = %{
      "credentials" => %{"key" => %{"env" => "TEST_KEY"}},
      "install" => %{"decisions" => decision, "chat" => chat}
    }

    assert {:ok, decoded} = HostConfig.decode(config, ".")
    assert decoded.install["decisions"].chat_installation.structured_output_mode == :json_schema
    assert decoded.install["decisions"].credential == "key"
    assert decoded.install["decisions"].usage_guarantees.cost_currency == nil

    for mode <- ["json_object", "unsupported"] do
      assert {:error, :invalid_host_config} =
               HostConfig.decode(
                 put_in(config, ["install", "chat", "structured_output_mode"], mode),
                 "."
               )
    end

    assert {:error, :invalid_host_config} =
             HostConfig.decode(update_in(config, ["install"], &Map.delete(&1, "chat")), ".")

    assert {:error, :invalid_host_config} =
             HostConfig.decode(put_in(config, ["install", "decisions", "llm"], "decisions"), ".")
  end

  @tag :tmp_dir
  test "decision installations require explicit bounds and credential bindings", %{tmp_dir: dir} do
    installation = %{
      "source" => "decision",
      "model" => "typesafe/jev-1.13",
      "credential" => "key",
      "installation_revision" => "decision-v1",
      "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
      "max_cost_per_call" => %{"currency" => "USD", "amount" => "0.01"},
      "max_total_tokens_per_call" => 8000,
      "routing" => %{"zdr" => true, "data_collection" => "deny", "allow_fallbacks" => false}
    }

    config = %{
      "credentials" => %{"key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{"decisions" => installation}
    }

    path = Path.join(dir, "host.json")
    File.write!(path, Jason.encode!(config))
    assert {:ok, host} = HostConfig.load(path)
    assert host.install["decisions"].source == :decision
    assert host.install["decisions"].max_cost_microusd_per_call == 10_000

    invalid =
      [
        Map.delete(installation, "max_cost_per_call"),
        Map.delete(installation, "max_total_tokens_per_call"),
        Map.put(installation, "max_total_tokens_per_call", 0),
        Map.put(installation, "credential", "literal-secret"),
        put_in(installation, ["routing", "unknown"], true)
      ] ++
        Enum.map(
          ["0", "-1", "bad", 0.01],
          &put_in(installation, ["max_cost_per_call", "amount"], &1)
        )

    for value <- invalid do
      File.write!(path, Jason.encode!(put_in(config, ["install", "decisions"], value)))
      assert {:error, _} = HostConfig.load(path)
    end
  end
end
