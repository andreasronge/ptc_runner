defmodule PtcRunner.TestSupport.TestHelpers do
  @moduledoc """
  Shared test helper functions used across multiple test files.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunState

  @doc "Dummy tool that ignores name and args and returns :ok"
  def dummy_tool(_name, _args), do: :ok

  @doc "A minimal valid application manifest. Merge `overrides` onto the top-level map."
  def valid_manifest(overrides \\ %{}) do
    base = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    Map.merge(base, overrides)
  end

  @doc "Builds the complete canonical dispatch context used by Kernel tests."
  def dispatch_context(state, environment, timeout_ms, opts \\ [])
      when environment in [:workflow, :mission] do
    limits = RunState.limits(state)

    %{
      timeout_ms: timeout_ms,
      validation_heap_words:
        if(environment == :workflow,
          do: limits.workflow_heap_words,
          else: limits.evaluation_heap_words
        ),
      evaluation_lease: Keyword.get(opts, :lease),
      validation_deadline_ms: Keyword.get(opts, :validation_deadline_ms),
      mission_name: Keyword.get(opts, :mission_name)
    }
  end

  @doc "Builds a current staged provider whose acquisition returns a normalized build map."
  def staged_provider(acquire) when is_function(acquire, 2) do
    ProviderRegistry.staged(fn config, context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> acquire.(config, context) end} end
       }}
    end)
  end

  @doc "Builds a valid current public LLM provider snapshot for trace tests."
  def llm_snapshot(alias_name, revision, model) do
    declaration = %{
      "name" => alias_name,
      "source" => "llm",
      "installation_revision" => revision,
      "data_class" => "normal",
      "accepts_data" => ["normal"],
      "authorization_mode" => "none",
      "config" => %{
        "default" => false,
        "max_request_bytes" => 1_000_000,
        "max_response_bytes" => 1_000_000,
        "max_calls" => 2_048
      }
    }

    acquisition = %{"source" => "llm", "resolved_model" => model}
    acquisition_hash = canonical_sha256(acquisition)

    identity = %{
      "declaration" => declaration,
      "acquisition" => acquisition,
      "acquisition_identity_hash" => acquisition_hash
    }

    identity
    |> Map.put("provider", alias_name)
    |> Map.put("snapshot_hash", canonical_sha256(identity))
  end

  @doc """
  Returns an ExUnit skip reason when optional environment variables are absent.

  Empty values count as absent. Tests still fail normally when a configured
  prerequisite is invalid or unavailable during execution.
  """
  @spec environment_skip_reason([String.t()]) :: String.t() | nil
  def environment_skip_reason(names) when is_list(names) do
    names
    |> Enum.filter(&(System.get_env(&1) in [nil, ""]))
    |> missing_environment_reason()
  end

  @doc """
  Returns an ExUnit skip reason when optional executables are unavailable.

  Tests still fail normally when a discovered executable cannot start or
  fails during execution.
  """
  @spec executable_skip_reason([String.t()]) :: String.t() | nil
  def executable_skip_reason(names) when is_list(names) do
    names
    |> Enum.filter(&(System.find_executable(&1) == nil))
    |> missing_executable_reason()
  end

  @doc """
  Stops a process (Agent/GenServer) started in test setup, tolerating the
  teardown race. A `start_link`-ed process dies with the test process, which can
  race `on_exit`: `if Process.alive?(pid), do: GenServer.stop(pid)` is a TOCTOU —
  the pid can read alive and then exit `:noproc` before the stop lands. This
  swallows that exit and is a no-op on an already-dead pid or non-pid value.
  """
  def stop_quietly(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  def stop_quietly(_), do: :ok

  defp missing_environment_reason([]), do: nil

  defp missing_environment_reason(names),
    do: "optional E2E prerequisites are not configured: #{Enum.join(names, ", ")}"

  defp missing_executable_reason([]), do: nil

  defp missing_executable_reason(names),
    do: "optional E2E executables are not available on PATH: #{Enum.join(names, ", ")}"

  defp canonical_sha256(value) do
    {:ok, bytes} = DeterministicJSON.encode(value)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  A PTC-Lisp entry body that genuinely occupies its worker while a test
  inspects the run in flight.

  `(loop [] (recur))` reads like an infinite loop and has been used across this
  suite as one, but it is not: PTC-Lisp hard-caps `loop`/`recur` at exactly
  1_000 jumps (`PtcRunner.Lisp.Eval.Context`'s `loop_limit`, which is not
  reachable through manifest limits), and an empty body burns through that cap
  in well under a second. Any test that kills a caller, traces an owner, or
  calls `:sys.get_state/1` on a session "while the run blocks" is really racing
  that natural completion, and loses under full-suite load — surfacing as an
  `ArgumentError` or a `:noproc` exit on an already-exited process rather than
  as an obvious timeout.

  This gives each of the 1_000 iterations real work instead. `repeats` scales
  that work roughly linearly: 1 lands near 6s on a developer machine, 5 near
  30s. Callers should pick the smallest value that clears their own setup
  overhead by a wide margin — the duration is calibrated, not guaranteed, so
  the margin is what separates a real regression from hardware variance.

  Prefer a shorter body on paths that do not pass `link: true` to
  `PtcRunner.Sandbox` (notably `Runner.execute_workflow/4`): there, killing the
  caller does not tear the sandbox process down, so an early test failure
  leaves this loop running unlinked until its own deadline.
  """
  def long_running_body(repeats \\ 1) when is_integer(repeats) and repeats >= 1 do
    work =
      "(reduce + 0 (range 20000))"
      |> List.duplicate(repeats)
      |> Enum.join(" ")

    "(loop [i 0 acc 0] (if (< i 1000) (recur (inc i) (+ acc #{work})) acc))"
  end
end
