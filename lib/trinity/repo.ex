defmodule Trinity.Repo do
  use Ecto.Repo,
    otp_app: :trinity,
    adapter: Ecto.Adapters.SQLite3
end
