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
  # Tools and Permissions sub-boundaries and, until 024, `Effects.Catalog` (now
  # `Tools.Catalog`, exported by Tools). Slice 024 exports Repo.Receipts (the Receipts
  # boundary writes it), CorePolicy (the boot receipt reads it) and the Receipts, Authority
  # and Effects sub-boundaries.
  use Boundary,
    deps: [],
    exports:
      [
        Paths,
        Repo,
        Repo.Receipts,
        UUID,
        Config,
        Sessions,
        Sessions.Message,
        Sessions.SessionRow,
        Sessions.Prompt,
        Personas,
        Context,
        Context.AgentsMd,
        LLM,
        Memory,
        Memory.Tokens,
        Memory.Search,
        Memory.AlwaysOn,
        Memory.Budget,
        Memory.Consolidator,
        Memory.Entry,
        Memory.Proposal,
        Memory.Change,
        Tools,
        Permissions,
        Permissions.Approval,
        Permissions.Rule,
        Effects,
        CorePolicy,
        Receipts,
        Receipts.Receipt,
        Receipts.Checkpoint,
        Receipts.Verifier,
        Receipts.KeyCustody,
        Authority,
        Content.Part
      ] ++
        if(Mix.env() == :test, do: [DataCase, NetworkGuard, Factory], else: [])

  @moduledoc """
  Trinity keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end
