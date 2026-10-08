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

  # Slice 136: every page needs a principal with `view` (TrinityWeb.Auth.Gate in the endpoint has
  # already refused a request with none). Every route that pipes through :browser pipes through
  # this too, except the login pages, which are the only HTML served without a principal; the
  # route census (test/trinity_web/auth/route_census_test.exs) holds that.
  pipeline :viewer do
    plug TrinityWeb.Auth.RequireRole, :view
  end

  # Slice 136: the privileged routes. Each use and each refusal is receipted with the principal.
  pipeline :administer do
    plug TrinityWeb.Auth.RequireRole, :administer
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Slice 062: the OAuth surfaces a client or another server reads without a browser session
  # (metadata, keys, the token and registration endpoints; the body form-encoded or JSON).
  pipeline :oauth do
    plug :accepts, ["json"]
  end

  scope "/", TrinityWeb do
    pipe_through :oauth

    get "/.well-known/oauth-protected-resource", OAuthController, :protected_resource
    get "/.well-known/oauth-protected-resource/*path", OAuthController, :protected_resource
    get "/.well-known/oauth-authorization-server", OAuthController, :authorization_server
    get "/.well-known/jwks.json", OAuthController, :jwks
    post "/oauth/token", OAuthController, :token
    post "/oauth/register", OAuthController, :register
  end

  # Slice 136: the login (OIDC or the shared token), its callback, the logout.
  scope "/auth", TrinityWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    get "/callback", AuthController, :callback
    post "/token", AuthController, :token
    post "/logout", AuthController, :logout
    get "/forbidden", AuthController, :forbidden
  end

  # Slice 013: the chat. The session id is the URL.
  # Slice 136: every live route mounts through `TrinityWeb.Auth.on_mount/4`, which checks the
  # principal on mount, on every patch and on every event (TrinityWeb.Auth.Policy names the role
  # each event needs).
  scope "/", TrinityWeb do
    pipe_through [:browser, :viewer]

    live_session :chat, on_mount: [{TrinityWeb.Auth, :view}] do
      live "/", SessionLive.Index, :index
      live "/s/:id", SessionLive.Show, :show
      # Slice 021: the approvals audit and the rules.
      live "/permissions", PermissionsLive, :index
      # Slice 031: full-text search over every message.
      live "/search", SearchLive, :index
      # Slice 090: what Trinity has been doing, and what it has cost.
      live "/activity", ActivityLive, :index
      # Slice 034: settings, with the export as a download.
      live "/settings", SettingsLive, :index
      # Slice 100: the first-run path, reusing the settings components.
      live "/setup", SetupLive, :index
      # Slice 030: personas and the always-on memory.
      live "/personas", PersonasLive, :index
      live "/personas/:id", PersonasLive, :edit
      live "/memory", MemoryLive, :index
      # Slice 040: the skills the registry found.
      live "/skills", SkillsLive, :index
      # Slice 060: the MCP servers and their health.
      live "/mcp", MCPLive, :index
      # Slice 070: the channels Trinity can be reached from, and who may.
      live "/gateways", GatewaysLive, :index
      # Slice 050: scheduled tasks, their runs and the results to read.
      live "/tasks", TasksLive, :index
      # Slice 024: a session's receipt chain, and the boot receipt of this run.
      live "/s/:id/receipts", ReceiptsLive, :session
      live "/receipts/boot", ReceiptsLive, :boot
    end
  end

  # Slice 136: the privileged routes, `administer` and receipted.
  scope "/", TrinityWeb do
    pipe_through [:browser, :viewer, :administer]

    # Slice 034: the export as a download; `keys=1` carries the private keys.
    get "/settings/export.tar.gz", ExportController, :download

    # Slice 062: the owner's pages of the authorization flows (a session and CSRF: the consent
    # is a form the owner submits; the callback lands in the browser).
    get "/oauth/authorize", OAuthController, :authorize
    post "/oauth/consent", OAuthController, :consent
    get "/oauth/callback", OAuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", TrinityWeb do
  #   pipe_through :api
  # end

  # Slice 050: Oban's dashboard, in development and wherever `config :trinity, :oban_web` is
  # set. Slice 136: `administer`, by the pipeline and again on mount.
  if Application.compile_env(:trinity, :dev_routes) ||
       Application.compile_env(:trinity, :oban_web, false) do
    import Oban.Web.Router

    scope "/" do
      pipe_through [:browser, :viewer, :administer]

      oban_dashboard("/oban",
        csp_nonce_assign_key: :csp_nonce,
        on_mount: [{TrinityWeb.Auth, :administer}]
      )
    end
  end

  # Enable LiveDashboard in development. Slice 136: `administer`, by the pipeline and on mount.
  if Application.compile_env(:trinity, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :viewer, :administer]

      live_dashboard "/dashboard",
        metrics: TrinityWeb.Telemetry,
        csp_nonce_assign_key: :csp_nonce,
        on_mount: [{TrinityWeb.Auth, :administer}],
        # Slice 090: which session processes are alive and what state each machine is in.
        additional_pages: [trinity_sessions: TrinityWeb.Dashboard.SessionsPage]
    end
  end
end
