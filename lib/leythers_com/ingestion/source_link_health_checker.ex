defmodule LeythersCom.Ingestion.SourceLinkHealthChecker do
  @moduledoc """
  Checks raw-source link health and records canonical redirects.
  """

  alias LeythersCom.Ingestion

  @http_client LeythersCom.Ingestion.HttpClient.Req

  def check_all_raw_sources(http_client \\ @http_client) do
    Ingestion.list_raw_sources()
    |> Task.async_stream(&check_raw_source(&1, http_client), timeout: :infinity)
    |> Enum.each(fn {:ok, {:ok, _raw_source}} -> :ok end)

    :ok
  end

  def check_raw_source(%{url: url} = raw_source, http_client \\ @http_client)
      when is_binary(url) do
    case http_client.probe(url) do
      {:ok, response} ->
        {:ok, updated_source} =
          Ingestion.record_raw_source_health(raw_source, %{
            last_checked_at: DateTime.utc_now(),
            last_check_status: health_status(url, response),
            url: canonical_target_url(url, response)
          })

        {:ok, updated_source}

      {:error, _reason} ->
        {:ok, updated_source} =
          Ingestion.record_raw_source_health(raw_source, %{
            last_checked_at: DateTime.utc_now(),
            last_check_status: "broken"
          })

        {:ok, updated_source}
    end
  end

  defp health_status(_url, %{status: status}) when status in 200..299, do: "ok"

  defp health_status(url, %{status: status, headers: headers}) when status in 300..399 do
    if redirect_target(url, headers) == url do
      "ok"
    else
      "redirected"
    end
  end

  defp health_status(_url, %{status: _status}), do: "broken"
  defp health_status(_url, _other), do: "ok"

  defp canonical_target_url(url, %{status: status, headers: headers}) when status in 300..399 do
    redirect_target(url, headers)
  end

  defp canonical_target_url(url, _other), do: url

  defp redirect_target(url, headers) do
    case headers do
      %{} = map ->
        Map.get(map, "location")
        |> List.first()
        |> resolve_redirect(url)

      _ ->
        url
    end
  end

  defp resolve_redirect(nil, url), do: url

  defp resolve_redirect(location, url) when is_binary(location) do
    url
    |> URI.merge(location)
    |> URI.to_string()
  end
end
