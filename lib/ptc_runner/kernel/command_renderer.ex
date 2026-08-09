defmodule PtcRunner.Kernel.CommandRenderer do
  @moduledoc """
  Deterministic, privacy-preserving human projection of sealed command outcomes.
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

      %{"status" => "ok", "result" => result} ->
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
      "error: #{error["phase"]}/#{error["code"]}: #{error["message"]} " <>
        "(run_ref: #{run_ref})"

    base <> rejection_suffix(rejection) <> "\n"
  end

  defp rejection_suffix(%CommandRejection{kind: :unknown_switch, accepted: accepted}),
    do: "; unknown switch; accepted: " <> Enum.join(accepted, ", ")

  defp rejection_suffix(%CommandRejection{
         kind: :retired_switch,
         retired: retired,
         replacement: replacement
       }),
       do: "; retired switch #{retired}; use #{replacement}"

  defp rejection_suffix(_rejection), do: ""

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
