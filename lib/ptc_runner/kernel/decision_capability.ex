defmodule PtcRunner.Kernel.DecisionCapability do
  @moduledoc """
  Constructs the vendor-neutral `decision-request` model capability.

  A request contains a JSON object `state` and a non-empty `questions` object
  keyed by question ID. Each question has string `instructions` and `type`
  (`boolean`, `choice`, or `score`). Boolean criteria are optional, otherwise
  exactly `true` and `false` descriptions. Choice criteria map one to 255
  option names to string descriptions. Score criteria are two to ten ordered
  string descriptions, indexed from zero. Other question keys are refused.

  Success contains the backend `model`, `answers` keyed by the same IDs, and
  reported `usage`. Boolean answers have `probability` and optional `value`
  (`true`, `false`, or null). False is a discrete answer; missing or null
  means none was supplied. Providers never infer `value` by thresholding a
  probability. Choice answers have
  `choice` and `probabilities`; score answers have weighted `score`, `legend`,
  and per-level `probabilities`. Each carries `confidence`. Probabilities,
  distributions, and confidence may be null when a backend cannot measure
  them. Measured distributions and weighted scores allow 0.01 rounding error.
  The provider applies no thresholds; workflows choose their own policy.
  Chat backends supply discrete answers with null measurements. Workflows
  may use those answers or require measurements and abstain or escalate when
  unavailable. Unavailable probability is not low confidence; switching
  backends does not promise identical answers or measurements. Jev records
  its served model; chat uses the adapter-attested public selector, or
  `private` when the selector is hidden.

  Model calls use the shared chat spend, token, admission, deadline, replay,
  and inspection machinery. Host installations declare non-negative per-call cost
  and positive token bounds; they never estimate decision reservations from tokens.
  Invalid responses and bound overruns are permanent `invalid_result` failures.
  """
  alias PtcRunner.Kernel.LLMUsage

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DecisionContract
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Lisp.RetainedSize

  @doc "Builds the decision capability with a two-argument requester and optional byte and usage bounds."
  @spec new(keyword()) :: {:ok, Capability.t()} | {:error, :invalid_capability}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Keyword.keys(opts) --
             [
               :requester,
               :max_request_bytes,
               :max_response_bytes,
               :usage_guarantees,
               :llm_reservation,
               :provider_call_guardian
             ] == [],
         requester when is_function(requester, 2) <- Keyword.get(opts, :requester),
         request_limit when is_integer(request_limit) and request_limit > 0 <-
           Keyword.get(opts, :max_request_bytes, 1_000_000),
         response_limit when is_integer(response_limit) and response_limit > 0 <-
           Keyword.get(opts, :max_response_bytes, 1_000_000),
         %{tokens: tokens, cost_currency: currency} = guarantees <-
           Keyword.get(opts, :usage_guarantees, %{tokens: false, cost_currency: nil}),
         true <- map_size(guarantees) == 2 and is_boolean(tokens) and currency in ["USD", nil] do
      build(opts, requester, request_limit, response_limit, guarantees)
    else
      _ -> {:error, :invalid_capability}
    end
  end

  def new(_opts), do: {:error, :invalid_capability}

  defp build(opts, requester, max_request, max_response, guarantees) do
    Capability.new(
      name: "decision-request",
      description:
        "Evaluate named boolean, choice, or score questions; workflows choose measurement or discrete-answer policy",
      effect: :read,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{"type" => "object", "additionalProperties" => true},
          "questions" => %{"type" => "object", "additionalProperties" => true}
        },
        "required" => ["state", "questions"],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "model" => %{"type" => "string"},
          "answers" => %{
            "type" => "object",
            "additionalProperties" => DecisionContract.answer_schema()
          },
          "usage" => %{"type" => "object", "additionalProperties" => true}
        },
        "required" => ["model", "answers", "usage"],
        "additionalProperties" => false
      },
      llm_reservation: Keyword.get(opts, :llm_reservation),
      provider_call_guardian: Keyword.get(opts, :provider_call_guardian, false),
      validate: fn request ->
        with true <- JSONValue.map?(request),
             bytes when is_integer(bytes) and bytes <= max_request <-
               RetainedSize.bytes_with_cap(request, max_request) do
          DecisionContract.validate_request(request)
        else
          _ -> {:error, "invalid or oversized decision request"}
        end
      end,
      callback: fn request, context ->
        case requester.(request, context) do
          {:ok, response} when is_map(response) ->
            bytes = RetainedSize.bytes_with_cap(response, max_response)

            if JSONValue.map?(response) and is_integer(bytes) and bytes <= max_response and
                 DecisionContract.valid_response?(response, request["questions"]) and
                 valid_usage?(response, guarantees) do
              {:ok, RetainedSize.detach_binaries(response)}
            else
              # Keep validated accounting for settlement; the missing answers
              # fail the declared output schema before anything crosses into Lisp.
              {:ok, Map.take(response, ["model", "usage"])}
            end

          {:ok, _invalid} ->
            {:ok, %{}}

          {:error, %ProviderError{}} = error ->
            error

          _ ->
            {:error,
             ProviderError.new(:unavailable, "Decision provider unavailable", retryable?: true)}
        end
      end
    )
  end

  defp valid_usage?(response, guarantees) do
    usage = LLMUsage.decision_usage(response["usage"])
    match?({:ok, _}, LLMUsage.normalize(usage, guarantees))
  end
end
