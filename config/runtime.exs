# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/trinity start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Slice 001 line 5. `--smoke` implies `server: true`.
#
# Read straight from `:init.get_plain_arguments/0` rather than through `Trinity.Smoke.argv/0`,
# which is the same call: this file is evaluated before the application is available under
# Mix, so it may not call project modules. `Burrito.Util.Args.get_arguments/0` reads the same
# thing.
smoke? =
  "--smoke" in Enum.map(:init.get_plain_arguments(), &to_string/1) or
    System.get_env("TRINITY_SMOKE") == "1"

# Slice 061: the headless profile is a server by definition.
headless? = System.get_env("TRINITY_MODE") == "headless"

if System.get_env("PHX_SERVER") || smoke? || headless? do
  config :trinity, TrinityWeb.Endpoint, server: true
end

# Scoped to :dev at slice 001 line 5. Unscoped, this line runs in every environment and
# **overrides** the port config/test.exs and the :prod block below set, because runtime.exs is
# evaluated last. Measured: with it unscoped, the test endpoint bound 4000 rather than the
# ephemeral port config/test.exs asks for, so a test asserting "the reported port is the port
# that was bound" was passing against a hardcoded default. :prod and :test each set their own
# port for their own reason; only :dev wants a fixed 4000 that PORT can move.
if config_env() == :dev do
  config :trinity, TrinityWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Slice 022: the filesystem roots a session may read and write without asking, beside the
# data directory and the session's working directory: TRINITY_FS_ROOTS, colon-separated.
if roots = System.get_env("TRINITY_FS_ROOTS") do
  config :trinity, :fs, roots: String.split(roots, ":", trim: true)
end

# Slice 022: the search provider's key is read at call time from BRAVE_SEARCH_API_KEY; the
# provider module is configuration so a fake can stand in.
if config_env() != :test do
  config :trinity, :web, search_provider: Trinity.Tools.Web.SearchProvider.Brave
end

# Slice 062: the MCP authorization profile. `TRINITY_MCP_AUTH_PROFILE` is `local` (the default:
# 061's static bearer on the loopback, no JWT anywhere), `production` (an OAuth 2.1 resource
# server against the external authorization server `TRINITY_MCP_AUTH_ISSUER` names, for this
# server's identifier `TRINITY_MCP_AUTH_RESOURCE`, its `/mcp` URL; Trinity issues nothing) or
# `personal` (the same resource server plus the embedded authorization server on the owner's
# machine; refused at boot under an external authority adapter). `TRINITY_MCP_AUTH_INTROSPECTION=1`
# asks the issuer about opaque tokens (RFC 7662) instead of validating JWTs, with
# `TRINITY_MCP_AUTH_INTROSPECTION_CLIENT` and `_SECRET` as the resource server's credentials when
# the issuer wants them; `TRINITY_MCP_AUTH_DCR=1` enables RFC 7591 registration (the embedded
# server's endpoint; the client role's registration when an issuer offers it);
# `TRINITY_MCP_AUTH_CLIENT_ID` is the client role's pre-registered identity at the enterprise
# authorization server, `TRINITY_MCP_AUTH_CLIENT_METADATA_URL` its Client ID Metadata Document.
# The suite sets `config :trinity, :mcp_auth` itself (docs/07-security-model.md).
auth_profile = System.get_env("TRINITY_MCP_AUTH_PROFILE")

if config_env() != :test and auth_profile not in [nil, ""] do
  present = fn name ->
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  introspection_credentials =
    case {present.("TRINITY_MCP_AUTH_INTROSPECTION_CLIENT"),
          present.("TRINITY_MCP_AUTH_INTROSPECTION_SECRET")} do
      {id, secret} when is_binary(id) and is_binary(secret) -> {id, secret}
      _ -> nil
    end

  profile_atom =
    case auth_profile do
      "local" -> :local
      "production" -> :production
      "personal" -> :personal
      other -> raise "TRINITY_MCP_AUTH_PROFILE is not local, production or personal: #{other}"
    end

  config :trinity, :mcp_auth,
    profile: profile_atom,
    issuer: present.("TRINITY_MCP_AUTH_ISSUER"),
    resource: present.("TRINITY_MCP_AUTH_RESOURCE"),
    audience: present.("TRINITY_MCP_AUTH_AUDIENCE"),
    introspection: System.get_env("TRINITY_MCP_AUTH_INTROSPECTION") in ["1", "true"],
    introspection_credentials: introspection_credentials,
    dcr: System.get_env("TRINITY_MCP_AUTH_DCR") in ["1", "true"],
    client_id: present.("TRINITY_MCP_AUTH_CLIENT_ID"),
    client_metadata_url: present.("TRINITY_MCP_AUTH_CLIENT_METADATA_URL")
end

