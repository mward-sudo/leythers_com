defmodule LeythersCom.Repo.Migrations.CreatePermanentArticles do
  use Ecto.Migration

  def change do
    create table(:permanent_articles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :author_type, :string, null: false, default: "ai_editor"
      add :raw_content_backup, :text
      add :status, :string, null: false, default: "published"
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:permanent_articles, [:slug])
    create index(:permanent_articles, [:status])
    create index(:permanent_articles, [:author_type])

    create constraint(:permanent_articles, :author_type_values,
             check: "author_type IN ('ai_editor','human_admin')"
           )

    create constraint(:permanent_articles, :status_values,
             check: "status IN ('draft','published')"
           )

    create constraint(:permanent_articles, :version_positive, check: "version >= 1")
  end
end
