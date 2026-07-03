defmodule LeythersCom.Intelligence.LLMInteractionLog do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w[ok error]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "llm_interaction_logs" do
    field :adapter, :string
    field :model, :string
    field :status, :string
    field :attempt, :integer, default: 1
    field :prompt, :string
    field :context, :map, default: %{}
    field :response_text, :string
    field :error_summary, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :adapter,
      :model,
      :status,
      :attempt,
      :prompt,
      :context,
      :response_text,
      :error_summary,
      :metadata
    ])
    |> validate_required([:adapter, :status, :attempt, :prompt, :context, :metadata])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
  end
end
