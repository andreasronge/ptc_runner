defmodule PtcRunner.Kernel.RuntimeLimitDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog

  # Naming a breached ceiling is only half an answer: the reader also has to know
  # where the number lives. The manifest is where a value is requested and the
  # host document is where the ceiling that bounds it is installed, so with the
  # shipped ceilings a host-only edit leaves the run at the compiled default —
  # the mistake this remedy exists to prevent. The ceiling is named second
  # because it is the binding one only when it sits below the value the
  # application needs.
  @manifest_remedy " in the manifest, and the installed host ceiling if it is lower"

  @subordinate_prefix "subordinate_evaluations limit "
  @subordinate_suffix " was exceeded; raise limits.subordinate_evaluations" <>
                        @manifest_remedy <>
                        ", or reduce total subordinate evaluations or agent turns"
  @subordinate_limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @subordinate_maximum_digits 10
  @subordinate_maximum_message_bytes byte_size(@subordinate_prefix) +
                                       @subordinate_maximum_digits +
                                       byte_size(@subordinate_suffix)

  @heap_prefix "workflow_heap_words limit "
  @heap_suffix " words was exceeded; raise limits.workflow_heap_words" <>
                 @manifest_remedy <> ", or hold less data in memory at once"
  @heap_maximum_message_bytes byte_size(@heap_prefix) + 10 + byte_size(@heap_suffix)

  @alias ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @alias_schema_pattern "[a-z][a-z0-9._-]{0,127}"
  @max_calls_prefix "max_calls limit "
  @max_calls_middle " for alias "
  @max_calls_suffix " was exceeded; raise config.max_calls for this model alias" <>
                      @manifest_remedy
  @max_calls_maximum_alias_bytes 128
  @max_calls_maximum_message_bytes byte_size(@max_calls_prefix) +
                                     @subordinate_maximum_digits +
                                     byte_size(@max_calls_middle) +
                                     @max_calls_maximum_alias_bytes +
                                     byte_size(@max_calls_suffix)

  @result_limit_prefix "terminal_result_bytes limit "
  @result_limit_suffix " bytes was exceeded; raise limits.terminal_result_bytes" <>
                         @manifest_remedy <> ", or return a smaller result"
  @result_limit_maximum_message_bytes byte_size(@result_limit_prefix) +
                                        @subordinate_maximum_digits +
                                        byte_size(@result_limit_suffix)

  # A bounded agent loop can end four ways, and only two of them are answered by
  # buying more turns. Naming `max_turns` for a model that never emitted a
  # usable tool call sells the reader another round of the same failure, so each
  # reason states what stopped the loop and what to change. The remedy names the
  # configuration key rather than `agent.core/run`, because a manifest that
  # declares `agent.main/run` never mentions the inner entry.
  @agent_reasons [
    {:turn_limit_exceeded, "agent turn limit ",
     " was exceeded; raise max_turns in the agent configuration, or reduce the work per turn"},
    {:intermediate_result, "agent turn limit ",
     " was exceeded while the model was still working; raise max_turns in the agent configuration, or reduce the work per turn"},
    {:evaluation_error, "agent turn limit ",
     " was exceeded after the final program failed; raise max_turns in the agent configuration, or simplify the work per turn"},
    {:protocol_error, "the model produced no valid tool call in ",
     " turns; raising max_turns repeats it. Check that the model supports tool calling and that any configured max_tokens leaves room for a complete call"},
    {:terminal_source_required, "a terminal-only phase rejected every program within ",
     " turns; the model must send a single top-level (return value) or (fail value) form, so raising max_turns only helps if the model can produce one"}
  ]
  @agent_reason_names [
    {"turn-limit-exceeded", :turn_limit_exceeded},
    {"intermediate-result", :intermediate_result},
    {"evaluation-error", :evaluation_error},
    {"protocol-error", :protocol_error},
    {"terminal-source-required", :terminal_source_required}
  ]
  @agent_limit_pattern "(?:[1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])"
  @agent_maximum_digits 3
  @agent_reason_atoms Enum.map(@agent_reasons, fn {reason, _prefix, _suffix} -> reason end)

  # The wire names and the messages are two lists that must describe the same
  # closed set. If they drift, a reason the loop can send has no message and the
  # command silently degrades to the unclassified workflow failure — so this is
  # a compile error rather than a runtime surprise.
  if Enum.sort(@agent_reason_atoms) !=
       Enum.sort(Enum.map(@agent_reason_names, fn {_name, reason} -> reason end)) do
    raise "agent turn-limit reason names and messages describe different sets"
  end

  @transcript_prefix "transcript limit "
  @transcript_suffix " characters was exceeded; raise max_transcript_chars for this agent.core/run call, or reduce the work carried between turns"
  @transcript_limit_pattern "(?:[1-9][0-9]{0,5}|1000000)"
  @transcript_maximum_digits 7
  @transcript_maximum_message_bytes byte_size(@transcript_prefix) +
                                      @transcript_maximum_digits +
                                      byte_size(@transcript_suffix)

  # `evaluation_timeout_ms` joins the family because the REPL evaluates every
  # form under it.
  @timeout_limits [:evaluation_timeout_ms, :parallel_timeout_ms, :workflow_timeout_ms]
  @timeout_phases [:compilation, :execution]
  @timeout_value_pattern @subordinate_limit_pattern
  @timeout_family [:run_duration_ms | @timeout_limits]
  @timeout_maximum_message_bytes (for limit <- @timeout_family, phase <- @timeout_phases do
                                    name = Atom.to_string(limit)

                                    byte_size(name <> " limit ") +
                                      @subordinate_maximum_digits +
                                      byte_size(
                                        " ms was exceeded during " <>
                                          Atom.to_string(phase) <>
                                          "; raise limits." <> name <> @manifest_remedy
                                      )
                                  end)
                                 |> Enum.max()

  @doc false
  @spec subordinate_evaluations_message(term()) :: {:ok, binary()} | :error
  def subordinate_evaluations_message(limit) do
    with {:ok, row} <- LimitCatalog.fetch(:subordinate_evaluations),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok, @subordinate_prefix <> Integer.to_string(limit) <> @subordinate_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec agent_turns_reasons() :: [atom()]
  def agent_turns_reasons, do: @agent_reason_atoms

  @doc false
  @spec agent_turns_reason?(term()) :: boolean()
  def agent_turns_reason?(reason), do: reason in @agent_reason_atoms

  @doc false
  @spec agent_turns_reason(term()) :: {:ok, atom()} | :error
  for {name, reason} <- @agent_reason_names do
    def agent_turns_reason(unquote(name)), do: {:ok, unquote(reason)}
  end

  def agent_turns_reason(_name), do: :error

  @doc false
  @spec agent_turns_message(term(), term()) :: {:ok, binary()} | :error
  for {reason, prefix, suffix} <- @agent_reasons do
    def agent_turns_message(limit, unquote(reason)) when is_integer(limit) and limit in 1..128,
      do: {:ok, unquote(prefix) <> Integer.to_string(limit) <> unquote(suffix)}
  end

  def agent_turns_message(_limit, _reason), do: :error

  @doc false
  @spec transcript_chars_message(term()) :: {:ok, binary()} | :error
  def transcript_chars_message(limit) when is_integer(limit) and limit in 1..1_000_000,
    do: {:ok, @transcript_prefix <> Integer.to_string(limit) <> @transcript_suffix}

  def transcript_chars_message(_limit), do: :error

  @doc false
  @spec timeout_message(term(), term(), term()) :: {:ok, binary()} | :error
  def timeout_message(limit, limit_ms, phase)
      when limit in @timeout_limits and phase in @timeout_phases do
    build_timeout_message(limit, limit_ms, phase)
  end

  def timeout_message(_limit, _limit_ms, _phase), do: :error

  @doc false
  @spec live_timeout_message(term(), term(), term()) :: {:ok, binary()} | :error
  def live_timeout_message(limit, limit_ms, phase)
      when limit in @timeout_family and phase in @timeout_phases do
    build_timeout_message(limit, limit_ms, phase)
  end

  def live_timeout_message(_limit, _limit_ms, _phase), do: :error

  # A heap kill is Kernel-observed runtime evidence, like a timeout. Raising the
  # ceiling still takes both documents: these remain `:manifest_narrowable` rows,
  # so a host-only edit leaves the run at the compiled default.
  @doc false
  @spec heap_words_message(term()) :: {:ok, binary()} | :error
  def heap_words_message(limit) do
    with {:ok, row} <- LimitCatalog.fetch(:workflow_heap_words),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok, @heap_prefix <> Integer.to_string(limit) <> @heap_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec heap_words_message?(term()) :: boolean()
  def heap_words_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @heap_prefix,
      @heap_suffix,
      @subordinate_maximum_digits,
      &heap_words_message/1
    )
  end

  def heap_words_message?(_message), do: false

  @doc false
  @spec max_calls_message(term(), term()) :: {:ok, binary()} | :error
  def max_calls_message(alias_name, limit) do
    with true <- is_binary(alias_name) and alias_name =~ @alias,
         {:ok, row} <- LimitCatalog.fetch(:workflow_capability_calls_per_name),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok,
       @max_calls_prefix <>
         Integer.to_string(limit) <> @max_calls_middle <> alias_name <> @max_calls_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec max_calls_message?(term()) :: boolean()
  def max_calls_message?(message) when is_binary(message) do
    with true <- String.starts_with?(message, @max_calls_prefix),
         true <- String.ends_with?(message, @max_calls_suffix),
         rest_bytes <-
           byte_size(message) - byte_size(@max_calls_prefix) - byte_size(@max_calls_suffix),
         true <- rest_bytes > 0,
         rest <- binary_part(message, byte_size(@max_calls_prefix), rest_bytes),
         [digits, alias_name] <- String.split(rest, @max_calls_middle, parts: 2),
         {limit, ""} <- Integer.parse(digits),
         true <- Integer.to_string(limit) == digits,
         {:ok, expected} <- max_calls_message(alias_name, limit) do
      message == expected
    else
      _invalid -> false
    end
  end

  def max_calls_message?(_message), do: false

  defp max_calls_message_branch do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @max_calls_maximum_message_bytes,
      "pattern" =>
        DiagnosticPattern.exact(
          DiagnosticPattern.escape(@max_calls_prefix) <>
            @subordinate_limit_pattern <>
            DiagnosticPattern.escape(@max_calls_middle) <>
            @alias_schema_pattern <>
            DiagnosticPattern.escape(@max_calls_suffix)
        )
    }
  end

  @doc false
  @spec result_limit_message(term()) :: {:ok, binary()} | :error
  def result_limit_message(limit) do
    with {:ok, row} <- LimitCatalog.fetch(:terminal_result_bytes),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok, @result_limit_prefix <> Integer.to_string(limit) <> @result_limit_suffix}
    else
      _invalid -> :error
    end
  end

  # One lookup from a runtime error's details to the setting it breached and the
  # sentence describing it. The command boundary needs a diagnostic code and a
  # source as well, so it keeps its own dispatch; the Live reporter needs only
  # these two, and reading them from one table is what stops the card showing a
  # bare `runtime_limit_exceeded` for a ceiling that can name itself.
  @doc false
  @spec details_message(term()) :: {:ok, binary(), binary()} | :error
  def details_message(%{limit: limit, limit_ms: limit_ms, phase: phase}),
    do: named_limit(limit, live_timeout_message(limit, limit_ms, phase))

  def details_message(%{limit: :subordinate_evaluations, limit_value: value}),
    do: named_limit(:subordinate_evaluations, subordinate_evaluations_message(value))

  def details_message(%{limit: :agent_turns, limit_value: value, limit_reason: reason}),
    do: named_limit(:max_turns, agent_turns_message(value, reason))

  def details_message(%{limit: :max_transcript_chars, limit_value: value}),
    do: named_limit(:max_transcript_chars, transcript_chars_message(value))

  def details_message(%{limit: :terminal_result_bytes, limit_value: value}),
    do: named_limit(:terminal_result_bytes, result_limit_message(value))

  def details_message(%{limit: :workflow_heap_words, limit_value: value}),
    do: named_limit(:workflow_heap_words, heap_words_message(value))

  def details_message(%{limit: :max_calls, alias: alias_name, limit_value: value}),
    do: named_limit(:max_calls, max_calls_message(alias_name, value))

  def details_message(_details), do: :error

  defp named_limit(limit, {:ok, message}), do: {:ok, Atom.to_string(limit), message}
  defp named_limit(_limit, :error), do: :error

  # The refusal a manifest gets for asking above the installed ceiling. Both
  # numbers are the Kernel's own — the request it just decoded and the ceiling
  # the host installed — so nothing here is taken on trust. It names them
  # because the alternative is a reader who cannot see how far they overshot,
  # or which of the two documents to edit.
  @installed_ceiling_middle " exceeds the installed ceiling "
  @installed_ceiling_suffix "; lower the manifest value to at most the ceiling, or raise the ceiling in the host document"
  @installed_ceiling_pattern ~r/^([a-z_]+) ([1-9][0-9]{0,9}) exceeds the installed ceiling ([1-9][0-9]{0,9}); lower the manifest value to at most the ceiling, or raise the ceiling in the host document$/

  @doc false
  @spec installed_ceiling_message(term(), term(), term()) :: {:ok, binary()} | :error
  def installed_ceiling_message(name, requested, ceiling) do
    with {:ok, %{scope: :manifest_narrowable} = row} <- LimitCatalog.fetch(name),
         true <- LimitCatalog.valid_value?(row, requested),
         true <- LimitCatalog.valid_value?(row, ceiling),
         true <- requested > ceiling do
      {:ok,
       row.name <>
         " " <>
         Integer.to_string(requested) <>
         @installed_ceiling_middle <>
         Integer.to_string(ceiling) <> @installed_ceiling_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec installed_ceiling_message?(term()) :: boolean()
  def installed_ceiling_message?(message) when is_binary(message) do
    case Regex.run(@installed_ceiling_pattern, message) do
      [_all, name, requested, ceiling] ->
        installed_ceiling_message(
          name,
          String.to_integer(requested),
          String.to_integer(ceiling)
        ) == {:ok, message}

      _no_match ->
        false
    end
  end

  def installed_ceiling_message?(_message), do: false

  @doc false
  @spec installed_ceiling_message_schema(binary()) :: map()
  def installed_ceiling_message_schema(fallback) when is_binary(fallback) do
    branches =
      for row <- LimitCatalog.rows(:manifest_narrowable) do
        bounded_branch(
          byte_size(row.name) + 1 + @subordinate_maximum_digits +
            byte_size(@installed_ceiling_middle) + @subordinate_maximum_digits +
            byte_size(@installed_ceiling_suffix),
          row.name <> " ",
          @subordinate_limit_pattern <>
            DiagnosticPattern.escape(@installed_ceiling_middle) <> @subordinate_limit_pattern,
          @installed_ceiling_suffix
        )
      end

    message_schema(fallback, branches)
  end

  defp build_timeout_message(limit, limit_ms, phase) do
    with {:ok, row} <- LimitCatalog.fetch(limit),
         true <- LimitCatalog.valid_value?(row, limit_ms) do
      {:ok,
       timeout_prefix(limit) <>
         Integer.to_string(limit_ms) <> timeout_suffix(limit, phase)}
    else
      _invalid -> :error
    end
  end

  defp timeout_prefix(limit), do: "#{limit} limit "

  defp timeout_suffix(limit, phase),
    do: " ms was exceeded during #{phase}; raise limits.#{limit}" <> @manifest_remedy

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    subordinate_evaluations_message?(message) or agent_turns_message?(message) or
      transcript_chars_message?(message) or timeout_message?(message) or
      heap_words_message?(message) or max_calls_message?(message)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec agent_turns_message?(term()) :: boolean()
  def agent_turns_message?(message) when is_binary(message) do
    Enum.any?(@agent_reasons, fn {reason, prefix, suffix} ->
      valid_exact_message?(
        message,
        prefix,
        suffix,
        @agent_maximum_digits,
        &agent_turns_message(&1, reason)
      )
    end)
  end

  def agent_turns_message?(_message), do: false

  @doc false
  @spec transcript_chars_message?(term()) :: boolean()
  def transcript_chars_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @transcript_prefix,
      @transcript_suffix,
      @transcript_maximum_digits,
      &transcript_chars_message/1
    )
  end

  def transcript_chars_message?(_message), do: false

  @doc false
  @spec run_duration_message?(term()) :: boolean()
  def run_duration_message?(message) when is_binary(message) do
    Enum.any?(@timeout_phases, fn phase ->
      valid_exact_message?(
        message,
        timeout_prefix(:run_duration_ms),
        timeout_suffix(:run_duration_ms, phase),
        @subordinate_maximum_digits,
        &live_timeout_message(:run_duration_ms, &1, phase)
      )
    end)
  end

  def run_duration_message?(_message), do: false

  @doc false
  @spec result_limit_message?(term()) :: boolean()
  def result_limit_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @result_limit_prefix,
      @result_limit_suffix,
      @subordinate_maximum_digits,
      &result_limit_message/1
    )
  end

  def result_limit_message?(_message), do: false

  @doc false
  @spec subordinate_evaluations_message?(term()) :: boolean()
  def subordinate_evaluations_message?(message) when is_binary(message) do
    valid_exact_message?(
      message,
      @subordinate_prefix,
      @subordinate_suffix,
      @subordinate_maximum_digits,
      &subordinate_evaluations_message/1
    )
  end

  def subordinate_evaluations_message?(_message), do: false

  @doc false
  @spec timeout_message?(term()) :: boolean()
  def timeout_message?(message) when is_binary(message) do
    Enum.any?(@timeout_limits, fn limit ->
      Enum.any?(@timeout_phases, fn phase ->
        valid_exact_timeout_message?(message, limit, phase)
      end)
    end)
  end

  def timeout_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    message_schema(
      fallback,
      [subordinate_message_branch()] ++
        agent_message_branches() ++
        [transcript_message_branch()] ++
        timeout_message_branches() ++ [heap_message_branch(), max_calls_message_branch()]
    )
  end

  @doc false
  @spec subordinate_evaluations_message_schema(binary()) :: map()
  def subordinate_evaluations_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [subordinate_message_branch()])

  @doc false
  @spec runtime_message_schema(binary()) :: map()
  def runtime_message_schema(fallback) when is_binary(fallback),
    do:
      message_schema(
        fallback,
        [subordinate_message_branch() | timeout_message_branches()] ++
          [heap_message_branch(), max_calls_message_branch()]
      )

  @doc false
  @spec agent_loop_message_schema(binary()) :: map()
  def agent_loop_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, agent_message_branches() ++ [transcript_message_branch()])

  @doc false
  @spec run_duration_message_schema(binary()) :: map()
  def run_duration_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, run_duration_message_branches())

  @doc false
  @spec result_limit_message_schema(binary()) :: map()
  def result_limit_message_schema(fallback) when is_binary(fallback),
    do: message_schema(fallback, [result_limit_message_branch()])

  defp message_schema(fallback, branches) do
    %{
      "oneOf" => [%{"const" => fallback} | branches]
    }
  end

  defp subordinate_message_branch do
    bounded_branch(
      @subordinate_maximum_message_bytes,
      @subordinate_prefix,
      @subordinate_limit_pattern,
      @subordinate_suffix
    )
  end

  defp result_limit_message_branch do
    bounded_branch(
      @result_limit_maximum_message_bytes,
      @result_limit_prefix,
      @subordinate_limit_pattern,
      @result_limit_suffix
    )
  end

  defp agent_message_branches do
    for {_reason, prefix, suffix} <- @agent_reasons do
      %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => byte_size(prefix) + @agent_maximum_digits + byte_size(suffix),
        "pattern" =>
          DiagnosticPattern.exact(
            DiagnosticPattern.escape(prefix) <>
              @agent_limit_pattern <> DiagnosticPattern.escape(suffix)
          )
      }
    end
  end

  defp heap_message_branch do
    bounded_branch(
      @heap_maximum_message_bytes,
      @heap_prefix,
      @subordinate_limit_pattern,
      @heap_suffix
    )
  end

  defp transcript_message_branch do
    bounded_branch(
      @transcript_maximum_message_bytes,
      @transcript_prefix,
      @transcript_limit_pattern,
      @transcript_suffix
    )
  end

  defp run_duration_message_branches, do: timeout_branches([:run_duration_ms])

  defp timeout_message_branches, do: timeout_branches(@timeout_limits)

  defp timeout_branches(limits) do
    for limit <- limits,
        phase <- @timeout_phases do
      bounded_branch(
        @timeout_maximum_message_bytes,
        timeout_prefix(limit),
        @timeout_value_pattern,
        timeout_suffix(limit, phase)
      )
    end
  end

  # Every branch here is prose wrapped around one integer, and the prose now
  # carries the dotted manifest key. `DiagnosticPattern` escapes only the
  # ECMA-262 metacharacters, so the pattern keeps matching exactly the message
  # its builder produces.
  defp bounded_branch(maximum_bytes, prefix, value_pattern, suffix) do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => maximum_bytes,
      "pattern" =>
        DiagnosticPattern.exact(
          DiagnosticPattern.escape(prefix) <>
            value_pattern <> DiagnosticPattern.escape(suffix)
        )
    }
  end

  defp valid_exact_timeout_message?(message, limit, phase) do
    valid_exact_message?(
      message,
      timeout_prefix(limit),
      timeout_suffix(limit, phase),
      @subordinate_maximum_digits,
      &timeout_message(limit, &1, phase)
    )
  end

  defp valid_exact_message?(message, prefix, suffix, maximum_digits, builder) do
    with true <- String.starts_with?(message, prefix),
         true <- String.ends_with?(message, suffix),
         digits_bytes <- byte_size(message) - byte_size(prefix) - byte_size(suffix),
         true <- digits_bytes in 1..maximum_digits,
         digits <- binary_part(message, byte_size(prefix), digits_bytes),
         {limit, ""} <- Integer.parse(digits),
         true <- Integer.to_string(limit) == digits,
         {:ok, expected} <- builder.(limit) do
      message == expected
    else
      _invalid -> false
    end
  end
end
