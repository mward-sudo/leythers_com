defmodule LeythersCom.Intelligence.SourceClusterer do
  @moduledoc """
  LLM-powered semantic clustering for grouping sources on the same topic.

  Uses the LLM to understand article content holistically, not just headlines.
  Falls back to fast keyword matching only for obvious near-duplicates.
  """

  alias LeythersCom.Intelligence.LLMClient
  alias LeythersCom.Intelligence.StorySimilarity

  defp llm_comparison_timeout_ms do
    Application.get_env(:leythers_com, :llm_comparison_timeout_ms, 3_000)
  end

  def cluster_by_topic(sources) when is_list(sources) do
    Enum.reduce(sources, [], fn source, clusters ->
      add_to_best_matching_cluster(clusters, source)
    end)
  end

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp add_to_best_matching_cluster([], source), do: [[source]]

  defp add_to_best_matching_cluster(clusters, source) do
    {updated_clusters, matched?} =
      Enum.reduce(clusters, {[], false}, fn cluster, {acc, matched} ->
        should_merge? =
          not matched and
            Enum.any?(cluster, fn cluster_source ->
              topic_similar?(source, cluster_source)
            end)

        if should_merge? do
          {[cluster ++ [source] | acc], true}
        else
          {[cluster | acc], matched}
        end
      end)

    if matched? do
      Enum.reverse(updated_clusters)
    else
      Enum.reverse([[source] | updated_clusters])
    end
  end

  defp topic_similar?(source_a, source_b) do
    # Quick check: if titles are nearly identical, definitely same topic
    if StorySimilarity.similar?(source_a.title, source_b.title, 0.75) do
      true
    else
      # Use LLM for semantic understanding of actual content
      llm_topic_similar?(source_a, source_b)
    end
  end

  defp llm_topic_similar?(source_a, source_b) do
    content_a = source_a.content || source_a.body_summary || ""
    content_b = source_b.content || source_b.body_summary || ""
    content_a_len = String.length(content_a)
    content_b_len = String.length(content_b)

    if content_a_len > 30 and content_b_len > 30 do
      call_llm_for_similarity(source_a.title, content_a, source_b.title, content_b)
    else
      keyword_similar_fallback?(source_a.title, source_b.title)
    end
  rescue
    _ -> false
  end

  defp call_llm_for_similarity(title_a, content_a, title_b, content_b) do
    prompt = semantic_comparison_prompt(title_a, content_a, title_b, content_b)

    case run_with_timeout(fn -> LLMClient.generate(prompt) end, llm_comparison_timeout_ms()) do
      {:ok, {:ok, %{text: text}}} -> parse_llm_response(text)
      _ -> false
    end
  end

  defp semantic_comparison_prompt(title_a, content_a, title_b, content_b) do
    # Truncate content to keep prompt reasonable
    content_a_snippet = String.slice(content_a, 0, 300)
    content_b_snippet = String.slice(content_b, 0, 300)

    """
    Are these two rugby news items describing the same topic, match, team development, or story?
    Consider both the headlines AND content. They might use different wording but cover the same event or topic.

    Article 1:
    Headline: #{title_a}
    Content: #{content_a_snippet}

    Article 2:
    Headline: #{title_b}
    Content: #{content_b_snippet}

    Reply with exactly one word: SAME or DIFFERENT
    """
  end

  defp parse_llm_response(text) when is_binary(text) do
    normalized = text |> String.trim() |> String.upcase()

    cond do
      String.starts_with?(normalized, "SAME") -> true
      String.starts_with?(normalized, "YES") -> true
      String.contains?(normalized, "SAME") -> true
      true -> false
    end
  end

  defp parse_llm_response(_), do: false

  defp run_with_timeout(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> :timeout
    end
  end

  # Fallback: quick keyword check when we lack content
  defp keyword_similar_fallback?(title_a, title_b) do
    keywords_a = extract_keywords(title_a)
    keywords_b = extract_keywords(title_b)

    # Both must have team reference and action keyword
    has_team_and_action?(keywords_a) and has_team_and_action?(keywords_b)
  end

  defp has_team_and_action?(keywords) do
    team_keywords = MapSet.new(["leigh", "leopards", "rhinos", "tigers", "saints", "wigan"])
    action_keywords = MapSet.new(["win", "loss", "match", "game", "beat", "draw", "defeat"])

    has_team =
      keywords
      |> MapSet.intersection(team_keywords)
      |> MapSet.size() > 0

    has_action =
      keywords
      |> MapSet.intersection(action_keywords)
      |> MapSet.size() > 0

    has_team and has_action
  end

  defp extract_keywords(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) <= 2))
    |> MapSet.new()
  end

  defp extract_keywords(_), do: MapSet.new()
end
