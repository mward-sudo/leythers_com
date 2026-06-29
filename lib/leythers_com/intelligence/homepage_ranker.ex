defmodule LeythersCom.Intelligence.HomepageRanker do
  @moduledoc """
  Hybrid homepage ranking using deterministic recency plus sparse LLM
  importance scoring with cooldown-based caching.
  """

  alias LeythersCom.Intelligence.LLMClient

  @cache_table :leythers_com_homepage_rank_cache

  @default_config [
    llm_enabled: true,
    llm_candidate_limit: 4,
    llm_cooldown_seconds: 1_800,
    recency_weight: 0.45,
    importance_weight: 0.55,
    max_age_hours: 72
  ]

  def rank(entries, opts \\ []) when is_list(entries) do
    started_at = System.monotonic_time()
    config = config() |> Keyword.merge(opts)

    ranked =
      entries
      |> Enum.sort_by(&recency_score(&1.article, DateTime.utc_now(), config), :desc)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        llm_candidate? = index < config[:llm_candidate_limit]
        score_entry(entry, llm_candidate?, config)
      end)
      |> Enum.sort_by(& &1.hybrid_score, :desc)

    emit_ranker_telemetry(ranked, started_at)
    ranked
  end

  def clear_cache! do
    ensure_cache_table!()
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  defp score_entry(entry, llm_candidate?, config) do
    now = DateTime.utc_now()
    recency = recency_score(entry.article, now, config)

    importance =
      importance_score(entry, llm_candidate?, config)
      |> clamp_score()

    hybrid =
      (recency * config[:recency_weight] + importance * config[:importance_weight])
      |> Float.round(2)

    entry
    |> Map.put(:recency_score, recency)
    |> Map.put(:importance_score, importance)
    |> Map.put(:hybrid_score, hybrid)
  end

  defp importance_score(entry, true, config) do
    if config[:llm_enabled] do
      cached_or_generated_importance(entry, config)
    else
      deterministic_importance(entry)
    end
  end

  defp importance_score(entry, false, _config), do: deterministic_importance(entry)

  defp cached_or_generated_importance(entry, config) do
    article_id = entry.article.id
    cooldown = config[:llm_cooldown_seconds]

    case cached_importance(article_id, cooldown) do
      {:ok, score} ->
        score

      :miss ->
        score = generate_importance(entry, config)
        put_cached_importance(article_id, score)
        score
    end
  end

  defp generate_importance(entry, config) do
    case config[:importance_generator] do
      generator when is_function(generator, 1) ->
        generator.(entry)

      _ ->
        prompt = importance_prompt(entry)

        case LLMClient.generate(prompt) do
          {:ok, %{text: text}} -> parse_importance_score(text) || deterministic_importance(entry)
          {:error, _reason} -> deterministic_importance(entry)
        end
    end
  end

  defp parse_importance_score(text) when is_binary(text) do
    case Regex.run(~r/\b(100|[1-9]?\d)\b/, text) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp parse_importance_score(_), do: nil

  defp importance_prompt(entry) do
    article = entry.article
    source_count = length(entry.sources)

    """
    Score homepage importance from 0 to 100 for Leigh Leopards supporters.
    Return only an integer.

    Title: #{article.title}
    Source count: #{source_count}
    Status: #{article.status}
    """
  end

  defp deterministic_importance(entry) do
    article = entry.article
    source_count_bonus = min(length(entry.sources) * 10, 40)
    authored_bonus = if article.author_type == "human_admin", do: 8, else: 0
    rumour_penalty = if rumour_article?(article.title), do: 10, else: 0

    50 + source_count_bonus + authored_bonus - rumour_penalty
  end

  defp rumour_article?(title) when is_binary(title),
    do: String.starts_with?(String.downcase(title), "rumour:")

  defp rumour_article?(_title), do: false

  defp recency_score(article, now, config) do
    timestamp = article.updated_at || article.inserted_at || now
    age_seconds = DateTime.diff(now, timestamp, :second)
    age_hours = max(age_seconds / 3600, 0)
    max_age_hours = config[:max_age_hours]

    score = 100 * max(0.0, 1.0 - age_hours / max_age_hours)
    Float.round(score, 2)
  end

  defp clamp_score(score) when is_integer(score), do: score |> max(0) |> min(100)
  defp clamp_score(score) when is_float(score), do: score |> round() |> clamp_score()
  defp clamp_score(_score), do: 50

  defp cached_importance(article_id, cooldown_seconds) do
    ensure_cache_table!()
    now_seconds = System.system_time(:second)

    case :ets.lookup(@cache_table, article_id) do
      [{^article_id, score, saved_at}] ->
        if now_seconds - saved_at <= cooldown_seconds do
          {:ok, score}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp put_cached_importance(article_id, score) do
    ensure_cache_table!()
    :ets.insert(@cache_table, {article_id, score, System.system_time(:second)})
    :ok
  end

  defp ensure_cache_table! do
    case :ets.whereis(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])
      _tid -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp emit_ranker_telemetry(ranked, started_at) do
    :telemetry.execute(
      [:leythers_com, :intelligence, :homepage_ranking, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: :ok, article_count: length(ranked)}
    )
  end

  defp config do
    Application.get_env(:leythers_com, :homepage_ranking, @default_config)
    |> Keyword.merge(@default_config, fn _key, left, _right -> left end)
  end
end
