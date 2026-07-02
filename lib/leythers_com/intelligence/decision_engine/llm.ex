defmodule LeythersCom.Intelligence.DecisionEngine.LLM do
  @moduledoc false

  alias LeythersCom.Intelligence.LLMClient

  @default_timeout_ms 2_500

  def decide_similarity_action(attrs, entries, opts \\ [])
      when is_map(attrs) and is_list(entries) do
    shortlist = shortlist_candidates(attrs, entries)

    if shortlist == [] do
      {:error, :no_candidates}
    else
      prompt = build_prompt(attrs, shortlist)
      timeout_ms = Keyword.get(opts, :llm_timeout_ms, @default_timeout_ms)

      case LLMClient.generate(prompt, timeout_ms: timeout_ms) do
        {:ok, %{text: text}} -> parse_decision(text, shortlist)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp shortlist_candidates(attrs, entries) do
    query =
      sanitize_plain_text(Map.get(attrs, :headline, "") <> " " <> Map.get(attrs, :summary, ""))

    entries
    |> Enum.map(fn entry ->
      candidate =
        sanitize_plain_text(Map.get(entry, :headline, "") <> " " <> Map.get(entry, :summary, ""))

      score = token_overlap_score(query, candidate)
      Map.put(entry, :candidate_score, score)
    end)
    |> Enum.sort_by(& &1.candidate_score, :desc)
    |> Enum.take(5)
  end

  defp build_prompt(attrs, shortlist) do
    candidate_json =
      Enum.map(shortlist, fn entry ->
        %{
          article_id: Map.get(entry, :article_id),
          headline: Map.get(entry, :headline, ""),
          summary: Map.get(entry, :summary, "")
        }
      end)
      |> Jason.encode!()

    """
    Decide if this incoming draft should UPDATE one existing article candidate or create NEW.
    Return JSON only with this schema:
    {"action":"update|new","target_article_id":"uuid|null","confidence":0.0,"reason":"text"}

    Incoming headline: #{Map.get(attrs, :headline, "")}
    Incoming summary: #{Map.get(attrs, :summary, "")}

    Candidates JSON:
    #{candidate_json}
    """
  end

  defp parse_decision(text, shortlist) do
    with {:ok, payload} <- decode_json_payload(text),
         {:ok, action} <- parse_action(payload["action"]),
         confidence <- parse_confidence(payload["confidence"]),
         {:ok, target_article_id} <- parse_target(payload["target_article_id"], action, shortlist) do
      {:ok,
       %{
         triage_action: action,
         target_article_id: target_article_id,
         decision_source: "llm",
         decision_confidence: confidence,
         fallback_reason: nil
       }}
    else
      _ -> {:error, :invalid_similarity_decision}
    end
  end

  defp decode_json_payload(text) when is_binary(text) do
    json_candidate =
      text
      |> String.trim()
      |> String.replace_prefix("```json", "")
      |> String.replace_prefix("```", "")
      |> String.replace_suffix("```", "")
      |> String.trim()

    case Regex.run(~r/\{[\s\S]*\}/, json_candidate) do
      [json] -> Jason.decode(json)
      _ -> Jason.decode(json_candidate)
    end
  end

  defp parse_action(action) when is_binary(action) do
    case String.downcase(String.trim(action)) do
      "update" -> {:ok, :update}
      "new" -> {:ok, :new}
      _ -> :error
    end
  end

  defp parse_action(_), do: :error

  defp parse_confidence(value) when is_number(value), do: max(min(value * 1.0, 1.0), 0.0)

  defp parse_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parse_confidence(parsed)
      :error -> 0.0
    end
  end

  defp parse_confidence(_), do: 0.0

  defp parse_target(_target, :new, _shortlist), do: {:ok, nil}

  defp parse_target(target, :update, shortlist) when is_binary(target) do
    normalized = String.trim(target)
    valid_ids = MapSet.new(Enum.map(shortlist, &Map.get(&1, :article_id)))

    if Regex.match?(~r/^[0-9a-fA-F-]{36}$/, normalized) and MapSet.member?(valid_ids, normalized) do
      {:ok, normalized}
    else
      :error
    end
  end

  defp parse_target(_target, :update, _shortlist), do: :error

  defp sanitize_plain_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp token_overlap_score(a, b) do
    set_a = token_set(a)
    set_b = token_set(b)

    if MapSet.size(set_a) == 0 or MapSet.size(set_b) == 0 do
      0.0
    else
      inter = MapSet.size(MapSet.intersection(set_a, set_b))
      union = MapSet.size(MapSet.union(set_a, set_b))
      inter / union
    end
  end

  defp token_set(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) <= 1))
    |> MapSet.new()
  end
end
