defmodule LeythersCom.Content.Articles do
  @moduledoc false

  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Story
  alias LeythersCom.Repo

  def create_article(attrs) do
    attrs = maybe_put_story_id(attrs)

    %PermanentArticle{}
    |> PermanentArticle.changeset(attrs)
    |> Repo.insert()
  end

  def update_article(%PermanentArticle{} = article, attrs) when is_map(attrs) do
    attrs = maybe_increment_article_version(article, attrs)

    article
    |> PermanentArticle.changeset(attrs)
    |> Repo.update()
  end

  def get_article!(id), do: Repo.get!(PermanentArticle, id)

  def get_article_by_slug(slug) do
    case Repo.get_by(PermanentArticle, slug: slug) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  defp maybe_increment_article_version(
         %PermanentArticle{status: "published", version: version},
         attrs
       )
       when is_integer(version) do
    put_version_update(attrs, version + 1)
  end

  defp maybe_increment_article_version(_article, attrs), do: attrs

  defp put_version_update(attrs, next_version) when map_size(attrs) == 0 do
    Map.put(attrs, :version, next_version)
  end

  defp put_version_update(attrs, next_version) do
    keys = Map.keys(attrs)

    cond do
      Enum.all?(keys, &is_atom/1) ->
        Map.put(attrs, :version, next_version)

      Enum.all?(keys, &is_binary/1) ->
        Map.put(attrs, "version", next_version)

      true ->
        attrs
        |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
        |> Map.put("version", next_version)
    end
  end

  defp maybe_put_story_id(attrs) when is_map(attrs) do
    has_story_id? = Map.has_key?(attrs, :story_id) or Map.has_key?(attrs, "story_id")
    title = fetch_story_headline(attrs)

    case {has_story_id?, blank?(title)} do
      {true, _} ->
        attrs

      {false, true} ->
        attrs

      {false, false} ->
        case create_story(title) do
          {:ok, story} -> Map.put(attrs, :story_id, story.id)
          {:error, _reason} -> attrs
        end
    end
  end

  defp maybe_put_story_id(attrs), do: attrs

  defp fetch_story_headline(attrs) do
    fetch_attr(attrs, :title) || fetch_attr(attrs, :headline) || ""
  end

  defp create_story(title) when is_binary(title) do
    %Story{}
    |> Story.changeset(%{headline: String.slice(String.trim(title), 0, 200), status: "active"})
    |> Repo.insert()
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp blank?(value), do: value in [nil, ""]
end
