defmodule PtcRunner.Kernel.CommandRenderer do
  @moduledoc """
  Deterministic, privacy-preserving human projection of sealed command outcomes.

  Provider failures include the validated provider subject already present in
  the public command envelope. Project, host, manifest, component-override,
  and value-contract failures with a non-root, schema-authorized path include
  its JSON Pointer. A contract schema rejected before it compiles also names the
  document its pointer indexes, because a manifest may carry two and the
  pointer means nothing without it. Unusual contract-authored pointers and
  logical names use an escaped quoted representation before they enter a
  terminal. Rendering never derives labels from a rejected value, provider
  response, credential, or unvalidated path. Component compile failures with a
  proven byte span render the logical component name and canonical half-open
  byte range already present in the envelope; rendering does not retain or
  reopen component source. A replay miss may include only its validated opaque
  request hash.
  """

  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDiagnosticRenderer
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.ModelContractDiagnostic

  @spec render(CommandOutcome.t(), CommandRejection.t() | nil) ::
          {:stdout | :stderr, binary()} | {:stdio, binary(), binary()}
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

      %{
        "status" => "ok",
        "command" => "version",
        "result" => %{
          "version" => version,
          "source_revision" => revision,
          "source_dirty" => dirty
        }
      } ->
        state = if dirty, do: "dirty", else: "clean"
        {:stdout, "#{version} (#{String.slice(revision, 0, 8)}, #{state})\n"}

      %{"status" => "ok", "command" => "docs", "result" => %{"content" => content}} ->
        {:stdout, content}

      %{"status" => "ok", "command" => "docs", "result" => %{"pages" => pages}} ->
        {:stdout, docs_listing_text(pages)}

      %{"status" => "ok", "command" => "init", "result" => %{"created" => created}} ->
        {:stdout, "created " <> Enum.join(created, ", ") <> "\n"}

      %{"status" => "ok", "result" => result} ->
        {:stdout, json_line(result)}

      %{
        "status" => "error",
        "command" => "doctor",
        "result" => %{"readiness" => "failed"} = result
      } = envelope ->
        case model_contract_warning(envelope) do
          "" -> {:stdout, json_line(result)}
          warning -> {:stdio, json_line(result), warning}
        end

      %{"status" => "error", "run_ref" => run_ref} = envelope ->
        {:stderr,
         model_contract_warning(envelope) <>
           failure_line(outcome, run_ref, rejection) <> evaluation_line(envelope)}
    end
  rescue
    _exception ->
      {:stderr,
       "error: internal/internal_error: internal command failure " <>
         "(run_ref: #{outcome_run_ref(outcome)})\n"}
  end

  defp model_contract_warning(%{
         "error" => %{
           "phase" => "local_preflight",
           "code" => "model_contract_unsupported",
           "message" => message
         }
       }) do
    ModelContractDiagnostic.warning_line(message)
  end

  defp model_contract_warning(_envelope), do: ""

  @spec envelope_failure(binary()) :: binary()
  def envelope_failure(run_ref) when is_binary(run_ref),
    do: envelope_failure(run_ref, :envelope_publication_failed)

  @spec envelope_failure(binary(), term()) :: binary()
  def envelope_failure(run_ref, {:project_artifact_root_not_owner_only, path})
      when is_binary(run_ref) and is_binary(path) do
    "error: envelope/publication_failed: #{path} is group/other-accessible; " <>
      "artifact directories must be owner-only (0700); chmod 700 #{path} " <>
      "(run_ref: #{run_ref})\n"
  end

  def envelope_failure(run_ref, {:project_artifact_root_incomplete, root})
      when is_binary(run_ref) and is_binary(root) do
    "error: envelope/publication_failed: #{root} is incomplete; remove it and let " <>
      "ptc recreate the owner-only artifact layout (run_ref: #{run_ref})\n"
  end

  def envelope_failure(run_ref, {:envelope_destination_parent_unavailable, path})
      when is_binary(run_ref) and is_binary(path) do
    parent = Path.dirname(path)

    "error: envelope/destination_parent_unavailable: the parent directory for " <>
      "--envelope must be an existing directory (#{parent}) (run_ref: #{run_ref})\n"
  end

  def envelope_failure(run_ref, _reason) when is_binary(run_ref),
    do:
      "error: envelope/publication_failed: command envelope could not be published " <>
        "(run_ref: #{run_ref})\n"

  @spec rejection(binary(), CommandRejection.t()) :: binary()
  def rejection(run_ref, %CommandRejection{} = rejection) do
    row = DiagnosticCatalog.fetch!(:arguments, rejection.code)
    diagnostic = CommandDiagnostic.new!(:arguments, rejection.code, message: row.message)
    failure_line(diagnostic, run_ref, rejection)
  end

  defp failure_line(diagnostic, run_ref, rejection) do
    {:ok, rendered} = CommandDiagnosticRenderer.render_with_run_ref(diagnostic, run_ref)
    "error: " <> rendered <> rejection_suffix(rejection) <> "\n"
  end

  defp evaluation_line(%{
         "execution" => %{
           "last_evaluation_error" => %{"kind" => kind, "message" => message}
         }
       })
       when is_binary(kind) and is_binary(message) and kind != "" and message != "",
       do: "evaluation: #{kind}: #{message}\n"

  defp evaluation_line(_envelope), do: ""

  defp rejection_suffix(%CommandRejection{kind: :unknown_switch, accepted: accepted}),
    do: "; unknown switch; accepted: " <> Enum.join(accepted, ", ")

  defp rejection_suffix(%CommandRejection{kind: :unknown_page, accepted: accepted}),
    do: "; pages: " <> Enum.join(accepted, ", ")

  defp rejection_suffix(%CommandRejection{kind: :unknown_example, accepted: accepted}),
    do: "; examples: " <> Enum.join(accepted, ", ")

  defp rejection_suffix(%CommandRejection{kind: :missing_switch_value, option: option}),
    do: "; #{option} requires a value"

  defp rejection_suffix(%CommandRejection{kind: :positional_arity, command: command}),
    do: "; usage: " <> Enum.join(CommandDeclaration.usage(command), " | ")

  defp rejection_suffix(%CommandRejection{
         kind: :invalid_destination,
         destination: destination
       }),
       do: "; invalid destination: #{destination}"

  defp rejection_suffix(%CommandRejection{
         kind: :destination_exists,
         destination: destination
       }),
       do: "; remove it or point #{destination} at another path"

  defp rejection_suffix(%CommandRejection{
         kind: :destination_collision,
         conflicts: [first, second]
       }),
       do: "; two destinations name the same file: #{first} and #{second}"

  defp rejection_suffix(%CommandRejection{kind: :private_output_recovery_collision}),
    do: "; --private-output must not name its reserved recovery file"

  defp rejection_suffix(%CommandRejection{kind: :init_destination_collision}),
    do: "; --envelope must be outside the init directory"

  defp rejection_suffix(%CommandRejection{
         command: :transcript,
         code: :invalid_arguments,
         kind: :generic
       }),
       do:
         "; required: RUN_ID, --traces, --inspection, --private-unattended, and --private-output"

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

  defp docs_listing_text(pages) do
    width = pages |> Enum.map(&String.length(&1["name"])) |> Enum.max(fn -> 0 end)

    rows =
      Enum.map(pages, fn page ->
        "  " <> String.pad_trailing(page["name"], width) <> " — " <> page["title"]
      end)

    Enum.join(["Usage:", "  ptc docs PAGE", "", "Pages:" | rows], "\n") <> "\n"
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
