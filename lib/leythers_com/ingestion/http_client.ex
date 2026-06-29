defmodule LeythersCom.Ingestion.HttpClient do
  @moduledoc """
  Behaviour for fetching raw source payloads.
  """

  @callback fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
end
