defmodule PtcRunner.Kernel.EvaluationObservation do
  @moduledoc """
  Builds bounded, non-authoritative observations for an agent turn.

  Continued values stay committed in subordinate history, but only the
  structural preview built here crosses into the outer workflow evaluator.
  Preview generation cannot change the evaluation outcome or continuation
  effect.
  """

  alias PtcRunner.Lisp.ValuePreview

  @max_preview_bytes_per_char 4
  @print_share_chars 512

  @spec project(map(), pos_integer()) :: map()
  def project(%{outcome: :continued} = evaluation, max_chars)
      when is_integer(max_chars) and max_chars > 0 do
    observation = success(evaluation, max_chars)

    evaluation
    |> Map.delete(:value)
    |> Map.delete(:prints)
    |> Map.put(:observation, observation.text)
    |> Map.put(:preview, %{
      truncated?: observation.truncated?,
      caps_hit: observation.caps_hit,
      sampled_keys: observation.sampled_keys,
      prints_truncated?: observation.prints_truncated?
    })
  rescue
    _error ->
      evaluation
      |> Map.delete(:value)
      |> Map.delete(:prints)
      |> Map.put(:observation, "user=> #<preview unavailable>")
      |> Map.put(:preview, %{
        truncated?: true,
        caps_hit: [:output],
        sampled_keys: [],
        prints_truncated?: Map.get(evaluation, :prints, []) != []
      })
  end

  # A returned value normally terminates the run, but a phased agent retains a
  # non-final return as transcript evidence, so it needs the same bounded
  # observation. The value stays: the caller still completes the run with it
  # when this is the final phase.
  def project(%{outcome: :returned} = evaluation, max_chars)
      when is_integer(max_chars) and max_chars > 0 do
    observation = success(evaluation, max_chars)

    evaluation
    |> Map.put(:observation, observation.text)
    |> Map.put(:preview, %{
      truncated?: observation.truncated?,
      caps_hit: observation.caps_hit,
      sampled_keys: observation.sampled_keys,
      prints_truncated?: observation.prints_truncated?
    })
  rescue
    _error ->
      evaluation
      |> Map.put(:observation, "user=> #<preview unavailable>")
      |> Map.put(:preview, %{
        truncated?: true,
        caps_hit: [:output],
        sampled_keys: [],
        prints_truncated?: Map.get(evaluation, :prints, []) != []
      })
  end

  def project(evaluation, _max_chars), do: evaluation

  @doc false
  @spec success(map(), pos_integer()) :: map()
  def success(evaluation, max_chars) when is_map(evaluation) and max_chars > 0 do
    prefix = "user=> "

    if max_chars <= String.length(prefix) do
      %{
        text: prefix |> take_graphemes(max_chars) |> elem(0),
        truncated?: true,
        caps_hit: [:output],
        sampled_keys: [],
        prints_truncated?: Map.get(evaluation, :prints, []) != []
      }
    else
      render_success(evaluation, max_chars, prefix)
    end
  end

  defp render_success(evaluation, max_chars, prefix) do
    prints = Map.get(evaluation, :prints, [])
    print_reserve = if(prints == [], do: 0, else: min(div(max_chars, 3), @print_share_chars))
    value_chars = max(max_chars - String.length(prefix) - print_reserve, 1)

    preview =
      ValuePreview.render_with_notice(Map.get(evaluation, :value),
        max_chars: value_chars,
        max_bytes: max(value_chars * @max_preview_bytes_per_char, value_chars)
      )

    initial = prefix <> preview.text
    {text, prints_truncated?} = append_prints(initial, prints, max_chars)

    %{
      text: text,
      truncated?: preview.truncated? or prints_truncated?,
      caps_hit: preview.caps_hit ++ if(prints_truncated?, do: [:prints], else: []),
      sampled_keys: preview.sampled_keys,
      prints_truncated?: prints_truncated?
    }
  end

  defp append_prints(text, [], _max_chars), do: {text, false}

  defp append_prints(text, prints, max_chars) do
    heading = "\nprintln:\n"

    case append_fragment(text, heading, max_chars) do
      {:ok, with_heading} -> append_print_entries(with_heading, prints, max_chars, true)
      :full -> {text, true}
    end
  end

  defp append_print_entries(text, [], _max_chars, _first?), do: {text, false}

  defp append_print_entries(text, [print | rest], max_chars, first?) do
    separator = if(first?, do: "", else: "\n")

    safe_print =
      if is_binary(print) and String.valid?(print),
        do: String.replace(print, "</untrusted_ptc_output>", "</untrusted_ptc_output (escaped)>"),
        else: ""

    case append_fragment(text, separator <> safe_print, max_chars) do
      {:ok, next} -> append_print_entries(next, rest, max_chars, false)
      :full -> {text, true}
    end
  end

  defp append_fragment(text, fragment, max_chars) do
    remaining = max_chars - String.length(text)

    if remaining <= 0 do
      :full
    else
      case take_graphemes(fragment, remaining) do
        {^fragment, false} -> {:ok, text <> fragment}
        {_prefix, true} -> :full
      end
    end
  end

  defp take_graphemes(text, limit), do: take_graphemes(text, limit, [])

  defp take_graphemes("", _limit, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), false}

  defp take_graphemes(rest, 0, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest != ""}

  defp take_graphemes(text, limit, acc) do
    case String.next_grapheme(text) do
      {grapheme, rest} -> take_graphemes(rest, limit - 1, [grapheme | acc])
      nil -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), false}
    end
  end
end
