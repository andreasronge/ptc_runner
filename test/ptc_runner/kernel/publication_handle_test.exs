defmodule PtcRunner.Kernel.PublicationHandleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.PublicationHandle

  @event [:ptc_runner, :publication, :destination_unavailable]

  @tag :tmp_dir
  test "reports an unmapped filesystem reason without exposing the destination", %{tmp_dir: dir} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    on_exit(fn -> :telemetry.detach(ref) end)
    destination = Path.join(dir, "result.json")

    fault_hook = fn
      :staging_file -> {:error, :eio}
      _stage -> :ok
    end

    assert {:error, :destination_unavailable} =
             PublicationHandle.reserve_direct(destination, :result, 0o600, self(), fault_hook)

    assert_receive {@event, ^ref, %{}, metadata}
    assert metadata == %{operation: :reserve, kind: :result, cause: {:reason, :eio}}
    refute inspect(metadata) =~ dir
    refute_receive {@event, ^ref, _, _}
  end

  @tag :tmp_dir
  test "reports an exception class without its message or destination", %{tmp_dir: dir} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    on_exit(fn -> :telemetry.detach(ref) end)
    destination = Path.join(dir, "result.json")

    fault_hook = fn
      :staging_file -> raise ArgumentError, "private text #{dir}"
      _stage -> :ok
    end

    assert {:error, :destination_unavailable} =
             PublicationHandle.reserve_direct(destination, :result, 0o600, self(), fault_hook)

    assert_receive {@event, ^ref, %{}, metadata}
    assert metadata == %{operation: :reserve, kind: :result, cause: {:exception, ArgumentError}}
    refute inspect(metadata) =~ dir
    refute_receive {@event, ^ref, _, _}
  end

  @tag :tmp_dir
  test "replaces a non-atom failure with unexpected_reply", %{tmp_dir: dir} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    on_exit(fn -> :telemetry.detach(ref) end)

    fault_hook = fn
      :staging_file -> {:error, dir}
      _stage -> :ok
    end

    assert {:error, :destination_unavailable} =
             PublicationHandle.reserve_direct(
               Path.join(dir, "result.json"),
               :result,
               0o600,
               self(),
               fault_hook
             )

    assert_receive {@event, ^ref, %{}, metadata}

    assert metadata == %{
             operation: :reserve,
             kind: :result,
             cause: {:reason, :unexpected_reply}
           }

    refute inspect(metadata) =~ dir
    refute_receive {@event, ^ref, _, _}
  end

  @tag :tmp_dir
  test "append reservation identifies its operation for an unexpected reply", %{tmp_dir: dir} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    on_exit(fn -> :telemetry.detach(ref) end)
    destination = Path.join(dir, "trace.jsonl")
    File.write!(destination, "")

    fault_hook = fn
      :after_open -> :unexpected_reply
      _stage -> :ok
    end

    assert {:error, :destination_unavailable} =
             PublicationHandle.reserve_append_direct(
               destination,
               :trace,
               0,
               self(),
               fault_hook
             )

    assert_receive {@event, ^ref, %{}, metadata}

    assert metadata == %{
             operation: :reserve_append,
             kind: :trace,
             cause: {:reason, :unexpected_reply}
           }

    refute_receive {@event, ^ref, _, _}
  end

  @tag :tmp_dir
  test "does not report a mapped filesystem failure as a collapse", %{tmp_dir: dir} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    on_exit(fn -> :telemetry.detach(ref) end)

    fault_hook = fn
      :staging_file -> {:error, :enospc}
      _stage -> :ok
    end

    assert {:error, :enospc} =
             PublicationHandle.reserve_direct(
               Path.join(dir, "result.json"),
               :result,
               0o600,
               self(),
               fault_hook
             )

    refute_receive {@event, ^ref, _, _}
  end
end
