defmodule LeythersCom.Content do
  @moduledoc """
  Content context for creating and querying permanent articles.
  """

  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Slug
  alias LeythersCom.Repo

  def create_article(attrs) do
    %PermanentArticle{}
    |> PermanentArticle.changeset(attrs)
    |> Repo.insert()
  end

  def publish_article(attrs, source_ids \\ []) do
    title = fetch_attr(attrs, :title) || ""
    body = fetch_attr(attrs, :body)
    {:ok, slug} = Slug.unique_for_title(title)

    article_attrs = %{
      title: title,
      body: body,
      slug: slug,
      author_type: "human_admin",
      status: "published",
      version: 1
    }

    Repo.transaction(fn ->
      with {:ok, article} <- create_article(article_attrs),
           :ok <- insert_article_sources(article.id, source_ids) do
        article
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, article} -> {:ok, article}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_article!(id), do: Repo.get!(PermanentArticle, id)

  def get_article_by_slug(slug) do
    case Repo.get_by(PermanentArticle, slug: slug) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  def list_articles(opts \\ []) do
    import Ecto.Query

    PermanentArticle
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    import Ecto.Query
    where(query, [a], a.status == ^status)
  end

  defp insert_article_sources(_article_id, []), do: :ok

  defp insert_article_sources(article_id, source_ids) do
    source_ids
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.reduce_while(:ok, fn raw_source_id, :ok ->
      case Repo.insert(
             ArticleSource.changeset(%ArticleSource{}, %{
               permanent_article_id: article_id,
               raw_source_id: raw_source_id
             })
           ) do
        {:ok, _article_source} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp blank?(value), do: value in [nil, ""]
end
