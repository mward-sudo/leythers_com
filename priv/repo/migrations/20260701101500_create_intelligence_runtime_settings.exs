defmodule LeythersCom.Repo.Migrations.CreateIntelligenceRuntimeSettings do
  use Ecto.Migration

  def change do
    create table(:intelligence_runtime_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:intelligence_runtime_settings, [:key])

    create constraint(
             :intelligence_runtime_settings,
             :intelligence_runtime_settings_dev_llm_provider_check,
             check: "key <> 'dev_llm_provider' OR value IN ('openrouter', 'ollama')"
           )
  end
end
