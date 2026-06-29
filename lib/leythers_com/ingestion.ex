defmodule LeythersCom.Ingestion do
  import Ecto.Query

  alias LeythersCom.Repo
  alias LeythersCom.Ingestion.RawSource

  def create_raw_source(attrs) do
    %RawSource{}
    |> RawSource.changeset(attrs)
    |> Repo.insert()
  end

  def upsert_raw_source(attrs) do
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

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)
end
