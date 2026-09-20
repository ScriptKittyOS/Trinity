# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestReceipts.BypassInserter do
  @moduledoc """
  A planted second insert path into `receipts` (slice 024, ADR-0013's census). It exists so
  the census test has something to name: a module that writes a receipt row without going
  through `Trinity.Receipts.ChainWriter`. Never called by product code.
  """

  @doc "Inserts a row directly. The census must flag this call."
  def insert(row), do: Trinity.Repo.Receipts.insert(row)
end
