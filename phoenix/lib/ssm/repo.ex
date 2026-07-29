defmodule Ssm.Repo do
  use Ecto.Repo,
    otp_app: :ssm,
    adapter: Ecto.Adapters.SQLite3
end
