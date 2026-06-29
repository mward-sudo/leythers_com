defmodule LeythersCom.Ingestion.Providers.Basic do
  @moduledoc """
  Default provider adapter for normalized source attrs.
  """

  @behaviour LeythersCom.Ingestion.Provider

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

  @impl true
  def normalize(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> trim_string_fields()
    |> normalize_url()
  end

  defp stringify_keys(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp trim_string_fields(attrs) do
    Enum.reduce(
      ["title", "body_summary", "origin_provider"],
      attrs,
      fn key, acc ->
        case Map.fetch(acc, key) do
          {:ok, value} when is_binary(value) -> Map.put(acc, key, String.trim(value))
          _ -> acc
        end
      end
    )
  end

  defp normalize_url(attrs) do
    case Map.fetch(attrs, "url") do
      {:ok, url} -> Map.put(attrs, "url", canonicalize_url(url))
      :error -> attrs
    end
  end

  defp canonicalize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} = uri ->
        URI.to_string(uri)

      %URI{query: query} = uri ->
        query =
          query
          |> URI.decode_query()
          |> Enum.reject(fn {key, _value} -> key in @tracking_query_params end)
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> URI.encode_query()

        uri
        |> Map.put(:query, empty_query_to_nil(query))
        |> URI.to_string()
    end
  end

  defp empty_query_to_nil(""), do: nil
  defp empty_query_to_nil(query), do: query
end
