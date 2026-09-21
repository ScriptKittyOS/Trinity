# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.ApprovalsCarryARequest do
  use Ecto.Migration

  # Slice 060: an approval may carry a server's input request (MRTR: what the server asked
  # for, `inputRequests` as sent) and, once decided, the answer the deciding party gave.
  # Both are absent on an ordinary approval.
  def change do
    alter table(:approvals) do
      add :request, :map
      add :answer, :map
    end
  end
end
