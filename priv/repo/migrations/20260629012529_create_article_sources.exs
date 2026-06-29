defmodule LeythersCom.Repo.Migrations.CreateArticleSources do
  use Ecto.Migration

  def change do
    create table(:article_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :permanent_article_id,
          references(:permanent_articles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :raw_source_id,
          references(:raw_sources, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:article_sources, [:permanent_article_id])
    create index(:article_sources, [:raw_source_id])
    create unique_index(:article_sources, [:permanent_article_id, :raw_source_id])
  end
end
