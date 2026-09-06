# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo do
  use Ecto.Repo,
    otp_app: :trinity,
    adapter: Ecto.Adapters.SQLite3
end
