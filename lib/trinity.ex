defmodule Trinity do
  # DataCase and NetworkGuard live in test/support, which is compiled only in :test, so the
  # export list is environment-dependent. TrinityWeb.ConnCase crosses the boundary to reach
  # DataCase, and the live-tagged tests reach NetworkGuard.
  use Boundary,
    deps: [],
    exports: if(Mix.env() == :test, do: [DataCase, NetworkGuard], else: [])

  @moduledoc """
  Trinity keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end
