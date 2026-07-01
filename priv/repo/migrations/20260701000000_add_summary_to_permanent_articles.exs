defmodule LeythersCom.Repo.Migrations.AddSummaryToPermanentArticles do
  use Ecto.Migration

  def change do
    alter table(:permanent_articles) do
      add :summary, :text, null: true
    end
  end
end
