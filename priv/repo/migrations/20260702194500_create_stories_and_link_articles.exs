defmodule LeythersCom.Repo.Migrations.CreateStoriesAndLinkArticles do
  use Ecto.Migration

  def change do
    create table(:stories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :headline, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:stories, :stories_status_check, check: "status IN ('active', 'archived')")
    create index(:stories, [:status])
    create index(:stories, [:inserted_at])

    alter table(:permanent_articles) do
      add :story_id, references(:stories, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:permanent_articles, [:story_id])
  end
end
