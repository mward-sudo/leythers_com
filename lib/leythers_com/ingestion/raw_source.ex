defmodule LeythersCom.Ingestion.RawSource do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w[pending processed ignored]
  @valid_check_statuses ~w[ok redirected broken]
  @valid_enrichment_statuses ~w[queued in_progress ready failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "raw_sources" do
    field :title, :string
    field :url, :string
    field :body_summary, :string
    field :content, :string
    field :origin_provider, :string
    field :external_published_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :enrichment_status, :string, default: "queued"
    field :enrichment_failure_count, :integer, default: 0
    field :enrichment_failure_reason, :string
    field :last_checked_at, :utc_datetime_usec
    field :last_check_status, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(raw_source, attrs) do
    raw_source
    |> cast(attrs, [
      :title,
      :url,
      :body_summary,
      :content,
      :origin_provider,
      :external_published_at,
      :status,
      :enrichment_status,
      :enrichment_failure_count,
      :enrichment_failure_reason,
      :last_checked_at,
      :last_check_status
    ])
    |> validate_required([:title, :url, :origin_provider, :external_published_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:enrichment_status, @valid_enrichment_statuses)
    |> validate_number(:enrichment_failure_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:last_check_status, @valid_check_statuses,
      message: "must be one of: ok, redirected, broken"
    )
    |> unique_constraint(:url)
  end
end
