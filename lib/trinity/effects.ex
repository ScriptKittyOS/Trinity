# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects do
  @moduledoc """
  The membrane (slice 024, docs/07): the one side-effect boundary every `:artifact` and
  `:catalog` effect crosses. A module, not a process; it holds no state. Filled in at G1
  line 6; this file opens the boundary so the boot receipt and the catalog have a home.
  """
  use Boundary,
    deps: [Trinity, Trinity.Tools, Trinity.Permissions, Trinity.Authority, Trinity.Receipts],
    exports: [Boot]
end
