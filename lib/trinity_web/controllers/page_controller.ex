defmodule TrinityWeb.PageController do
  use TrinityWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
