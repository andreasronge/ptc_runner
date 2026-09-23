defmodule PtcRunner.Examples.JevDecisionLab do
  @moduledoc false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @endpoint "https://openrouter.ai/api/alpha/decisions"
  @model "typesafe/jev-1.13"
  @rounding_tolerance 0.01
  @float_epsilon 1.0e-12

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

  @refund_triage_program ~S"""
  (let [decision
        (decision/request
          {"state"
           {"tickets"
            [{"id" "T-1001"
              "subject" "Refund for duplicate charge"
              "body" "Charged twice for the March invoice, please refund one."}
             {"id" "T-1002"
              "subject" "Dashboard is down"
              "body" "Our whole team gets a 502 on the dashboard since this morning."}
             {"id" "T-1003"
              "subject" "How do I export CSV?"
              "body" "Looking for the export button described in the docs."}
             {"id" "T-1004"
              "subject" "Refund policy question"
              "body" "Considering a downgrade; does the refund cover unused months?"}
             {"id" "T-1005"
              "subject" "API returns 500 on upload"
              "body" "Uploads over 10 MB fail with a 500 since yesterday."}
             {"id" "T-1006"
              "subject" "Password reset loop"
              "body" "Reset email link keeps sending me back to the login page."}]}
           "questions"
           {"T_1001" {"type" "boolean" "instructions" "Does ticket T-1001 ask about a refund?"}
            "T_1002" {"type" "boolean" "instructions" "Does ticket T-1002 ask about a refund?"}
            "T_1003" {"type" "boolean" "instructions" "Does ticket T-1003 ask about a refund?"}
            "T_1004" {"type" "boolean" "instructions" "Does ticket T-1004 ask about a refund?"}
            "T_1005" {"type" "boolean" "instructions" "Does ticket T-1005 ask about a refund?"}
            "T_1006" {"type" "boolean" "instructions" "Does ticket T-1006 ask about a refund?"}}})]
    (if (and (contains? decision :status)
             (= :error (get decision :status)))
      (return decision)
      (let [answers (get decision "answers")
            tickets [{"answer_id" "T_1001" "ticket_id" "T-1001"}
                     {"answer_id" "T_1002" "ticket_id" "T-1002"}
                     {"answer_id" "T_1003" "ticket_id" "T-1003"}
                     {"answer_id" "T_1004" "ticket_id" "T-1004"}
                     {"answer_id" "T_1005" "ticket_id" "T-1005"}
                     {"answer_id" "T_1006" "ticket_id" "T-1006"}]
            refund-ids
            (->> tickets
                 (filter (fn [ticket]
                           (>= (get-in answers [(get ticket "answer_id") "probability"]) 0.5)))
                 (map (fn [ticket] (get ticket "ticket_id")))
                 vec)]
        (return
          {"refund_ticket_ids" refund-ids
           "decisions" answers
           "model" (get decision "model")
           "usage" (get decision "usage")}))))
  """

  def run(opts \\ []) when is_list(opts) do
    run_program(@program, opts, "jev-decision-lab")
  end

  def run_refund_triage(opts \\ []) when is_list(opts) do
    run_program(@refund_triage_program, opts, "jev-refund-triage-lab")
  end

  def run_request(request, opts \\ []) when is_map(request) and is_list(opts) do
    encoded_request =
      request |> Jason.encode!() |> inspect(limit: :infinity, printable_limit: :infinity)

    run_program(
      "(return (decision/request (json/parse-string #{encoded_request})))",
      opts,
      "jev-request-lab"
    )
  end

  defp run_program(program, opts, run_id) do
    with {:ok, capability} <- capability(opts),
         {:ok, component} <- decision_component(),
         {:ok, bundle} <- Kernel.compile_bundle([component]),
         {:ok, workflow} <-
           WorkflowEnvironment.new(bundle: bundle, capabilities: [capability]),
         {:ok, mission} <- MissionEnvironment.new([]),
         {:ok, limits} <-
           Limits.new(run_duration_ms: 60_000, workflow_timeout_ms: 45_000),
         {:ok, sink} <- EventSink.start(:normal, limits, run_id: run_id),
         {:ok, config} <-
           RunConfig.new(
             workflow_environment: workflow,
             missions: %{"default" => mission},
             input: %{},
             limits: limits,
             event_sink: sink
           ) do
      Kernel.run(program, config)
    end
  end

  def capability(opts \\ []) when is_list(opts) do
    model = Keyword.get(opts, :model, @model)
    requester = Keyword.get(opts, :requester, &openrouter_request/1)

    record_directory =
      Keyword.get(
        opts,
        :record_directory,
        Path.expand("../../../../tmp/jev-decision-attempts", __DIR__)
      )

    recorder = Keyword.get(opts, :recorder, &record_attempt(&1, record_directory))

    Capability.new(
      name: "decision-request",
      description: "Evaluate named choice, score, or boolean questions against JSON state",
      effect: :read,
      input_schema: @input_schema,
      output_schema: @output_schema,
      validate: &validate_request/1,
      callback: fn request -> evaluate(request, model, requester, recorder) end
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

  defp validate_request(%{"state" => state, "questions" => questions})
       when is_map(questions) and map_size(questions) > 0 and is_map(state) do
    if Enum.all?(questions, &valid_question?/1),
      do: :ok,
      else: {:error, "questions must be named choice, score, or boolean definitions"}
  end

  defp validate_request(_request), do: {:error, "questions must not be empty"}

  defp valid_question?({name, %{"type" => type, "instructions" => instructions} = question})
       when is_binary(name) and type in ["choice", "score", "boolean"] and
              is_binary(instructions) do
    byte_size(name) > 0 and byte_size(instructions) > 0 and
      Map.keys(question) -- ["type", "instructions", "criteria"] == [] and
      valid_criteria?(type, Map.get(question, "criteria"))
  end

  defp valid_question?(_question), do: false

  defp valid_criteria?("boolean", nil), do: true

  defp valid_criteria?("boolean", %{"true" => yes, "false" => no} = criteria),
    do: map_size(criteria) == 2 and is_binary(yes) and is_binary(no)

  defp valid_criteria?("choice", criteria) when is_map(criteria),
    do:
      map_size(criteria) in 1..255 and
        Enum.all?(criteria, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: length(criteria) in 2..10 and Enum.all?(criteria, &is_binary/1)

  defp valid_criteria?(_type, _criteria), do: false

  defp evaluate(%{"state" => state, "questions" => questions}, model, requester, recorder) do
    body = %{
      "model" => model,
      "state" => state,
      "questions" => encode_questions(questions)
    }

    case requester.(body) do
      {:ok, %{status: status, body: response} = received} when status in 200..299 ->
        result = decode_response(response, questions)

        recorder.(%{
          request: body,
          response: response,
          model: if(is_map(response), do: Map.get(response, "model"), else: nil),
          usage: validated_usage(response),
          cost: validated_cost(response),
          outcome: if(match?({:ok, _}, result), do: :accepted, else: :invalid_result),
          status: status,
          headers: allowed_headers(Map.get(received, :headers, %{}))
        })

        result

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

  defp decode_response(%{"model" => model, "answers" => answers, "usage" => usage}, questions)
       when is_binary(model) and byte_size(model) > 0 and is_map(answers) do
    if valid_usage?(usage) and MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(questions)) and
         Enum.all?(questions, fn {id, question} -> valid_answer?(answers[id], question) end) do
      {:ok, %{"model" => model, "answers" => normalize_answers(answers), "usage" => usage}}
    else
      invalid_response()
    end
  end

  defp decode_response(_response, _questions), do: invalid_response()

  defp invalid_response do
    {:error,
     ProviderError.new(:invalid_result, "OpenRouter Decisions returned an invalid response",
       dispatch_provenance: :dispatched
     )}
  end

  defp valid_answer?(%{"type" => "noul", "noul" => probability}, %{"type" => "boolean"}),
    do: probability?(probability)

  defp valid_answer?(
         %{
           "type" => "choice",
           "choice" => choice,
           "probabilities" => probabilities,
           "confidence" => confidence
         },
         %{"type" => "choice", "criteria" => criteria}
       ) do
    valid_distribution?(probabilities, Map.keys(criteria)) and probability?(confidence) and
      Map.has_key?(probabilities, choice) and
      within_rounding_tolerance?(Enum.max(Map.values(probabilities)) - probabilities[choice])
  end

  defp valid_answer?(
         %{
           "type" => "score",
           "score" => score,
           "legend" => legend,
           "probabilities" => probabilities,
           "confidence" => confidence
         },
         %{"type" => "score", "criteria" => criteria}
       ) do
    levels = Enum.map(0..(length(criteria) - 1), &Integer.to_string/1)
    expected_legend = levels |> Enum.zip(criteria) |> Map.new()

    valid_distribution?(probabilities, levels) and legend == expected_legend and
      probability?(confidence) and finite_number?(score) and score >= 0 and
      score <= length(criteria) - 1 and
      within_rounding_tolerance?(
        score -
          Enum.reduce(0..(length(criteria) - 1), 0.0, fn level, sum ->
            sum + level * probabilities[Integer.to_string(level)]
          end)
      )
  end

  defp valid_answer?(_, _), do: false

  defp valid_distribution?(values, keys) when is_map(values) do
    MapSet.new(Map.keys(values)) == MapSet.new(keys) and
      Enum.all?(Map.values(values), &probability?/1) and
      within_rounding_tolerance?(Enum.sum(Map.values(values)) - 1.0)
  end

  defp valid_distribution?(_, _), do: false

  defp probability?(value), do: finite_number?(value) and value >= 0 and value <= 1

  defp within_rounding_tolerance?(difference),
    do: abs(difference) <= @rounding_tolerance + @float_epsilon

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value == value and abs(value) < 1.0e308
  defp finite_number?(_), do: false

  defp valid_usage?(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    valid_token_usage?(input, output) and
      (not Map.has_key?(usage, "cost") or
         (finite_number?(usage["cost"]) and usage["cost"] >= 0))
  end

  defp valid_usage?(_), do: false

  defp validated_usage(%{
         "usage" => %{"input_tokens" => input, "output_tokens" => output} = usage
       }) do
    if valid_token_usage?(input, output) do
      if valid_usage?(usage), do: usage, else: Map.take(usage, ~w(input_tokens output_tokens))
    else
      :unknown
    end
  end

  defp validated_usage(_), do: :unknown

  defp valid_token_usage?(input, output),
    do: is_integer(input) and input >= 0 and is_integer(output) and output >= 0

  defp validated_cost(%{"usage" => %{"cost" => cost}}),
    do: if(finite_number?(cost) and cost >= 0, do: cost, else: :unknown)

  defp validated_cost(_), do: :unknown

  defp allowed_headers(headers) when is_map(headers) do
    allowed = ~w(x-generation-id x-request-id retry-after)

    headers
    |> Enum.filter(fn {key, _} -> is_binary(key) and String.downcase(key) in allowed end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = if is_list(value), do: List.first(value), else: value

      if is_binary(value) and byte_size(value) <= 128,
        do: Map.put(acc, String.downcase(key), value),
        else: acc
    end)
  end

  defp allowed_headers(_), do: %{}

  defp record_attempt(record, dir) do
    :ok = ensure_private_record_directory(dir)

    path =
      Path.join(
        dir,
        "attempt-#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}.term"
      )

    File.open!(path, [:write, :exclusive], fn io ->
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, :erlang.term_to_binary(record))
    end)
  end

  defp ensure_private_record_directory(dir) do
    with :ok <- ensure_private_record_parent(Path.dirname(dir)) do
      case File.lstat(dir, time: :posix) do
        {:error, :enoent} ->
          case PrivateDirectory.create(dir) do
            :ok -> validate_private_record_directory(dir)
            {:error, _race_or_failure} -> validate_private_record_directory(dir)
          end

        {:ok, _existing} ->
          validate_private_record_directory(dir)

        {:error, _reason} ->
          {:error, :private_record_directory_unavailable}
      end
    end
  end

  defp ensure_private_record_parent(parent) do
    case File.lstat(parent, time: :posix) do
      {:error, :enoent} ->
        case PrivateDirectory.create(parent) do
          :ok -> validate_private_record_parent(parent)
          {:error, _race_or_failure} -> validate_private_record_parent(parent)
        end

      {:ok, _existing} ->
        validate_private_record_parent(parent)

      {:error, _reason} ->
        {:error, :private_record_directory_unavailable}
    end
  end

  defp validate_private_record_parent(parent) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(parent, "record-directory")),
         {:ok, %File.Stat{type: :directory, uid: ^uid}} <- File.lstat(parent, time: :posix) do
      :ok
    else
      _unsafe_or_unavailable -> {:error, :private_record_directory_unavailable}
    end
  end

  defp validate_private_record_directory(dir) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(dir, "record.term")),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <-
           File.lstat(dir, time: :posix),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      :ok
    else
      _unsafe_or_unavailable -> {:error, :private_record_directory_unavailable}
    end
  end

  defp normalize_answers(answers) do
    Map.new(answers, fn
      {name, %{"type" => "noul", "noul" => probability} = answer} ->
        {name,
         answer
         |> Map.delete("noul")
         |> Map.put("type", "boolean")
         |> Map.put("probability", probability)}

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
