defmodule PtcRunner.Examples.JevDecisionLab do
  @moduledoc false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @endpoint "https://openrouter.ai/api/alpha/decisions"
  @model "typesafe/jev-1.13"

  @input_schema %{
    "type" => "object",
    "properties" => %{
      "state" => %{"type" => "object", "additionalProperties" => true},
      "questions" => %{"type" => "object", "additionalProperties" => true}
    },
    "required" => ["state", "questions"],
    "additionalProperties" => false
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "model" => %{"type" => "string"},
      "answers" => %{"type" => "object", "additionalProperties" => true},
      "usage" => %{"type" => "object", "additionalProperties" => true}
    },
    "required" => ["model", "answers", "usage"],
    "additionalProperties" => false
  }

  @program ~S"""
  (return
    (decision/request
      {"state"
       {"ticket" "I was charged twice and need the duplicate refunded today."
        "customer_tier" "standard"}
       "questions"
       {"department"
        {"type" "choice"
         "instructions" "Which team should handle this ticket?"
         "criteria"
         {"billing" "Billing, charges, and refunds"
          "support" "Technical or product support"
          "sales" "Purchasing and upgrades"}}
        "severity"
        {"type" "score"
         "instructions" "How severe is the customer impact?"
         "criteria" ["low" "medium" "high" "critical"]}
        "urgent"
        {"type" "boolean"
         "instructions" "Does this require action today?"}}}))
  """

  def run(opts \\ []) when is_list(opts) do
    with {:ok, capability} <- capability(opts),
         {:ok, component} <- decision_component(),
         {:ok, bundle} <- Kernel.compile_bundle([component]),
         {:ok, workflow} <-
           WorkflowEnvironment.new(bundle: bundle, capabilities: [capability]),
         {:ok, mission} <- MissionEnvironment.new([]),
         {:ok, limits} <-
           Limits.new(run_duration_ms: 60_000, workflow_timeout_ms: 45_000),
         {:ok, sink} <- EventSink.start(:normal, limits, run_id: "jev-decision-lab"),
         {:ok, config} <-
           RunConfig.new(
             workflow_environment: workflow,
             missions: %{"default" => mission},
             input: %{},
             limits: limits,
             event_sink: sink
           ) do
      Kernel.run(@program, config)
    end
  end

  def capability(opts \\ []) when is_list(opts) do
    model = Keyword.get(opts, :model, @model)
    requester = Keyword.get(opts, :requester, &openrouter_request/1)

    Capability.new(
      name: "decision-request",
      description: "Evaluate named choice, score, or boolean questions against JSON state",
      effect: :read,
      input_schema: @input_schema,
      output_schema: @output_schema,
      validate: &validate_request/1,
      callback: fn request -> evaluate(request, model, requester) end
    )
  end

  defp decision_component do
    path = Path.expand("../decision.clj", __DIR__)

    Component.new(
      id: "decision",
      source: File.read!(path),
      origin: path
    )
  end

  defp validate_request(%{"questions" => questions}) when map_size(questions) > 0 do
    if Enum.all?(questions, &valid_question?/1),
      do: :ok,
      else: {:error, "questions must be named choice, score, or boolean definitions"}
  end

  defp validate_request(_request), do: {:error, "questions must not be empty"}

  defp valid_question?({name, %{"type" => type, "instructions" => instructions} = question})
       when is_binary(name) and type in ["choice", "score", "boolean"] and
              is_binary(instructions) do
    valid_criteria?(type, Map.get(question, "criteria"))
  end

  defp valid_question?(_question), do: false

  defp valid_criteria?("boolean", nil), do: true

  defp valid_criteria?("choice", criteria) when is_map(criteria),
    do:
      map_size(criteria) > 0 and
        Enum.all?(criteria, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: criteria != [] and Enum.all?(criteria, &is_binary/1)

  defp valid_criteria?(_type, _criteria), do: false

  defp evaluate(%{"state" => state, "questions" => questions}, model, requester) do
    body = %{
      "model" => model,
      "state" => state,
      "questions" => encode_questions(questions)
    }

    case requester.(body) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decode_response(response)

      {:ok, %{status: status}} ->
        {:error,
         ProviderError.new(http_error_kind(status), "OpenRouter Decisions request failed",
           retryable?: status in [408, 429, 500, 502, 503, 504, 529],
           dispatch_provenance: :dispatched
         )}

      {:error, :missing_openrouter_api_key} ->
        {:error,
         ProviderError.new(:authentication_failed, "OPENROUTER_API_KEY is not configured",
           dispatch_provenance: :not_dispatched
         )}

      {:error, _reason} ->
        {:error,
         ProviderError.new(:transport_error, "OpenRouter Decisions transport failed",
           retryable?: true,
           dispatch_provenance: :possibly_dispatched
         )}
    end
  end

  defp encode_questions(questions) do
    Map.new(questions, fn
      {name, %{"type" => "boolean"} = question} ->
        {name, question |> Map.delete("type") |> Map.put("type", "noul")}

      question ->
        question
    end)
  end

  defp decode_response(%{
         "model" => model,
         "answers" => answers,
         "usage" => usage
       })
       when is_binary(model) and is_map(answers) and is_map(usage) do
    {:ok,
     %{
       "model" => model,
       "answers" => normalize_answers(answers),
       "usage" => usage
     }}
  end

  defp decode_response(_response) do
    {:error,
     ProviderError.new(:invalid_result, "OpenRouter Decisions returned an invalid response",
       dispatch_provenance: :dispatched
     )}
  end

  defp normalize_answers(answers) do
    Map.new(answers, fn
      {name, %{"type" => "noul", "noul" => probability} = answer} ->
        normalized =
          answer
          |> Map.delete("noul")
          |> Map.put("type", "boolean")
          |> Map.put("probability", probability)

        {name, normalized}

      answer ->
        answer
    end)
  end

  defp openrouter_request(body) do
    case System.fetch_env("OPENROUTER_API_KEY") do
      {:ok, api_key} ->
        Req.post(@endpoint,
          json: body,
          auth: {:bearer, api_key},
          retry: false,
          receive_timeout: 30_000
        )

      :error ->
        {:error, :missing_openrouter_api_key}
    end
  end

  defp http_error_kind(401), do: :authentication_failed
  defp http_error_kind(402), do: :payment_required
  defp http_error_kind(429), do: :rate_limited
  defp http_error_kind(status) when status in 400..499, do: :invalid_request
  defp http_error_kind(_status), do: :unavailable
end
