# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity do
  # DataCase and NetworkGuard live in test/support, which is compiled only in :test, so the
  # export list is environment-dependent. TrinityWeb.ConnCase crosses the boundary to reach
  # DataCase, and the live-tagged tests reach NetworkGuard. Slice 010 exports Paths (the
  # application locks the data directory before the Repo starts), Repo and UUID (the contexts
  # use them), and the Sessions sub-boundary: a context TrinityWeb may call (docs/01). Slice
  # 013 exports the schemas the chat renders, `Sessions.Message` and `Sessions.SessionRow`,
  # which the Sessions boundary exports itself; Store stays inside. Slice 020 exports the
  # Tools and Permissions sub-boundaries and `Effects.Catalog`, a plain module of this
  # boundary the tool registry reads (Effects becomes its own boundary at 024).
  use Boundary,
    deps: [],
    exports:
      [
        Paths,
        Repo,
        UUID,
        Config,
        Sessions,
        Sessions.Message,
        Sessions.SessionRow,
        LLM,
        Tools,
        Permissions,
        Effects.Catalog
      ] ++
        if(Mix.env() == :test, do: [DataCase, NetworkGuard, Factory], else: [])

  @moduledoc """
  Trinity keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end
