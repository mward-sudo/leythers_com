defmodule LeythersCom.Repo.Migrations.AddContentToRawSources do
  use Ecto.Migration

  def change do
    alter table(:raw_sources) do
      add :content, :text, null: true
    end
  end
end
