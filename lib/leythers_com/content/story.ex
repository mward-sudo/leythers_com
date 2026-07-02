defmodule LeythersCom.Content.Story do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w[active archived]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stories" do
    field :headline, :string
    field :status, :string, default: "active"

    has_many :articles, LeythersCom.Content.PermanentArticle

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(story, attrs) do
    story
    |> cast(attrs, [:headline, :status])
    |> validate_required([:headline])
    |> validate_length(:headline, min: 3, max: 200)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
