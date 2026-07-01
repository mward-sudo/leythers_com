defmodule LeythersCom.Intelligence.RuntimeSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intelligence_runtime_settings" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> validate_length(:key, min: 1, max: 100)
    |> validate_length(:value, min: 1, max: 255)
    |> unique_constraint(:key)
  end
end
