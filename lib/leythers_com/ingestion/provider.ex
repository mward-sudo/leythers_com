defmodule LeythersCom.Ingestion.Provider do
  @moduledoc """
  Behaviour for ingestion provider adapters.
  """

  @callback normalize(map()) :: map()
end
