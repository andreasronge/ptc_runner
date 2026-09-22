defmodule PtcRunner.Kernel.ProviderPinsCommandTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag :nightly
  @tag :tmp_dir
  test "operator command prints the exact two pin maps without running the workflow", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(%{"type" => "object"}))

    File.write!(
      Path.join(dir, "main.clj"),
      ~s|(ns app) (defn run {:effect :write} [input] (fail {"message" "must never execute"}))|
    )

    File.write!(
      Path.join(dir, "ptc.json"),
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"path" => "deliberately-missing.json"},
        "providers" => %{"workflow" => [%{"name" => "selected", "config" => %{}}]},
        "contracts" => %{
          "input_schema" => %{"path" => "schema.json"},
          "result_schema" => %{"path" => "schema.json"}
        }
      })
    )

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_PIN_COMMAND_KEY"}},
        "install" => %{
          "selected" => %{
            "source" => "llm",
            "model" => "openrouter:google/gemma-2-27b-it",
            "credential" => "key",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "pins-command-v1"
          }
        }
      })
    )

    secret = "operator-command-private-value"
    File.write!(Path.join(dir, "capture.env"), "PTC_PIN_COMMAND_KEY=" <> secret <> "\n")

    {output, status} =
      System.cmd(
        "mix",
        [
          "ptc.provider_pins",
          Path.join(dir, "ptc.json"),
          "--host",
          Path.join(dir, "host.json"),
          "--env-file",
          Path.join(dir, "capture.env")
        ],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ secret
    pins = output |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()
    assert Map.keys(pins) |> Enum.sort() == ["installation_config_pins", "provider_snapshot_pins"]
    assert %{"selected" => "sha256:" <> installation} = pins["installation_config_pins"]
    assert %{"workflow/selected" => "sha256:" <> acquisition} = pins["provider_snapshot_pins"]
    assert byte_size(installation) == 64
    assert byte_size(acquisition) == 64
  end
end
