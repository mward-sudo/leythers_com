defmodule LeythersCom.Ingestion do
  @moduledoc """
  Ingestion context for creating and querying normalized raw sources.
  """

  import Ecto.Query

  alias LeythersCom.Ingestion.Providers.Basic
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Repo

  def create_raw_source(attrs) do
    attrs
    |> Basic.normalize()
    |> then(&(%RawSource{} |> RawSource.changeset(&1)))
    |> Repo.insert()
  end

  def upsert_raw_source(attrs) do
    attrs = Basic.normalize(attrs)
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    changeset = RawSource.changeset(%RawSource{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :url) do
      {:ok, _} ->
        {:ok, Repo.get_by!(RawSource, url: url)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_raw_source!(id), do: Repo.get!(RawSource, id)

  def list_raw_sources(opts \\ []) do
    RawSource
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def record_raw_source_health(%RawSource{} = raw_source, attrs) when is_map(attrs) do
    raw_source
    |> RawSource.changeset(Basic.normalize(attrs))
    |> Repo.update()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)
end
