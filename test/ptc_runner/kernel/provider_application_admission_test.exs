defmodule PtcRunner.Kernel.ProviderApplicationAdmissionTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.TestSupport.LLMSupport

  # `LLMSupport.admit_provider_application!/0` stands in for the command-owned
  # gate in modules that build providers directly, so it applies the same
  # VM-global, persistent ReqLLM pool geometry the gate does. This module pins
  # that geometry, and — by admitting from `setup_all` the way every live module
  # does — that the admission is undone when the admitting scope exits. An
  # admission that outlives its module hands its pool configuration to every
  # later test in the VM; that is how a passing suite still failed
  # `ProviderActiveSessionTest`'s startup-failure assertion under `--include
  # e2e`, where a live module ran first.
  setup_all do
    :ok = LLMSupport.admit_provider_application!()
    :ok
  end

  test "admission applies the command-owned pool geometry" do
    assert Application.get_env(:req_llm, :stream_pool_count) == 1

    assert Application.get_env(:req_llm, :stream_pool_size) ==
             Limits.installed_defaults().live_provider_tasks

    assert Application.get_env(:req_llm, :load_dotenv) == false
    assert :req_llm in Enum.map(Application.started_applications(), &elem(&1, 0))
  end
end
