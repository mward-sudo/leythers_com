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

  @default_options [
    llm_enabled: false,
    llm_max_comparisons: 0,
    llm_timeout_ms: 3_000,
    deterministic_merge_threshold: 0.78,
    deterministic_reject_threshold: 0.45,
    llm_grouping_min_jaccard: 0.0,
    similarity_classifier: nil
  ]

  def cluster_by_topic(sources, opts \\ []) when is_list(sources) and is_list(opts) do
    config =
      @default_options
      |> Keyword.merge(opts)
      |> normalize_cluster_config()

    {clusters, _remaining_budget} =
      Enum.reduce(sources, {[], config.llm_max_comparisons}, fn source, {clusters, llm_budget} ->
        add_to_best_matching_cluster(clusters, source, config, llm_budget)
      end)

    clusters
  end

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp add_to_best_matching_cluster([], source, _config, llm_budget), do: {[[source]], llm_budget}

  defp add_to_best_matching_cluster(clusters, source, config, llm_budget) do
    {updated_clusters, matched?, remaining_budget} =
      Enum.reduce(clusters, {[], false, llm_budget}, fn cluster, {acc, matched, budget} ->
        {should_merge?, updated_budget} =
          if matched do
            {false, budget}
          else
            cluster_similarity_match?(source, cluster, config, budget)
          end

        if should_merge? do
          {[cluster ++ [source] | acc], true, updated_budget}
        else
          {[cluster | acc], matched, updated_budget}
        end
      end)

    if matched? do
      {Enum.reverse(updated_clusters), remaining_budget}
    else
      {Enum.reverse([[source] | updated_clusters]), remaining_budget}
    end
  end

  defp cluster_similarity_match?(source, cluster, config, llm_budget) do
    Enum.reduce_while(cluster, {false, llm_budget}, fn cluster_source, {_, budget} ->
      {is_similar?, updated_budget} = topic_similar?(source, cluster_source, config, budget)

      if is_similar? do
        {:halt, {true, updated_budget}}
      else
        {:cont, {false, updated_budget}}
      end
    end)
  end

  defp topic_similar?(source_a, source_b, config, llm_budget) do
    comparison = deterministic_similarity(source_a, source_b, config)

    cond do
      comparison.merge? ->
        {true, llm_budget}

      comparison.reject? ->
        {false, llm_budget}

      llm_budget <= 0 ->
        {false, llm_budget}

      comparison.jaccard < config.llm_grouping_min_jaccard ->
        {false, llm_budget}

      config.llm_enabled ->
        {llm_topic_similar?(source_a, source_b, config), llm_budget - 1}

      true ->
        {false, llm_budget}
    end
  end

  defp deterministic_similarity(source_a, source_b, config) do
    title_a = source_a.title || ""
    title_b = source_b.title || ""
    text_a = similarity_text(source_a)
    text_b = similarity_text(source_b)

    title_score = StorySimilarity.score(title_a, title_b)
    text_score = StorySimilarity.score(text_a, text_b)
    jaccard = keyword_jaccard_similarity(text_a, text_b)

    strongest = max(title_score, max(text_score, jaccard))

    %{
      strongest: strongest,
      jaccard: jaccard,
      merge?: strongest >= config.deterministic_merge_threshold,
      reject?: strongest < config.deterministic_reject_threshold
    }
  end

  defp similarity_text(source) do
    [source.title, source.content, source.body_summary]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp keyword_jaccard_similarity(text_a, text_b) do
    keywords_a = extract_keywords(text_a)
    keywords_b = extract_keywords(text_b)

    union_size = MapSet.union(keywords_a, keywords_b) |> MapSet.size()

    if union_size == 0 do
      0.0
    else
      intersection_size = MapSet.intersection(keywords_a, keywords_b) |> MapSet.size()
      intersection_size / union_size
    end
  end

  defp llm_topic_similar?(source_a, source_b, config) do
    classifier = config.similarity_classifier

    if is_function(classifier, 2) do
      classifier.(source_a, source_b)
    else
      llm_topic_similar_via_adapter(source_a, source_b, config)
    end
  end

  defp llm_topic_similar_via_adapter(source_a, source_b, config) do
    content_a = source_a.content || source_a.body_summary || ""
    content_b = source_b.content || source_b.body_summary || ""
    content_a_len = String.length(content_a)
    content_b_len = String.length(content_b)

    if content_a_len > 30 and content_b_len > 30 do
      call_llm_for_similarity(source_a.title, content_a, source_b.title, content_b, config)
    else
      keyword_similar_fallback?(source_a.title, source_b.title)
    end
  end

  defp call_llm_for_similarity(title_a, content_a, title_b, content_b, config) do
    prompt = semantic_comparison_prompt(title_a, content_a, title_b, content_b)

    log_context = %{
      source_a: %{title: title_a, content_excerpt: String.slice(content_a, 0, 300)},
      source_b: %{title: title_b, content_excerpt: String.slice(content_b, 0, 300)}
    }

    case run_with_timeout(
           fn ->
             LLMClient.generate(prompt,
               log_context: log_context,
               log_metadata: %{purpose: "source_cluster_similarity"}
             )
           end,
           config.llm_timeout_ms
         ) do
      {:ok, {:ok, %{text: text}}} -> parse_llm_response(text)
      {:ok, {:error, reason}} -> raise "llm_unavailable: #{inspect(reason)}"
      :timeout -> raise "llm_unavailable: timeout"
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

  defp normalize_cluster_config(opts) do
    llm_enabled = Keyword.get(opts, :llm_enabled, false)

    llm_max_comparisons =
      opts
      |> Keyword.get(:llm_max_comparisons, if(llm_enabled, do: 6, else: 0))
      |> normalize_non_negative_int()

    %{
      llm_enabled: llm_enabled,
      llm_max_comparisons: llm_max_comparisons,
      llm_timeout_ms:
        opts
        |> Keyword.get(:llm_timeout_ms, llm_comparison_timeout_ms())
        |> normalize_positive_int(llm_comparison_timeout_ms()),
      deterministic_merge_threshold: Keyword.get(opts, :deterministic_merge_threshold, 0.78),
      deterministic_reject_threshold: Keyword.get(opts, :deterministic_reject_threshold, 0.45),
      llm_grouping_min_jaccard: Keyword.get(opts, :llm_grouping_min_jaccard, 0.0),
      similarity_classifier: Keyword.get(opts, :similarity_classifier)
    }
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp normalize_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_int(_value), do: 0
end
