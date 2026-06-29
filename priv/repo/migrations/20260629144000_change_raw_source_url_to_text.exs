defmodule LeythersCom.Repo.Migrations.ChangeRawSourceUrlToText do
  use Ecto.Migration

  def up do
    alter table(:raw_sources) do
      modify :url, :text, null: false
    end
  end

  def down do
    alter table(:raw_sources) do
      modify :url, :string, null: false
    end
  end
end
