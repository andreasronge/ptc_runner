defmodule PtcRunner.Kernel.CapabilityExceptionDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionRecordTypes
  alias PtcRunner.Utf8

  @capture_timeout_ms 250
  @capture_heap_words 1_000_000
  @max_stacktrace_frames 64
  @message_unavailable "exception message unavailable"
  @stacktrace_unavailable "stacktrace unavailable"

  @doc false
  @spec capture(Exception.t(), Exception.stacktrace()) :: map()
  def capture(%{__struct__: exception_class} = exception, stacktrace)
      when is_atom(exception_class) and is_list(stacktrace) do
    {message, message_truncated?} = exception_message(exception)
    {formatted_stacktrace, stacktrace_truncated?} = formatted_stacktrace(stacktrace)

    %{
      exception_class: exception_class(exception_class),
      message: message,
      message_truncated: message_truncated?,
      stacktrace: formatted_stacktrace,
      stacktrace_truncated: stacktrace_truncated?
    }
  end

  @doc false
  @spec start(Exception.t(), Exception.stacktrace(), pid()) ::
          {:ok, pid(), binary()} | {:error, binary()}
  def start(%{__struct__: exception_class} = exception, stacktrace, owner)
      when is_atom(exception_class) and is_list(stacktrace) and is_pid(owner) do
    exception_class = exception_class(exception_class)

    try do
      pid =
        Process.spawn(
          fn ->
            owner_ref = Process.monitor(owner)

            receive do
              {:capture, received_exception, received_stacktrace} ->
                receive do
                  :capture ->
                    diagnostic = capture(received_exception, received_stacktrace)
                    send(owner, {:capability_exception_diagnostic, self(), diagnostic})

                  {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
                    :ok
                after
                  @capture_timeout_ms -> :ok
                end

              {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
                :ok
            after
              @capture_timeout_ms -> :ok
            end
          end,
          max_heap_size: %{
            size: @capture_heap_words,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          }
        )

      send(pid, {:capture, exception, stacktrace})
      {:ok, pid, exception_class}
    rescue
      _exception -> {:error, exception_class}
    catch
      _kind, _reason -> {:error, exception_class}
    end
  end

  @doc false
  @spec await(pid(), binary()) :: map()
  def await(pid, exception_class) when is_pid(pid) and is_binary(exception_class) do
    ref = Process.monitor(pid)
    send(pid, :capture)

    receive do
      {:capability_exception_diagnostic, ^pid, diagnostic} ->
        Process.demonitor(ref, [:flush])
        diagnostic

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        unavailable(exception_class)
    after
      @capture_timeout_ms ->
        Process.exit(pid, :kill)
        await_down(ref, pid)
        flush_diagnostic(pid)
        unavailable(exception_class)
    end
  end

  @doc false
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    await_down(ref, pid)
    flush_diagnostic(pid)
  end

  @doc false
  @spec unavailable(binary()) :: map()
  def unavailable(exception_class) when is_binary(exception_class) do
    %{
      exception_class: exception_class,
      message: @message_unavailable,
      message_truncated: true,
      stacktrace: @stacktrace_unavailable,
      stacktrace_truncated: true
    }
  end

  defp exception_message(exception) do
    case safely(fn -> exception.__struct__.message(exception) end) do
      {:ok, message} when is_binary(message) ->
        bound(message, InspectionRecordTypes.max_exception_message_bytes(), false)

      _unavailable ->
        {@message_unavailable, true}
    end
  end

  defp formatted_stacktrace(stacktrace) do
    {frames, remainder} = Enum.split(stacktrace, @max_stacktrace_frames)

    case safely(fn ->
           frames
           |> Enum.map(&without_arguments/1)
           |> Exception.format_stacktrace()
         end) do
      {:ok, formatted} when is_binary(formatted) ->
        bound(
          formatted,
          InspectionRecordTypes.max_exception_stacktrace_bytes(),
          remainder != []
        )

      _unavailable ->
        {@stacktrace_unavailable, true}
    end
  end

  defp without_arguments({module, function, arguments, location}) when is_list(arguments),
    do: {module, function, length(arguments), location}

  defp without_arguments(frame), do: frame

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp bound(value, max_bytes, already_truncated?) do
    bounded = Utf8.truncate_valid(value, max_bytes)
    {bounded, already_truncated? or bounded != value}
  end

  defp exception_class(exception_class) do
    exception_class
    |> Atom.to_string()
    |> Utf8.truncate_valid(InspectionRecordTypes.max_exception_class_bytes())
  end

  defp await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp flush_diagnostic(pid) do
    receive do
      {:capability_exception_diagnostic, ^pid, _diagnostic} -> :ok
    after
      0 -> :ok
    end
  end
end
