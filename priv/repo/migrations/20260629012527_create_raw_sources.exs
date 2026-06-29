defmodule LeythersCom.Repo.Migrations.CreateRawSources do
  use Ecto.Migration

  def change do
    create table(:raw_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :url, :string, null: false
      add :body_summary, :text
      add :origin_provider, :string, null: false
      add :external_published_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :last_checked_at, :utc_datetime_usec
      add :last_check_status, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:raw_sources, [:url])
    create index(:raw_sources, [:status])
    create index(:raw_sources, [:external_published_at])
    create index(:raw_sources, [:last_check_status])

    create constraint(:raw_sources, :status_values,
             check: "status IN ('pending','processed','ignored')")

    create constraint(:raw_sources, :last_check_status_values,
             check:
               "last_check_status IS NULL OR last_check_status IN ('ok','redirected','broken')")
  end
end
