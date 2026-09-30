defmodule PtcRunner.Kernel.DecisionHostConfigTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation

  test "HTTP decisions admit zero bounds and diagnose endpoints" do
    installation = %{
      "source" => "decision",
      "backend" => "http",
      "endpoint" => "http://127.0.0.1:8321/decisions",
      "allow_insecure_loopback" => true,
      "model" => "local-v1",
      "usage_guarantees" => %{"tokens" => true, "cost_currency" => nil},
      "installation_revision" => "v1",
      "max_cost_per_call" => %{"currency" => "USD", "amount" => "0"},
      "max_total_tokens_per_call" => 8000
    }

    config = %{"install" => %{"decisions" => installation}}
    assert {:ok, host} = HostConfig.decode(config, ".")
    assert host.install["decisions"].max_cost_microusd_per_call == 0

    assert HostInstallation.installation_credential_names(host.install["decisions"]) == []

    {:ok, changed} =
      HostConfig.decode(
        put_in(config, ["install", "decisions", "endpoint"], "http://127.0.0.1:8322/decisions"),
        "."
      )

    refute host.install["decisions"].installation_config_digest ==
             changed.install["decisions"].installation_config_digest

    for endpoint <- ["http://[::1]:8321/x", "http://127.0.0.1:1/x"] do
      assert {:ok, _} =
               HostConfig.decode(
                 put_in(config, ["install", "decisions", "endpoint"], endpoint),
                 "."
               )

      assert {:error, _} =
               HostConfig.decode(
                 put_in(
                   config,
                   ["install", "decisions"],
                   installation
                   |> Map.put("endpoint", endpoint)
                   |> Map.delete("allow_insecure_loopback")
                 ),
                 "."
               )
    end

    secure =
      installation
      |> Map.put("endpoint", "https://example.test/x")
      |> Map.delete("allow_insecure_loopback")

    assert {:ok, _} = HostConfig.decode(put_in(config, ["install", "decisions"], secure), ".")

    for invalid <- [
          Map.put(secure, "allow_insecure_loopback", true),
          Map.put(installation, "credential", "key"),
          Map.put(secure, "endpoint", "https://user@example.test/x"),
          Map.put(secure, "endpoint", "https://example.test/x#fragment"),
          Map.put(secure, "endpoint", "https://example.test/x\r\n"),
          Map.put(installation, "max_total_tokens_per_call", 0),
          put_in(installation, ["max_cost_per_call", "amount"], "-1"),
          put_in(installation, ["max_cost_per_call", "amount"], "bad")
        ] do
      assert {:error, _} =
               HostConfig.decode(put_in(config, ["install", "decisions"], invalid), ".")
    end

    assert {:error, _} =
             HostConfig.decode(Map.put(config, "limits", %{"llm_cost_microusd" => 1000}), ".")

    for key <- ~w(endpoint model usage_guarantees installation_revision) do
      assert {:error, _} =
               HostConfig.decode(
                 put_in(config, ["install", "decisions"], Map.delete(installation, key)),
                 "."
               )
    end

    assert {:error, _} =
             HostConfig.decode(put_in(config, ["install", "decisions", "unknown"], true), ".")

    assert {:error, {:installation_endpoint_invalid, "decisions", :literal_loopback_required}} =
             HostConfig.decode_command(
               put_in(config, ["install", "decisions", "endpoint"], "http://localhost/x"),
               "."
             )
  end

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
      "max_cost_per_call" => %{"currency" => "USD", "amount" => "0"},
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

    assert {:ok, zero} =
             HostConfig.decode(
               put_in(config, ["install", "decisions", "max_cost_per_call", "amount"], "0"),
               dir
             )

    assert zero.install["decisions"].max_cost_microusd_per_call == 0

    invalid =
      [
        Map.delete(installation, "max_cost_per_call"),
        Map.delete(installation, "max_total_tokens_per_call"),
        Map.put(installation, "max_total_tokens_per_call", 0),
        Map.put(installation, "credential", "literal-secret"),
        put_in(installation, ["routing", "unknown"], true)
      ] ++
        Enum.map(
          ["-1", "bad", 0.01],
          &put_in(installation, ["max_cost_per_call", "amount"], &1)
        )

    for value <- invalid do
      File.write!(path, Jason.encode!(put_in(config, ["install", "decisions"], value)))
      assert {:error, _} = HostConfig.load(path)
    end
  end
end
