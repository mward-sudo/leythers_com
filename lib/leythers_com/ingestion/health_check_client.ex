defmodule LeythersCom.Ingestion.HealthCheckClient do
  @moduledoc """
  Behaviour for probing source link health.
  """

  @callback probe(String.t()) :: {:ok, map()} | {:error, term()}
end
