defmodule PtcRunner.Kernel.CommandRenderer do
  @moduledoc """
  Deterministic, privacy-preserving human projection of sealed command outcomes.

  Provider failures include the validated provider subject already present in
  the public command envelope. Manifest and value-contract failures with a
  non-root, schema-authorized path include its JSON Pointer. Unusual
  contract-authored pointers use an escaped quoted representation before they
  enter a terminal. Rendering never derives labels from a rejected value,
  provider response, credential, or unvalidated path. Component compile
  failures with a proven byte span render the logical component name and
  canonical half-open byte range already present in the envelope; rendering
  does not retain or reopen component source. A replay miss may include only
  its validated opaque request hash.
  """

  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DiagnosticCatalog

  @spec render(CommandOutcome.t(), CommandRejection.t() | nil) ::
          {:stdout | :stderr, binary()}
  def render(%CommandOutcome{} = outcome, rejection \\ nil) do
    envelope = CommandOutcome.to_map(outcome)

    case envelope do
      %{
        "status" => "ok",
        "command" => "run",
        "result" => %{"result_class" => "normal", "value" => value}
      } ->
        {:stdout, json_line(value)}

      %{"status" => "ok", "command" => "run", "artifact_class" => artifact_class} ->
        {:stdout, json_line(%{"artifact_class" => artifact_class, "status" => "ok"})}

      %{"status" => "ok", "command" => "help", "result" => result} ->
        {:stdout, help_text(result)}

      %{"status" => "ok", "command" => "version", "result" => %{"version" => version}} ->
        {:stdout, version <> "\n"}

      %{"status" => "ok", "command" => "init", "result" => %{"created" => created}} ->
        {:stdout, "created " <> Enum.join(created, ", ") <> "\n"}

      %{"status" => "ok", "result" => result} ->
        {:stdout, json_line(result)}

      %{
        "status" => "error",
        "command" => "doctor",
        "result" => %{"readiness" => "failed"} = result
      } ->
        {:stdout, json_line(result)}

      %{"status" => "error", "error" => error, "run_ref" => run_ref} ->
        {:stderr, failure_line(error, run_ref, rejection)}
    end
  rescue
    _exception ->
      {:stderr,
       "error: internal/internal_error: internal command failure " <>
         "(run_ref: #{outcome_run_ref(outcome)})\n"}
  end

  @spec envelope_failure(binary()) :: binary()
  def envelope_failure(run_ref) when is_binary(run_ref),
    do:
      "error: envelope/publication_failed: command envelope could not be published " <>
        "(run_ref: #{run_ref})\n"

  @spec rejection(binary(), CommandRejection.t()) :: binary()
  def rejection(run_ref, %CommandRejection{} = rejection) do
    row = DiagnosticCatalog.fetch!(:arguments, rejection.code)

    failure_line(
      %{
        "phase" => "arguments",
        "code" => Atom.to_string(rejection.code),
        "message" => row.message
      },
      run_ref,
      rejection
    )
  end

  defp failure_line(error, run_ref, rejection) do
    base =
      "error: #{error["phase"]}/#{error["code"]}: " <>
        subject_prefix(error["subject"]) <>
        error["message"] <>
        location_suffix(error) <>
        "(run_ref: #{run_ref})"

    base <> diagnostic_suffix(error) <> rejection_suffix(rejection) <> "\n"
  end

  defp diagnostic_suffix(%{
         "phase" => "active_preflight",
         "code" => "credential_unavailable",
         "subject" => %{"operation" => "credentials"}
       }),
       do: "; export it, pass --env-file PATH, or use a host file credential"

  defp diagnostic_suffix(_error), do: ""

  defp location_suffix(%{
         "phase" => "application",
         "code" => "schema_violation",
         "source" => %{"kind" => "application"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> path <> " "

  defp location_suffix(%{
         "phase" => "bundle",
         "source" => %{"kind" => "component", "name" => name},
         "span" => %{"start_byte" => start_byte, "end_byte" => end_byte}
       })
       when is_binary(name) and is_integer(start_byte) and is_integer(end_byte),
       do: " at #{name} bytes [#{start_byte},#{end_byte}) "

  defp location_suffix(%{
         "phase" => "application",
         "code" => "input_contract_failed",
         "source" => %{"kind" => kind},
         "path" => path
       })
       when kind in ["application", "external_input", "input_contract"] and
              is_binary(path) and path != "",
       do: " at " <> terminal_contract_path(path) <> " "

  defp location_suffix(%{
         "phase" => "result_cleanup",
         "code" => "result_contract_failed",
         "source" => %{"kind" => "result_contract"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> terminal_contract_path(path) <> " "

  defp location_suffix(_error), do: " "

  defp terminal_contract_path(path) do
    case path =~ ~r/\A\/[A-Za-z0-9._~\/-]+\z/ do
      true -> path
      false -> inspect(path, binaries: :as_strings, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp subject_prefix(%{
         "kind" => "provider",
         "name" => name,
         "operation" => operation,
         "occurrence" => nil
       }),
       do: "provider/#{name}/#{operation}: "

  defp subject_prefix(%{
         "kind" => "provider",
         "name" => name,
         "operation" => operation,
         "occurrence" => %{"destination" => destination, "index" => index}
       }),
       do: "provider/#{name}/#{operation} at #{destination}[#{index}]: "

  defp subject_prefix(nil), do: ""

  defp rejection_suffix(%CommandRejection{kind: :unknown_switch, accepted: accepted}),
    do: "; unknown switch; accepted: " <> Enum.join(accepted, ", ")

  defp rejection_suffix(%CommandRejection{
         kind: :invalid_destination,
         destination: destination
       }),
       do: "; invalid destination: #{destination}"

  defp rejection_suffix(%CommandRejection{
         kind: :destination_collision,
         conflicts: [first, second]
       }),
       do: "; two destinations name the same file: #{first} and #{second}"

  defp rejection_suffix(%CommandRejection{kind: :private_output_recovery_collision}),
    do: "; --private-output must not name its reserved recovery file"

  defp rejection_suffix(%CommandRejection{kind: :init_destination_collision}),
    do: "; --envelope must be outside the init directory"

  defp rejection_suffix(_rejection), do: ""

  defp help_text(%{"usage" => usage, "options" => options, "notices" => notices}) do
    option_labels = Enum.map(options, &Enum.join(&1["switches"], ", "))
    option_width = option_labels |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

    lines =
      ["Usage:" | Enum.map(usage, &("  " <> &1))]
      |> append_options(options, option_labels, option_width)
      |> append_notices(notices)

    Enum.join(lines, "\n") <> "\n"
  end

  defp append_options(lines, [], _labels, _width), do: lines

  defp append_options(lines, options, labels, width) do
    rows =
      options
      |> Enum.zip(labels)
      |> Enum.map(fn {option, label} ->
        "  " <> String.pad_trailing(label, width) <> " — " <> option["description"]
      end)

    lines ++ ["", "Options:" | rows]
  end

  defp append_notices(lines, []), do: lines

  defp append_notices(lines, notices),
    do: lines ++ ["", "Notices:" | Enum.map(notices, &("  " <> &1))]

  defp json_line(value) do
    case DeterministicJSON.encode(value) do
      {:ok, encoded} -> encoded <> "\n"
      {:error, _reason} -> raise ArgumentError, "invalid sealed rendering value"
    end
  end

  defp outcome_run_ref(%CommandOutcome{envelope: %{"run_ref" => run_ref}}) do
    if CommandRunRef.valid?(run_ref),
      do: run_ref,
      else: "cmd-00000000000000000000000000"
  end

  defp outcome_run_ref(_outcome), do: "cmd-00000000000000000000000000"
end
