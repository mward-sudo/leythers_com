defmodule LeythersCom.Content.ArticleSource do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "article_sources" do
    field :permanent_article_id, :binary_id
    field :raw_source_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(article_source, attrs) do
    article_source
    |> cast(attrs, [:permanent_article_id, :raw_source_id])
    |> validate_required([:permanent_article_id])
  end
end
