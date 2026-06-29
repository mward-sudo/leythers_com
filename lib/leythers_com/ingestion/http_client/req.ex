defmodule LeythersCom.Ingestion.HttpClient.Req do
  @moduledoc """
  Req-backed ingestion HTTP client.
  """

  @behaviour LeythersCom.Ingestion.HttpClient

  @impl true
  def fetch(url) when is_binary(url) do
    case Req.get(url, retry: false) do
      {:ok, resp} -> {:ok, resp.body}
      {:error, reason} -> {:error, reason}
    end
  end
end
