defmodule LeythersCom.Repo do
  use Ecto.Repo,
    otp_app: :leythers_com,
    adapter: Ecto.Adapters.Postgres
end
