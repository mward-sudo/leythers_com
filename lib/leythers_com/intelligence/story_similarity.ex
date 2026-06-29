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
      similarity >= threshold
    end
  end

  def similar?(_title_a, _title_b, _threshold), do: false

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
end
