defmodule PtcRunnerMcp.CredentialsTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.Credentials` — the singleton GenServer that
  resolves bindings to bytes and owns the redaction-set ETS table.

  Spec: `Plans/http-transport-credentials.md` §4.2, §5.4.1, §7.1, §7.2,
  §7.4, §7.5, §7.5.2.

  These tests are `async: false` because the GenServer optionally
  registers itself as a global named singleton and writes to a named
  ETS table. Each test starts its own instance under a unique name to
  isolate state.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding

  # ---- helpers --------------------------------------------------------------

  defp unique_name do
    :"creds_#{:erlang.unique_integer([:positive])}"
  end

  defp start_creds(bindings) do
    name = unique_name()
    pid = start_supervised!({Credentials, [name: name, bindings: bindings]})
    %{name: name, pid: pid}
  end

  defp env_binding(name, var, opts \\ []) do
    %Binding{
      name: name,
      source: :env,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{var: var}
    }
  end

  defp file_binding(name, path, opts \\ []) do
    %Binding{
      name: name,
      source: :file,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{path: path}
    }
  end

  defp literal_binding(name, value, opts \\ []) do
    %Binding{
      name: name,
      source: :literal,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{value: value}
    }
  end

  defp tmp_secret_file(content, mode \\ 0o600) do
    path =
      Path.join(System.tmp_dir!(), "creds_#{:erlang.unique_integer([:positive])}.secret")

    File.write!(path, content)
    File.chmod!(path, mode)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp redaction_table(server) do
    :sys.get_state(server).table
  end

  defp redaction_secrets(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {secret, _meta} -> secret end)
    |> Enum.sort()
  end

  # ---- exposed module-level helpers -----------------------------------------

  describe "table_name/0" do
    test "returns the spec-mandated name :credentials_redaction_set" do
      assert Credentials.table_name() == :credentials_redaction_set
    end
  end

  describe "list_bindings/1" do
    test "returns sorted binding names" do
      %{name: name} =
        start_creds(%{
          "zeta" => literal_binding("zeta", "z"),
          "alpha" => literal_binding("alpha", "a"),
          "mid" => literal_binding("mid", "m")
        })

      assert Credentials.list_bindings(name) == ["alpha", "mid", "zeta"]
    end

    test "returns [] when no bindings configured" do
      %{name: name} = start_creds(%{})
      assert Credentials.list_bindings(name) == []
    end
  end

  describe "materialize/2 — env source" do
    test "happy path resolves to env value" do
      var = "PTC_TEST_CREDS_#{:erlang.unique_integer([:positive])}"
      System.put_env(var, "tok-abcdef-1234567890")
      on_exit(fn -> System.delete_env(var) end)

      %{name: name} = start_creds(%{"b" => env_binding("b", var)})

      assert {:ok, %{raw: "tok-abcdef-1234567890", scheme_hint: :raw, expires_at: :never}} =
               Credentials.materialize(name, "b")
    end

    test "returns :resolution_failed when env var is unset" do
      var = "PTC_TEST_CREDS_MISSING_#{:erlang.unique_integer([:positive])}"
      System.delete_env(var)

      %{name: name} = start_creds(%{"b" => env_binding("b", var)})

      assert {:error, :resolution_failed, detail} = Credentials.materialize(name, "b")
      assert detail =~ var
    end

    test "treats empty env var as unset" do
      var = "PTC_TEST_CREDS_EMPTY_#{:erlang.unique_integer([:positive])}"
      System.put_env(var, "")
      on_exit(fn -> System.delete_env(var) end)

      %{name: name} = start_creds(%{"b" => env_binding("b", var)})

      assert {:error, :resolution_failed, _detail} = Credentials.materialize(name, "b")
    end

    test "re-resolves env var on every call (no cache, §7.4)" do
      var = "PTC_TEST_CREDS_ROT_#{:erlang.unique_integer([:positive])}"
      System.put_env(var, "rot-value-one-aaaaaa")
      on_exit(fn -> System.delete_env(var) end)

      %{name: name} = start_creds(%{"b" => env_binding("b", var)})

      assert {:ok, %{raw: "rot-value-one-aaaaaa"}} = Credentials.materialize(name, "b")

      System.put_env(var, "rot-value-two-bbbbbb")

      assert {:ok, %{raw: "rot-value-two-bbbbbb"}} = Credentials.materialize(name, "b")
    end
  end

  describe "materialize/2 — file source" do
    test "happy path reads file and trims trailing whitespace" do
      path = tmp_secret_file("file-secret-xyz-99\n")
      %{name: name} = start_creds(%{"b" => file_binding("b", path)})

      assert {:ok, %{raw: "file-secret-xyz-99", scheme_hint: :raw}} =
               Credentials.materialize(name, "b")
    end

    test "returns :resolution_failed when file is missing" do
      missing = Path.join(System.tmp_dir!(), "does_not_exist_#{:erlang.unique_integer()}")

      %{name: name} = start_creds(%{"b" => file_binding("b", missing)})

      assert {:error, :resolution_failed, detail} = Credentials.materialize(name, "b")
      assert detail =~ missing
    end

    test "returns :resolution_failed when file is empty after trim" do
      path = tmp_secret_file("\n   \n")
      %{name: name} = start_creds(%{"b" => file_binding("b", path)})

      assert {:error, :resolution_failed, detail} = Credentials.materialize(name, "b")
      assert detail =~ "empty"
    end

    test "re-reads file on every call (no cache, §7.4)" do
      path = tmp_secret_file("first-content-aaaaaaa\n")
      %{name: name} = start_creds(%{"b" => file_binding("b", path)})

      assert {:ok, %{raw: "first-content-aaaaaaa"}} = Credentials.materialize(name, "b")

      File.write!(path, "second-content-bbbbbbb\n")

      assert {:ok, %{raw: "second-content-bbbbbbb"}} = Credentials.materialize(name, "b")
    end

    test "logs at info when file mode has loose bits (group/world readable)" do
      prior = PtcRunnerMcp.Log.level()
      PtcRunnerMcp.Log.set_level(:info)
      on_exit(fn -> PtcRunnerMcp.Log.set_level(prior) end)

      path = tmp_secret_file("loose-mode-secret-aaaa\n", 0o644)
      %{name: name} = start_creds(%{"loose" => file_binding("loose", path)})

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, _} = Credentials.materialize(name, "loose")
        end)

      assert stderr =~ "credentials_file_mode_loose"
      # Sanity: the file's contents must NOT appear in the log (§5.4.1).
      refute stderr =~ "loose-mode-secret-aaaa"
    end

    test "does not log loose-mode warning when mode is 0o600" do
      prior = PtcRunnerMcp.Log.level()
      PtcRunnerMcp.Log.set_level(:info)
      on_exit(fn -> PtcRunnerMcp.Log.set_level(prior) end)

      path = tmp_secret_file("tight-mode-secret-aaaa\n", 0o600)
      %{name: name} = start_creds(%{"tight" => file_binding("tight", path)})

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, _} = Credentials.materialize(name, "tight")
        end)

      refute stderr =~ "credentials_file_mode_loose"
    end
  end

  describe "materialize/2 — literal source" do
    test "happy path reads from spec verbatim" do
      %{name: name} = start_creds(%{"b" => literal_binding("b", "lit-secret-aaaa")})

      assert {:ok, %{raw: "lit-secret-aaaa", scheme_hint: :raw}} =
               Credentials.materialize(name, "b")
    end
  end

  describe "materialize/2 — unknown binding" do
    test "returns :unknown_binding error" do
      %{name: name} = start_creds(%{})

      assert {:error, :unknown_binding, detail} = Credentials.materialize(name, "nope")
      assert detail =~ "nope"
    end
  end

  describe "scheme_hint passthrough" do
    test "echoes the binding's scheme_hint when set" do
      %{name: name} =
        start_creds(%{
          "b" => literal_binding("b", "v-aaaa", scheme_hint: :bearer)
        })

      assert {:ok, %{scheme_hint: :bearer}} = Credentials.materialize(name, "b")
    end

    test "defaults to :raw when scheme_hint is nil" do
      %{name: name} =
        start_creds(%{"b" => literal_binding("b", "v-aaaa")})

      assert {:ok, %{scheme_hint: :raw}} = Credentials.materialize(name, "b")
    end
  end

  describe "redaction set ETS table" do
    test "first-emission race property: value is in the table BEFORE materialize/2 returns (§7.5.2)" do
      %{name: name, pid: pid} =
        start_creds(%{"b" => literal_binding("b", "race-secret-aaaaa")})

      table = redaction_table(pid)

      assert {:ok, %{raw: raw}} = Credentials.materialize(name, "b")
      # Synchronous: the lookup happens in the test process, after
      # materialize/2 returns. If the GenServer didn't insert before
      # replying, this would be flaky. The point of the test is that
      # there's no flake — the contract guarantees the insert is done.
      assert [{^raw, %{scopes: scopes, bytes: bytes}}] =
               :ets.lookup(table, raw)

      assert bytes == byte_size(raw)
      assert get_in(scopes, [{:binding, "b"}, :source]) == :literal
    end

    test "table is :protected — readable by other processes, not writable" do
      %{name: name, pid: pid} =
        start_creds(%{"b" => literal_binding("b", "prot-secret-aaa")})

      table = redaction_table(pid)
      assert {:ok, %{raw: raw}} = Credentials.materialize(name, "b")

      # Another process can read.
      assert [{^raw, %{scopes: scopes}}] =
               Task.async(fn -> :ets.lookup(table, raw) end)
               |> Task.await()

      assert Map.has_key?(scopes, {:binding, "b"})

      # Another process cannot write — :ets.insert raises ArgumentError
      # under :protected access mode.
      task =
        Task.async(fn ->
          try do
            :ets.insert(table, {"injected-secret", true})
            :inserted
          rescue
            ArgumentError -> :rejected
          end
        end)

      assert Task.await(task) == :rejected
    end

    test "two materializations of same binding both end up in the set (set semantics dedupe)" do
      %{name: name, pid: pid} =
        start_creds(%{"b" => literal_binding("b", "dup-secret-aaaa")})

      table = redaction_table(pid)

      assert {:ok, %{raw: r1}} = Credentials.materialize(name, "b")
      assert {:ok, %{raw: r2}} = Credentials.materialize(name, "b")
      assert r1 == r2
      assert [{^r1, %{scopes: scopes}}] = :ets.lookup(table, r1)
      assert Map.has_key?(scopes, {:binding, "b"})
      assert :ets.tab2list(table) |> Enum.count(fn {k, _} -> k == r1 end) == 1
    end

    test "pruning one binding does not remove a shared secret still used by another binding" do
      var = "PTC_TEST_CREDS_SHARED_#{:erlang.unique_integer([:positive])}"
      System.put_env(var, "shared-secret-aaaaaa")
      on_exit(fn -> System.delete_env(var) end)

      %{name: name, pid: pid} =
        start_creds(%{
          "a" => literal_binding("a", "shared-secret-aaaaaa"),
          "b" => env_binding("b", var)
        })

      table = redaction_table(pid)

      assert {:ok, %{raw: shared}} = Credentials.materialize(name, "a")
      assert {:ok, %{raw: ^shared}} = Credentials.materialize(name, "b")

      System.put_env(var, "b-rotation-one-bbbbb")
      assert {:ok, %{raw: _}} = Credentials.materialize(name, "b")

      System.put_env(var, "b-rotation-two-ccccc")
      assert {:ok, %{raw: _}} = Credentials.materialize(name, "b")

      assert [{^shared, %{scopes: scopes}}] = :ets.lookup(table, shared)
      assert Map.has_key?(scopes, {:binding, "a"})
      refute Map.has_key?(scopes, {:binding, "b"})
    end

    test "rotated values keep only the current value plus one prior rotation" do
      var = "PTC_TEST_CREDS_ROT2_#{:erlang.unique_integer([:positive])}"
      System.put_env(var, "old-rotated-aaaaaaa")
      on_exit(fn -> System.delete_env(var) end)

      %{name: name, pid: pid} = start_creds(%{"b" => env_binding("b", var)})
      table = redaction_table(pid)

      assert {:ok, %{raw: old}} = Credentials.materialize(name, "b")
      System.put_env(var, "new-rotated-bbbbbbb")
      assert {:ok, %{raw: new}} = Credentials.materialize(name, "b")

      assert [_] = :ets.lookup(table, old)
      assert [_] = :ets.lookup(table, new)

      System.put_env(var, "third-rotated-cccccc")
      assert {:ok, %{raw: third}} = Credentials.materialize(name, "b")

      assert :ets.lookup(table, old) == []
      assert redaction_secrets(table) == Enum.sort([new, third])
    end

    test "oversized resolved credentials fail before insertion" do
      max = Credentials.max_redaction_secret_bytes()
      value = String.duplicate("x", max + 1)
      %{name: name, pid: pid} = start_creds(%{"b" => literal_binding("b", value)})
      table = redaction_table(pid)

      assert {:error, :resolution_failed, detail} = Credentials.materialize(name, "b")
      assert detail =~ "exceeds #{max} bytes"
      assert :ets.info(table, :size) == 0
    end

    test "manually registered redaction secrets are bounded by total secret bytes" do
      %{name: name, pid: pid} = start_creds(%{})
      table = redaction_table(pid)
      max = Credentials.max_redaction_total_bytes()
      chunk_size = div(Credentials.max_redaction_secret_bytes(), 2)
      count = div(max, chunk_size) + 4

      secrets =
        for n <- 1..count do
          Integer.to_string(n) <> ":" <> String.duplicate("x", chunk_size - 3)
        end

      :ok = Credentials.register_redaction_secrets(name, secrets)

      total_bytes =
        table
        |> :ets.tab2list()
        |> Enum.reduce(0, fn {secret, _meta}, acc -> acc + byte_size(secret) end)

      assert total_bytes <= max
      assert :ets.info(table, :size) < count
    end

    test "manual redaction pressure does not evict current binding values" do
      %{name: name, pid: pid} =
        start_creds(%{"b" => literal_binding("b", "active-binding-secret-aaaa")})

      table = redaction_table(pid)
      assert {:ok, %{raw: active}} = Credentials.materialize(name, "b")

      max = Credentials.max_redaction_total_bytes()
      chunk_size = div(Credentials.max_redaction_secret_bytes(), 2)
      count = div(max, chunk_size) + 4

      manual_secrets =
        for n <- 1..count do
          "manual-#{n}-" <> String.duplicate("x", chunk_size - byte_size("manual-#{n}-"))
        end

      :ok = Credentials.register_redaction_secrets(name, manual_secrets)

      assert [{^active, %{scopes: scopes}}] = :ets.lookup(table, active)
      assert Map.has_key?(scopes, {:binding, "b"})

      total_bytes =
        table
        |> :ets.tab2list()
        |> Enum.reduce(0, fn {secret, _meta}, acc -> acc + byte_size(secret) end)

      assert total_bytes <= max
    end

    test "materialization fails instead of evicting an active binding when current values exceed total cap" do
      max_secret = Credentials.max_redaction_secret_bytes()
      max_total = Credentials.max_redaction_total_bytes()
      successful_count = div(max_total, max_secret)
      overflowing_name = "b#{successful_count + 1}"

      bindings =
        for n <- 1..(successful_count + 1), into: %{} do
          name = "b#{n}"
          value = name <> ":" <> String.duplicate("x", max_secret - byte_size(name) - 1)
          {name, literal_binding(name, value)}
        end

      %{name: name, pid: pid} = start_creds(bindings)
      table = redaction_table(pid)

      materialized =
        for n <- 1..successful_count do
          binding_name = "b#{n}"
          assert {:ok, %{raw: raw}} = Credentials.materialize(name, binding_name)
          {binding_name, raw}
        end

      assert {:error, :resolution_failed, detail} =
               Credentials.materialize(name, overflowing_name)

      assert detail =~ "exceeds redaction table capacity"

      for {_binding_name, raw} <- materialized do
        assert [_] = :ets.lookup(table, raw)
      end

      overflowing_value =
        bindings |> Map.fetch!(overflowing_name) |> Map.fetch!(:spec) |> Map.fetch!(:value)

      assert :ets.lookup(table, overflowing_value) == []
    end

    test "failed capacity rollback restores rows pruned during the attempted materialization" do
      max_secret = Credentials.max_redaction_secret_bytes()
      max_total = Credentials.max_redaction_total_bytes()
      successful_count = div(max_total, max_secret)
      overflowing_name = "b#{successful_count + 1}"

      bindings =
        for n <- 1..(successful_count + 1), into: %{} do
          name = "b#{n}"
          value = name <> ":" <> String.duplicate("x", max_secret - byte_size(name) - 1)
          {name, literal_binding(name, value)}
        end

      %{name: name, pid: pid} = start_creds(bindings)
      table = redaction_table(pid)

      for n <- 1..successful_count do
        assert {:ok, %{raw: _raw}} = Credentials.materialize(name, "b#{n}")
      end

      manual = "manual-row-that-total-prune-would-delete"

      :sys.replace_state(pid, fn state ->
        :ets.insert(state.table, {
          manual,
          %{
            bytes: byte_size(manual),
            scopes: %{manual: %{source: :manual, inserted_at: 1}}
          }
        })

        state
      end)

      overflowing_value =
        bindings |> Map.fetch!(overflowing_name) |> Map.fetch!(:spec) |> Map.fetch!(:value)

      assert {:error, :resolution_failed, _detail} =
               Credentials.materialize(name, overflowing_name)

      assert [_] = :ets.lookup(table, manual)
      assert :ets.lookup(table, overflowing_value) == []
    end

    test "oversized manually registered redaction secrets are ignored" do
      %{name: name, pid: pid} = start_creds(%{})
      table = redaction_table(pid)
      oversized = String.duplicate("x", Credentials.max_redaction_secret_bytes() + 1)

      :ok = Credentials.register_redaction_secrets(name, [oversized])

      assert :ets.info(table, :size) == 0
    end
  end
end
