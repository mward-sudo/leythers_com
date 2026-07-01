defmodule LeythersCom.Intelligence.HomepageRanker do
  @moduledoc """
  Hybrid homepage ranking using deterministic recency plus sparse LLM
  importance scoring with cooldown-based caching.
  """

  alias LeythersCom.Intelligence.LLMClient

  @cache_table :leythers_com_homepage_rank_cache

  @default_config [
    llm_enabled: true,
    llm_candidate_limit: 1,
    llm_cooldown_seconds: 1_800,
    llm_timeout_ms: 2_500,
    recency_weight: 0.45,
    importance_weight: 0.55,
    max_age_hours: 72
  ]

  def rank(entries, opts \\ []) when is_list(entries) do
    started_at = System.monotonic_time()
    config = config() |> Keyword.merge(opts)
    now = DateTime.utc_now()

    ranked =
      entries
      |> Enum.sort_by(&recency_score(&1, now, config), :desc)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        llm_candidate? = index < config[:llm_candidate_limit]
        score_entry(entry, llm_candidate?, now, config)
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

  defp score_entry(entry, llm_candidate?, now, config) do
    recency = recency_score(entry, now, config)

    {importance, importance_source} =
      entry
      |> importance_score(llm_candidate?, config)
      |> normalize_importance_score()

    hybrid =
      (recency * config[:recency_weight] + importance * config[:importance_weight])
      |> Float.round(2)

    entry
    |> Map.put(:recency_score, recency)
    |> Map.put(:importance_score, importance)
    |> Map.put(:importance_source, importance_source)
    |> Map.put(:hybrid_score, hybrid)
  end

  defp importance_score(entry, true, config) do
    if config[:llm_enabled] do
      cached_or_generated_importance(entry, config)
    else
      {:deterministic, deterministic_importance(entry)}
    end
  end

  defp importance_score(entry, false, _config),
    do: {:deterministic, deterministic_importance(entry)}

  defp cached_or_generated_importance(entry, config) do
    article_id = entry.article.id
    cooldown = config[:llm_cooldown_seconds]

    case cached_importance(article_id, cooldown) do
      {:ok, source, score} ->
        {normalize_cached_source(source), score}

      :miss ->
        {source, score} = generate_importance(entry, config)
        put_cached_importance(article_id, score, source)
        {source, score}
    end
  end

  defp generate_importance(entry, config) do
    case config[:importance_generator] do
      generator when is_function(generator, 1) ->
        run_generator_with_timeout(generator, entry, config)

      _ ->
        run_llm_with_timeout(entry, config)
    end
  end

  defp run_generator_with_timeout(generator, entry, config) do
    timeout_ms = config[:llm_timeout_ms]

    case run_with_timeout(fn -> generator.(entry) end, timeout_ms) do
      {:ok, score} -> {:llm_generated, score}
      :timeout -> raise "llm_unavailable: timeout"
    end
  end

  defp run_llm_with_timeout(entry, config) do
    timeout_ms = config[:llm_timeout_ms]
    prompt = importance_prompt(entry)

    case run_with_timeout(fn -> LLMClient.generate(prompt) end, timeout_ms) do
      {:ok, {:ok, %{text: text}}} ->
        case parse_importance_score(text) do
          nil -> raise "llm_unavailable: invalid_importance_response"
          parsed_score -> {:llm_generated, parsed_score}
        end

      {:ok, {:error, reason}} ->
        raise "llm_unavailable: #{inspect(reason)}"

      :timeout ->
        raise "llm_unavailable: timeout"
    end
  end

  defp run_with_timeout(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> :timeout
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

  defp recency_score(entry, now, config) do
    timestamp = publication_timestamp(entry, now)
    age_seconds = DateTime.diff(now, timestamp, :second)
    age_hours = max(age_seconds / 3600, 0)
    max_age_hours = config[:max_age_hours]

    score = 100 * max(0.0, 1.0 - age_hours / max_age_hours)
    Float.round(score, 2)
  end

  defp publication_timestamp(%{sources: sources, article: article}, now) do
    publication_dates =
      sources
      |> Enum.map(fn
        %{external_published_at: timestamp} -> timestamp
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case publication_dates do
      [] -> article.updated_at || article.inserted_at || now
      dates -> Enum.max_by(dates, &DateTime.to_unix/1)
    end
  end

  defp publication_timestamp(%{article: article}, now),
    do: article.updated_at || article.inserted_at || now

  defp clamp_score(score) when is_integer(score), do: score |> max(0) |> min(100)
  defp clamp_score(score) when is_float(score), do: score |> round() |> clamp_score()
  defp clamp_score(_score), do: 50

  defp normalize_importance_score({source, score}) do
    {clamp_score(score), source}
  end

  defp cached_importance(article_id, cooldown_seconds) do
    ensure_cache_table!()
    now_seconds = System.system_time(:second)

    case :ets.lookup(@cache_table, article_id) do
      [{^article_id, score, source, saved_at}] ->
        if now_seconds - saved_at <= cooldown_seconds do
          {:ok, source, score}
        else
          :miss
        end

      [{^article_id, score, saved_at}] ->
        if now_seconds - saved_at <= cooldown_seconds do
          {:ok, :llm_generated, score}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp put_cached_importance(article_id, score, source) do
    ensure_cache_table!()
    :ets.insert(@cache_table, {article_id, score, source, System.system_time(:second)})
    :ok
  end

  defp normalize_cached_source(:llm_generated), do: :llm_cached
  defp normalize_cached_source("llm_generated"), do: :llm_cached
  defp normalize_cached_source(_source), do: :deterministic

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
