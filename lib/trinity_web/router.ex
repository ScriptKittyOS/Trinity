# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Router do
  use TrinityWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TrinityWeb.Layouts, :root}
    plug :protect_from_forgery
    # Slice 013: before put_secure_browser_headers, which keeps a policy already present.
    plug TrinityWeb.Plugs.ContentSecurityPolicy
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Slice 013: the chat. One local user, so no scope is fetched; the session id is the URL.
  scope "/", TrinityWeb do
    pipe_through :browser

    live_session :chat do
      live "/", SessionLive.Index, :index
      live "/s/:id", SessionLive.Show, :show
      # Slice 021: the approvals audit and the rules.
      live "/permissions", PermissionsLive, :index
      # Slice 031: full-text search over every message.
      live "/search", SearchLive, :index
      # Slice 034: settings, with the export as a download.
      live "/settings", SettingsLive, :index
      get "/settings/export.tar.gz", ExportController, :download
      # Slice 030: personas and the always-on memory.
      live "/personas", PersonasLive, :index
      live "/personas/:id", PersonasLive, :edit
      live "/memory", MemoryLive, :index
      # Slice 040: the skills the registry found.
      live "/skills", SkillsLive, :index
      # Slice 060: the MCP servers and their health.
      live "/mcp", MCPLive, :index
      # Slice 050: scheduled tasks, their runs and the results to read.
      live "/tasks", TasksLive, :index
      # Slice 024: a session's receipt chain, and the boot receipt of this run.
      live "/s/:id/receipts", ReceiptsLive, :session
      live "/receipts/boot", ReceiptsLive, :boot
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", TrinityWeb do
  #   pipe_through :api
  # end

  # Slice 050: Oban's dashboard, in development and wherever `config :trinity, :oban_web` is
  # set (the pages carry no authentication yet; the same rule as every other page).
  if Application.compile_env(:trinity, :dev_routes) ||
       Application.compile_env(:trinity, :oban_web, false) do
    import Oban.Web.Router

    scope "/" do
      pipe_through :browser
      oban_dashboard("/oban", csp_nonce_assign_key: :csp_nonce)
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:trinity, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TrinityWeb.Telemetry, csp_nonce_assign_key: :csp_nonce
    end
  end
end
