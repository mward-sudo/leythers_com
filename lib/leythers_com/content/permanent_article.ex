defmodule LeythersCom.Content.PermanentArticle do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_author_types ~w[ai_editor human_admin]
  @valid_statuses ~w[draft published]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "permanent_articles" do
    field :slug, :string
    field :title, :string
    field :summary, :string
    field :body, :string
    field :author_type, :string, default: "ai_editor"
    field :raw_content_backup, :string
    field :status, :string, default: "published"
    field :version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(article, attrs) do
    article
    |> cast(attrs, [
      :slug,
      :title,
      :summary,
      :body,
      :author_type,
      :raw_content_backup,
      :status,
      :version
    ])
    |> validate_required([:slug, :title, :body])
    |> validate_inclusion(:author_type, @valid_author_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> unique_constraint(:slug)
  end
end