# Slice 013. `TRINITY_FAKE_PROVIDER=1 mix phx.server` runs the chat on the scripted provider:
# the registry becomes the fake's two entries and a fresh stream answers with its markdown
# demo, so the UI can be exercised and screenshotted with no key and no egress. Development
# only; the test registry is config/test.exs and production never reads this variable.
if config_env() == :dev and System.get_env("TRINITY_FAKE_PROVIDER") in ["1", "true"] do
  config :trinity, :llm,
    default_model: "fake:chat",
    providers: %{fake: Trinity.LLM.Providers.Fake},
    retry: [attempts: 3, base_ms: 1],
    models: [
      %{
        id: "fake:chat",
        provider: :fake,
        model: "chat",
        caps: [:stream, :tools, :json],
        price: %{input: 1.0, output: 2.0}
      },
      %{
        id: "fake:slow",
        provider: :fake,
        model: "chat",
        caps: [:stream, :tools, :json],
        price: %{input: 1.0, output: 2.0}
      }
    ]

  config :trinity, Trinity.LLM.Providers.Fake, script: :demo
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :trinity, TrinityWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/trinity_web/router\.ex$"E,
        ~r"lib/trinity_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Slice 001 line 5. A packaged binary is double-clicked with no environment prepared for it,
  # so the generator's "raise if DATABASE_PATH is missing" is right for a server deployment and
  # fatal for a desktop app. The env var still wins where someone sets it; the fallback is the
  # per-OS data directory `Trinity.Paths` resolves, which is the only place a desktop app has
  # any business writing to.
  database_path = System.get_env("DATABASE_PATH") || Trinity.Paths.database_path()

  # Slice 010: the pool size is 1 by config/config.exs and is not read from the environment
  # here, because a larger pool on SQLite is a second writer waiting on busy_timeout, not
  # capacity. A Postgres build sets its own size below.
  config :trinity, Trinity.Repo, database: database_path

  # Slice 024: the receipts file beside it, the same way.
  config :trinity, Trinity.Repo.Receipts,
    database: System.get_env("RECEIPTS_DATABASE_PATH") || Trinity.Paths.receipts_database_path()

  if System.get_env("TRINITY_DB") == "postgres" do
    config :trinity, Trinity.Repo,
      url: System.get_env("DATABASE_URL") || raise("TRINITY_DB=postgres needs DATABASE_URL"),
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # Slice 032: pgvector's `vector` type.
      types: Trinity.Repo.PostgrexTypes

    config :trinity, Trinity.Repo.Receipts,
      url: System.get_env("DATABASE_URL"),
      pool_size: 2
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # Slice 001 line 5, and the same reasoning: a double-clicked binary has no SECRET_KEY_BASE.
  #
  # The fallback is generated fresh on every boot and **written nowhere**. That is a deliberate
  # limit, not an oversight: sessions and signed cookies do not survive a restart of the
  # packaged app. Persisting a secret means writing a credential to the user's disk and
  # deciding its file mode, its rotation and what happens when it is copied to another machine
  # (a decision of that kind belongs to the operator, and the desktop keychain is later work
  # session story. A spike that quietly invented a credential store would be the larger sin.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  host = System.get_env("PHX_HOST") || "example.com"

  config :trinity, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Slice 001 line 5. A desktop app binds the loopback on an ephemeral port and tells the shell
  # which one it got; it does not listen on every interface, and a spike that shipped
  # `{0,0,0,0,0,0,0,0}` in a binary users double-click would be putting a Phoenix app on their
  # LAN without asking. PORT still wins where it is set, which is how ex_tauri drives it.
  desktop_port = String.to_integer(System.get_env("PORT") || "0")

  # Slice 061: the headless profile binds the address it is told (`TRINITY_BIND`, loopback by
  # default: a server on a LAN is the operator's decision, made by setting it) on `PORT`,
  # 4000 by default, since nobody reads an ephemeral port off a headless machine. The bearer
  # on /mcp (`TRINITY_MCP_SERVER_TOKEN`, or the generated token file) is required whatever
  # the bind; the web pages carry no authentication yet, which is why the default stays on
  # the loopback (docs/mcp-server.md).
  {bind_ip, bind_port} =
    if System.get_env("TRINITY_MODE") == "headless" do
      ip =
        case System.get_env("TRINITY_BIND", "127.0.0.1")
             |> String.to_charlist()
             |> :inet.parse_address() do
          {:ok, ip} ->
            ip

          {:error, _} ->
            raise "TRINITY_BIND is not an IP address: #{System.get_env("TRINITY_BIND")}"
        end

      {ip, String.to_integer(System.get_env("PORT") || "4000")}
    else
      {{127, 0, 0, 1}, desktop_port}
    end

  config :trinity, TrinityWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_ip, port: bind_port],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :trinity, TrinityWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :trinity, TrinityWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
