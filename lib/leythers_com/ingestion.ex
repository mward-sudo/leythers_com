defmodule LeythersCom.Ingestion do
  @moduledoc """
  Ingestion context for creating and querying normalized raw sources.
  """

  import Ecto.Query

  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Repo

  @tracking_query_params ~w[
    fbclid
    gclid
    mc_cid
    mc_eid
    ref
    ref_src
    utm_campaign
    utm_content
    utm_id
    utm_medium
    utm_source
    utm_term
  ]

  def create_raw_source(attrs) do
    attrs
    |> canonicalize_source_attrs()
    |> then(&(%RawSource{} |> RawSource.changeset(&1)))
    |> Repo.insert()
  end

  def upsert_raw_source(attrs) do
    attrs = canonicalize_source_attrs(attrs)
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

  def canonicalize_source_attrs(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :url) ->
        Map.update!(attrs, :url, &canonicalize_url/1)

      Map.has_key?(attrs, "url") ->
        Map.update!(attrs, "url", &canonicalize_url/1)

      true ->
        attrs
    end
  end

  def canonicalize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} = uri ->
        URI.to_string(uri)

      %URI{query: query} = uri ->
        query
        |> URI.decode_query()
        |> Enum.reject(fn {key, _value} -> key in @tracking_query_params end)
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> URI.encode_query()
        |> then(fn encoded_query ->
          uri
          |> Map.put(:query, if(encoded_query == "", do: nil, else: encoded_query))
          |> URI.to_string()
        end)
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)
end
