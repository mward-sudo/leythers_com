defmodule LeythersCom.Intelligence.StorySimilarity do
  @moduledoc false

  @stopwords MapSet.new([
               "a",
               "an",
               "and",
               "are",
               "as",
               "at",
               "be",
               "for",
               "from",
               "in",
               "into",
               "is",
               "it",
               "of",
               "on",
               "or",
               "the",
               "to",
               "with"
             ])

  @default_threshold 0.5

  def similar?(title_a, title_b, threshold \\ @default_threshold)

  def similar?(title_a, title_b, threshold)
      when is_binary(title_a) and is_binary(title_b) and is_number(threshold) do
    tokens_a = token_set(title_a)
    tokens_b = token_set(title_b)

    if MapSet.size(tokens_a) == 0 or MapSet.size(tokens_b) == 0 do
      false
    else
      similarity = jaccard_similarity(tokens_a, tokens_b)

      similarity >= threshold or
        strong_anchor_overlap?(title_a, title_b, tokens_a, tokens_b)
    end
  end

  def similar?(_title_a, _title_b, _threshold), do: false

  def score(title_a, title_b) when is_binary(title_a) and is_binary(title_b) do
    tokens_a = token_set(title_a)
    tokens_b = token_set(title_b)

    if MapSet.size(tokens_a) == 0 or MapSet.size(tokens_b) == 0 do
      0.0
    else
      jaccard_similarity(tokens_a, tokens_b)
    end
  end

  def score(_title_a, _title_b), do: 0.0

  def token_set(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(MapSet.member?(@stopwords, &1) or String.length(&1) <= 1))
    |> MapSet.new()
  end

  def token_set(_title), do: MapSet.new()

  defp jaccard_similarity(set_a, set_b) do
    intersection_size =
      set_a
      |> MapSet.intersection(set_b)
      |> MapSet.size()

    union_size =
      set_a
      |> MapSet.union(set_b)
      |> MapSet.size()

    if union_size == 0 do
      0.0
    else
      intersection_size / union_size
    end
  end

  defp strong_anchor_overlap?(title_a, title_b, tokens_a, tokens_b) do
    overlap_count =
      tokens_a
      |> MapSet.intersection(tokens_b)
      |> MapSet.size()

    min_size = min(MapSet.size(tokens_a), MapSet.size(tokens_b))

    containment =
      if min_size == 0 do
        0.0
      else
        overlap_count / min_size
      end

    overlap_count >= 4 and containment >= 0.35 and shared_bigram?(title_a, title_b)
  end

  defp shared_bigram?(title_a, title_b) do
    bigrams_a = title_bigrams(title_a)
    bigrams_b = title_bigrams(title_b)

    MapSet.size(MapSet.intersection(bigrams_a, bigrams_b)) > 0
  end

  defp title_bigrams(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(MapSet.member?(@stopwords, &1) or String.length(&1) <= 1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join(&1, " "))
    |> MapSet.new()
  end
end
