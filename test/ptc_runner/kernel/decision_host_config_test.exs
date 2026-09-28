defmodule PtcRunner.Kernel.DecisionHostConfigTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.HostConfig

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
