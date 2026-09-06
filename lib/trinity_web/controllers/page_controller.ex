# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.PageController do
  use TrinityWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
