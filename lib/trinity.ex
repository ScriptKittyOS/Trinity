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
  # and Effects sub-boundaries. Slice 032 exports Memory.Semantic, Memory.Retriever and
  # Memory.Embedders.Bumblebee (the memory page's semantic tab and its download action).
  # Slice 025 adds `Trinity.Keys`, which is a top-level boundary with `deps: []` of its own so it
  # stays extractable. It is listed here because this boundary's code calls into it; the arrow
  # points one way and the compiler holds it that way.
  use Boundary,
    deps: [Trinity.Keys],
    exports:
      [
        Paths,
        # Slice 025: the skills staging and the archive export seal through it.
        Vault,
        # Slice 080: the delegate tool and the session view's subagent panel call it.
        Subagents,
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
        Context.SkillsIndex,
        Archive,
        Archive.Layout,
        Archive.Manifest,
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
        Memory.Semantic,
        Memory.Retriever,
        Memory.Embedders.Bumblebee,
        Tools,
        # Slice 060: what the MCP bridge (a top-level boundary) implements and returns.
        Tools.Tool,
        Tools.Context,
        Tools.Result,
        Tools.Untrusted,
        # Slice 061: the MCP server reads the exported entries' definitions and runs calls
        # through the membrane's runner.
        Tools.Registry,
        Effects.Runner,
        Permissions,
        Permissions.Approval,
        Permissions.Rule,
        Effects,
        Skills,
        Skills.Skill,
        Skills.Registry,
        Skills.Sources,
        Skills.Change,
        Skills.Staging,
        Skills.Promotion,
        Skills.Manager,
        Skills.Learn,
        # Slice 050: the tasks page reads and writes the scheduler.
        # Slice 070: the /gateways page reads the channels, the identities and the cap; the
        # scheduler's gateway delivery reaches the adapter through these too. `Gateways` is a
        # boundary of its own under this one, as `Scheduler` is.
        Gateways,
        Gateways.Adapter,
        Gateways.Cap,
        Gateways.Console,
        Gateways.Identities,
        Gateways.Identity,
        Gateways.Router,
        Scheduler,
        Scheduler.Task,
        Scheduler.Run,
        Scheduler.Parse,
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
