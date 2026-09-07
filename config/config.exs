# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Written by `mix ex_tauri.install`; the reasoning is mine, moved here from config/dev.exs
# when the generator put the same keys in this file. All environments, because
# `ExTauri.ShutdownManager` runs in the packaged binary as well as in development.
#
# `:version` is the **Tauri** version and only its major is consumed —
# `ExTauri.Install.Helpers.extract_cli_version/1` takes the major and installs
# `tauri-cli ^<major>`, which resolved to 2.11.4 on 2026-09-06 (VERSIONS.md carries that row
# with its deriving command). 2.5.1 is ex_tauri's own suggested value, kept so this file does
# not invent a pin the library does not use.
config :ex_tauri, app_name: "Trinity", host: "localhost", port: 4000, version: "2.5.1"

config :trinity,
  ecto_repos: [Trinity.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :trinity, TrinityWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TrinityWeb.ErrorHTML, json: TrinityWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Trinity.PubSub,
  live_view: [signing_salt: "HZOW4v9g"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  trinity: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  trinity: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
